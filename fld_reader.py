"""Reads a YSFlight field (.fld) into flat geometry for the viewer, and a ground-height lookup.

Follows YSFlight's own loader and renderer (YSFLIGHT-master/src/scenery/yssceneryio.cpp,
ysscenery.cpp and ysscenerygl2.0.cpp):
  * a field is a tree: PC2 (map: 2D picture lying on the ground), PLT (sign board: 2D picture
    standing up), TER (terrain mesh), FLD (sub-field), RGN (region), GOB (ground object), PST
    (point set, not drawn), SRF (3D shell; not read). Each element has FIL (file) and
    POS x y z h p b, angles in 1/65536 of a circle. `PCK "name" n` embeds the next n lines as a
    file; a sub-field only sees its own embedded files.
  * pictures: PLG polygon (concave ones are split into triangles), QST quad strip, GQS quad strip
    shaded from COL on one edge to CL2 on the other, QDR quads, TRI triangles, PLL line strip, LSQ
    separate lines, PST lights, APL approach lights. A map's 2D point (x, y) -> (x, 0, y); a sign
    board's -> (x, y, 0).
  * maps are painted in order, each over the last, one plane at a time: maps whose planes agree
    within 5 cm form a group; groups come in the order they are first met, a field's own maps
    before its sub-fields' (YsScenery::MakeMapDrawingOrder / DrawMapVisual).
  * terrain (TerrMesh): NBL nx nz blocks of TMS xw zw metres each; (nx+1)*(nz+1) BLO points, point
    (i, j) at (i*xw, y, j*zw). Each block has two flat-coloured triangles; "L" and "R" pick the
    diagonal; flag bit 1 = visible. CBE colours by height instead; BOT/RIG/TOP/LEF add side walls.
    Lighting uses a smooth normal per point (the average of the triangles around it).
  * colours are written as YSFlight shows them in daylight with its default sun: lit surfaces
    get ambient 0.3 + diffuse 0.6 x (normal . sun), so flat ground shows at 82 % of its colour;
    lights are not lit.
  * beyond the map: YSFlight shows the field's ground colour (GND). A black GND (Luavi's) reads as
    a void, so the viewer uses the colour at the map's edge instead: the sea strips that fade
    to GND (GQS with CL2 = GND) keep their COL all the way out, and that COL is the ground
    beyond (or, with no such strips, the colour of the largest picture).
Coordinates stay in YSFlight's frame (x east, y up, z north); the viewer flips z.
"""
import bisect
import json
import math
import os
import re

import weapon_sim   # axes(): YSFlight attitude -> (right, up, forward) unit vectors

ANGLE = math.pi / 32768.0
FORMAT = 3                                  # of the map files; older ones are rebuilt
SUN = (0.0, math.sqrt(3.0) / 2.0, -0.5)     # towards the sun: YSFlight's default (fsconfig.cpp), high in the south
AMBIENT, DIFFUSE = 0.3, 0.6                 # FsSetDirectionalLight, daylight
UP = (0.0, 1.0, 0.0)
SAME_PLANE = 0.05                           # metres


def lit(col, n):
    """A colour as YSFlight draws it on a surface facing n."""
    f = AMBIENT + DIFFUSE * max(0.0, n[0] * SUN[0] + n[1] * SUN[1] + n[2] * SUN[2])
    return [min(255, int(round(v * f))) for v in col]


def _unit(v):
    d = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
    return (v[0] / d, v[1] / d, v[2] / d) if d > 0.0 else None


class Transform:
    """World placement: world = origin + right*x + up*y + forward*z."""
    def __init__(self, origin=(0.0, 0.0, 0.0), axes=((1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0))):
        self.o = origin
        self.a = axes

    def point(self, x, y, z):
        r, u, f = self.a
        return (self.o[0] + r[0] * x + u[0] * y + f[0] * z,
                self.o[1] + r[1] * x + u[1] * y + f[1] * z,
                self.o[2] + r[2] * x + u[2] * y + f[2] * z)

    def vector(self, v):
        r, u, f = self.a
        return (r[0] * v[0] + u[0] * v[1] + f[0] * v[2],
                r[1] * v[0] + u[1] * v[1] + f[1] * v[2],
                r[2] * v[0] + u[2] * v[1] + f[2] * v[2])

    def child(self, pos, att):
        axes = weapon_sim.axes(*att)
        return Transform(self.point(*pos), tuple(self.vector(v) for v in axes))

    def local(self, p):
        d = (p[0] - self.o[0], p[1] - self.o[1], p[2] - self.o[2])
        return tuple(d[0] * v[0] + d[1] * v[1] + d[2] * v[2] for v in self.a)


