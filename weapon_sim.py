"""Re-flies guided weapons (AIM-9, AIM-9X, AIM-120, AGM-65) from a replay's launch records.

A port of FsWeapon::Move and the missile part of FsWeapon::HitObject in
YSFLIGHT-master/src/core/fsweapon.cpp - the same code YSFlight's own replay uses to
re-fly recorded launches. Works in YSFlight coordinates (x east, y up, z north).

What YSFlight does each step (and so does this):
  * unguided for the first 3.0 s (AIM-120), 0.5 s (AIM-9X), 1.6 s (AGM-65)
  * looks at the target in the missile's own frame; an air-to-air missile goes for
    the closest flare ahead of it inside its seeker cone instead, if there is one
  * if the target is inside the seeker cone, turns toward it: yaw and pitch each
    limited to turn_rate * dt; a target more than 300 m behind is dropped
  * speeds up by 50 m/s^2 to its top speed (slows by 20 m/s^2 if above it)
  * "range" is the distance it can still fly; it is used up as it flies
  * proximity fuse (air-to-air only): 18 m AIM-9, 23 m AIM-9X, 25 m AIM-120

  * an AIM-9X or AIM-120 keeps guiding outside its seeker cone while the shooter
    still has the target locked (FsWeapon::IsOwnerStillHaveTarget). The replay does
    not store radar locks, so the lock is worked out the way FsAirplane::LockOn
    picks it: the live enemy nearest the shooter's nose inside a 30-degree cone,
    within 30 km (AIM-120) or 5 km (AIM-9X)

Not modelled: terrain (the ground is taken as y = 0 until .fld terrain is loaded),
radar cross-section and look-down limits in the lock (taken as always visible).
"""
import bisect
import math

DT = 1.0 / 30.0         # simulation step (s)
SAMPLE_EVERY = 0.1      # path sample spacing written to the JSON (s)
GRAVITY = 9.807
UNGUIDED_TIME = {6: 3.0, 10: 0.5, 2: 1.6}           # AIM120, AIM9X, AGM65
PROXIMITY = {1: 18.0, 10: 23.0, 6: 25.0}            # AIM9, AIM9X, AIM120
LOCK_CONE = math.pi / 6.0                           # FsAirplaneProperty::GetAAMRadarAngle
LOCK_RANGE = {6: 30000.0, 10: 5000.0}               # FsAirplaneProperty::GetAAMRange
DEATH_GRACE = 0.5   # a victim flagged dead up to this long before the hit can still be hit
                    # (its death and the fatal missile arrive in the same network update)
AGM_HIT_RADIUS = 20.0   # used when a ground object's .dat (HTRADIUS) isn't available
AIR_TO_AIR = {1, 6, 10}
GUIDED = {1, 2, 6, 10}


def axes(h, p, b):
    """YSFlight attitude -> (right, up, forward) unit vectors in world coordinates.
    Same convention as ys_basis() in node_3d.gd: bank, then pitch, then heading."""
    ch, sh, cp, sp, cb, sb = math.cos(h), math.sin(h), math.cos(p), math.sin(p), math.cos(b), math.sin(b)
    right = (ch * cb + sh * sp * sb, cp * sb, sh * cb - ch * sp * sb)
    up = (-ch * sb + sh * sp * cb, cp * cb, -sh * sb - ch * sp * cb)
    fwd = (-sh * cp, sp, ch * cp)
    return right, up, fwd


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _comb(a, ka, b, kb):
    return (a[0] * ka + b[0] * kb, a[1] * ka + b[1] * kb, a[2] * ka + b[2] * kb)


def _closest(prev, pos, q0, q1):
    """Closest approach during one step, with BOTH the weapon (prev -> pos) and the target
    (q0 -> q1) moving: (miss distance, weapon position then). YSFlight tests the closest point
    against one frame's flight segment, which depends on the recording PC's frame rate; this
    doesn't, and a fast missile can't skip through a small target between steps."""
    r0 = (prev[0] - q0[0], prev[1] - q0[1], prev[2] - q0[2])
    dr = ((pos[0] - prev[0]) - (q1[0] - q0[0]),
          (pos[1] - prev[1]) - (q1[1] - q0[1]),
          (pos[2] - prev[2]) - (q1[2] - q0[2]))
    dd = _dot(dr, dr)
    u = max(0.0, min(1.0, -_dot(r0, dr) / dd)) if dd > 0 else 0.0
    r = _comb(r0, 1.0, dr, u)
    return math.sqrt(_dot(r, r)), (prev[0] + (pos[0] - prev[0]) * u,
                                   prev[1] + (pos[1] - prev[1]) * u,
                                   prev[2] + (pos[2] - prev[2]) * u)


