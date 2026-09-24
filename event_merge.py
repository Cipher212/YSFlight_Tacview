"""Merges several players' replays of one event into a single timeline.

What the 20260718 event's 12 replays showed (and this code relies on):
  * every file has its own clock (offsets up to ~20 minutes). Kills, messages every client got
    at the same moment, and aircraft spawn times line the clocks up to a few hundredths of a
    second, with no measurable drift over an hour
  * each client gets login messages at its own join time, and countdown messages repeat in
    every match: messages only count once they are seen at the same time in several files
  * aircraft IDs and ground-object numbers are per client, so aircraft are matched by pilot +
    type + time + position, ground objects by type + name + position
  * everyone sees everyone else 0.25-0.45 s late; a pilot's own file has the true track
  * a player's file can be from another match played the same day: checked by comparing
    aircraft positions once the clocks are lined up

Each merged aircraft sortie comes from ONE file: the pilot's own recording if there is one,
otherwise the spectator file that saw most of it (its times moved earlier by that file's
measured delay). The sortie's weapon launches come from the same file. Ground-object fire,
explosions and messages come from one "primary" file at each moment. Kills are gathered from
every file and counted: how many files recorded each one, and how many could have.
"""
import bisect
import collections
import math
import statistics

MATCH_DISTANCE = 500.0     # same sortie in two files: median distance under this (metres)
KILL_WINDOW = 10.0         # kill records this close to a death belong to it (seconds)
SHIFTS = [x / 20 for x in range(0, 21)]   # delays tried: 0 .. 1.0 s


def label_air(a):
    return "A:%s|%s" % (a["name"], a["type"])


def label_gnd(g):
    return "G:%s|%s" % (g["type"], g["name"])


def ref_label(f, ref):
    kind, n = ref[:1], ref[1:]
    if kind == "A" and n.isdigit() and int(n) < len(f["aircraft"]):
        return label_air(f["aircraft"][int(n)])
    if kind == "G" and n.isdigit() and int(n) < len(f["ground"]):
        return label_gnd(f["ground"][int(n)])
    return "N"


def anchors(f):
    """Clock anchors of one file: (local time, key). Keys are the same in every file."""
    out = []
    for k in f["kills"]:
        out.append((k["t"], ("K", k["weapon"], ref_label(f, k["killer"]), ref_label(f, k["victim"]))))
    counts = collections.Counter(e["text"] for e in f["events"])
    for e in f["events"]:
        if counts[e["text"]] == 1:
            out.append((e["t"], ("M", e["text"])))
    for a in f["aircraft"]:
        if a.get("count") and a["name"]:
            out.append((a["t0"], ("S", label_air(a))))
    return out


def densest_offset(timeline, anchors_f, skip_messages=()):
    """Offset (timeline time - file time) agreed by most anchors: (offset, inliers, spread)."""
    by = collections.defaultdict(list)
    for t, key in timeline:
        by[key].append(t)
    diffs = []
    for t, key in anchors_f:
        if key[0] == "M" and key[1] in skip_messages:
            continue
        diffs += [tt - t for tt in by.get(key, ())]
    if len(diffs) < 3:
        return None
    diffs.sort()
    best, j = (0, 0, 0), 0
    for i in range(len(diffs)):
        while diffs[i] - diffs[j] > 2.0:
            j += 1
        if i - j + 1 > best[0]:
            best = (i - j + 1, j, i)
    centre = statistics.median(diffs[best[1]:best[2] + 1])
    inliers = [d for d in diffs if abs(d - centre) < 1.0]
    off = statistics.median(inliers)
    return off, len(inliers), statistics.median(abs(d - off) for d in inliers)


def interp(track, t):
    """Position on a (t, x, y, z) track at time t, None outside it or across long gaps."""
    k = bisect.bisect_right(track, (t, math.inf, 0, 0)) - 1
    if k < 0 or k >= len(track) - 1:
        return track[-1][1:] if track and abs(track[-1][0] - t) < 1e-6 else None
    t0, t1 = track[k][0], track[k + 1][0]
    if t1 - t0 > 10.0:
        return None
    w = (t - t0) / (t1 - t0) if t1 > t0 else 0.0
    a, b = track[k], track[k + 1]
    return (a[1] + (b[1] - a[1]) * w, a[2] + (b[2] - a[2]) * w, a[3] + (b[3] - a[3]) * w)