class Shapes:
    """Triangles, line segments or points: flat lists of coordinates and colours."""
    def __init__(self):
        self.v, self.c = [], []

    def add(self, pts, cols):
        for p, c in zip(pts, cols):
            self.v.extend((round(p[0], 2), round(p[1], 2), round(p[2], 2)))
            self.c.extend(c)

    def count(self, per):
        return len(self.v) // (3 * per)

    def data(self):
        return {"v": self.v, "c": self.c}


class Layer:
    """The maps on one plane, painted in order, each over the last."""
    def __init__(self, normal, origin):
        self.n, self.o = normal, origin
        self.tris, self.lines = Shapes(), Shapes()


class Geometry:
    def __init__(self):
        self.layers = []                       # maps, one layer per plane, in drawing order
        self.solid = Shapes()                  # terrain and sign boards
        self.solid_lines = Shapes()            # lines on sign boards
        self.lights = Shapes()
        self.void = None                       # a black GND: strips fading to it are kept in their COL
        self.edge_colour = None                # COL of the first such strip
        self.largest = (0.0, None)             # (area, colour) of the largest filled picture

    def layer(self, T):
        n = T.vector(UP)
        for L in self.layers:
            if all(abs(L.n[q] - n[q]) < 1e-6 for q in range(3)) and \
                    abs(sum((T.o[q] - L.o[q]) * n[q] for q in range(3))) < SAME_PLANE:
                return L
        self.layers.append(Layer(n, T.o))
        return self.layers[-1]


class Field:
    def __init__(self):
        self.name = ""
        self.sky = [82, 122, 163]
        self.ground = [0, 0, 0]
        self.default_area = "NOAREA"
        self.geo = Geometry()
        self.grids = []            # terrain meshes, for the height lookup
        self.regions = []
        self.ground_objects = []


def load_field(path, name=""):
    f = Field()
    f.name = name
    with open(path, encoding="utf-8", errors="ignore") as fh:
        lines = fh.read().split("\n")
    _field(lines, Transform(), f, os.path.dirname(path), top=True)
    return f


def _args(line):
    return re.findall(r'"[^"]*"|\S+', line.strip())


def _field(lines, T, f, folder, top=False):
    packs, items = {}, []
    i, n = 0, len(lines)
    while i < n:
        a = _args(lines[i])
        if not a or a[0].startswith("#"):
            i += 1
            continue
        w = a[0].upper()
        if w == "PCK":
            count = int(a[2])
            packs[a[1].strip('"')] = lines[i + 1:i + 1 + count]
            i += 1 + count
            continue
        if w == "ENDF":
            break
        if top and w == "GND":
            f.ground = [int(v) for v in a[1:4]]
            f.geo.void = f.ground if not any(f.ground) else None
        elif top and w == "SKY":
            f.sky = [int(v) for v in a[1:4]]
        elif top and w == "DEFAREA":
            f.default_area = a[1]
        elif w in ("PC2", "PLT", "SRF", "TER", "RGN", "FLD", "GOB", "PST", "AOB"):
            item = {"kind": w, "pos": (0.0, 0.0, 0.0), "att": (0.0, 0.0, 0.0)}
            i += 1
            while i < n:
                b = _args(lines[i])
                i += 1
                if not b:
                    continue
                k = b[0].upper()
                if k == "END":
                    break
                if k == "FIL":
                    item["fil"] = b[1].strip('"')
                elif k == "POS":
                    v = [float(x) for x in b[1:7]]
                    item["pos"] = tuple(v[:3])
                    item["att"] = tuple(x * ANGLE for x in v[3:6])
                elif k in ("TAG", "NAM"):
                    item[k.lower()] = b[1].strip('"') if len(b) > 1 else ""
                elif k in ("ID", "IFF", "FLG"):
                    item[k.lower()] = int(b[1])
                elif k == "PMT":
                    item["primary"] = True
                elif k == "ARE":
                    item["area"] = [float(x) for x in b[1:5]]
            items.append(item)
            continue
        i += 1
    # a field's own elements first, then its sub-fields: YSFlight's order for painting maps
    for item in items:
        if item["kind"] != "FLD":
            _element(item, packs, T, f, folder)
    for item in items:
        if item["kind"] == "FLD":
            _element(item, packs, T, f, folder)