class Track:
    """Position of an aircraft or ground object over time (linear interpolation)."""
    def __init__(self, samples):
        self.t = [s["t"] for s in samples]
        self.p = [(s["x"], s["y"], s["z"]) for s in samples]
        self.start, self.end = self.t[0], self.t[-1]
        self.att = [(s["yaw"], s["pitch"], s["roll"]) for s in samples]
        # aircraft: flight state 3/4/5 = dead; ground objects: state 1 = destroyed
        self.dead = [(s["ctrl"][0] in (3, 4, 5)) if "ctrl" in s else s.get("state", 0) == 1
                     for s in samples]

    def alive(self, t):
        k = bisect.bisect_right(self.t, t) - 1
        return self.start <= t <= self.end and not self.dead[max(k, 0)]

    def att_at(self, t):
        return self.att[max(bisect.bisect_right(self.t, t) - 1, 0)]

    def at(self, t):
        k = bisect.bisect_right(self.t, t) - 1
        if k < 0:
            return self.p[0]
        if k >= len(self.t) - 1:
            return self.p[-1]
        t0, t1 = self.t[k], self.t[k + 1]
        w = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
        a, b = self.p[k], self.p[k + 1]
        return (a[0] + (b[0] - a[0]) * w, a[1] + (b[1] - a[1]) * w, a[2] + (b[2] - a[2]) * w)


FLARE_MAX_SPEED = 120.0   # live-game value (fsairplaneproperty.cpp); the replay doesn't store it


def flare_points(f):
    """Flare flight (FsWeapon::Move, FSWEAPON_FLARE), one point per DT: falls under
    gravity, slows by 20 m/s^2 while faster than 120 m/s, burns out after its range."""
    _, _, fwd = axes(f["yaw"], f["pitch"], f["roll"])
    v = f["velocity"]
    vec = (fwd[0] * v, fwd[1] * v, fwd[2] * v)
    pos = (f["x"], f["y"], f["z"])
    life = f["range"]
    pts = [pos]
    while life > 0.0 and len(pts) < 1800:
        vec = (vec[0], vec[1] - GRAVITY * DT, vec[2])
        speed = math.sqrt(_dot(vec, vec))
        if speed > FLARE_MAX_SPEED:
            k = (speed - 20.0 * DT) / speed
            speed -= 20.0 * DT
            vec = (vec[0] * k, vec[1] * k, vec[2] * k)
        pos = (pos[0] + vec[0] * DT, pos[1] + vec[1] * DT, pos[2] + vec[2] * DT)
        life -= speed * DT
        pts.append(pos)
    return pts


def locked_target(owner, aircraft_tracks, iffs, t, max_range):
    """Index of the aircraft the shooter's radar is locked on at time t (FsAirplane::LockOn):
    the live enemy nearest its nose, in front, inside the 30-degree cone and in range."""
    tr = aircraft_tracks.get(owner)
    if tr is None or not tr.alive(t):
        return None
    op = tr.at(t)
    right, up, fwd = axes(*tr.att_at(t))
    best, best_angle = None, LOCK_CONE
    for k, other in aircraft_tracks.items():
        if k == owner or iffs.get(k) == iffs.get(owner) or not other.alive(t):
            continue
        q = other.at(t)
        d = (q[0] - op[0], q[1] - op[1], q[2] - op[2])
        tz = _dot(d, fwd)
        if tz <= 0.0 or _dot(d, d) >= max_range * max_range:
            continue
        tx, ty = _dot(d, right), _dot(d, up)
        angle = math.atan2(math.sqrt(tx * tx + ty * ty), tz)
        if angle < best_angle:
            best, best_angle = k, angle
    return best


def sea_level(x, z):
    return 0.0


