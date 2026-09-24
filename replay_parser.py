"""Turns one or more YSFlight replays (.yfs) of the same event into an event file for the viewer.

    python replay_parser.py [options] replay1.yfs [replay2.yfs ...]
        -o, --out FILE   event file to write (default: parsed_telemetry.json)
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
import json
import math
import multiprocessing
import os
import statistics
import sys
import time
from concurrent.futures import ProcessPoolExecutor

import event_merge
import fates
import fld_reader
import gamedata
import weapon_sim
import yfs_reader

HERE = os.path.dirname(os.path.abspath(__file__))


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
    jobs = [(files[i]["path"], requests[i]["sorties"], requests[i]["sorties"], requests[i]["intervals"])
            for i in keys]
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
            if w.get("target", -1) >= 0:
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
    for g in ground_list:
        destroyed = [s["t"] for s in g["samples"] if s["state"] == 1]
        deaths["G%d" % g["index"]] = destroyed[0] if destroyed else None
    track_end = {"A%d" % e["index"]: e["telemetry"][-1]["t"] for e in aircraft_list if e["telemetry"]}
    own_file = {"A%d" % n: g[0]["file"] for n, g in enumerate(sorties) if g[0]["air"]["own"]}
    kills, unconfirmed = event_merge.merge_kills(records, deaths, track_end, own_file, cover)

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
    with open(out_path, "w") as out_f:
        json.dump(match_data, out_f, separators=(",", ":"))

    missile_kills = [k for k in kills if "reconstructed" in k]
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
    print("  unconfirmed credits (no matching death) %d; missile kills reproduced %d of %d" % (
        len(unconfirmed), sum(k["reconstructed"] for k in missile_kills), len(missile_kills)))
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


def link_missile_kills(match_data):
    """Missile kills get "reconstructed" (did a re-flown missile from the same shooter hit
    that victim within 1.5 s of the recorded kill?) and, if so, "weapon_index" of it.
    KILLCREDIT is what YSFlight decided; the re-flown paths are a reconstruction."""
    hits = {}
    for i, w in enumerate(match_data["weapons"]):
        end = w.get("end")
        if end and end["reason"] == "hit":
            victim = ("A%d" % end["aircraft_index"]) if "aircraft_index" in end else ("G%d" % end["ground_index"])
            hits.setdefault((w["owner"], victim), []).append((end["t"], i))
    for k in match_data["kills"]:
        if k["weapon"] not in (1, 2, 6, 10):     # AIM9, AGM65, AIM120, AIM9X
            continue
        near = [(abs(t - k["t"]), i) for t, i in hits.get((k["killer"], k["victim"]), [])
                if abs(t - k["t"]) < 1.5]
        k["reconstructed"] = bool(near)
        if near:
            k["weapon_index"] = min(near)[1]


def main():
    ap = argparse.ArgumentParser(description="YSFlight replay(s) -> event file for the viewer")
    ap.add_argument("replays", nargs="*")
    ap.add_argument("-o", "--out", default="parsed_telemetry.json")
    ap.add_argument("--map", default=None, help="map name (default: the replay's field)")
    ap.add_argument("--fld", default=None, help="the map's .fld (default: found from the replay's field)")
    ap.add_argument("--pack", default=os.path.join(HERE, "gamefiles"))
    args = ap.parse_args()
    replays = args.replays or [os.path.join("Raw_Data", "1-WW3_event.yfs")]
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