def _element(item, packs, T, f, folder):
    kind = item["kind"]
    ET = T.child(item["pos"], item["att"])
    body = None
    if item.get("fil"):
        body = packs.get(item["fil"])
        if body is None:
            p = os.path.join(folder, item["fil"])
            if os.path.isfile(p):
                with open(p, encoding="utf-8", errors="ignore") as fh:
                    body = fh.read().split("\n")
    if kind in ("PC2", "PLT") and body is not None:
        _picture(body, ET, f.geo, kind == "PC2")
    elif kind == "TER" and body is not None:
        _terrain(body, ET, f)
    elif kind == "FLD" and body is not None:
        _field(body, ET, f, folder)
    elif kind == "RGN" and "area" in item:
        x0, z0, x1, z1 = item["area"]
        corners = [ET.point(x, 0.0, z) for x, z in ((x0, z0), (x1, z0), (x1, z1), (x0, z1))]
        f.regions.append({"tag": item.get("tag", ""), "id": item.get("id", 0),
                          "corners": [[round(c[0], 1), round(c[2], 1)] for c in corners]})
    elif kind == "GOB":
        p = ET.point(0.0, 0.0, 0.0)
        fwd = ET.vector((0.0, 0.0, 1.0))
        f.ground_objects.append({"type": item.get("nam", ""), "tag": item.get("tag", ""),
                                 "iff": item.get("iff", 0) + 1, "primary": item.get("primary", False),
                                 "x": round(p[0], 2), "y": round(p[1], 2), "z": round(p[2], 2),
                                 "yaw": round(math.atan2(-fwd[0], fwd[2]), 4)})


# --- pictures ---

def _picture(lines, T, g, on_ground):
    """A map (on_ground, painted in its plane's layer) or a sign board (a solid, standing up)."""
    if on_ground:
        layer = g.layer(T)
        to = (layer.tris, layer.lines, layer.n, lambda x, y: T.point(x, 0.0, y))
    else:
        to = (g.solid, g.solid_lines, T.vector((0.0, 0.0, -1.0)), lambda x, y: T.point(x, y, 0.0))
    elem = None
    for line in lines:
        a = _args(line)
        if not a:
            continue
        w = a[0].upper()
        if w in ("PST", "PLL", "LSQ", "PLG", "APL", "GQS", "QST", "QDR", "TRI"):
            elem = {"t": w, "c": [0, 0, 0], "c2": None, "p": []}
        elif elem is None:
            continue
        elif w == "COL":
            elem["c"] = [int(v) for v in a[1:4]]
        elif w == "CL2":
            elem["c2"] = [int(v) for v in a[1:4]]
        elif w == "VER":
            elem["p"].append((float(a[1]), float(a[2])))
        elif w == "ENDO":
            _picture_element(elem, to, g)
            elem = None


def _picture_element(e, to, g):
    tris, lines, normal, place = to
    t, pts = e["t"], e["p"]
    w = [place(x, y) for x, y in pts]
    if t in ("PST", "APL"):                           # lights are not lit
        for p in w:
            g.lights.add((p,), (e["c"],))
        return
    if t in ("PLG", "QST", "GQS", "QDR", "TRI") and len(pts) >= 3:
        area = abs(sum(pts[k][0] * pts[k - 1][1] - pts[k - 1][0] * pts[k][1] for k in range(len(pts)))) / 2.0
        if area > g.largest[0]:
            g.largest = (area, e["c"])
    c = lit(e["c"], normal)
    if t == "PLG" and len(pts) >= 3:
        for a, b, d in triangulate(pts):
            tris.add((w[a], w[b], w[d]), (c, c, c))
    elif t in ("QST", "GQS"):
        c2 = lit(e["c2"], normal) if t == "GQS" and e["c2"] else c
        if t == "GQS" and g.void is not None and e["c2"] == g.void:
            c2 = c                                    # a fade into the black void: keep the edge colour
            g.edge_colour = g.edge_colour or e["c"]
        col = [c if k % 2 == 0 else c2 for k in range(len(w))]   # GQS: even points COL, odd CL2
        for k in range(0, len(w) - 3, 2):
            tris.add((w[k], w[k + 1], w[k + 2]), (col[k], col[k + 1], col[k + 2]))
            tris.add((w[k + 1], w[k + 3], w[k + 2]), (col[k + 1], col[k + 3], col[k + 2]))
    elif t == "QDR":
        for k in range(0, len(w) - 3, 4):
            tris.add((w[k], w[k + 1], w[k + 2]), (c, c, c))
            tris.add((w[k], w[k + 2], w[k + 3]), (c, c, c))
    elif t == "TRI":
        for k in range(0, len(w) - 2, 3):
            tris.add((w[k], w[k + 1], w[k + 2]), (c, c, c))
    elif t == "PLL":                                  # line strip
        for k in range(len(w) - 1):
            lines.add((w[k], w[k + 1]), (c, c))
    elif t == "LSQ":                                  # separate segments
        for k in range(0, len(w) - 1, 2):
            lines.add((w[k], w[k + 1]), (c, c))