def simulate(w, aircraft_tracks, ground_tracks, flares, wind=(0.0, 0.0, 0.0), iffs=None, ground=sea_level):
    """Fly one guided weapon record. Returns {"path": [[t,x,y,z],...], "end": {...}}.
    ground(x, z) is the terrain height (fld_reader.GroundHeight); sea level without a map."""
    wtype = w["type"]
    t = w["t"]
    pos = (w["x"], w["y"], w["z"])
    right, up, fwd = axes(w["yaw"], w["pitch"], w["roll"])
    velocity = w["velocity"]
    vmax = w.get("max_speed", velocity)
    turn = w.get("turn_rate", 0.0)
    cone = w.get("seeker_cone", 0.0)
    life = w["range"]
    unguided = UNGUIDED_TIME.get(wtype, 0.0)

    target = None
    if w.get("target", -1) >= 0:
        target = (ground_tracks if wtype == 2 else aircraft_tracks).get(w["target"])
    owner = w["owner"]

    path = [[round(t, 3), round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)]]
    next_sample = t + SAMPLE_EVERY
    candidates, next_scan = [], t
    lock_checked_at, owner_has_lock = -1.0, False
    end = {"reason": "burnout"}

    while life > 0.0 and t - w["t"] < 120.0:
        # --- guidance (FsWeapon::Move) ---
        if target is not None and unguided <= 1e-6:
            tp = target.at(t)
            if wtype in AIR_TO_AIR:
                nearest = life
                for f in flares:          # flares released around this missile's flight
                    k = int((t - f["t"]) / DT)
                    if k < 0 or k >= len(f["_pts"]):
                        continue          # not released yet, or burnt out
                    fp = f["_pts"][k]
                    d = (fp[0] - pos[0], fp[1] - pos[1], fp[2] - pos[2])
                    fz = _dot(d, fwd)
                    if 0.0 < fz < nearest:
                        fx, fy = _dot(d, right), _dot(d, up)
                        if math.atan2(fx * fx + fy * fy, fz) < cone:   # (sic: YSFlight compares x^2+y^2, not its root)
                            tp, nearest = fp, fz
            d = (tp[0] - pos[0], tp[1] - pos[1], tp[2] - pos[2])
            tx, ty, tz = _dot(d, right), _dot(d, up), _dot(d, fwd)
            off_boresight = math.atan2(math.sqrt(tx * tx + ty * ty), tz)
            if off_boresight >= cone and wtype in LOCK_RANGE and owner is not None and iffs:
                if t - lock_checked_at >= 0.1:          # re-check the shooter's lock 10x a second
                    owner_has_lock = locked_target(owner, aircraft_tracks, iffs, t,
                                                   LOCK_RANGE[wtype]) == w.get("target")
                    lock_checked_at = t
            else:
                owner_has_lock = False
            if off_boresight < cone or owner_has_lock:
                limit = turn * DT
                yaw = max(-limit, min(limit, math.atan2(-tx, tz)))
                pit = max(-limit, min(limit, math.atan2(ty, tz)))
                c, s = math.cos(yaw), math.sin(yaw)          # yaw left about the missile's up axis
                fwd, right = _comb(fwd, c, right, -s), _comb(right, c, fwd, s)
                c, s = math.cos(pit), math.sin(pit)          # then nose up about its right axis
                fwd, up = _comb(fwd, c, up, s), _comb(up, c, fwd, -s)
            elif tz < -300.0:
                target = None
        if unguided > 0.0:
            unguided -= DT

        if velocity < vmax:
            velocity += 50.0 * DT
        elif velocity > vmax:
            velocity -= 20.0 * DT

        prev = pos
        pos = (pos[0] + (fwd[0] * velocity + wind[0]) * DT,
               pos[1] + (fwd[1] * velocity + wind[1]) * DT,
               pos[2] + (fwd[2] * velocity + wind[2]) * DT)
        life -= velocity * DT
        t += DT

        # --- proximity fuse (FsWeapon::HitObject), air-to-air missiles ---
        if wtype in AIR_TO_AIR:
            if t >= next_scan:            # cheap pre-filter: aircraft within 5 km
                candidates = [(k, tr) for k, tr in aircraft_tracks.items()
                              if k != owner and tr.start <= t <= tr.end
                              and math.dist(tr.at(t), pos) < 5000.0]
                next_scan = t + 0.5
            fuse = PROXIMITY[wtype]
            hit = None
            for k, tr in candidates:
                if not (tr.alive(t) or tr.alive(t - DEATH_GRACE)):
                    continue
                miss, at = _closest(prev, pos, tr.at(t - DT), tr.at(t))
                if miss < fuse and (hit is None or miss < hit[1]):
                    hit = (k, miss, at)
            if hit is not None:
                pos = hit[2]
                end = {"reason": "hit", "aircraft_index": hit[0], "miss_distance": round(hit[1], 1)}
                break

        # --- AGM-65: direct hit on its designated ground target (FsWeapon::HitObject) ---
        if wtype == 2 and target is not None:
            miss, at = _closest(prev, pos, target.at(t - DT), target.at(t))
            if miss < getattr(target, "radius", AGM_HIT_RADIUS):
                pos = at
                end = {"reason": "hit", "ground_index": w["target"], "miss_distance": round(miss, 1)}
                break

        if pos[1] <= ground(pos[0], pos[2]):
            end = {"reason": "ground"}
            break

        if t >= next_sample:
            path.append([round(t, 3), round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)])
            next_sample += SAMPLE_EVERY

    path.append([round(t, 3), round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)])
    end["t"] = round(t, 3)
    return {"path": path, "end": end}


def air_density(y):
    """Approximate standard atmosphere (kg/m^3); only the high-drag bomb uses it."""
    return 1.225 * math.exp(-max(y, 0.0) / 8500.0)


