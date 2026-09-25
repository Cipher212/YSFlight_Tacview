"""How each sortie ended, laid out for the scorers: what the replays show about it and, when they
don't settle it, the likely causes with a rough likelihood. Scorers decide (kamikaze, specials
and every final call are theirs); this gathers the angles.

The likelihood is a points system over the evidence, not a statistical model: each piece of
evidence adds points to the cause it supports, with a reason in words, and a cause's share of
all points is its likelihood. The weights are the constants below. Evidence, on the event clock:
  * the aircraft's own track: tumbling (flight state 4/5), health (STRENGTH) dropping and the G
    at the time, height above the terrain (the map), speed, on the ground or flying
  * the other replays' copies of it: did they see it tumble, did they see it for longer
  * kill credits (merged, and the unconfirmed ones), explosions near it
  * weapons: re-flown missiles that hit it, passed close or were still chasing it, gun rounds
    passing close
  * other aircraft close to it (collision)
  * whether the pilot's own replay ends right there (game closed, crashed or lost connection)
Over-G: RvB servers damage an aircraft above about 11-12 G, one health point at a time (about
every 0.3 s; checked on RvB 6). So over-G can only finish an aircraft that is nearly out of
health; one that still had several points just before it went down was finished by something
bigger (a missile, a bomb, the ground, another aircraft).
A leave is any exit in flight (game crash, network, or the exit key); one while a missile was
chasing the aircraft, rounds were landing or an enemy was close is "under fire", with the
threats listed, since scorers may credit that as a kill. Aircraft removed with several others at
the same moment at the end are the event closing, not deaths.
Also per sortie: a damage log (every health drop and what was near it then) and, for crashes,
the nearest aircraft and ground object at that moment (for judging a kamikaze). Evidence only."""
import bisect
import collections
import math

import weapon_sim

OVER_G = 11.0          # G above which RvB servers start damaging an aircraft
OVER_G_FINISH = 2      # health an over-G tick can take away at once (1, with some slack)
LIKELY = 0.7           # a most likely cause below this share needs a scorer's look
GUN_HIT = 12.0         # m: a gun round passing this close probably hit
GUN_NEAR = 40.0        # m: ... this close may have (weak evidence)
MISSILE_NEAR = 60.0    # m: a re-flown missile passing this close may have hit in the game
GUN_REACH = 2500.0     # m: rounds fired from further away are not checked
NEAR_ENEMY = 5000.0    # m: an enemy aircraft this close when someone leaves counts as a threat
DAMAGE_WINDOW = 30.0   # s of health history looked at before an aircraft went down
KILL_WINDOW = 12.0     # s between a kill credit and the death it explains
DAMAGE_JOIN = 1.0      # s: health drops this close together (of one kind) are one damage log line
COLLIDE_NEAR = 30.0    # m: another aircraft this close when health dropped is worth a mention
MASS_REMOVAL = 4       # this many aircraft gone within 2 s near the end = the event closing
MS_TO_KT = 1.943844

# points (see the module notes)
P_CREDIT, P_CREDIT_EXTRA, P_CREDIT_VICTIM, P_CREDIT_SHOOTER = 6, 2, 3, 2
P_THIN_CREDIT = 3                    # to "unclear": only one of several replays credited the kill
P_MISSILE_HIT, P_MISSILE_NEAR, P_UNCONFIRMED = 5, 2, 3
P_MISSILE_HIT_SEEN = 4               # hit it as the shooter's game showed it (weapon_sim.refly_as_seen)
P_BOOM_BY, P_DAMAGE_AT_HIT, P_DIED, P_BIG_HIT = 2, 3, 1, 2
P_HIT_UNKNOWN = 3                    # health lost at low G, no shooter found
P_COLLIDE_BOTH = ((15.0, 10), (30.0, 6))
P_COLLIDE_ONE = ((15.0, 2), (30.0, 1))
P_TERRAIN = ((5.0, 10), (15.0, 7))
P_TERRAIN_DIVING = 4
P_OVERG_LAST, P_OVERG_CLEAN, P_OVERG_WEAK = 6, 2, 1
P_LEAVE, P_LEAVE_OWN_END = 8, 2
P_UNKNOWN = 1


def analyse(md, aircraft_list, views, own_file, cover, ground_height, resolve):
    """Sets e["fate"] on every aircraft and "confidence" (0..1), "evidence" (sentences) and
    "check" on every kill. views[n]: each replay's copy of sortie n ([0] = the one used), as
    {"file", "own" (the pilot's own replay), "end" (its track's end), "down" (when it started
    tumbling there, or None)}, on the event clock; own_file: {"A<n>": replay index of the
    pilot's own recording}; cover: {replay index: (from, to)}; resolve(label) -> reference for
    the viewer."""
    ctx = _Context(md, aircraft_list, cover, ground_height, resolve)
    for n, e in enumerate(aircraft_list):
        e["fate"] = _ending(ctx, n, e, views[n], own_file.get("A%d" % n))
        e["damage"] = damage_log(ctx, n, e)
    for k in md["kills"]:
        _kill_evidence(ctx, k, aircraft_list)


