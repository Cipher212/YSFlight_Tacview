"""Reads one YSFlight replay (.yfs), in two passes so many replays can be merged cheaply.

read_file(path)          pass 1: everything except full aircraft tracks and weapon launches.
                         Each sortie keeps a thinned track (every THIN-th sample) for matching
                         and clock alignment, plus where its samples sit in the file.
read_details(path, ...)  pass 2: full tracks of chosen sorties and the weapon launches wanted.

Record layouts follow YSFlight's own writer (YSFLIGHT-master/src/core/
fssimulationfileio.cpp, fsweapon.cpp, fsexplosion.cpp):
  aircraft sample (NUMRECOR n 4) = 4 lines: time / x y z heading pitch bank G /
      18 control values (see CTRL) / turret count + turret data
  ground sample (NUMGDREC n 3) = 6 lines: time / x y z heading pitch bank /
      state strength / aim angles / steering, doors, brake, lights / turrets
  weapon launch (BULRECOR) = 2 lines, +1 for AIM9/AIM9X/AIM120/AGM65/ROCKET
  kill credit (KILLCREDIT, inside BULRECOR) = 1 line; explosion (EXPRECOR) = 1 line
Weapons and kills name aircraft "A<n>" and ground objects "G<n>": n counts the AIRPLANE (or
GROUNDOB) blocks in THIS file from 0. The numbering differs between players' files.
"""
import collections
import os

THIN = 8   # pass-1 track thinning (~2 samples a second)

# Index of each value in an aircraft sample's "ctrl" list
CTRL = ["state", "vgw", "spoiler", "gear", "flap", "brake", "smoke", "vapor", "flags",
        "strength", "throttle", "elevator", "aileron", "rudder", "trim", "thrust_vector",
        "reverser", "bomb_bay"]
# ctrl[0] flight state: 0 flying, 1 on ground, 2 stall, 3 dead, 4 dead (spin),
# 5 dead (flat spin), 6 stopped, 7 overrun. ctrl[8] flags: 1 afterburner,
# 4 velocity marker, 8 off runway, 16 beacon, 32 nav lights, 64 strobe, 128 landing light.
DEAD_STATES = (3, 4, 5)

WEAPON_TYPES = {0: "GUN", 1: "AIM9", 2: "AGM65", 3: "BOMB500", 4: "ROCKET", 5: "FLARE",
                6: "AIM120", 7: "BOMB250", 8: "SMOKE", 9: "BOMB500HD", 10: "AIM9X",
                11: "FLAREPOD", 12: "FUELTANK"}
AIR_TO_AIR_GUIDED = {1, 6, 10}   # third line ends with the target aircraft number
AIR_TO_GROUND_GUIDED = {2}       # third line ends with the target ground object number
ROCKET = 4                       # third line is the rocket's top speed


def _lines(path):
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        return f.read().split("\n")


