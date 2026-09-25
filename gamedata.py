"""Ground-object data from YSFlight's .dat files, looked up by the IDENTIFY name the replay uses.
Gives threat ranges (GUNRANGE, SAMRANGE), hit sizes (HTRADIUS), strength and missile type, and
the object's size: the box around its model, taken from the ground lists (gro*.lst lines are
"<.dat> <model> <collision .srf> <cockpit> <coarse .srf>"): the coarse model if there is one, else
the collision model, else the model itself. "solid" is False when the collision model is empty
(null.srf), as for RvB's clouds.

The game-files pack (for RvB: C:\\YSFlight_Tacview\\gamefiles) is searched first, then YSFlight's
stock objects (YSFLIGHT-master/runtime/ground), so add-on versions win over stock ones."""
import os
import re

UNITS = {"m": 1.0, "km": 1000.0, "ft": 0.3048, "nm": 1852.0, "sm": 1609.344}
KEYS = {"GUNRANGE": "gun_range", "SAMRANGE": "sam_range", "HTRADIUS": "hit_radius"}


def _key(path):
    return os.path.normcase(os.path.normpath(path))


def _args(line):
    return [x.strip('"') for x in re.findall(r'"[^"]*"|\S+', line)]


def _srf_points(lines):
    """Points of a .srf: its "V x y z" lines. Inside a face (F ... E) "V" lists the face's
    point numbers instead, so those are skipped. Keywords come short or long (VER, FAC, END)."""
    pts, in_face = [], False
    for line in lines:
        w = line.split()
        if not w:
            continue
        k = w[0].upper()
        if k in ("F", "FAC"):
            in_face = True
        elif k in ("E", "END"):
            in_face = False
        elif k in ("V", "VER") and not in_face and len(w) >= 4:
            try:
                pts.append((float(w[1]), float(w[2]), float(w[3])))
            except ValueError:
                pass
    return pts


def _model_points(path):
    """Points of a .srf, or of a .dnm's parts shown in their first state, each moved by its POS
    (and its parents')."""
    with open(path, encoding="utf-8", errors="ignore") as fh:
        lines = fh.read().split("\n")
    if not lines or lines[0].strip().upper() != "DYNAMODEL":
        return _srf_points(lines)
    packs, parts, order, cur = {}, {}, [], None
    i = 0
    while i < len(lines):
        a = _args(lines[i])
        i += 1
        if not a:
            continue
        k = a[0].upper()
        if k == "PCK" and len(a) >= 3:
            n = int(a[2])
            packs[a[1]] = lines[i:i + n]
            i += n
        elif k == "SRF":
            cur = {"name": a[1] if len(a) > 1 else "", "fil": None, "pos": (0.0, 0.0, 0.0),
                   "shown": True, "children": []}
            parts[cur["name"]] = cur
            order.append(cur)
        elif cur is not None and k == "FIL" and len(a) > 1:
            cur["fil"] = a[1]
        elif cur is not None and k == "POS" and len(a) >= 4:
            cur["pos"] = tuple(float(x) for x in a[1:4])     # its last value does not hide a part
        elif cur is not None and k == "STA" and len(a) >= 8 and not cur.get("has_state"):
            cur["has_state"] = True
            cur["shown"] = a[7] != "0"                      # shown in its first state
        elif cur is not None and k == "CLD" and len(a) > 1:
            cur["children"].append(a[1])
    children = {c for p in order for c in p["children"]}
    pts = []

    def walk(part, offset, depth):
        if not part["shown"] or depth > 16:
            return
        o = tuple(offset[j] + part["pos"][j] for j in range(3))
        body = packs.get(part["fil"])
        if body is None and part["fil"]:
            p = os.path.join(os.path.dirname(path), part["fil"])
            body = open(p, encoding="utf-8", errors="ignore").read().split("\n") if os.path.isfile(p) else []
        pts.extend((x + o[0], y + o[1], z + o[2]) for x, y, z in _srf_points(body or []))
        for c in part["children"]:
            if c in parts:
                walk(parts[c], o, depth + 1)
    for p in order:
        if p["name"] not in children:
            walk(p, (0.0, 0.0, 0.0), 0)
    return pts


