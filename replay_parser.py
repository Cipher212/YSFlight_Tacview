"""Turns one or more YSFlight replays (.yfs) of the same event into an event file for the viewer.

    python replay_parser.py [options] replay1.yfs [replay2.yfs ...]    (or Raw_Data/*.yfs)
        -o, --out FILE   event file to write (default: parsed_telemetry.json); a name ending in
                         .gz is written gzip-compressed (several times smaller; the viewer reads both)
        --fld FILE       the map's .fld (default: the replay's field, found in the scenery lists)
        --map NAME       map name to show (default: the replay's field)
        --pack DIR       game files with the ground .dat files (default: gamefiles next to this)

With no replays given it reads Raw_Data\\1-WW3_event.yfs. Several replays are merged into one
timeline (event_merge.py); guided weapons are re-flown with YSFlight's missile code
(weapon_sim.py). Lines "PROGRESS <percent> <text>" are for the viewer's progress bar.
"""
import argparse
import bisect
import collections
import glob
import gzip
import json
import math
import multiprocessing
import os
import statistics
import sys
import time
from concurrent.futures import ProcessPoolExecutor

# The Python bundled with the .exe (Windows "embeddable" Python) doesn't look for modules next to
# the script it runs, so the pipeline's own modules are found from here.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import event_merge
import fates
import fld_reader
import gamedata
import weapon_sim
import yfs_reader

HERE = os.path.dirname(os.path.abspath(__file__))
GZIP_LEVEL = 5      # event files written .gz: much faster than the default 9, nearly as small


def progress(percent, text):
    print("PROGRESS %d %s" % (percent, text), flush=True)


def _pass2(job):
    path, sorties, owners, intervals = job
    owners = {"A%d" % n for n in owners}

    def want(t, wtype, owner):
        if owner.startswith("A"):
            return owner in owners           # this file is the source of that sortie
        return any(a <= t < b for a, b in intervals)   # ground fire: this file's moments
    return yfs_reader.read_details(path, sorties, want)