def read_file(path):
    lines = _lines(path)
    d = {"file": os.path.basename(path), "path": path, "field": "", "wind": [0.0, 0.0, 0.0],
         "aircraft": [], "ground": [], "kills": [], "explosions": [], "events": [],
         "loadouts": [], "plrair": [], "bulrecor_line": None, "ground_fire": {}, "a2a_targets": {}}
    cur = None
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        word = line.split(" ", 1)[0]

        if word == "FIELDNAM":
            d["field"] = line.split()[1]

        elif word == "EVTBLOCK":
            i = _read_events(lines, i + 1, d)
            continue

        elif word == "AIRPLANE":
            parts = line.split()
            cur = {"type": parts[1], "flag": len(parts) > 2 and parts[2] == "TRUE", "id": None,
                   "name": "", "iff": None, "index": len(d["aircraft"]), "count": 0}
            d["aircraft"].append(cur)

        elif word == "GROUNDOB":
            parts = line.split()
            cur = {"type": parts[1], "name": "", "id": None, "iff": None,
                   "index": len(d["ground"]), "primary": False, "samples": []}
            d["ground"].append(cur)

        elif word == "PRTARGET" and cur is not None and "primary" in cur:
            cur["primary"] = True

        elif word == "IDENTIFY" and cur is not None:
            cur["iff"] = int(line.split()[1]) + 1   # IDENTIFY 0..3 = IFF 1..4

        elif word == "IDANDTAG" and cur is not None:
            parts = line.split(" ", 2)
            cur["id"] = int(parts[1])
            cur["name"] = parts[2].strip().strip('"') if len(parts) > 2 else ""

        elif word == "NUMRECOR":
            count = int(line.split()[1])
            cur["line"], cur["count"] = i + 1, count
            if count:
                cur["t0"] = float(lines[i + 1])
                cur["t1"] = float(lines[i + 1 + 4 * (count - 1)])
                keep = list(range(0, count, THIN))
                if keep[-1] != count - 1:
                    keep.append(count - 1)
                thin = []
                for k in keep:
                    b = i + 1 + 4 * k
                    s = lines[b + 1].split()
                    thin.append((float(lines[b]), float(s[0]), float(s[1]), float(s[2])))
                cur["thin"] = thin
                cur["end"] = _track_end(lines, i + 1, count)
            i += 1 + 4 * count
            continue

        elif word == "NUMGDREC":
            count = int(line.split()[1])
            for k in range(count):
                b = i + 1 + 6 * k
                s = [float(v) for v in lines[b + 1].split()]
                state, strength = (int(v) for v in lines[b + 2].split()[:2])
                cur["samples"].append({"t": float(lines[b]), "x": s[0], "y": s[1], "z": s[2],
                                       "yaw": s[3], "pitch": s[4], "roll": s[5],
                                       "state": state, "strength": strength})
            i += 1 + 6 * count
            continue

        elif word == "BULRECOR":
            d["bulrecor_line"] = i
            i = _skip_to_kills(lines, i + 1, d)
            continue

        elif word == "EXPRECOR":
            i = _read_explosions(lines, i + 1, d)
            continue

        elif word == "CONSTWIND":   # "CONSTWIND 0.000000m/s 0.000000m/s 0.000000m/s"
            d["wind"] = [float(v.replace("m/s", "")) for v in line.split()[1:4]]

        i += 1

    # Whose replay is it? The player's aircraft switches (PLRAIR) name them; old replays
    # without PLRAIR only mark the aircraft flown when the file was saved (TRUE).
    by_id = {a["id"]: a for a in d["aircraft"] if a["id"] is not None}
    names = collections.Counter(by_id[o]["name"] for _, o in d["plrair"] if o in by_id)
    flagged = [a["name"] for a in d["aircraft"] if a["flag"]]
    d["recorder"] = names.most_common(1)[0][0] if names else (flagged[0] if flagged else None)
    for a in d["aircraft"]:
        a["own"] = bool(d["recorder"]) and a["name"] == d["recorder"]
    return d


def read_details(path, sortie_indices, want_weapon):
    """Pass 2. Full samples for the listed aircraft (by index in this file), and the weapon
    launches for which want_weapon(t, type, owner) is true.
    Returns ({index: [(t, x, y, z, h, p, b, g, ctrl), ...]}, [launch dicts])."""
    lines = _lines(path)
    tracks = {}
    wanted = set(sortie_indices)
    index = -1
    i, n = 0, len(lines)
    weapons = []
    while i < n:
        line = lines[i]
        if line.startswith("AIRPLANE "):
            index += 1
        elif line.startswith("NUMRECOR "):
            count = int(line.split()[1])
            if index in wanted:
                tr = []
                for k in range(count):
                    b = i + 1 + 4 * k
                    s = lines[b + 1].split()
                    tr.append((float(lines[b]), float(s[0]), float(s[1]), float(s[2]),
                               float(s[3]), float(s[4]), float(s[5]), float(s[6]),
                               [int(v) for v in lines[b + 2].split()]))
                tracks[index] = tr
            i += 1 + 4 * count
            continue
        elif line.startswith("NUMGDREC "):
            i += 1 + 6 * int(line.split()[1])
            continue
        elif line.startswith("BULRECOR"):
            _read_weapons(lines, i + 1, weapons, want_weapon)
            break
        i += 1
    return tracks, weapons


# How a track ends, read backwards through its final dead stretch (state 3 = removed): did this
# game see the aircraft tumble (state 4/5) before it was removed, and from when (file clock).
def _track_end(lines, first, count):
    tumbled, t_down = False, None
    for k in range(count - 1, max(-1, count - 401), -1):
        b = first + 4 * k
        state = int(lines[b + 2].split()[0])
        if state in (4, 5):
            tumbled, t_down = True, float(lines[b])
        elif state != 3:
            break
    return {"tumbled": tumbled, "t_down": t_down}


# --- sections ---

def _read_events(lines, i, d):
    # EVTBLOCK ... EDEVTBLK. Each event: "<TYPE> <time> 0", body lines, "ENDEVT".
    event = None
    while i < len(lines) and not lines[i].startswith("EDEVTBLK"):
        line = lines[i]
        parts = line.split()
        if line.startswith("TXTEVT"):
            event = {"t": float(parts[1]), "text": ""}
            d["events"].append(event)
        elif line.startswith("WPNCFG"):
            event = {"t": float(parts[1]), "id": None, "cfg": []}
            d["loadouts"].append(event)
        elif line.startswith("PLRAIR"):
            event = {"t": float(parts[1]), "plrair": True}
        elif line.startswith("TXT ") and event is not None and "text" in event:
            event["text"] = line[4:].strip()
        elif line.startswith("AIRID") and event is not None and "cfg" in event:
            event["id"] = int(parts[1])   # the aircraft's IDANDTAG id in this file
        elif line.startswith("CFG ") and event is not None and "cfg" in event:
            event["cfg"].append([parts[1], int(parts[2])])
        elif line.startswith("OBJID") and event is not None and "plrair" in event:
            d["plrair"].append((event["t"], int(parts[1])))
        elif line.startswith("ENDEVT"):
            event = None
        i += 1
    d["events"] = [e for e in d["events"] if e["text"]]
    return i + 1