def triangulate(pts):
    """Ear clipping for a simple polygon (either winding). Returns index triples.
    Convex polygons (most of them) come out as a fan, like YSFlight's GL_POLYGON."""
    n = len(pts)
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    sign = 1.0 if area >= 0 else -1.0

    def cross(o, a, b):
        return ((a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])) * sign

    if all(cross(pts[i], pts[(i + 1) % n], pts[(i + 2) % n]) >= 0 for i in range(n)):
        return [(0, i, i + 1) for i in range(1, n - 1)]
    idx = list(range(n))

    def corner(k):                           # turn at idx[k], > 0 = convex, < 0 = reflex
        m = len(idx)
        return cross(pts[idx[k - 1]], pts[idx[k]], pts[idx[(k + 1) % m]])

    # only reflex corners can lie inside an ear, so only they are tested
    reflex = {idx[k] for k in range(n) if corner(k) < 0}
    out = []
    k, misses = 0, 0
    while len(idx) > 3 and misses <= len(idx):
        m = len(idx)
        k %= m
        i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % m]
        a, b, c = pts[i0], pts[i1], pts[i2]
        if cross(a, b, c) >= 0 and not any(
                j not in (i0, i1, i2) and cross(a, b, pts[j]) > 0 and cross(b, c, pts[j]) > 0
                and cross(c, a, pts[j]) > 0 for j in reflex):
            out.append((i0, i1, i2))
            idx.pop(k)
            reflex.discard(i1)
            m -= 1
            for kk in (k - 1, k % m):         # the two neighbours may have become convex
                if corner(kk) >= 0:
                    reflex.discard(idx[kk])
            misses = 0
        else:
            k += 1
            misses += 1
    for q in range(1, len(idx) - 1):          # last triangle (or a degenerate remainder)
        out.append((idx[0], idx[q], idx[q + 1]))
    return out


# --- terrain ---