def build_event(paths, out_path, map_name, pack_dirs, fld_path=None):
    started = time.time()
    workers = max(1, min(4, len(paths), os.cpu_count() or 1))

    progress(2, "reading %d replay file(s)" % len(paths))
    with ProcessPoolExecutor(max_workers=workers) as ex:
        files = list(ex.map(yfs_reader.read_file, paths))
    fields = collections.Counter(f["field"] for f in files)
    if len(fields) > 1:
        print("WARNING: the replays are from different maps: %s" % dict(fields))

    progress(25, "lining up the clocks")
    log = lambda s: print(s, flush=True)
    offsets, info, ref, local = event_merge.align(files, log)
    delays = event_merge.estimate_delays(files, offsets)
    event_merge.refine_offsets(files, offsets, delays, info, log)
    delays = event_merge.estimate_delays(files, offsets)
    sorties = event_merge.cluster_sorties(files, offsets, delays)
    span = {i: event_merge.coverage(files[i]) for i in offsets}
    order = [ref] + sorted((i for i in offsets if i != ref), key=lambda i: span[i][0] - span[i][1])
    ground, ground_maps = event_merge.match_ground(files, offsets, order)
    pieces = event_merge.primary_pieces(files, offsets, order)
    t0 = math.floor(min(g[0]["start"] for g in sorties)) if sorties else 0.0

    air_maps = {i: {} for i in offsets}
    for n, g in enumerate(sorties):
        for m in g:
            air_maps[m["file"]][m["air"]["index"]] = n

    def remap(i, ref_text):
        kind, num = ref_text[:1], ref_text[1:]
        if kind == "A" and num.isdigit() and int(num) in air_maps[i]:
            return "A%d" % air_maps[i][int(num)]
        if kind == "G" and num.isdigit() and int(num) in ground_maps[i]:
            return "G%d" % ground_maps[i][int(num)]
        return "N"

    progress(35, "reading tracks and weapons")
    requests = collections.defaultdict(lambda: {"sorties": [], "intervals": []})
    for g in sorties:
        requests[g[0]["file"]]["sorties"].append(g[0]["air"]["index"])
    for a, b, f in pieces:
        requests[f]["intervals"].append((a - offsets[f], b - offsets[f]))
    keys = list(requests)
    jobs = []
    for i in keys:
        own = requests[i]["sorties"]
        # also the targets of these pilots' air-to-air missiles, as this game saw them (the
        # deeper missile checks: weapon_sim.refly_as_seen)
        aimed = sorted({tg for o in own for tg in files[i].get("a2a_targets", {}).get(o, ())} - set(own))
        jobs.append((files[i]["path"], own + aimed, own, requests[i]["intervals"]))
    with ProcessPoolExecutor(max_workers=max(1, min(workers, len(jobs)))) as ex:
        details = dict(zip(keys, ex.map(_pass2, jobs)))

    progress(60, "merging")
    ground_data = gamedata.load_ground_data(pack_dirs)
    entities, aircraft_list = {}, []
    for n, g in enumerate(sorties):
        src = g[0]
        i, a = src["file"], src["air"]
        shift = src["shift"] - t0
        tel = [{"t": round(t + shift, 3), "x": x, "y": y, "z": z, "yaw": h, "pitch": p, "roll": b,
                "g": gl, "ctrl": ctrl}
               for t, x, y, z, h, p, b, gl, ctrl in details[i][0][a["index"]]]
        went_down, gone = event_merge.sortie_end(tel)
        e = {"id": n + 1, "index": n, "player": a["name"], "aircraft": a["type"], "iff": a["iff"],
             "recorded_by_player": a["own"],
             "source": {"file": files[i]["file"], "own": a["own"],
                        "delay": 0.0 if a["own"] else delays[i], "seen_in_files": len(g)},
             "death_t": went_down, "gone_t": gone, "sample_count": len(tel), "telemetry": tel}
        entities[str(n + 1)] = e
        aircraft_list.append(e)

    ground_list = []
    for k, m in enumerate(ground):
        g = m["ground"]
        shift = m["shift"] - t0
        ground_list.append({"index": k, "type": g["type"], "name": g["name"], "iff": g["iff"],
                            "primary": g["primary"], "dat": ground_data.get(g["type"].upper()),
                            "samples": [dict(s, t=round(s["t"] + shift, 3)) for s in g["samples"]]})

    weapons = []
    for i in keys:
        for w in details[i][1]:
            owner = w["owner"]
            shift = offsets[i] - t0
            if owner.startswith("A"):
                shift -= 0.0 if files[i]["aircraft"][int(owner[1:])]["own"] else delays[i]
            w["owner"] = remap(i, owner)
            w["t"] = round(w["t"] + shift, 3)
            w["_file"], w["_owner_local"] = i, owner
            if w.get("target", -1) >= 0:
                w["_target_local"] = w["target"]
                tmap = ground_maps[i] if w["type"] in yfs_reader.AIR_TO_GROUND_GUIDED else air_maps[i]
                w["target"] = tmap.get(w["target"], -1)
            weapons.append(w)
    weapons.sort(key=lambda w: w["t"])

    # kills: one death, one kill (see event_merge.merge_kills)
    cover = {i: (span[i][0] + offsets[i] - t0, span[i][1] + offsets[i] - t0) for i in offsets}
    records = [(k["t"] + offsets[i] - t0, k["weapon"], remap(i, k["killer"]), remap(i, k["victim"]), i, k)
               for i in offsets for k in files[i]["kills"]]
    # an aircraft's kill is checked against when it went down (or, if it never tumbled, when
    # it was removed: some hits destroy an aircraft outright)
    deaths = {"A%d" % e["index"]: e["death_t"] if e["death_t"] is not None else e["gone_t"]
              for e in aircraft_list}
    track_end = {"A%d" % e["index"]: e["telemetry"][-1]["t"] for e in aircraft_list if e["telemetry"]}
    # a ground object is destroyed only when the replays agree and it never fires again (a kill
    # credit alone doesn't do it: event_merge.ground_fates); one still there "kept flying"
    for g, fate in zip(ground_list, event_merge.ground_fates(files, offsets, t0, ground, ground_maps, cover)):
        g.update(destroyed_t=fate["destroyed_t"], destroyed_check=fate["check"],
                 destroyed_evidence=fate["evidence"])
        deaths["G%d" % g["index"]] = fate["destroyed_t"]
        if fate["destroyed_t"] is None and fate["last_alive"] is not None:
            track_end["G%d" % g["index"]] = fate["last_alive"]
    own_file = {"A%d" % n: g[0]["file"] for n, g in enumerate(sorties) if g[0]["air"]["own"]}
    kills, unconfirmed = event_merge.merge_kills(records, deaths, track_end, own_file, cover)
    for u in unconfirmed:
        if u["victim"].startswith("G"):
            u["evidence"] = ground_list[int(u["victim"][1:])]["destroyed_evidence"]

    explosions, events = [], []
    for i in offsets:
        for e in files[i]["explosions"]:
            ts = e["t"] + offsets[i]
            if event_merge.primary_at(pieces, ts) == i:
                explosions.append(dict(e, t=round(ts - t0, 3), caused_by=remap(i, e["caused_by"])))
        for e in files[i]["events"]:
            ts = e["t"] + offsets[i]
            if event_merge.primary_at(pieces, ts) == i and e["text"] not in local:
                events.append({"t": round(ts - t0, 3), "text": e["text"]})
    explosions.sort(key=lambda e: e["t"])
    events.sort(key=lambda e: e["t"])

    loadouts = []
    for n, g in enumerate(sorties):
        src = g[0]
        for lo in files[src["file"]]["loadouts"]:
            if lo["id"] == src["air"]["id"]:
                loadouts.append({"t": round(lo["t"] + offsets[src["file"]] - t0, 3), "id": n + 1, "cfg": lo["cfg"]})

    sources = []
    for i, f in enumerate(files):
        s = {"file": f["file"], "recorded_by": f["recorder"], "field": f["field"]}
        if i in offsets:
            s.update({"included": True, "clock_offset": round(offsets[i] - t0, 3),
                      "from": round(cover[i][0], 1), "to": round(cover[i][1], 1),
                      "delay": delays[i], "anchors": info[i].get("anchors"),
                      "agreement_ms": round(1000 * info[i].get("spread", 0.0)),
                      "check": info[i].get("note") or info[i].get("positions", ""),
                      "sorties_used": sum(1 for g in sorties if g[0]["file"] == i)})
        else:
            s.update({"included": False, "reason": info[i]["left_out"]})
        sources.append(s)

    map_name = map_name or files[ref]["field"]
    match_data = {"format": 2, "field": files[ref]["field"], "map": map_name, "wind": files[ref]["wind"],
                  "sources": sources, "entities": entities, "ground_objects": ground_list,
                  "weapons": weapons, "kills": kills, "unconfirmed_kills": unconfirmed,
                  "explosions": explosions, "events": events, "loadouts": loadouts}

    progress(66, "loading the map")
    ground_height = load_map(match_data, [pack_dirs[0], os.path.join(HERE, "YSFLIGHT-master", "runtime")], fld_path)

    progress(70, "re-flying %d guided weapons" % sum(1 for w in weapons if w["type"] in weapon_sim.GUIDED))
    weapon_sim.simulate_all(match_data, aircraft_list, ground_list, ground_height)
    seen = _as_seen_targets(weapons, aircraft_list, files, details, offsets, delays, t0)
    progress(78, "re-flying %d missed missile(s) as the shooters' games saw them" % len(seen))
    weapon_sim.refly_as_seen(match_data, aircraft_list, seen, ground_height)
    for w in weapons:
        for key in ("_file", "_owner_local", "_target_local"):
            w.pop(key, None)
    link_missile_kills(match_data)

    # references for the viewer: aircraft by id (entities key), ground objects by index
    def resolve(ref_text):
        kind, num = ref_text[:1], ref_text[1:]
        if kind == "A":
            return {"kind": "aircraft", "id": int(num) + 1}
        if kind == "G":
            return {"kind": "ground", "index": int(num)}
        return None
    for w in weapons:
        w["owner_ref"] = resolve(w["owner"])
        if w.get("target", -1) >= 0:
            w["target_ref"] = resolve(("G%d" if w["type"] in yfs_reader.AIR_TO_GROUND_GUIDED else "A%d") % w["target"])
    for k in kills + unconfirmed:
        k["killer_ref"], k["victim_ref"] = resolve(k["killer"]), resolve(k["victim"])
        for c in k.get("other_claims", ()):
            c["killer_ref"] = resolve(c["killer"])
    for e in explosions:
        e["caused_by_ref"] = resolve(e["caused_by"])

    # how each sortie ended, with the evidence and likely causes (fates.py); each replay's copy of
    # the sortie on the event clock: when its track ended and when it started tumbling there
    progress(85, "working out how each aircraft went down")
    views = []
    for g in sorties:
        views.append([{"file": m["file"], "own": m["air"]["own"], "end": m["end"] - t0,
                       "down": (m["air"]["end"]["t_down"] + m["shift"] - t0)
                       if m["air"].get("end", {}).get("tumbled") else None} for m in g])
    fates.analyse(match_data, aircraft_list, views, own_file, cover, ground_height, resolve)

    progress(90, "writing the event file")
    if out_path.lower().endswith(".gz"):
        out_f = gzip.open(out_path, "wt", encoding="utf-8", compresslevel=GZIP_LEVEL)
    else:
        out_f = open(out_path, "w", encoding="utf-8")
    with out_f:
        json.dump(match_data, out_f, separators=(",", ":"))

    missile_kills = [k for k in kills if "reconstructed" in k]
    as_seen = sum(1 for k in missile_kills if k.get("reconstructed_as_seen"))
    print("-" * 70)
    print("Event: %s  (map %s), %d file(s) used of %d" % (match_data["field"], map_name,
          len(offsets), len(files)))
    for s in sources:
        if s["included"]:
            print("  + %-34s %-18s %7.0f..%-7.0f s  delay %.2f s  %s" % (
                s["file"][:34], (s["recorded_by"] or "?")[:18], s["from"], s["to"], s["delay"], s["check"]))
        else:
            print("  - %-34s %-18s left out: %s" % (s["file"][:34], (s["recorded_by"] or "?")[:18], s["reason"]))
    print("  sorties %d (%d from the pilot's own file), ground objects %d, weapon launches %d" % (
        len(aircraft_list), sum(e["recorded_by_player"] for e in aircraft_list), len(ground_list), len(weapons)))
    endings = collections.Counter(e["fate"]["kind"] for e in aircraft_list)
    print("  how sorties ended: %s; %d marked for a scorer's look" % (
        ", ".join("%s %d" % kv for kv in endings.most_common()), sum(e["fate"]["check"] for e in aircraft_list)))
    print("  kills %d: credit from the victim's game %d, the shooter's game %d, most games %d; "
          "disputed %d, death not seen %d" % (
              len(kills), sum(k["basis"] == "the victim's own game" for k in kills),
              sum(k["basis"] == "the shooter's own game" for k in kills),
              sum(k["basis"] == "most games" for k in kills),
              sum(1 for k in kills if k["other_claims"]), sum(1 for k in kills if not k["verified"])))
    print("  unconfirmed credits (no matching death) %d; missile kills reproduced %d of %d%s" % (
        len(unconfirmed), sum(k["reconstructed"] for k in missile_kills) + as_seen, len(missile_kills),
        " (%d of them only as the shooter's game saw them)" % as_seen if as_seen else ""))
    print("  ground objects destroyed %d (%d where the replays disagree); credits on ones still there %d" % (
        sum(g["destroyed_t"] is not None for g in ground_list),
        sum(g["destroyed_t"] is not None and g["destroyed_check"] for g in ground_list),
        sum(1 for u in unconfirmed if u["victim"].startswith("G"))))
    print("  saved %s in %.0f s" % (out_path, time.time() - started))
    progress(100, "done")


