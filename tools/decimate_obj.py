#!/usr/bin/env python3
"""Shrink robot meshes (OBJ or STL, e.g. from Webots / URDF) so Godot can draw
several robots, and write them as OBJ (Godot has no STL importer).

Vertex clustering: vertices are snapped to a cubic grid, merged, and triangles
that collapse are dropped. Output keeps the Webots robot frame (x forward, z up,
meters) and one normal per face (flat shading suits the CAD parts).

  python3 decimate_obj.py IN.obj OUT.obj --cell 0.002
  python3 decimate_obj.py BODY.STL body.obj --cell 0.003
  python3 decimate_obj.py FL_1.STL fl_1.obj --cell 0       (convert only)
"""

import argparse

import numpy as np


def load_stl(path):
    data = open(path, 'rb').read()
    n = int.from_bytes(data[80:84], 'little') if len(data) >= 84 else 0
    if len(data) == 84 + 50 * n:
        rec = np.frombuffer(data, dtype=np.dtype([('n', '<f4', 3), ('v', '<f4', (3, 3)), ('a', '<u2')]),
                            count=n, offset=84)
        tri = rec['v'].astype(np.float64)
    else:  # ASCII STL
        vals = [l.split()[1:4] for l in data.decode(errors='ignore').splitlines() if l.strip().startswith('vertex')]
        tri = np.array(vals, dtype=np.float64).reshape(-1, 3, 3)
    v = tri.reshape(-1, 3)
    return v, np.arange(len(v)).reshape(-1, 3)


def load(path):
    if path.lower().endswith('.stl'):
        return load_stl(path)
    verts, faces = [], []
    with open(path, 'rb') as f:
        for line in f:
            if line.startswith(b'v '):
                verts.append(line[2:].split()[:3])
            elif line.startswith(b'f '):
                faces.append([int(t.split(b'/')[0]) for t in line[2:].split()[:3]])
    return np.array(verts, dtype=np.float64), np.array(faces, dtype=np.int64) - 1


def decimate(v, f, cell):
    key = np.floor(v / cell).astype(np.int64)
    uniq, inv = np.unique(key, axis=0, return_inverse=True)
    inv = inv.reshape(-1)
    # each cluster becomes the mean of its vertices
    nv = np.zeros((len(uniq), 3))
    np.add.at(nv, inv, v)
    nv /= np.bincount(inv, minlength=len(uniq))[:, None]
    nf = inv[f]
    keep = (nf[:, 0] != nf[:, 1]) & (nf[:, 1] != nf[:, 2]) & (nf[:, 0] != nf[:, 2])
    nf = nf[keep]
    # duplicate triangles (same vertex set) from merged coplanar patches
    _, first = np.unique(np.sort(nf, axis=1), axis=0, return_index=True)
    nf = nf[np.sort(first)]
    return nv, nf


def save(path, v, f):
    n = np.cross(v[f[:, 1]] - v[f[:, 0]], v[f[:, 2]] - v[f[:, 0]])
    ln = np.linalg.norm(n, axis=1)
    ok = ln > 1e-14
    f, n = f[ok], n[ok] / ln[ok, None]
    idx = np.arange(1, len(f) + 1)
    with open(path, 'w') as out:
        out.write('# decimated by robomaster_gui_node/tools/decimate_obj.py\n')
        np.savetxt(out, v, fmt='v %.5f %.5f %.5f')
        np.savetxt(out, n, fmt='vn %.4f %.4f %.4f')
        cols = np.column_stack([f[:, 0] + 1, idx, f[:, 1] + 1, idx, f[:, 2] + 1, idx])
        np.savetxt(out, cols, fmt='f %d//%d %d//%d %d//%d')
    return len(f)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('src')
    p.add_argument('dst')
    p.add_argument('--cell', type=float, default=0.002, help='cluster size [m]')
    a = p.parse_args()
    v, f = load(a.src)
    # cell 0: only weld identical vertices (format conversion)
    nv, nf = decimate(v, f, a.cell if a.cell > 0 else 1e-6)
    n = save(a.dst, nv, nf)
    print(f'{a.src}: {len(f)} -> {n} triangles, {len(v)} -> {len(nv)} vertices')


if __name__ == '__main__':
    main()