def _skip_to_kills(lines, i, d):
    # Pass 1 reads only who fired when for ground objects ("ground_fire": {local ground index:
    # [times]}: one that fires is still there), whom each aircraft aimed its air-to-air missiles at
    # ("a2a_targets": {local aircraft index: {local target indices}}, for the deeper missile
    # checks) and the kill credits; the launches themselves are read later, only from the files
    # that are used
    fire = collections.defaultdict(list)
    aims = collections.defaultdict(set)
    d["ground_fire"] = fire
    d["a2a_targets"] = aims
    while i < len(lines):
        line = lines[i]
        if line.startswith("NUMRECO"):
            count = int(line.split()[1])
            i += 1
            for _ in range(count):
                a = lines[i].split(None, 2)
                owner = lines[i + 1].split()[3:4]
                wtype = int(a[1])
                if owner and owner[0][:1] == "G" and owner[0][1:].isdigit():
                    fire[int(owner[0][1:])].append(float(a[0]))
                if wtype in AIR_TO_AIR_GUIDED and owner and owner[0][:1] == "A" and owner[0][1:].isdigit():
                    c = lines[i + 2].split()
                    if len(c) > 3 and c[3].lstrip("-").isdigit() and int(c[3]) >= 0:
                        aims[int(owner[0][1:])].add(int(c[3]))
                extra = wtype in AIR_TO_AIR_GUIDED or wtype in AIR_TO_GROUND_GUIDED or wtype == ROCKET
                i += 3 if extra else 2
            continue
        if line.startswith("KILLCREDIT"):
            count = int(line.split()[2])
            for k in range(count):
                p = lines[i + 1 + k].split()
                wtype = int(p[0])
                d["kills"].append({"weapon": wtype, "name": WEAPON_TYPES.get(wtype, str(wtype)),
                                   "killer": p[1], "victim": p[2], "credit": p[3],
                                   "x": float(p[4]), "y": float(p[5]), "z": float(p[6]),
                                   "t": float(p[7])})
            i += 1 + count
            continue
        if line.startswith("ENDRECO"):
            return i + 1
        i += 1
    return i


def _read_weapons(lines, i, out, want):
    # BULRECOR / VERSION 4 / NUMRECO n / records / [KILLCREDIT...] / ENDRECO
    while i < len(lines):
        line = lines[i]
        if line.startswith("NUMRECO"):
            count = int(line.split()[1])
            i += 1
            for _ in range(count):
                a = lines[i].split()
                b = lines[i + 1].split()
                wtype = int(a[1])
                extra = wtype in AIR_TO_AIR_GUIDED or wtype in AIR_TO_GROUND_GUIDED or wtype == ROCKET
                t, owner = float(a[0]), b[3]
                if want(t, wtype, owner):
                    w = {"t": t, "type": wtype, "name": WEAPON_TYPES.get(wtype, str(wtype)),
                         "x": float(a[2]), "y": float(a[3]), "z": float(a[4]),
                         "yaw": float(a[5]), "pitch": float(a[6]), "roll": float(a[7]),
                         "velocity": float(b[0]), "range": float(b[1]), "damage": int(b[2]),
                         "owner": owner, "credit": b[4] if len(b) > 4 else "U"}
                    if extra:
                        c = lines[i + 2].split()
                        if wtype == ROCKET:
                            w["max_speed"] = float(c[0])
                        else:
                            w.update({"max_speed": float(c[0]), "turn_rate": float(c[1]),
                                      "seeker_cone": float(c[2]), "target": int(c[3])})
                    out.append(w)
                i += 3 if extra else 2
            return
        i += 1


def _read_explosions(lines, i, d):
    # EXPRECOR / VERSION 3 / NUMRECO n / "t x y z remain start_radius radius by flash type"
    while i < len(lines):
        line = lines[i]
        if line.startswith("NUMRECO"):
            count = int(line.split()[1])
            for k in range(count):
                p = lines[i + 1 + k].split()
                d["explosions"].append({
                    "t": float(p[0]), "x": float(p[1]), "y": float(p[2]), "z": float(p[3]),
                    "duration": float(p[4]), "start_radius": float(p[5]), "radius": float(p[6]),
                    "caused_by": p[7], "flash": int(p[8]), "type": int(p[9])})
            i += 1 + count
            continue
        if line.startswith("ENDRECO"):
            return i + 1
        i += 1
    return i