def load_map(match_data, scenery_dirs, fld_path=None):
    """The .fld given (else the event's field, found in the scenery lists): (re)build
    maps/<FIELD>.json if needed and return its terrain-height lookup (sea level if there is no
    map). A .fld other than the field's own is named after its file."""
    found = (fld_reader.find_field(match_data["field"], scenery_dirs)
             or fld_reader.find_field(match_data["map"], scenery_dirs))
    if fld_path:
        same = found and os.path.normcase(os.path.abspath(found[1])) == os.path.normcase(os.path.abspath(fld_path))
        found = found if same else (os.path.splitext(os.path.basename(fld_path))[0], fld_path)
    match_data["map_file"] = None
    if not found:
        print("WARNING: no .fld found for %s; the event is shown without its map" % match_data["field"])
        return weapon_sim.sea_level
    name, fld_path = found
    maps_dir = os.path.join(HERE, "maps")
    os.makedirs(maps_dir, exist_ok=True)
    out = os.path.join(maps_dir, fld_reader.map_file_name(name))
    if not fld_reader.map_is_current(out, fld_path):
        field = fld_reader.build_map(name, fld_path, out)
        print("map %s built from %s" % (os.path.basename(out), fld_path))
    else:
        field = fld_reader.load_field(fld_path, name)
    match_data["map_file"] = os.path.basename(out)
    return fld_reader.GroundHeight(field.grids)