def _model_box(path):
    """[x0, y0, z0, x1, y1, z1] around a .srf or .dnm model, or None."""
    try:
        pts = _model_points(path)
    except (OSError, ValueError, IndexError):
        return None
    if not pts:
        return None
    lo = [min(p[k] for p in pts) for k in range(3)]
    hi = [max(p[k] for p in pts) for k in range(3)]
    if all(hi[k] - lo[k] < 0.01 for k in range(3)):
        return None
    return [round(c, 2) for c in lo + hi]


def load_ground_models(pack_dirs):
    """{.dat path key: {"box": [...] or None, "solid": bool}} from the ground lists."""
    table = {}
    for base in pack_dirs:
        if not base or not os.path.isdir(base):
            continue
        roots = [base, os.path.dirname(base)]          # list paths are relative to the game folder
        for root, _, files in os.walk(base):
            for f in files:
                if not (f.lower().startswith("gro") and f.lower().endswith(".lst")):
                    continue
                for line in open(os.path.join(root, f), encoding="utf-8", errors="ignore"):
                    a = _args(line)
                    if len(a) < 2 or a[0].startswith("#"):
                        continue

                    def find(rel):
                        for r in roots:
                            p = os.path.join(r, rel.replace("/", os.sep))
                            if rel and os.path.isfile(p):
                                return p
                        return None
                    dat = find(a[0])
                    if not dat or _key(dat) in table:
                        continue
                    visual, coll, coarse = (find(a[k]) if len(a) > k else None for k in (1, 2, 4))
                    empty = lambda p: p is None or os.path.basename(p).lower() == "null.srf"
                    box = None
                    for p in (coarse, coll, visual):
                        if not empty(p):
                            box = _model_box(p)
                            if box:
                                break
                    table[_key(dat)] = {"box": box, "solid": not empty(coll) and _model_box(coll) is not None}
    return table


def _length(text):
    m = re.match(r"\s*(-?[\d.]+)\s*([a-zA-Z]*)", text)
    if not m:
        return None
    return float(m.group(1)) * UNITS.get((m.group(2) or "m").lower(), 1.0)


def load_ground_data(pack_dirs):
    """{IDENTIFY name (upper case): {"file", "gun_range", "sam_range", "hit_radius", "strength",
    "missile", "box", "solid"}} from every .dat under the given folders (earlier folders win)."""
    table = {}
    models = load_ground_models(pack_dirs)
    for base in pack_dirs:
        if not base or not os.path.isdir(base):
            continue
        for root, _, files in os.walk(base):
            for f in files:
                if not f.lower().endswith(".dat"):
                    continue
                path = os.path.join(root, f)
                try:
                    text = open(path, encoding="utf-8", errors="ignore").read()
                except OSError:
                    continue
                m = re.search(r'^IDENTIFY\s+"?([^"\r\n]+?)"?\s*$', text, re.M)
                if not m or m.group(1).strip().upper() in table:
                    continue
                entry = {"file": os.path.relpath(path, base)}
                # a key given twice: the game keeps the last one (the 2S6M's SAMRANGE 6000m, then 2000m)
                for key, name in KEYS.items():
                    v = re.findall(r"^%s\s+(\S+)" % key, text, re.M)
                    if v:
                        entry[name] = _length(v[-1])
                v = re.findall(r"^STRENGTH\s+(\d+)", text, re.M)
                if v:
                    entry["strength"] = int(v[-1])
                v = re.findall(r"^MSSLTYPE\s+(\S+)", text, re.M)
                if v:
                    entry["missile"] = v[-1]
                model = models.get(_key(path), {})
                entry["box"] = model.get("box")
                entry["solid"] = model.get("solid", True)
                table[m.group(1).strip().upper()] = entry
    return table