def median_distance(a, b, min_points=2):
    d = [math.dist(p[1:], q) for p in a for q in [interp(b, p[0])] if q is not None]
    return statistics.median(d) if len(d) >= min_points else None


def shifted(track, shift):
    return [(t + shift, x, y, z) for t, x, y, z in track]


def coverage(f):
    ts = [(a["t0"], a["t1"]) for a in f["aircraft"] if a.get("count")]
    return (min(t for t, _ in ts), max(t for _, t in ts)) if ts else (0.0, 0.0)


# --- 1. clocks and match membership ---

def align(files, log):
    anc = [anchors(f) for f in files]
    ref = max(range(len(files)), key=lambda i: (len(anc[i]), coverage(files[i])[1] - coverage(files[i])[0]))
    offsets, info = {ref: 0.0}, {ref: {"anchors": len(anc[ref]), "spread": 0.0, "note": "reference clock"}}
    timeline = list(anc[ref])
    pending = set(range(len(files))) - {ref}
    while pending:
        tries = [(i, densest_offset(timeline, anc[i])) for i in pending]
        tries = [(i, r) for i, r in tries if r]
        if not tries:
            break
        i, (off, n, spread) = max(tries, key=lambda x: x[1][1])
        if n < 5:
            break
        agree, checked = position_agreement(files[i], off, [(files[j], offsets[j]) for j in offsets])
        pending.discard(i)
        if checked >= 3 and agree / checked < 0.6:
            info[i] = {"left_out": "another match: only %d of %d aircraft are where the other files put them"
                                   % (agree, checked)}
            continue
        if checked < 3 and (n < 10 or spread > 0.5):
            info[i] = {"left_out": "too little overlap with the other files to check it"}
            continue
        offsets[i] = off
        info[i] = {"anchors": n, "spread": spread, "positions": "%d of %d aircraft agree" % (agree, checked)}
        timeline += [(t + off, k) for t, k in anc[i]]
    for i in pending:
        info[i] = {"left_out": "nothing in common with the other files (kills, messages, aircraft)"}

    # Messages each client got at its own time (logins, countdowns of other matches) are
    # dropped, then every file is lined up again against all the others.
    heard = collections.defaultdict(list)
    for i, off in offsets.items():
        for e in files[i]["events"]:
            heard[e["text"]].append(e["t"] + off)
    local = {txt for txt, ts in heard.items() if len(ts) >= 2 and max(ts) - min(ts) > 5.0}
    for i in list(offsets):
        if i == ref:
            continue
        others = [(t + offsets[j], k) for j in offsets if j != i for t, k in anc[j]]
        r = densest_offset(others, anc[i], skip_messages=local)
        if r:
            offsets[i] = r[0]
            info[i].update({"anchors": r[1], "spread": r[2]})
    log("clocks lined up: %d of %d files" % (len(offsets), len(files)))
    return offsets, info, ref, local


def position_agreement(f, off_f, aligned):
    """How many of f's aircraft are where the already lined-up files put them."""
    index = collections.defaultdict(list)
    for g, off_g in aligned:
        for a in g["aircraft"]:
            if a.get("thin"):
                index[label_air(a)].append(shifted(a["thin"], off_g))
    agree = checked = 0
    for a in f["aircraft"]:
        if len(a.get("thin", ())) < 5:
            continue
        tr = shifted(a["thin"], off_f)
        best = None
        for other in index.get(label_air(a), ()):
            d = median_distance(tr, other, min_points=5)
            if d is not None and (best is None or d < best):
                best = d
        if best is not None:
            checked += 1
            agree += best < 1000.0
    return agree, checked


# --- 2. network delay of each file ---