def _as_seen_targets(weapons, aircraft_list, files, details, offsets, delays, t0):
    """{weapon index: (Track, file name, delay)} for the deeper missile checks: each air-to-air
    missile that missed its target in the re-flight, fired from the shooter's own replay, with the
    target's track as that replay recorded it (other aircraft there run `delay` behind; not
    corrected: that is what the shooter's game showed and flew the missile against). Only when
    the target lost health, went down or vanished while the missile flew (or within 3 s after):
    a miss that did nothing needs no second look."""
    hurt = {}                     # aircraft index -> times it lost health, went down or ended
    for a in aircraft_list:
        tel = a["telemetry"]
        hurt[a["index"]] = sorted([tel[k]["t"] for k in range(1, len(tel))
                                   if tel[k]["ctrl"][9] < tel[k - 1]["ctrl"][9]]
                                  + [t for t in (a["death_t"], a["gone_t"]) if t is not None])
    out = {}
    for n, w in enumerate(weapons):
        end = w.get("end") or {}
        if w["type"] not in weapon_sim.AIR_TO_AIR or w.get("target", -1) < 0 or "_target_local" not in w:
            continue
        if end.get("reason") == "hit" and end.get("aircraft_index") == w["target"]:
            continue
        times = hurt.get(w["target"], [])
        k = bisect.bisect_left(times, w["t"])
        if k >= len(times) or times[k] > end.get("t", w["t"] + 60.0) + 3.0:
            continue
        i, shooter, target = w["_file"], w["_owner_local"], w["_target_local"]
        planes = files[i]["aircraft"]
        if not (shooter.startswith("A") and shooter[1:].isdigit() and int(shooter[1:]) < len(planes)
                and planes[int(shooter[1:])]["own"]) or target >= len(planes) or planes[target]["own"]:
            continue              # not the shooter's own game, or the target's own game (no lag)
        samples = details[i][0].get(target)
        if not samples:
            continue
        shift = offsets[i] - t0
        track = weapon_sim.Track([{"t": t + shift, "x": x, "y": y, "z": z, "yaw": h, "pitch": p, "roll": b,
                                   "ctrl": ctrl} for t, x, y, z, h, p, b, g, ctrl in samples])
        out[n] = (track, files[i]["file"], delays[i])
    return out


