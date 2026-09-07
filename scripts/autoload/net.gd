extends Node
## Net -- LAN / internet co-op session (ENet, host-authoritative).
##
## One player hosts a room (UDP port 7777), the others join by the host's
## IP. All RPCs live here so node paths are identical on every peer; the
## game (group "game") gets plain callbacks:
##     net_event(kind, args, from)          reliable, any peer -> everyone
##     net_player_state(from, ...)          20 Hz, unreliable
##     net_monster_state(...)               20 Hz, host -> clients
## Without a session (`active == false`) every helper is a no-op and the
## game behaves exactly like single player.

signal lobby_changed
signal session_started(seedv: int, level: int)
signal joined_ok
signal join_failed(reason: String)
signal session_closed(reason: String)
signal peer_left(id: int)

const PORT := 7777
const MAX_PLAYERS := 4
const SEND_HZ := 20.0

var active := false
var is_host := false
var in_game := false
var nick := "ОПЕРАТОР"
var peers := {}                 # id -> {"name": String}
var _peer: ENetMultiplayerPeer = null
var _connecting := false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_conn_failed)
	multiplayer.server_disconnected.connect(_on_server_gone)
	var n: Variant = GameSettings.get("net_nick")
	if n != null and str(n) != "":
		nick = str(n)
	else:
		nick = "ОПЕРАТОР-%02d" % (randi() % 90 + 10)


# ------------------------------------------------------------------ queries
func my_id() -> int:
	return multiplayer.get_unique_id() if active else 1


func is_authority() -> bool:
	## True when this instance runs the AI: single player, or the host.
	return not active or is_host


func peer_ids() -> Array:
	var ids: Array = peers.keys()
	ids.sort()
	return ids


func peer_name(id: int) -> String:
	if peers.has(id):
		return str(peers[id].get("name", "?"))
	return "ОПЕРАТОР %d" % id


func local_ips() -> Array[String]:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		var s := str(a)
		if s.find(":") != -1:
			continue                      # IPv6
		if s.begins_with("127.") or s.begins_with("169.254."):
			continue
		out.append(s)
	return out


# ------------------------------------------------------------------ session
func host(port := PORT) -> String:
	leave()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		_peer = null
		return "НЕ УДАЛОСЬ ОТКРЫТЬ ПОРТ %d (код %d)" % [port, err]
	multiplayer.multiplayer_peer = _peer
	active = true
	is_host = true
	in_game = false
	peers = {1: {"name": nick}}
	lobby_changed.emit()
	print("NET host on port %d, local ips=%s" % [port, str(local_ips())])
	return ""


func join(ip: String, port := PORT) -> String:
	leave()
	ip = ip.strip_edges()
	if ip.find(":") != -1 and ip.count(":") == 1:
		var parts := ip.split(":")
		ip = parts[0]
		port = int(parts[1])
	if ip == "":
		return "ВВЕДИТЕ IP ХОСТА"
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(ip, port)
	if err != OK:
		_peer = null
		return "НЕВЕРНЫЙ АДРЕС (код %d)" % err
	multiplayer.multiplayer_peer = _peer
	active = true
	is_host = false
	in_game = false
	_connecting = true
	peers = {}
	print("NET joining %s:%d" % [ip, port])
	return ""


func leave() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	if active:
		multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	active = false
	is_host = false
	in_game = false
	_connecting = false
	peers = {}
	lobby_changed.emit()


func start_game(seedv: int, level: int) -> void:
	## Host only: everybody (host included) builds the same world.
	if not active or not is_host:
		return
	in_game = true
	rpc("_start", seedv, level)


# ------------------------------------------------------------------ sending
func send_event(kind: String, a: Array = []) -> void:
	## Reliable broadcast to everyone, including ourselves (call_local).
	if not active:
		var g := _game()
		if g != null:
			g.net_event(kind, a, 1)
		return
	rpc("ev", kind, a)


func send_event_to(id: int, kind: String, a: Array = []) -> void:
	if not active or id == my_id():
		var g := _game()
		if g != null:
			g.net_event(kind, a, my_id())
		return
	rpc_id(id, "ev", kind, a)


func send_player_state(pos: Vector3, yaw: float, pitch: float, flags: int, vel: Vector3) -> void:
	if active and peers.size() > 1:
		rpc("p_state", pos, yaw, pitch, flags, vel)


func send_monster_state(kind: int, pos: Vector3, yaw: float, st: int, vel: Vector3, target: int, aware: float, flags: int, extra: int) -> void:
	if active and is_host and peers.size() > 1:
		rpc("m_state", kind, pos, yaw, st, vel, target, aware, flags, extra)


# ------------------------------------------------------------------ rpcs
@rpc("any_peer", "reliable")
func _hello(name: String) -> void:
	if not is_host:
		return
	var id := multiplayer.get_remote_sender_id()
	if in_game:
		# no drop-in mid-tape: the world is already built
		_peer.disconnect_peer(id)
		return
	peers[id] = {"name": name}
	rpc("_lobby", peers)
	lobby_changed.emit()
	print("NET peer %d '%s' joined (%d in room)" % [id, name, peers.size()])


@rpc("authority", "reliable")
func _lobby(p: Dictionary) -> void:
	peers = p
	lobby_changed.emit()


@rpc("authority", "call_local", "reliable")
func _start(seedv: int, level: int) -> void:
	in_game = true
	session_started.emit(seedv, level)


@rpc("any_peer", "call_local", "reliable")
func ev(kind: String, a: Array) -> void:
	var from := multiplayer.get_remote_sender_id()
	if from == 0:
		from = my_id()
	var g := _game()
	if g != null:
		g.net_event(kind, a, from)


@rpc("any_peer", "unreliable_ordered")
func p_state(pos: Vector3, yaw: float, pitch: float, flags: int, vel: Vector3) -> void:
	var g := _game()
	if g != null:
		g.net_player_state(multiplayer.get_remote_sender_id(), pos, yaw, pitch, flags, vel)


@rpc("authority", "unreliable_ordered")
func m_state(kind: int, pos: Vector3, yaw: float, st: int, vel: Vector3, target: int, aware: float, flags: int, extra: int) -> void:
	var g := _game()
	if g != null:
		g.net_monster_state(kind, pos, yaw, st, vel, target, aware, flags, extra)


# ------------------------------------------------------------------ callbacks
func _on_peer_connected(id: int) -> void:
	if is_host and in_game:
		_peer.disconnect_peer(id)


func _on_peer_disconnected(id: int) -> void:
	if peers.has(id):
		print("NET peer %d left" % id)
		peers.erase(id)
	if is_host:
		rpc("_lobby", peers)
	lobby_changed.emit()
	peer_left.emit(id)


func _on_connected() -> void:
	_connecting = false
	rpc_id(1, "_hello", nick)
	joined_ok.emit()


func _on_conn_failed() -> void:
	leave()
	join_failed.emit("НЕ УДАЛОСЬ ПОДКЛЮЧИТЬСЯ. ПРОВЕРЬ IP И ПОРТ 7777")


func _on_server_gone() -> void:
	leave()
	session_closed.emit("ХОСТ ОТКЛЮЧИЛСЯ")


func _game() -> Node:
	return get_tree().get_first_node_in_group("game")