def estimate_delays(files, offsets):
    """How late each file saw other pilots, measured against those pilots' own recordings."""
    own = collections.defaultdict(list)
    for i, off in offsets.items():
        for a in files[i]["aircraft"]:
            if a.get("own") and a.get("thin"):
                own[label_air(a)].append((i, shifted(a["thin"], off)))
    delays = {}
    for i, off in offsets.items():
        gaps = collections.defaultdict(list)
        for a in files[i]["aircraft"]:
            if a.get("own") or not a.get("thin"):
                continue
            tr = shifted(a["thin"], off)
            for j, ref_track in own.get(label_air(a), ()):
                if j == i or ref_track[0][0] > tr[-1][0] or ref_track[-1][0] < tr[0][0]:
                    continue
                for p in tr[::2]:
                    for s in SHIFTS:
                        q = interp(ref_track, p[0] - s)
                        if q is not None:
                            gaps[s].append(math.dist(p[1:], q))
        table = {s: statistics.median(v) for s, v in gaps.items() if len(v) >= 30}
        if table:
            delays[i] = min(table, key=table.get)
    default = statistics.median(delays.values()) if delays else 0.0
    for i in offsets:
        delays.setdefault(i, default)
    return delays


# --- 3. the same sortie in several files ---

def cluster_sorties(files, offsets, delays):
    members = []
    for i, off in offsets.items():
        for a in files[i]["aircraft"]:
            if not a.get("count"):
                continue
            shift = off - (0.0 if a["own"] else delays[i])
            tr = shifted(a["thin"], shift)
            members.append({"file": i, "air": a, "track": tr, "start": tr[0][0], "end": tr[-1][0],
                            "shift": shift})
    by_label = collections.defaultdict(list)
    for m in members:
        by_label[label_air(m["air"])].append(m)
    order = sorted(offsets, key=lambda i: -len(files[i]["aircraft"]))
    rank = {i: r for r, i in enumerate(order)}
    sorties = []
    for ms in by_label.values():
        # Files in turn; each sortie joins the NEAREST group from other files that overlaps it
        # in time (identically named AI aircraft can fly in formation), or starts a new group.
        groups = []
        for m in sorted(ms, key=lambda m: (rank[m["file"]], m["start"])):
            best, best_d = None, MATCH_DISTANCE
            for g in groups:
                if any(x["file"] == m["file"] for x in g):
                    continue
                ds = [d for x in g if x["start"] <= m["end"] and m["start"] <= x["end"]
                      for d in [median_distance(m["track"], x["track"]) or median_distance(x["track"], m["track"])]
                      if d is not None]
                if ds and min(ds) < best_d:
                    best, best_d = g, min(ds)
            if best is None:
                groups.append([m])
            else:
                best.append(m)
        sorties += groups
    for g in sorties:
        # the pilot's own recording first, otherwise the file that saw most of the sortie
        g.sort(key=lambda m: (not m["air"]["own"], -(m["end"] - m["start"])))
    sorties.sort(key=lambda g: g[0]["start"])
    return sorties


# --- 4. ground objects ---

def match_ground(files, offsets, order):
    """Merged ground objects (first file in `order` that has one is its source) and, per file,
    local index -> merged index."""
    merged, maps = [], {i: {} for i in offsets}
    by_name = collections.defaultdict(list)
    for i in order:
        off = offsets[i]
        for g in files[i]["ground"]:
            if not g["samples"]:
                continue
            s = g["samples"][0]
            t, pos = s["t"] + off, (s["x"], s["y"], s["z"])
            # the nearest identical object (SAM sites hold several identical launchers side by
            # side); a file never holds the same object twice
            found, best = None, 50.0
            for k in by_name[(g["type"], g["name"])]:
                if i in merged[k]["files"]:
                    continue
                d = math.dist(pos, interp_ground(merged[k], t))
                if d < best:
                    found, best = k, d
            if found is None:
                found = len(merged)
                merged.append({"file": i, "ground": g, "shift": off, "files": set()})
                by_name[(g["type"], g["name"])].append(found)
            merged[found]["files"].add(i)
            maps[i][g["index"]] = found
    return merged, maps


def interp_ground(m, t):
    """Position of a merged ground object at time t. Ground objects are recorded only when
    they change (a static one may have a dozen samples in an hour), so no gap limit here."""
    s = m["ground"]["samples"]
    ts = [x["t"] + m["shift"] for x in s]
    k = bisect.bisect_right(ts, t) - 1
    if k < 0:
        return s[0]["x"], s[0]["y"], s[0]["z"]
    if k >= len(s) - 1:
        return s[-1]["x"], s[-1]["y"], s[-1]["z"]
    w = (t - ts[k]) / (ts[k + 1] - ts[k]) if ts[k + 1] > ts[k] else 0.0
    return tuple(s[k][c] + (s[k + 1][c] - s[k][c]) * w for c in ("x", "y", "z"))