class _Context:
    def __init__(self, md, aircraft_list, cover, ground_height, resolve):
        self.aircraft = aircraft_list
        self.cover = cover
        self.ground = ground_height
        self.resolve = resolve
        self.event_end = max(c[1] for c in cover.values()) if cover else 0.0
        self.tracks = {n: weapon_sim.Track(e["telemetry"]) for n, e in enumerate(aircraft_list) if e["telemetry"]}
        self.ends = sorted(e["gone_t"] for e in aircraft_list if e["telemetry"])
        self.kills = {k["victim"]: k for k in md["kills"]}
        self.unconfirmed = collections.defaultdict(list)
        for u in md["unconfirmed_kills"]:
            self.unconfirmed[u["victim"]].append(u)
        self.guns = sorted((w for w in md["weapons"] if w["name"] == "GUN"), key=lambda w: w["t"])
        self.gun_t = [w["t"] for w in self.guns]
        self.rockets = sorted((w for w in md["weapons"] if w["name"] == "ROCKET"), key=lambda w: w["t"])
        self.rocket_t = [w["t"] for w in self.rockets]
        self.flying = [w for w in md["weapons"] if w["name"] not in ("GUN", "ROCKET", "FLARE")
                       and (w.get("path") or w.get("end"))]
        self.flying.sort(key=lambda w: w["t"])
        self.flying_t = [w["t"] for w in self.flying]
        self.missiles_at = collections.defaultdict(list)      # aircraft index -> guided weapons aimed at it
        for w in md["weapons"]:
            if w.get("path") and w.get("target", -1) >= 0 and w["type"] in weapon_sim.AIR_TO_AIR:
                self.missiles_at[w["target"]].append(w)
        self.booms = sorted(md["explosions"], key=lambda x: x["t"])
        self.boom_t = [x["t"] for x in self.booms]
        self.ground_objects = md["ground_objects"]
        self.ground_number = []                  # each object's number among those of its type
        seen = collections.Counter()
        for g in self.ground_objects:
            seen[g["type"]] += 1
            self.ground_number.append(seen[g["type"]])

    def name(self, label):
        if label and label.startswith("A") and label[1:].isdigit():
            e = self.aircraft[int(label[1:])]
            return "%s (%s)" % (e["player"], e["aircraft"].split("(")[0])
        if label and label.startswith("G") and label[1:].isdigit():
            g = self.ground_objects[int(label[1:])]
            return "%s #%d" % (g["name"] or g["type"], self.ground_number[int(label[1:])])
        return "someone the replays don't name"


def _clock(t):
    s = int(max(t, 0.0))
    return "%d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60) if s >= 3600 else "%d:%02d" % (s // 60, s % 60)


def _weapon(name):
    return {"AIM9": "AIM-9", "AIM9X": "AIM-9X", "AIM120": "AIM-120", "AGM65": "AGM-65", "GUN": "gun",
            "ROCKET": "rocket"}.get(name, (name or "?").lower())


