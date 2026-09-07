#!/usr/bin/env python3
"""Strip a GLB down to the animations / nodes we actually use.

usage: strip_glb.py in.glb out.glb --keep-anim Idle,Walking_A --drop-node Knife,1H_Crossbow
Rebuilds the binary buffer so only referenced bufferViews survive.
"""
import argparse, json, struct, sys


def load(path):
    b = open(path, 'rb').read()
    assert b[:4] == b'glTF'
    ln = struct.unpack('<I', b[12:16])[0]
    j = json.loads(b[20:20 + ln])
    off = 20 + ln
    bl, bt = struct.unpack('<II', b[off:off + 8])
    assert bt == 0x004E4942
    return j, b[off + 8:off + 8 + bl]


def save(path, j, bin_):
    js = json.dumps(j, separators=(',', ':')).encode()
    js += b' ' * ((4 - len(js) % 4) % 4)
    bin_ += b'\0' * ((4 - len(bin_) % 4) % 4)
    total = 12 + 8 + len(js) + 8 + len(bin_)
    with open(path, 'wb') as f:
        f.write(b'glTF' + struct.pack('<II', 2, total))
        f.write(struct.pack('<II', len(js), 0x4E4F534A) + js)
        f.write(struct.pack('<II', len(bin_), 0x004E4942) + bin_)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src'); ap.add_argument('dst')
    ap.add_argument('--keep-anim', default='')
    ap.add_argument('--drop-node', default='')
    a = ap.parse_args()
    j, bin_ = load(a.src)
    keep = set(filter(None, a.keep_anim.split(',')))
    drop = set(filter(None, a.drop_node.split(',')))

    if keep:
        j['animations'] = [an for an in j.get('animations', []) if an.get('name') in keep]
    # drop nodes (unlink from parents + scene, drop their meshes)
    drop_ids = {i for i, n in enumerate(j['nodes']) if n.get('name') in drop}
    for n in j['nodes']:
        if 'children' in n:
            n['children'] = [c for c in n['children'] if c not in drop_ids]
    for s in j['scenes']:
        s['nodes'] = [c for c in s['nodes'] if c not in drop_ids]
    for i in drop_ids:
        j['nodes'][i].pop('mesh', None)
        j['nodes'][i].pop('skin', None)

    # collect used accessors
    used_acc = set()
    used_mesh = {n['mesh'] for n in j['nodes'] if 'mesh' in n}
    for mi, m in enumerate(j['meshes']):
        if mi not in used_mesh:
            continue
        for p in m['primitives']:
            used_acc.update(p['attributes'].values())
            if 'indices' in p:
                used_acc.add(p['indices'])
            for t in p.get('targets', []):
                used_acc.update(t.values())
    for sk in j.get('skins', []):
        if 'inverseBindMatrices' in sk:
            used_acc.add(sk['inverseBindMatrices'])
    for an in j.get('animations', []):
        for s in an['samplers']:
            used_acc.add(s['input']); used_acc.add(s['output'])
    # remap accessors
    acc_map = {}
    new_acc = []
    for i, acc in enumerate(j['accessors']):
        if i in used_acc:
            acc_map[i] = len(new_acc); new_acc.append(acc)
    # used bufferViews
    used_bv = {acc['bufferView'] for acc in new_acc if 'bufferView' in acc}
    for im in j.get('images', []):
        if 'bufferView' in im:
            used_bv.add(im['bufferView'])
    bv_map = {}
    new_bv = []
    out = bytearray()
    for i, bv in enumerate(j['bufferViews']):
        if i not in used_bv:
            continue
        o = bv.get('byteOffset', 0); l = bv['byteLength']
        while len(out) % 4:
            out += b'\0'
        nb = dict(bv); nb['byteOffset'] = len(out); nb['buffer'] = 0
        out += bin_[o:o + l]
        bv_map[i] = len(new_bv); new_bv.append(nb)
    for acc in new_acc:
        if 'bufferView' in acc:
            acc['bufferView'] = bv_map[acc['bufferView']]
    for im in j.get('images', []):
        if 'bufferView' in im:
            im['bufferView'] = bv_map[im['bufferView']]

    def remap_prim(p):
        p['attributes'] = {k: acc_map[v] for k, v in p['attributes'].items()}
        if 'indices' in p:
            p['indices'] = acc_map[p['indices']]
        if 'targets' in p:
            p['targets'] = [{k: acc_map[v] for k, v in t.items()} for t in p['targets']]
    # meshes: keep all entries (indices referenced by nodes) but clear unused ones
    for mi, m in enumerate(j['meshes']):
        if mi in used_mesh:
            for p in m['primitives']:
                remap_prim(p)
        else:
            m['primitives'] = []
    # remove empty meshes and remap node->mesh
    mesh_map = {}
    new_meshes = []
    for mi, m in enumerate(j['meshes']):
        if m['primitives']:
            mesh_map[mi] = len(new_meshes); new_meshes.append(m)
    for n in j['nodes']:
        if 'mesh' in n:
            n['mesh'] = mesh_map[n['mesh']]
    j['meshes'] = new_meshes
    for sk in j.get('skins', []):
        if 'inverseBindMatrices' in sk:
            sk['inverseBindMatrices'] = acc_map[sk['inverseBindMatrices']]
    for an in j.get('animations', []):
        for s in an['samplers']:
            s['input'] = acc_map[s['input']]; s['output'] = acc_map[s['output']]
    j['accessors'] = new_acc
    j['bufferViews'] = new_bv
    j['buffers'] = [{'byteLength': len(out)}]
    save(a.dst, j, bytes(out))
    print(f"{a.src}: anims {len(j.get('animations', []))}, meshes {len(new_meshes)}, "
          f"accessors {len(new_acc)}, bin {len(out)} bytes")


if __name__ == '__main__':
    main()