# --- 5. which file speaks for each moment (ground fire, explosions, messages) ---

def primary_pieces(files, offsets, order):
    cov = {i: tuple(c + offsets[i] for c in coverage(files[i])) for i in offsets}
    edges = sorted({-1e9, 1e9} | {c for i in offsets for c in cov[i]})
    pieces = []
    for a, b in zip(edges, edges[1:]):
        mid = (a + b) / 2
        inside = [i for i in order if cov[i][0] - 5 <= mid <= cov[i][1] + 5]
        f = inside[0] if inside else min(order, key=lambda i: min(abs(mid - cov[i][0]), abs(mid - cov[i][1])))
        if pieces and pieces[-1][2] == f:
            pieces[-1] = (pieces[-1][0], b, f)
        else:
            pieces.append((a, b, f))
    return pieces


def primary_at(pieces, t):
    for a, b, f in pieces:
        if a <= t < b:
            return f
    return pieces[-1][2]


# --- 6. kills: one death, one kill ---

def merge_kills(records, deaths, track_end, own_file, cover):
    """records: (t, weapon, killer, victim, file, raw record) on the event clock, with merged
    references ("A3", "G12", or "N" for unknown).
    deaths: {victim: time it died (aircraft) or was destroyed (ground object), or None}.
    track_end: {aircraft victim: time its track ends}.  own_file: {aircraft: its pilot's file}.
    cover: {file: (from, to)} on the event clock.

    Every player's game decides kills in its own simulation, so the files disagree: some
    kills are only in the shooter's (or victim's) game, and games log repeat credits. Each
    death gets ONE kill. Credit goes to what the victim's own game recorded, else the shooter's
    own game, else the choice of most games; other credits are kept as "other_claims".
    Records that match no death are returned separately as unconfirmed claims."""
    by_victim = collections.defaultdict(list)
    for r in records:
        by_victim[r[3]].append(r)
    kills, unconfirmed = [], []
    for victim, rs in by_victim.items():
        rs.sort(key=lambda r: r[0])
        death = deaths.get(victim)
        if death is not None:
            near = [r for r in rs if abs(r[0] - death) <= KILL_WINDOW]
        elif victim in track_end and track_end[victim] > rs[0][0] + 5.0:
            near = []            # the victim kept flying: nobody's credit is confirmed
        else:
            near = [r for r in rs if r[0] - rs[0][0] <= KILL_WINDOW]   # no track to check against
        rest = [r for r in rs if r not in near]

        if near:
            claims = collections.defaultdict(list)
            for r in near:
                claims[(r[2], r[1])].append(r)
            known = [k for k in claims if k[0] != "N"] or list(claims)   # prefer a named killer
            key, basis = None, ""
            victim_file = own_file.get(victim)
            if victim_file is not None:
                hits = [k for k in known if any(r[4] == victim_file for r in claims[k])]
                if hits:
                    key = min(hits, key=lambda k: min(abs(r[0] - (death or r[0])) for r in claims[k]))
                    basis = "the victim's own game"
            if key is None:
                shooters = [k for k in known if own_file.get(k[0]) is not None
                            and any(r[4] == own_file[k[0]] for r in claims[k])]
                if shooters:
                    key, basis = shooters[0], "the shooter's own game"
            if key is None:
                key = max(known, key=lambda k: (len({r[4] for r in claims[k]}), -claims[k][0][0]))
                basis = "most games"
            chosen = claims[key]
            t = death if death is not None else statistics.median(r[0] for r in chosen)
            k0 = chosen[0][5]
            kills.append({
                "t": round(t, 3), "weapon": key[1], "name": k0["name"], "killer": key[0],
                "victim": victim, "credit": k0["credit"], "x": k0["x"], "y": k0["y"], "z": k0["z"],
                "seen_by": len({r[4] for r in chosen}), "recorded_in": sorted({r[4] for r in chosen}),
                "covered_by": sum(1 for c in cover.values() if c[0] <= t <= c[1]),
                "basis": basis, "verified": death is not None,
                "other_claims": [{"killer": k[0], "weapon": k[1], "name": v[0][5]["name"],
                                  "recorded_in": sorted({r[4] for r in v})}
                                 for k, v in claims.items() if k != key]})
        # everything else: credits that match no death of this victim
        groups = []
        for r in rest:
            if groups and groups[-1][-1][1:3] == r[1:3] and r[0] - groups[-1][-1][0] < 1.5:
                groups[-1].append(r)
            else:
                groups.append([r])
        for g in groups:
            k0 = g[0][5]
            unconfirmed.append({"t": round(g[0][0], 3), "weapon": g[0][1], "name": k0["name"],
                                "killer": g[0][2], "victim": victim,
                                "recorded_in": sorted({r[4] for r in g}),
                                "reason": "the victim did not die then" if death is not None or near == []
                                else "a second credit for the same victim"})
    kills.sort(key=lambda k: k["t"])
    unconfirmed.sort(key=lambda k: k["t"])
    return kills, unconfirmed