def _ending(ctx, n, e, members, own):
    tel = e["telemetry"]
    if not tel:
        return {"kind": "none", "t": 0.0, "summary": "no track", "causes": [], "evidence": [], "check": False}
    tr = ctx.tracks[n]
    label = "A%d" % n
    t_gone, t_down = e["gone_t"], e["death_t"]
    t_ref = t_down if t_down is not None else t_gone
    k_ref = max(bisect.bisect_right(tr.t, t_ref) - 1, 0)
    live = k_ref                                   # the last sample that shows it alive
    while live > 0 and tel[live]["ctrl"][0] in (3, 4, 5):
        live -= 1
    pos = tr.at(t_ref)
    k2 = bisect.bisect_left(tr.t, tel[live]["t"] - 0.5)
    dt = tel[live]["t"] - tel[k2]["t"]
    vel = [(tr.p[live][c] - tr.p[k2][c]) / dt for c in range(3)] if dt > 0 else [0.0, 0.0, 0.0]
    speed = math.sqrt(sum(v * v for v in vel))
    agl = pos[1] - ctx.ground(pos[0], pos[2])
    evidence = []
    fate = {"t": round(t_ref, 3), "gone": round(t_gone, 3), "causes": [], "evidence": evidence,
            "threats": [], "check": False}

    # the event closing: still there when the recordings stop, or removed along with others then
    together = bisect.bisect_right(ctx.ends, t_gone + 2.0) - bisect.bisect_left(ctx.ends, t_gone - 2.0)
    if t_gone >= ctx.event_end - 2.0 or (t_gone >= ctx.event_end - 30.0 and together >= MASS_REMOVAL):
        fate.update(kind="end", summary="still there when the event ended")
        if together >= MASS_REMOVAL:
            evidence.append("%d aircraft were removed within 2 s of each other at %s." % (together, _clock(t_gone)))
        return fate
    # other replays kept seeing it after the one used lost it
    others_end = max((m["end"] for m in members[1:]), default=None)
    own_ends_here = own is not None and abs(ctx.cover[own][1] - t_gone) < 3.0
    if t_down is None and others_end is not None and others_end > t_gone + 3.0 and not members[0]["own"]:
        evidence.append("The replay used for this aircraft ends at %s, but %d other replay(s) show it until %s."
                        % (_clock(t_gone), sum(1 for m in members[1:] if m["end"] > t_gone + 3.0), _clock(others_end)))
        fate.update(kind="cut", summary="the replay used ends here; other replays show it longer", check=True)
        return fate
    # left the aircraft on the ground (not a leave in flight)
    if t_down is None and (tel[live]["ctrl"][0] in (1, 6) or (speed * MS_TO_KT < 30.0 and agl < 10.0)):
        fate.update(kind="ground_exit", summary="left the aircraft on the ground")
        return fate

    cands = {}

    def add(key, cause, points, why, by=None, weapon=None):
        c = cands.setdefault(key, {"cause": cause, "by": by, "weapon": weapon, "points": 0.0, "why": []})
        c["points"] += points
        c["why"].append(why)

    # --- what the replays show about the aircraft itself ---
    tumbled = t_down is not None
    other_down = [m for m in members[1:] if m["down"] is not None and abs(m["down"] - t_ref) < 10.0]
    other_gone = [m for m in members[1:] if m["down"] is None and abs(m["end"] - t_gone) < 10.0]
    if tumbled:
        evidence.append("Went down (tumbling) at %s in the replay used." % _clock(t_down))
    else:
        evidence.append("Disappeared at %s without tumbling in the replay used." % _clock(t_gone))
    if members[1:]:
        evidence.append("Other replays: %d saw it go down, %d saw it just disappear." % (len(other_down), len(other_gone)))
    k0 = bisect.bisect_left(tr.t, t_ref - DAMAGE_WINDOW)
    drops = []                                     # (time, health lost, G then)
    for k in range(max(k0, 1), live + 1):
        lost = tel[k - 1]["ctrl"][9] - tel[k]["ctrl"][9]
        if lost > 0:
            j = bisect.bisect_left(tr.t, tel[k]["t"] - 0.5)
            drops.append((tel[k]["t"], lost, max(abs(f.get("g", 0.0)) for f in tel[j:k + 1])))
    health_end = tel[live]["ctrl"][9]
    over_g_lost = sum(d[1] for d in drops if d[2] >= OVER_G)
    other_lost = sum(d[1] for d in drops if d[2] < OVER_G)
    if drops:
        evidence.append("Health in the last %d s: %d -> %d (%d lost while pulling %.0f+ G, %d otherwise)."
                        % (DAMAGE_WINDOW, health_end + over_g_lost + other_lost, health_end, over_g_lost,
                           OVER_G, other_lost))
    b0 = bisect.bisect_left(ctx.boom_t, t_ref - 3.0)
    boom = None
    for x in ctx.booms[b0:bisect.bisect_right(ctx.boom_t, t_gone + 3.0)]:
        d = math.dist((x["x"], x["y"], x["z"]), pos)
        if d < 150.0 and (boom is None or d < boom[1]):
            boom = (x, d)
    if boom:
        evidence.append("Explosion recorded %.0f m away at %s." % (boom[1], _clock(boom[0]["t"])))
    died = tumbled or bool(other_down) or (boom is not None and boom[1] < 60.0) or health_end <= 0
    evidence.append("Then: %.0f m above the ground, %.0f kt, %s." % (
        agl, speed * MS_TO_KT, "climbing %.0f m/s" % vel[1] if vel[1] > 2.0 else
        ("descending %.0f m/s" % -vel[1] if vel[1] < -2.0 else "level")))

    # --- weapons ---
    k = ctx.kills.get(label)
    credited = k is not None and abs(k["t"] - t_ref) <= KILL_WINDOW
    if credited:
        key = ("weapon", k["killer"], k["name"])
        seen, covered = k.get("seen_by", 1), max(k.get("covered_by", 1), 1)
        add(key, "weapon", P_CREDIT + P_CREDIT_EXTRA * min(seen - 1, 2),
            "Kill credited to %s (%s) in %d of %d replays that were recording then."
            % (ctx.name(k["killer"]), _weapon(k["name"]), seen, covered), k["killer"], k["name"])
        if k.get("basis") == "the victim's own game":
            add(key, "weapon", P_CREDIT_VICTIM, "The victim's own game recorded this kill.")
        elif k.get("basis") == "the shooter's own game":
            add(key, "weapon", P_CREDIT_SHOOTER, "The shooter's own game recorded this kill.")
        if seen == 1 and covered >= 3:
            add(("unknown",), "unknown", P_THIN_CREDIT, "Only 1 of %d replays credited the kill." % covered)
        if k.get("other_claims"):
            evidence.append("Other games credited: %s." % ", ".join(
                "%s (%s)" % (ctx.name(c["killer"]), _weapon(c["name"])) for c in k["other_claims"]))
    for u in ctx.unconfirmed.get(label, ()):
        if abs(u["t"] - t_ref) <= 10.0:
            add(("weapon", u["killer"], u["name"]), "weapon", P_UNCONFIRMED,
                "%s's game credited a kill (%s) at %s." % (ctx.name(u["killer"]), _weapon(u["name"]), _clock(u["t"])),
                u["killer"], u["name"])
    missile_threats = []
    for w in ctx.missiles_at.get(n, ()):
        end = w.get("end", {})
        if w["t"] > t_gone:
            continue
        if end.get("reason") == "hit" and end.get("aircraft_index") == n and abs(end["t"] - t_ref) <= 3.0:
            add(("weapon", w["owner"], w["name"]), "weapon", P_MISSILE_HIT,
                "Re-flown %s from %s hit it at %s (passed %.0f m away)."
                % (_weapon(w["name"]), ctx.name(w["owner"]), _clock(end["t"]), end.get("miss_distance", 0.0)),
                w["owner"], w["name"])
            continue
        seen = w.get("as_seen") or {}
        if seen.get("reason") == "hit" and seen.get("aircraft_index") == n \
                and abs(seen["t"] - t_ref) <= 3.0 + seen.get("delay", 0.0):
            add(("weapon", w["owner"], w["name"]), "weapon", P_MISSILE_HIT_SEEN,
                "Re-flown %s from %s hit it at %s as the shooter's game showed it (%s, which saw it %.2f s "
                "late; it missed in the re-flight against its own track)."
                % (_weapon(w["name"]), ctx.name(w["owner"]), _clock(seen["t"]), seen.get("file", "?"),
                   seen.get("delay", 0.0)), w["owner"], w["name"])
            continue
        close = _missile_pass(w, tr, t_ref - 3.0, t_ref + 1.0)
        if close is not None and close[0] <= MISSILE_NEAR:
            add(("weapon", w["owner"], w["name"]), "weapon", P_MISSILE_NEAR,
                "Re-flown %s from %s passed %.0f m from it at %s (a miss in the re-flight; the game may "
                "have counted a hit)." % (_weapon(w["name"]), ctx.name(w["owner"]), close[0], _clock(close[1])),
                w["owner"], w["name"])
        if end.get("t", 0.0) > t_gone - 0.5:
            m = _missile_at(w, t_gone)
            if m is not None:
                d = math.dist(m[0], tr.at(t_gone))
                eta = d / max(m[1], 1.0)
                missile_threats.append({"by": ctx.resolve(w["owner"]), "weapon": w["name"], "distance": round(d),
                                        "eta": round(eta, 1), "text": "%s from %s, %.0f m away (about %.1f s to impact)"
                                        % (_weapon(w["name"]), ctx.name(w["owner"]), d, eta)})
    passes = _gun_passes(ctx, n, label, t_ref)
    for owner, ps in passes.items():
        hits = [p for p in ps if p[1] <= GUN_HIT]
        if hits:
            add(("weapon", owner, "GUN"), "weapon", 2 + min(len(hits), 6),
                "%d round(s) from %s passed within %.0f m of it in the last 4 s." % (len(hits), ctx.name(owner), GUN_HIT),
                owner, "GUN")
        else:
            add(("weapon", owner, "GUN"), "weapon", 0.7 * min(len(ps), 3),
                "%d round(s) from %s passed within %.0f m of it in the last 4 s." % (len(ps), ctx.name(owner), GUN_NEAR),
                owner, "GUN")
    if drops and drops[-1][2] < OVER_G:
        last = drops[-1]
        for key, c in cands.items():
            times = [p[0] for p in passes.get(c["by"], [])]
            if c["cause"] == "weapon" and any(abs(h - last[0]) <= 0.6 for h in times):
                add(key, "weapon", P_DAMAGE_AT_HIT, "Its health dropped as those rounds arrived.")
    if boom and boom[0].get("caused_by", "N") != "N":
        for key, c in cands.items():
            if c["cause"] == "weapon" and c["by"] == boom[0]["caused_by"]:
                add(key, "weapon", P_BOOM_BY, "The explosion was caused by %s." % ctx.name(c["by"]))
    big_hit = died and health_end > OVER_G_FINISH       # it still had health: one big hit finished it
    if died:
        for key, c in list(cands.items()):
            if c["cause"] == "weapon":
                add(key, "weapon", P_DIED + (P_BIG_HIT if big_hit else 0),
                    "It really went down%s." % (", with %d health left just before (one big hit)" % health_end
                                                if big_hit else ""))
    if other_lost > 0 and not any(c["cause"] == "weapon" for c in cands.values()):
        add(("hit",), "hit", P_HIT_UNKNOWN, "It lost %d health in the last %d s without pulling hard: something hit it."
            % (other_lost, DAMAGE_WINDOW))

    # --- collision, terrain, over-G ---
    near = _nearest_aircraft(ctx, n, t_ref)
    if near is not None:
        other, d, when = near
        o = ctx.aircraft[other]
        o_end = o["death_t"] if o["death_t"] is not None else o["gone_t"]
        both = abs(o_end - t_ref) < 3.0
        for limit, pts in (P_COLLIDE_BOTH if both else P_COLLIDE_ONE):
            if d < limit:
                add(("collision", "A%d" % other), "collision", pts, "Passed %.0f m from %s at %s.%s" % (
                    d, ctx.name("A%d" % other), _clock(when), " It went down too." if both else " It flew on."),
                    "A%d" % other)
                break
    for limit, pts in P_TERRAIN:
        if agl < limit:
            add(("terrain",), "terrain", pts, "Only %.0f m above the ground at %.0f kt when it went down."
                % (max(agl, 0.0), speed * MS_TO_KT))
            break
    else:
        if agl < 40.0 and -vel[1] > 10.0:
            add(("terrain",), "terrain", P_TERRAIN_DIVING, "Diving at %.0f m/s only %.0f m above the ground."
                % (-vel[1], agl))
    if drops and drops[-1][2] >= OVER_G and died and not big_hit:
        add(("overg",), "overg", P_OVERG_LAST + min(over_g_lost, 6) / 2.0,
            "Its last health went while pulling %.1f G (about %.0f G starts damaging an aircraft); %d health "
            "lost that way." % (drops[-1][2], OVER_G, over_g_lost))
        if other_lost == 0:
            add(("overg",), "overg", P_OVERG_CLEAN, "No other damage before it.")
    elif over_g_lost > 0:
        add(("overg",), "overg", P_OVERG_WEAK, "%d health lost while pulling %.0f+ G weakened it." % (over_g_lost, OVER_G))

    # --- left the aircraft ---
    if not died:
        add(("leave",), "leave", P_LEAVE,
            "Disappeared in flight without tumbling%s." % ("" if not drops else ", though it had taken damage"))
        if own_ends_here:
            add(("leave",), "leave", P_LEAVE_OWN_END,
                "The pilot's own replay ends at the same moment (game closed, crashed or lost connection).")
        gun_threats = _gun_passes(ctx, n, label, t_gone, reach=50.0, window=3.0)
        nearest_enemy = _nearest_enemy(ctx, n, t_gone)
        fate["threats"] = missile_threats + [
            {"by": ctx.resolve(o), "weapon": "GUN", "text": "%d round(s) from %s within 50 m in the last 3 s"
             % (len(p), ctx.name(o))} for o, p in gun_threats.items()]
        if nearest_enemy is not None and nearest_enemy[1] < NEAR_ENEMY:
            fate["threats"].append({"by": ctx.resolve("A%d" % nearest_enemy[0]), "weapon": None,
                                    "distance": round(nearest_enemy[1]),
                                    "text": "%s %.1f km away" % (ctx.name("A%d" % nearest_enemy[0]),
                                                                 nearest_enemy[1] / 1000.0)})
    add(("unknown",), "unknown", P_UNKNOWN, "Something the replays don't show.")

    # --- likelihoods ---
    total = sum(c["points"] for c in cands.values())
    causes = []
    for c in sorted(cands.values(), key=lambda c: -c["points"]):
        causes.append({"cause": c["cause"], "p": round(c["points"] / total, 2),
                       "by": ctx.resolve(c["by"]) if c["by"] else None, "weapon": c["weapon"],
                       "text": _cause_text(ctx, c, label), "why": c["why"]})
    top = causes[0]
    fate["causes"] = causes
    fate["kind"] = {"weapon": "killed", "hit": "shot_down", "collision": "collision", "terrain": "crashed",
                    "overg": "overg", "leave": "left", "unknown": "unknown"}[top["cause"]]
    if fate["kind"] == "killed" and not (credited and top["by"] == ctx.resolve(k["killer"])):
        fate["kind"] = "shot_down"                  # most likely a weapon, but not the credited one
    if fate["kind"] == "left" and fate["threats"]:
        fate["kind"] = "left_under_fire"
    fate["summary"] = top["text"] + (" under fire" if fate["kind"] == "left_under_fire" else "")
    fate["check"] = top["p"] < LIKELY or (credited and fate["kind"] != "killed") or fate["kind"] == "left_under_fire"
    if fate["kind"] in ("killed", "shot_down"):
        fate["by"], fate["weapon"] = top["by"], top["weapon"]
    if fate["kind"] in ("crashed", "collision", "unknown"):
        evidence.extend(_crash_neighbours(ctx, n, t_ref))
    return fate