def _terrain(lines, T, f):
    nx = nz = 0
    xw = zw = 0.0
    nodes, walls, cbe = [], {}, None
    for line in lines:
        a = _args(line)
        if not a:
            continue
        w = a[0].upper()
        if w.startswith("NBL"):
            nx, nz = int(a[1]), int(a[2])
        elif w.startswith("TMS"):
            xw, zw = float(a[1]), float(a[2])
        elif w.startswith("BLO"):
            node = {"y": float(a[1]), "lup": False, "vis": [False, False], "c": [[0, 0, 0], [0, 0, 0]]}
            if len(a) > 2:
                node["lup"] = a[2].upper().startswith("L")
                for k, s in ((0, 3), (1, 7)):
                    flag = a[s].upper()
                    node["vis"][k] = (int(flag) & 1) == 1 if flag[:1].isdigit() else flag == "ON"
                    node["c"][k] = [int(v) for v in a[s + 1:s + 4]]
            nodes.append(node)
        elif w[:3] in ("BOT", "RIG", "TOP", "LEF"):
            walls[w[:3]] = [int(v) for v in a[1:4]]
        elif w.startswith("CBE"):
            cbe = (float(a[1]), float(a[2]), [int(v) for v in a[3:6]], [int(v) for v in a[6:9]])
        elif w == "END":
            break
    if len(nodes) != (nx + 1) * (nz + 1) or nx <= 0 or nz <= 0:
        return
    solid = f.geo.solid
    w = nx + 1

    def local(n):                           # point number -> mesh coordinates
        return ((n % w) * xw, nodes[n]["y"], (n // w) * zw)

    def colour(nd, k, n):
        if cbe is None:
            return nd["c"][k]
        y0, y1, c0, c1 = cbe
        s = min(max((nodes[n]["y"] - y0) / (y1 - y0), 0.0), 1.0) if y1 != y0 else 0.0
        return [c0[m] + (c1[m] - c0[m]) * s for m in range(3)]

    # the two triangles of block (i, j), as point numbers; corners 0 (i, j), 1 (i, j+1), 2 (i+1, j), 3 (i+1, j+1)
    blocks = []
    for j in range(nz):
        for i in range(nx):
            nd = nodes[j * w + i]
            rc = (j * w + i, (j + 1) * w + i, j * w + i + 1, (j + 1) * w + i + 1)
            order = ((3, 1, 2), (0, 2, 1)) if nd["lup"] else ((1, 0, 3), (2, 3, 0))
            blocks.append((nd, [[rc[q] for q in tri] for tri in order]))
    # smooth normals: each point takes the average of the triangles around it, seen or not
    sums = [[0.0, 0.0, 0.0] for _ in nodes]
    for nd, tris in blocks:
        for tri in tris:
            a, b, c = (local(n) for n in tri)
            u = (b[0] - a[0], b[1] - a[1], b[2] - a[2])
            v = (c[0] - a[0], c[1] - a[1], c[2] - a[2])
            nrm = _unit((u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]))
            if nrm is None:
                continue
            if nrm[1] < 0.0:
                nrm = (-nrm[0], -nrm[1], -nrm[2])
            for n in tri:
                s = sums[n]
                s[0] += nrm[0]
                s[1] += nrm[1]
                s[2] += nrm[2]
    normals = [T.vector(_unit(s) or UP) for s in sums]
    for nd, tris in blocks:
        for k, tri in enumerate(tris):
            if nd["vis"][k]:
                solid.add([T.point(*local(n)) for n in tri], [lit(colour(nd, k, n), normals[n]) for n in tri])
    # side walls: from the mesh edge down to the mesh's base
    edges = {"BOT": ([n for n in range(w)], (0.0, 0.0, -1.0)),
             "TOP": ([nz * w + n for n in range(w)], (0.0, 0.0, 1.0)),
             "LEF": ([j * w for j in range(nz + 1)], (-1.0, 0.0, 0.0)),
             "RIG": ([j * w + nx for j in range(nz + 1)], (1.0, 0.0, 0.0))}
    for side, col in walls.items():
        pts, nrm = edges[side]
        col = lit(col, T.vector(nrm))
        for n0, n1 in zip(pts, pts[1:]):
            a, b = local(n0), local(n1)
            a0, b0 = (a[0], 0.0, a[2]), (b[0], 0.0, b[2])
            if a[1] != 0.0:
                solid.add([T.point(*p) for p in (a, b0, a0)], (col, col, col))
            if b[1] != 0.0:
                solid.add([T.point(*p) for p in (a, b, b0)], (col, col, col))
    f.grids.append({"T": T, "nx": nx, "nz": nz, "xw": xw, "zw": zw,
                    "y": [nd["y"] for nd in nodes], "lup": [nd["lup"] for nd in nodes]})


# --- ground height (for weapons reaching the ground) ---

class GroundHeight:
    """Terrain height at (x, z): the highest terrain mesh there, else 0 (sea / flat pictures)."""
    def __init__(self, grids, cell=2000.0):
        self.grids = grids
        self.cell = cell
        self.index = {}
        for n, gr in enumerate(grids):
            T = gr["T"]
            corners = [T.point(x, 0.0, z) for x in (0.0, gr["nx"] * gr["xw"]) for z in (0.0, gr["nz"] * gr["zw"])]
            xs = [c[0] for c in corners]
            zs = [c[2] for c in corners]
            for cx in range(int(math.floor(min(xs) / cell)), int(math.floor(max(xs) / cell)) + 1):
                for cz in range(int(math.floor(min(zs) / cell)), int(math.floor(max(zs) / cell)) + 1):
                    self.index.setdefault((cx, cz), []).append(n)

    def __call__(self, x, z):
        best = 0.0
        for n in self.index.get((int(math.floor(x / self.cell)), int(math.floor(z / self.cell))), ()):
            h = self._grid_height(self.grids[n], x, z)
            if h is not None and h > best:
                best = h
        return best

    @staticmethod
    def _grid_height(gr, x, z):
        T = gr["T"]
        lx, _, lz = T.local((x, T.o[1], z))
        i, j = int(math.floor(lx / gr["xw"])), int(math.floor(lz / gr["zw"]))
        if not (0 <= i < gr["nx"] and 0 <= j < gr["nz"]):
            return None
        s, t = lx / gr["xw"] - i, lz / gr["zw"] - j
        w = gr["nx"] + 1
        y00, y10 = gr["y"][j * w + i], gr["y"][j * w + i + 1]
        y01, y11 = gr["y"][(j + 1) * w + i], gr["y"][(j + 1) * w + i + 1]
        if gr["lup"][j * w + i]:          # diagonal from (i, j+1) to (i+1, j)
            y = y00 + (y10 - y00) * s + (y01 - y00) * t if s + t <= 1.0 else \
                y11 + (y01 - y11) * (1.0 - s) + (y10 - y11) * (1.0 - t)
        else:                             # diagonal from (i, j) to (i+1, j+1)
            y = y00 + (y10 - y00) * s + (y11 - y10) * t if s >= t else \
                y00 + (y11 - y01) * s + (y01 - y00) * t
        return T.o[1] + y


# --- finding and caching a map ---

def find_field(field_name, pack_dirs):
    """The .fld for a field name ("[RVB]LUAVI", or just "LUAVI"), from the scenery lists
    (sce*.lst: "<field name> <.fld> <.stp> ...", paths relative to the pack folder)."""
    exact, partial = None, None
    for base in pack_dirs:
        if not base or not os.path.isdir(base):
            continue
        for root, _, files in os.walk(base):
            for fn in files:
                if fn.lower().startswith("sce") and fn.lower().endswith(".lst"):
                    for line in open(os.path.join(root, fn), encoding="utf-8", errors="ignore"):
                        a = _args(line)
                        if len(a) >= 2 and not a[0].startswith("#"):
                            fld = os.path.join(base, a[1].strip('"').replace("/", os.sep))
                            if a[0].upper() == field_name.upper() and os.path.exists(fld):
                                exact = exact or (a[0], fld)
                            elif field_name.upper() in a[0].upper() and os.path.exists(fld):
                                partial = partial or (a[0], fld)
    return exact or partial


def map_file_name(field_name):
    return re.sub(r"[^A-Za-z0-9]+", "_", field_name).strip("_").upper() + ".json"


def map_is_current(out_path, fld_path):
    """The map file exists in this format and is newer than the .fld and this reader."""
    try:
        with open(out_path, "rb") as fh:
            head = fh.read(20)
        newest = max(os.path.getmtime(fld_path), os.path.getmtime(os.path.abspath(__file__)))
        return head.startswith(b'{"format":%d,' % FORMAT) and os.path.getmtime(out_path) >= newest
    except OSError:
        return False


def build_map(field_name, fld_path, out_path):
    f = load_field(fld_path, field_name)
    g = f.geo
    outside = f.ground
    if g.void is not None:
        outside = g.edge_colour or g.largest[1] or f.ground
    data = {"format": FORMAT, "field": field_name, "fld": os.path.basename(fld_path),
            "sky": f.sky, "ground": lit(outside, UP), "default_area": f.default_area,
            "layers": [{"tris": L.tris.data(), "lines": L.lines.data()} for L in g.layers if L.tris.v or L.lines.v],
            "solid": g.solid.data(), "solid_lines": g.solid_lines.data(), "lights": g.lights.data(),
            "regions": f.regions, "ground_objects": f.ground_objects}
    with open(out_path, "w") as fh:
        json.dump(data, fh, separators=(",", ":"))
    return f


if __name__ == "__main__":
    import sys
    import time
    here = os.path.dirname(os.path.abspath(__file__))
    name = sys.argv[1] if len(sys.argv) > 1 else "[RVB]LUAVI"
    found = find_field(name, [os.path.join(here, "gamefiles")])
    if not found:
        sys.exit("field %s not found in the scenery lists" % name)
    started = time.time()
    os.makedirs(os.path.join(here, "maps"), exist_ok=True)
    out = os.path.join(here, "maps", map_file_name(found[0]))
    fld = build_map(found[0], found[1], out)
    g = fld.geo
    ys = g.solid.v[1::3]
    print("%s <- %s" % (out, found[1]))
    print("  map layers %d: triangles %d, line segments %d; solid triangles %d; lights %d" % (
        len(g.layers), sum(L.tris.count(3) for L in g.layers), sum(L.lines.count(2) for L in g.layers),
        g.solid.count(3), g.lights.count(1)))
    print("  terrain meshes %d, height %.0f .. %.0f m; regions %d; ground objects %d; %.1f s" % (
        len(fld.grids), min(ys) if ys else 0, max(ys) if ys else 0, len(fld.regions),
        len(fld.ground_objects), time.time() - started))
