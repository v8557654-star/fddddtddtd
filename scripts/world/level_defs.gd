class_name LevelDefs
extends RefCounted
## Static table of the game's levels (both are GLB maps from
## github.com/v8557654-star/models). Index = level id.

const LEVELS := [
	{
		"id": 0,
		"name": "LEVEL 0",
		"title": "УРОВЕНЬ 0 — «ВЕСТИБЮЛЬ»",
		"path": "res://models/original_backrooms.glb",
		"scale": 1.35,
		"lamp_step": 5.0,          # metres between ceiling lamps
		"lamp_on": 0.74,           # chance a lamp still works
		"pickups": 6,              # almond water + batteries scattered
		"chairs": 12,              # set dressing: toppled chairs / paper on the floor
		"papers": 16,
		"intensity": 1.0,          # hallucination frequency multiplier
		"objective": "ЦЕЛЬ: НАЙДИ ДВЕРЬ НА НИЖНИЙ УРОВЕНЬ",
		"intro": "Уровень 0. Где-то здесь есть дверь — она ведёт глубже.",
		"door_is_exit": false,
	},
	{
		"id": 1,
		"name": "LEVEL 1",
		"title": "УРОВЕНЬ 1 — «БЕСКОНЕЧНЫЙ ОФИС»",
		"path": "res://models/level1_big.glb",
		"scale": 0.34,
		"lamp_step": 6.5,
		"lamp_on": 0.62,
		"pickups": 14,
		"chairs": 26,
		"papers": 34,
		"intensity": 1.45,
		"objective": "ЦЕЛЬ: НАЙДИ АВАРИЙНЫЙ ВЫХОД",
		"intro": "Уровень 1. Стены здесь длиннее, а лампы — реже. Ищи аварийный выход.",
		"door_is_exit": false,
		"door_style": "iron",
	},
	{
		"id": 2,
		"name": "LEVEL 2",
		"title": "УРОВЕНЬ 2 — «ЗАКУЛИСЬЕ»",
		"path": "res://models/backstage.glb",
		"scale": 1.0,
		"lamp_step": 7.0,
		"lamp_on": 0.45,
		"lamp_energy": 1.5,        # pale walls: dimmer tubes
		"pickups": 3,
		"chairs": 9,
		"papers": 12,
		"intensity": 0.45,
		"objective": "ЦЕЛЬ: ИДИ ВПЕРЁД. НАЙДИ ВЫХОД",
		"intro": "Уровень 2. Закулисье. Пахнет пылью, ржавчиной и чем-то ещё.",
		"door_is_exit": false,       # v7: the red door now drops you into Level 3
		"door_red": true,
		# scripted encounter (see scripts/world/backstage_script.gd); positions are
		# in the GLB's own coordinates, converted by CustomMap.glb_to_world()
		"scripted": "backstage",
		"fine_walls": true,
		"cull_glb": [[33.3, 3.6, -0.2, 34.45, 6.2, 0.5]],   # cabinet blocking the corridor mouth
		"spawn_glb": [-11.5, 0.0],
		"spawn_yaw_deg": -90.0,       # face +X, down the hall
		"door_glb": [65.0, 0.3],       # far wall, straight in line with the corridor
		"crate_glb": [57.5, -3.4],     # in the back room, just past the corridor mouth
		"chase_x_glb": 31.0,           # crossing this X (hall end) starts the chase
		"corridor_z_glb": 0.3,
	},
	{
		"id": 3,
		"name": "LEVEL 3",
		"title": "УРОВЕНЬ 3 — «ЯМА»",
		"path": "res://models/level7.glb",
		"scale": 0.45,
		"lamp_step": 6.0,
		"lamp_on": 0.6,
		"lamp_energy": 2.6,
		"pickups": 5,
		"chairs": 0,
		"papers": 10,
		"intensity": 0.7,
		"objective": "ЦЕЛЬ: НАЙДИ КЛЮЧ ОТ ЖЕЛЕЗНОЙ ДВЕРИ",
		"intro": "Уровень 3. Яма. Лабиринт под открытым небом, которого нет. Где-то здесь лестница наверх.",
		"door_is_exit": false,
		"door_style": "iron",
		# quest director: scripts/world/level7_script.gd
		"scripted": "level7",
		"fine_walls": true,
		"wall_clear": 0.37,          # cell is solid within this many metres of a wall
		# the maze is a pit under a giant terrain mesh: keep only the pit
		"cull_above_glb": 24.0,      # drop meshes whose lowest point is above this (glb y)
		"clip_glb": [-63.5, -173.7, 97.3, 112.7],   # x0, z0, x1, z1 (glb): drop meshes entirely outside
		"floor_y_glb": 13.04,
		"ceiling_h": 4.3,            # procedural lid over the open maze (m, world)
		"ceiling_hole_glb": [89.9, -30.0, 96.5, -18.7],   # the stair shaft
		"albedo_min": 0.42,          # lift the export's pitch-black albedo factors
		"spawn_glb": [8.5, -34.6],
		"spawn_yaw_deg": 0.0,
		"key_glb": [-55.2, 61.3],    # far north-west pocket
		"door_glb": [79.16, -45.9],  # iron door in the 1.1 m wall gap at the pocket entrance
		"door_yaw_deg": 0.0,         # wall direction +Z: the visible side faces the player (south)
		"rubble_glb": [95.6, -35.5], # earth pile in the 0.9 m gap between the nook wall and the rim
		"rubble_cells_glb": [[95.6, -36.0], [95.6, -34.5]],
		"door_cells_glb": [[79.0, -46.2], [79.0, -44.5]],
		"stairs_x_glb": 93.2,        # stair shaft: centre x, bottom z (south end), top z (north end)
		"stairs_z0_glb": -33.4,
		"stairs_z1_glb": -19.2,
		"stairs_w": 2.8,
		"chase_from_glb": [86.0, -32.0],   # where the creature is dropped for the final run
	},
	{
		# v9: reached through one of the two tunnels behind the Level 3
		# rubble. No GLB -- scripts/world/run_level.gd builds the tunnel.
		"id": 4,
		"name": "LEVEL 4",
		"title": "УРОВЕНЬ 4 — «БЕГИ ИЛИ УМРИ»",
		"path": "",
		"scale": 1.0,
		"lamp_step": 6.0,
		"lamp_on": 0.8,
		"lamp_energy": 2.4,
		"pickups": 0,
		"chairs": 0,
		"papers": 0,
		"intensity": 0.0,
		"objective": "ЦЕЛЬ: БЕГИ К СВЕТУ. НЕ ОСТАНАВЛИВАЙСЯ",
		"intro": "Уровень 4. Тоннель дрожит. Впереди — белый свет. Сзади — всё, что здесь живёт.",
		"door_is_exit": true,
		"scripted": "run",
		"procedural": "run",
	},
]


static func get_def(i: int) -> Dictionary:
	return LEVELS[clampi(i, 0, LEVELS.size() - 1)]


static func count() -> int:
	return LEVELS.size()