def _cause_text(ctx, c, label):
    if c["cause"] == "weapon" and c["by"] == label:
        return "killed by its own %s" % _weapon(c["weapon"])
    if c["cause"] == "weapon":
        return "shot down by %s (%s)" % (ctx.name(c["by"]), _weapon(c["weapon"]))
    return {"hit": "hit by weapons fire (shooter not found)",
            "collision": "collided with %s" % (ctx.name(c["by"]) if c["by"] else "another aircraft"),
            "terrain": "flew into the ground", "overg": "over-G (G-limiter damage)",
            "leave": "left the aircraft in flight", "unknown": "unclear"}[c["cause"]]


def _missile_at(w, t):
    """(position, speed) of a re-flown weapon at time t, or None if it isn't flying then."""
    path = w["path"]
    if not path or t < path[0][0] or t > path[-1][0]:
        return None
    ts = [p[0] for p in path]
    k = max(min(bisect.bisect_right(ts, t) - 1, len(path) - 2), 0)
    a, b = path[k], path[min(k + 1, len(path) - 1)]
    dt = b[0] - a[0]
    u = (t - a[0]) / dt if dt > 0 else 0.0
    p = tuple(a[c] + (b[c] - a[c]) * u for c in (1, 2, 3))
    speed = math.dist(a[1:], b[1:]) / dt if dt > 0 else 0.0
    return p, speed