# --- 7. how a sortie ended ---

def sortie_end(samples):
    """Every track ends in flight state 3: the aircraft was removed from the game (the player
    left or respawned, or the wreck came down). Aircraft that were shot down or crashed first
    tumble for a few seconds in state 4 or 5 ("dead spin").
    Returns (went_down, gone): went_down = when it started tumbling (None if it never did),
    gone = when it stopped flying. A spectator's copy can flicker tumbling -> flying ->
    tumbling (stale network updates): a tumble up to 1.5 s before the final one counts as the
    start, and the samples after it are made consistent."""
    if not samples:
        return None, None
    k = len(samples) - 1
    while k >= 0 and samples[k]["ctrl"][0] in (3, 4, 5):
        k -= 1
    run = k + 1                                   # first sample of the final dead stretch
    if run >= len(samples):
        return None, samples[-1]["t"]
    start, tumbled = run, any(s["ctrl"][0] in (4, 5) for s in samples[run:])
    for j in range(run - 1, -1, -1):
        if samples[run]["t"] - samples[j]["t"] > 1.5:
            break
        if samples[j]["ctrl"][0] in (4, 5):
            start, tumbled = j, True
    for j in range(start, len(samples)):
        if samples[j]["ctrl"][0] not in (3, 4, 5):
            samples[j]["ctrl"][0] = 4
    return (samples[start]["t"] if tumbled else None), samples[start]["t"]


def refine_offsets(files, offsets, delays, info, log):
    """A game on a bad connection logs events late by varying amounts, so its clock anchors are
    loose. Such files are re-timed with their pilot's own tracks: the shift that puts the pilot
    where the well-timed files (minus their delays) saw him."""
    good = {j for j in offsets if info[j].get("spread", 0.0) < 0.1}
    errs = [x / 20 for x in range(-40, 41)]          # -2 .. +2 s
    for i in offsets:
        if i in good:
            continue
        views = collections.defaultdict(list)
        for j in good:
            for b in files[j]["aircraft"]:
                if j != i and not b.get("own") and b.get("thin"):
                    views[label_air(b)].append(shifted(b["thin"], offsets[j] - delays[j]))
        gaps = collections.defaultdict(list)
        for a in files[i]["aircraft"]:
            if not (a.get("own") and a.get("thin")):
                continue
            tr = shifted(a["thin"], offsets[i])
            for view in views.get(label_air(a), ()):
                if view[0][0] > tr[-1][0] or view[-1][0] < tr[0][0]:
                    continue
                for p in tr[::2]:
                    for e in errs:
                        q = interp(view, p[0] + e)
                        if q is not None:
                            gaps[e].append(math.dist(p[1:], q))
        table = {e: statistics.median(v) for e, v in gaps.items() if len(v) >= 30}
        if table:
            e = min(table, key=table.get)
            offsets[i] += e
            info[i]["refined_by"] = e
            log("  re-timed %s by %+.2f s using its pilot's own tracks" % (files[i]["file"], e))