def falling_path(w, wind=(0.0, 0.0, 0.0), ground=sea_level):
    """Bombs and dropped fuel tanks (FsWeapon::Move): fall under gravity until they reach
    the ground (ground(x, z): terrain height). BOMB500HD also has drag (cdS 0.8, 226.8 kg)."""
    _, _, fwd = axes(w["yaw"], w["pitch"], w["roll"])
    v = w["velocity"]
    vec = (fwd[0] * v, fwd[1] * v, fwd[2] * v)
    t, pos = w["t"], (w["x"], w["y"], w["z"])
    path = [[round(t, 3), round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)]]
    next_sample = t + SAMPLE_EVERY
    while pos[1] > ground(pos[0], pos[2]) and t - w["t"] < 300.0:
        vec = (vec[0], vec[1] - GRAVITY * DT, vec[2])
        if w["type"] == 9:
            speed2 = _dot(vec, vec)
            if speed2 > 0:
                a = 0.5 * 0.8 * speed2 * air_density(pos[1]) / 226.8
                k = 1.0 - a * DT / math.sqrt(speed2)
                vec = (vec[0] * k, vec[1] * k, vec[2] * k)
        pos = (pos[0] + (vec[0] + wind[0]) * DT, pos[1] + (vec[1] + wind[1]) * DT, pos[2] + (vec[2] + wind[2]) * DT)
        t += DT
        if t >= next_sample:
            path.append([round(t, 3), round(pos[0], 2), round(pos[1], 2), round(pos[2], 2)])
            next_sample += SAMPLE_EVERY
    path.append([round(t, 3), round(pos[0], 2), round(max(pos[1], ground(pos[0], pos[2])), 2), round(pos[2], 2)])
    return {"path": path, "end": {"reason": "ground", "t": round(t, 3)}}


def sampled(points, t0):
    """Every-DT points (from flare_points) -> [[t,x,y,z],...] every SAMPLE_EVERY seconds."""
    step = max(1, int(round(SAMPLE_EVERY / DT)))
    idx = list(range(0, len(points), step))
    if idx[-1] != len(points) - 1:
        idx.append(len(points) - 1)
    return [[round(t0 + k * DT, 3), round(points[k][0], 2), round(points[k][1], 2), round(points[k][2], 2)]
            for k in idx]


def simulate_all(match_data, aircraft_list, ground_list, ground=sea_level):
    """Adds "path" and "end" to every guided missile, flare, bomb and dropped fuel tank in
    match_data["weapons"]. Guns and rockets are simple enough for the viewer to compute.
    ground(x, z): terrain height, so weapons stop where they hit the map."""
    wind = tuple(match_data.get("wind", (0.0, 0.0, 0.0)))
    aircraft_tracks = {a["index"]: Track(a["telemetry"]) for a in aircraft_list if a.get("telemetry")}
    iffs = {a["index"]: a.get("iff") for a in aircraft_list}
    ground_tracks = {}
    for g in ground_list:
        if g.get("samples"):
            ground_tracks[g["index"]] = Track(g["samples"])
            ground_tracks[g["index"]].radius = (g.get("dat") or {}).get("hit_radius") or AGM_HIT_RADIUS
    # owner references are "A<n>"; keep them as indices so the fuse can skip the shooter
    flares = sorted((dict(w) for w in match_data["weapons"] if w["type"] == 5), key=lambda f: f["t"])
    for f in flares:
        f["_pts"] = flare_points(f)
    flare_times = [f["t"] for f in flares]
    done = 0
    for w in match_data["weapons"]:
        if w["type"] == 5:                                   # flare
            pts = flare_points(w)
            w["path"] = sampled(pts, w["t"])
            w["end"] = {"reason": "burnout", "t": w["path"][-1][0]}
            continue
        if w["type"] in (3, 7, 9, 12):                       # bombs, dropped fuel tank
            w.update(falling_path(w, wind, ground))
            continue
        if w["type"] not in GUIDED:
            continue
        owner = w["owner"]
        w_owner_index = int(owner[1:]) if owner.startswith("A") else None
        lo = bisect.bisect_left(flare_times, w["t"] - 30.0)
        hi = bisect.bisect_right(flare_times, w["t"] + 120.0)
        rec = dict(w, owner=w_owner_index)
        result = simulate(rec, aircraft_tracks, ground_tracks, flares[lo:hi], wind, iffs, ground)
        # Without a target a guided weapon never steers, so it flies dead straight like a
        # rocket (ships' and tanks' guns often fire this way). The viewer draws those itself;
        # only the end (hit, ground or burnout) is kept.
        if w.get("target", -1) >= 0:
            w["path"] = result["path"]
        w["end"] = result["end"]
        done += 1
    return done