def _missile_pass(w, tr, t0, t1):
    """(closest distance, when) between a re-flown weapon and an aircraft between t0 and t1."""
    best = None
    path = w["path"]
    for a, b in zip(path, path[1:]):
        if b[0] < t0 or a[0] > t1 or not (tr.start <= a[0] <= tr.end):
            continue
        d, _ = weapon_sim._closest(a[1:], b[1:], tr.at(a[0]), tr.at(b[0]))
        if best is None or d < best[0]:
            best = (d, a[0])
    return best


def _gun_passes(ctx, n, label, t_end, reach=GUN_NEAR, window=4.0, rockets=False):
    """{shooter: [(time, distance)]} of gun rounds (from others) passing within `reach` of
    aircraft n in the `window` seconds before t_end: each round flies straight on from where it
    was fired, dropping under gravity, while the aircraft follows its track. Only rounds fired
    within GUN_REACH and within about 20 degrees of the aircraft are followed. rockets: the same
    for rockets (straight, speeding up to their top speed as the viewer draws them)."""
    tr = ctx.tracks[n]
    out = collections.defaultdict(list)
    shots, times = (ctx.rockets, ctx.rocket_t) if rockets else (ctx.guns, ctx.gun_t)
    i0 = bisect.bisect_left(times, t_end - window)
    for w in shots[i0:bisect.bisect_right(times, t_end + 0.2)]:
        if w["owner"] == label or w["owner"] == "N" or not (tr.start <= w["t"] <= tr.end):
            continue
        p0 = (w["x"], w["y"], w["z"])
        target = tr.at(w["t"])
        dist = math.dist(p0, target)
        if dist > GUN_REACH or dist < 1e-3:
            continue
        fwd = weapon_sim.axes(w["yaw"], w["pitch"], 0.0)[2]
        if sum(fwd[c] * (target[c] - p0[c]) for c in range(3)) < 0.94 * dist:
            continue                                # not pointed at it
        v = max(float(w.get("velocity", 0.0)), 1.0)
        vmax = max(float(w.get("max_speed", v)), v)
        tof = min(float(w.get("range", 2000.0)) / (0.5 * (v + vmax)), 6.0 if rockets else 3.0, t_end + 0.5 - w["t"])
        steps = max(int(tof / 0.1), 1)
        best = None
        prev_r, prev_q = p0, target
        for s in range(1, steps + 1):
            tau = tof * s / steps
            if rockets:
                a = _rocket_dist(v, vmax, tau)
                r = (p0[0] + fwd[0] * a, p0[1] + fwd[1] * a, p0[2] + fwd[2] * a)
            else:
                r = (p0[0] + fwd[0] * v * tau, p0[1] + fwd[1] * v * tau - 4.9035 * tau * tau, p0[2] + fwd[2] * v * tau)
            q = tr.at(w["t"] + tau)
            d, _ = weapon_sim._closest(prev_r, r, prev_q, q)
            if best is None or d < best[1]:
                best = (w["t"] + tau, d)
            prev_r, prev_q = r, q
        if best and best[1] <= reach:
            out[w["owner"]].append(best)
    return out