def link_missile_kills(match_data):
    """Missile kills get "reconstructed" (did a re-flown missile from the same shooter hit
    that victim within 1.5 s of the recorded kill?) and, if so, "weapon_index" of it; failing
    that, "reconstructed_as_seen" (it hit the victim as the shooter's own game showed it:
    weapon_sim.refly_as_seen; that game runs `delay` behind, so a little more time is allowed).
    KILLCREDIT is what YSFlight decided; the re-flown paths are a reconstruction."""
    hits, seen_hits = {}, {}
    for i, w in enumerate(match_data["weapons"]):
        end = w.get("end")
        if end and end["reason"] == "hit":
            victim = ("A%d" % end["aircraft_index"]) if "aircraft_index" in end else ("G%d" % end["ground_index"])
            hits.setdefault((w["owner"], victim), []).append((end["t"], i))
        seen = w.get("as_seen")
        if seen and seen["reason"] == "hit" and "aircraft_index" in seen:
            seen_hits.setdefault((w["owner"], "A%d" % seen["aircraft_index"]), []).append((seen["t"], i, seen["delay"]))
    for k in match_data["kills"]:
        if k["weapon"] not in (1, 2, 6, 10):     # AIM9, AGM65, AIM120, AIM9X
            continue
        near = [(abs(t - k["t"]), i) for t, i in hits.get((k["killer"], k["victim"]), [])
                if abs(t - k["t"]) < 1.5]
        k["reconstructed"] = bool(near)
        if near:
            k["weapon_index"] = min(near)[1]
            continue
        near = [(abs(t - k["t"]), i) for t, i, delay in seen_hits.get((k["killer"], k["victim"]), [])
                if abs(t - k["t"]) < 2.0 + delay]
        if near:
            k["reconstructed_as_seen"] = True
            k["weapon_index"] = min(near)[1]


def main():
    ap = argparse.ArgumentParser(description="YSFlight replay(s) -> event file for the viewer")
    ap.add_argument("replays", nargs="*")
    ap.add_argument("-o", "--out", default="parsed_telemetry.json")
    ap.add_argument("--map", default=None, help="map name (default: the replay's field)")
    ap.add_argument("--fld", default=None, help="the map's .fld (default: found from the replay's field)")
    ap.add_argument("--pack", default=os.path.join(HERE, "gamefiles"))
    args = ap.parse_args()
    replays = []
    for r in args.replays or [os.path.join("Raw_Data", "1-WW3_event.yfs")]:
        # Windows' shells pass "Raw_Data/*.yfs" on as it is: the wildcards are expanded here
        replays += (sorted(glob.glob(r)) or [r]) if ("*" in r or "?" in r) else [r]
    missing = [p for p in replays + ([args.fld] if args.fld else []) if not os.path.exists(p)]
    if missing:
        print("ERROR: file not found: %s" % ", ".join(missing))
        sys.exit(1)
    packs = [args.pack, os.path.join(HERE, "YSFLIGHT-master", "runtime", "ground")]
    build_event(replays, args.out, args.map, packs, args.fld)


if __name__ == "__main__":
    multiprocessing.freeze_support()   # for a packaged .exe later
    sys.stderr = sys.stdout            # errors show up in the viewer's log, which reads stdout
    main()