def _nearest_aircraft(ctx, n, t_ref):
    """(other aircraft index, closest distance, when) over the second before t_ref; the same
    pilot's other sorties don't count (a respawn can appear right where the old aircraft was)."""
    tr = ctx.tracks[n]
    me = ctx.aircraft[n]["player"]
    best = None
    for m, other in ctx.tracks.items():
        if m == n or ctx.aircraft[m]["player"] == me or other.end < t_ref - 1.0 or other.start > t_ref:
            continue
        for s in range(11):
            t = t_ref - 1.0 + 0.1 * s
            if other.start <= t <= other.end and tr.start <= t <= tr.end:
                d = math.dist(tr.at(t), other.at(t))
                if best is None or d < best[1]:
                    best = (m, d, t)
    return best


def _nearest_enemy(ctx, n, t):
    """(aircraft index, distance) of the closest aircraft of another team flying at time t."""
    tr = ctx.tracks[n]
    mine = ctx.aircraft[n]["iff"]
    best = None
    for m, other in ctx.tracks.items():
        if m == n or ctx.aircraft[m]["iff"] == mine or not other.alive(t):
            continue
        d = math.dist(tr.at(t), other.at(t))
        if best is None or d < best[1]:
            best = (m, d)
    return best


def _kill_evidence(ctx, k, aircraft_list):
    """Confidence and evidence for one merged kill: for an aircraft, the share of its ending's
    points that went to this shooter; for a ground object, the corroboration."""
    v = k["victim"]
    if v.startswith("A") and v[1:].isdigit():
        fate = aircraft_list[int(v[1:])].get("fate", {})
        match = next((c for c in fate.get("causes", []) if c["cause"] == "weapon"
                      and c["by"] == ctx.resolve(k["killer"])), None)
        k["confidence"] = match["p"] if match else 0.0
        k["evidence"] = (match["why"] if match else ["The victim's ending shows no sign of this shooter."]) \
            + fate.get("evidence", [])
        k["check"] = bool(fate.get("check")) or k["confidence"] < LIKELY
        return
    g = ctx.ground_objects[int(v[1:])] if v.startswith("G") and v[1:].isdigit() else {}
    p = 0.5 + (0.25 if k.get("reconstructed") else 0.0) + (0.15 if k.get("seen_by", 1) >= 2 else 0.0) \
        + (0.05 if k.get("verified") else 0.0)
    k["confidence"] = round(min(p, 0.95), 2)
    k["evidence"] = ["Recorded in %d of %d replays that were recording then."
                     % (k.get("seen_by", 1), max(k.get("covered_by", 1), 1))]
    if k.get("reconstructed") is not None:
        k["evidence"].append("Re-flown missile %s." % ("hit it" if k["reconstructed"] else "did not reach it"))
    k["evidence"] += g.get("destroyed_evidence", [])     # when the replays agree it was destroyed
    k["check"] = k["confidence"] < LIKELY or bool(g.get("destroyed_check"))


def _rocket_dist(v0, vmax, tau):
    """How far a rocket has flown tau seconds after launch (50 m/s^2 up to its top speed; as the
    viewer draws it, combat_layer.gd)."""
    if v0 >= vmax:
        return v0 * tau
    t_acc = (vmax - v0) / 50.0
    if tau <= t_acc:
        return v0 * tau + 25.0 * tau * tau
    return v0 * t_acc + 25.0 * t_acc * t_acc + vmax * (tau - t_acc)


def damage_log(ctx, n, e):
    """Every time aircraft n lost health, with what was near it then: re-flown weapons that hit it
    or passed close (also as the shooter's game showed it), explosions, gun rounds and rockets
    passing close, over-G, another aircraft close. Evidence for the scorers, not a verdict.
    Drops less than DAMAGE_JOIN apart, of one kind (over-G or not), make one entry:
    {"t", "t_end", "from", "to", "down" (it went down then), "g", "text"}."""
    tel = e["telemetry"]
    tr = ctx.tracks.get(n)
    if not tel or tr is None:
        return []
    final = len(tel)                                # the dead stretch the track ends in
    while final > 0 and tel[final - 1]["ctrl"][0] in (3, 4, 5):
        final -= 1
    groups = []
    for k in range(1, len(tel)):
        if k - 1 >= final:
            break                                   # already going down (health is then set to 1)
        lost = tel[k - 1]["ctrl"][9] - tel[k]["ctrl"][9]
        if lost <= 0:
            continue
        t = tel[k]["t"]
        j = bisect.bisect_left(tr.t, t - 0.5)
        g = max(abs(f.get("g", 0.0)) for f in tel[j:k + 1])
        down = k >= final and tel[k]["ctrl"][0] in (4, 5)   # (a tumble it flew on from is no death)
        last = groups[-1] if groups else None
        if last and not down and not last["down"] and t - last["t1"] <= DAMAGE_JOIN and (g >= OVER_G) == last["overg"]:
            last.update(t1=t, to=tel[k]["ctrl"][9], g=max(last["g"], g))
        else:
            groups.append({"t0": t, "t1": t, "from": tel[k - 1]["ctrl"][9], "to": tel[k]["ctrl"][9],
                           "g": g, "overg": g >= OVER_G, "down": down})
    out = []
    for grp in groups:
        why = _damage_sources(ctx, n, grp)
        what = "Health %d, went down" % grp["from"] if grp["down"] else "Health %d -> %d" % (grp["from"], grp["to"])
        if grp["t1"] - grp["t0"] >= 0.3:
            what += " over %.1f s" % (grp["t1"] - grp["t0"])
        out.append({"t": round(grp["t0"], 3), "t_end": round(grp["t1"], 3), "from": grp["from"], "to": grp["to"],
                    "down": grp["down"], "g": round(grp["g"], 1),
                    "text": "%s (%d s)  %s: %s" % (_clock(grp["t0"]), int(grp["t0"]), what, "; ".join(why))})
    return out


def _damage_sources(ctx, n, grp):
    """Sentences on what was near aircraft n when it lost health (grp from damage_log), the
    likeliest first; at most four."""
    tr = ctx.tracks[n]
    label = "A%d" % n
    t0, t1 = grp["t0"], grp["t1"]
    found = []                                     # (rank, sentence): lower first
    lo = bisect.bisect_left(ctx.flying_t, t0 - 130.0)
    for w in ctx.flying[lo:bisect.bisect_right(ctx.flying_t, t1 + 0.5)]:
        if w["owner"] == label:
            continue
        end = w.get("end") or {}
        seen = w.get("as_seen") or {}
        what = "%s from %s" % (_weapon(w["name"]), ctx.name(w["owner"]))
        if end.get("reason") == "hit" and end.get("aircraft_index") == n and t0 - 2.0 <= end["t"] <= t1 + 0.5:
            found.append((0.0, "%s hit it (re-flown)" % what))
        elif seen.get("reason") == "hit" and seen.get("aircraft_index") == n \
                and t0 - 2.0 - seen.get("delay", 0.0) <= seen["t"] <= t1 + 0.5:
            found.append((0.1, "%s hit it as the shooter's game showed it (re-flown there; %.2f s late)"
                          % (what, seen.get("delay", 0.0))))
        elif w.get("path") and w["path"][-1][0] >= t0 - 2.0:
            close = _missile_pass(w, tr, t0 - 2.0, t1 + 0.5)
            if close is not None and close[0] <= MISSILE_NEAR:
                found.append((1.0 + close[0] / 1000.0, "%s passed %.0f m away (re-flown)" % (what, close[0])))
    b0 = bisect.bisect_left(ctx.boom_t, t0 - 1.5)
    for x in ctx.booms[b0:bisect.bisect_right(ctx.boom_t, t1 + 0.5)]:
        d = math.dist((x["x"], x["y"], x["z"]), tr.at(x["t"]))
        by = x.get("caused_by", "N")
        if grp["down"] and by in (None, "N") and x["t"] >= t0 - 0.1:
            continue                               # its own crash, most likely
        if d < 100.0:
            found.append((2.0 + d / 1000.0, "an explosion %.0f m away%s" % (
                d, ", caused by %s" % ctx.name(by) if by and by != "N" else "")))
    p1 = tr.at(t1)
    agl = p1[1] - ctx.ground(p1[0], p1[2])
    if agl < 15.0:
        found.append((0.2, "it was %.0f m above the ground" % max(agl, 0.0)))
    for rockets in (False, True):
        for owner, ps in _gun_passes(ctx, n, label, t1 + 0.3, reach=GUN_NEAR, window=t1 - t0 + 2.0,
                                     rockets=rockets).items():
            best = min(p[1] for p in ps)
            found.append((3.0 + best / 1000.0, "%d %s from %s passed within %.0f m" % (
                len(ps), ("rocket(s)" if rockets else "round(s)"), ctx.name(owner), max(best, 1.0))))
    if grp["overg"]:
        found.append((0.5, "pulling %.1f G (RvB's servers take health above about %.0f G)" % (grp["g"], OVER_G)))
    near = _nearest_aircraft(ctx, n, t0 + 0.2)
    if near is not None and near[1] < COLLIDE_NEAR:
        found.append((1.5, "%s passed %.0f m from it" % (ctx.name("A%d" % near[0]), near[1])))
    if not found:
        return ["nothing the replays show was near it (a hit they don't record, or lag)"]
    found.sort(key=lambda f: f[0])
    return [f[1] for f in found[:4]]


def _crash_neighbours(ctx, n, t):
    """For a crash: the nearest other aircraft and ground object at that moment, and how fast the
    aircraft was closing on them, so scorers can judge a kamikaze quickly."""
    tr = ctx.tracks[n]
    pos = tr.at(t)
    me = ctx.aircraft[n]
    lines = []
    best = None
    for m, other in ctx.tracks.items():
        if m == n or ctx.aircraft[m]["player"] == me["player"] or not (other.start <= t <= other.end):
            continue
        d = math.dist(pos, other.at(t))
        if best is None or d < best[1]:
            best = (m, d)
    if best is not None and best[1] < 20000.0:
        m, d = best
        closing = _closing(tr, ctx.tracks[m], t)
        lines.append("Nearest aircraft then: %s, %s, %s, %s." % (
            ctx.name("A%d" % m), "same team" if ctx.aircraft[m]["iff"] == me["iff"] else "other team", _distance(d),
            "closing at %.0f kt" % (closing * MS_TO_KT) if closing > 5.0 else
            ("moving apart" if closing < -5.0 else "keeping its distance")))
    gbest = None
    for k, g in enumerate(ctx.ground_objects):
        if not (g.get("dat") or {}).get("solid", True):
            continue                                # clouds
        if g.get("destroyed_t") is not None and g["destroyed_t"] < t - 1.0:
            continue
        gp = _ground_at(g, t)
        if gp is not None:
            d = math.dist(pos, gp)
            if gbest is None or d < gbest[1]:
                gbest = (k, d)
    if gbest is not None and gbest[1] < 5000.0:
        g = ctx.ground_objects[gbest[0]]
        lines.append("Nearest ground object then: %s, %s, %s." % (
            ctx.name("G%d" % gbest[0]), {1: "Blue", 4: "Red"}.get(g.get("iff"), "neutral"), _distance(gbest[1])))
    return lines


def _closing(a, b, t):
    """How fast (m/s) track a closes on track b around time t (negative: moving apart)."""
    t0 = t - 0.5
    pa, pb = a.at(t), b.at(t)
    qa, qb = a.at(t0), b.at(t0)
    d1, d0 = math.dist(pa, pb), math.dist(qa, qb)
    return (d0 - d1) / 0.5


def _ground_at(g, t):
    """A ground object's position at time t (its last sample before then), or None."""
    samples = g.get("samples") or []
    if not samples:
        return None
    at = samples[0]
    for sm in samples:
        if sm["t"] <= t:
            at = sm
    return (at["x"], at["y"], at["z"])


def _distance(d):
    return "%.0f m away" % d if d < 1000.0 else "%.1f km away" % (d / 1000.0)
