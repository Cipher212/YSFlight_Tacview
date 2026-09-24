# YSFlight RvB replay viewer ("poor man's Tacview") - notes for Claude

The user organises YSFlight Red vs Blue (RvB) events and is not a developer: explain in plain
words, give step-by-step guides, keep the app a plain utility (function over looks; no glow,
filler labels or constant animation). Scoring stays **man in the loop**: the app gathers every
angle and the evidence; scorers watch it and score by hand in their Google Sheet using the
viewer's timestamps (seconds since event start). Never automate scoring decisions (kills,
kamikaze, specials are the scorers'). 2-4 people will use it; end goal: a clickable .exe.
All future events follow the RvB 6 standard (map Luavi); RvB 1 (2ch map) is legacy, ignore it.

This folder is both the Godot 4.7.2 project (`project.godot`, main scene `node_3d.tscn`) and the
Python pipeline. Windows, PowerShell 5.1; Godot at
`C:\Users\zafar\Downloads\Godot_v4.7.2-stable_win64.exe\Godot_v4.7.2-stable_win64_console.exe`
(on the user's PC). Git is not installed there; the user pushes with GitHub Desktop / the web UI.
The replays (`Raw_Data/`) and events (`events/`) are not in the repository (too big).

## Data flow

`replay_parser.py` (CLI; the viewer runs it via `event_builder.gd`, prints `PROGRESS n text`):
1. `yfs_reader.read_file` (pass 1, per replay, in parallel): thinned tracks, kills, events,
   loadouts, recorder, and how each track ends (`end`: tumbled?). `read_details` (pass 2): full
   tracks and weapon launches, only from the replay chosen for each sortie.
2. `event_merge.py`: clock alignment (anchors: kills, server-wide messages, spawns), match check
   by positions, per-replay delay, sortie identity across replays (label + position <500 m; the
   pilot's own replay preferred), ground objects, kills: **one death, one kill** (credit: the
   victim's game, else the shooter's, else most games; `other_claims`, unconfirmed credits).
3. `gamedata.py`: ground `.dat` (GUNRANGE, SAMRANGE, HTRADIUS, STRENGTH) and each object's box
   from the ground lists (`gro*.lst`: `<dat> <model> <collision> <cockpit> <coarse>`).
4. `fld_reader.py` (`load_map`): the `.fld` -> `maps/<FIELD>.json` (format 3) and a terrain
   height lookup; `--fld` picks the file (the start menu passes it).
5. `weapon_sim.py`: re-flies guided weapons with YSFlight's own rules (FsWeapon::Move/HitObject).
   The replay stores only launches (and KILLCREDIT / explosions); YSFlight's own replay re-flies
   them the same way.
6. `fates.py`: how every sortie ended, with evidence and likely causes (%); kill confidence.
7. Writes the event JSON (entities with 20 Hz telemetry, weapons with re-flown paths, kills,
   explosions, ground objects, sources, `events` = text messages, `loadouts` = WPNCFG). An `-o`
   name ending in `.gz` is written gzip-compressed (level 5: ~7x smaller, a few seconds more);
   the viewer builds `events/<name>.json.gz` and reads both `.json.gz` and old plain `.json`.
   The pipeline puts its own folder on `sys.path` (Windows embeddable Python doesn't).

Viewer scripts: `node_3d.gd` (controller: clock, play/rewind/steps, loading on a thread,
aircraft, name tags, flight path vectors, camera, keys, view settings), `ui_layer.gd` (start
menu, bars, side panel: search box, review filter, jump buttons, tabs Pilots / Kills / Deaths /
Messages / Files / View, details box with the review buttons and note), `review.gd` (the review
marks and their file), `combat_layer.gd` (trails, weapon models, tethers, markers, fireballs,
kill feed), `weapon_models.gd` (which model each weapon uses), `ribbon_layer.gd` (energy ribbons
+ black smoke of aircraft going down; shader-windowed, built once on the loader thread),
`ground_layer.gd` (ground objects: game models as MultiMesh per type, blocks if none),
`map_layer.gd` (the map), `dnm_model.gd` (YSFlight `.dnm`/`.srf` models, cached in
`user://model_cache`, parsed on WorkerThreadPool), `event_builder.gd`, `fmt.gd`, `ys_air.gd`,
`paths.gd` (where the data folders are). Settings (last event, panel, `view_*`) live in
`user://settings.cfg`: the user's own; tests must not write it.

## Conventions and facts (verified; don't re-litigate)

- YSFlight world is left-handed (x east, y up, z north). Godot position = `(x, y, -z)`; attitude
  = `Basis.from_euler(Vector3(pitch, yaw, roll))` (YXZ), no negations; model nose = -Z. The
  same holds for `.dnm`/`.fld` attitudes (units: 1/65536 turn). Other people suggested "YZX":
  it was tested and fails in steep turns.
- `.yfs` aircraft sample ctrl (18): state, vgw, spoiler, gear, flap, brake, smoke, vapor, flags,
  strength (health), throttle, elevator, aileron, rudder, trim, thrust_vector, reverser,
  bomb_bay. vgw/spoiler/gear/flap/brake 0-255; throttle, thrust vector, bomb bay 0-99;
  elevator/aileron/rudder -99..99; flags bit 1 = afterburner. States: 0 flying, 1 ground,
  2 stall, 3 removed (every track ends with it), 4/5 tumbling (going down), 6 stopped,
  7 overrun. At death health jumps to 1.
- Aircraft/ground numbering (A<n>, G<n>, IDANDTAG) is per replay; merged refs are
  `{"kind": "aircraft", "id": n+1}` / `{"kind": "ground", "index": n}`.
- Units shown: IAS/TAS in knots, Mach, altitude in feet; tethers in metres.
- Teams: Blue IFF 1, Red IFF 4, anything else neutral grey.
- Models: aircraft come from `aircraft/<team>/` (`.dat` IDENTIFY = the replay's name; `.dat`
  and `.dnm` pair by file name, then prefix (J7 -> J7E), then name (Q-5 -> Q5)). Only gear
  (class 0, t = (gear - 0.2) / 0.6) and afterburner (class 2) animate (the user: RvB aircraft
  have no other animation); other parts at state 0; IRST/pipper parts skipped. POS's last value
  does NOT hide a part (the UCAV body has it 0 and shows in the game); ZA = transparency
  (0 opaque, face numbers from 0); in viewer axes a face's points run counter-clockwise around
  its normal. Ground objects use the model from column 2 of `gro*.lst`, static. `.srf`
  keywords come short or long (V/VER, F/FAC, C/COL, N/NOR, B/BRI, E/END; 18 weapon models and
  the 2ch ground models use the long ones).
- Weapon models (as FsWeapon::Draw): the shooter's `.dat` line `WPNSHAPE <type> FLYING <file>`
  (types AIM9 AIM9X AIM120 AGM65 B500 B250 B500HD RKT FLR FUEL), else the game's own model in
  `YSFLIGHT-master/runtime/misc` (aim9, aim9x, aim120, agm65, bomb, bomb250, bomb500hd, rocket,
  fueltank). The `.dat` paths (`user/RvB/weapon/...`) are looked up by name in `aircraft/weapon`:
  same name, else the shortest starting with it (AIM-9 -> AIM-9L, 13 aircraft), else at most 2
  letters different (Phyton3 -> Python3); the drones' `user/matrix_v2` files aren't in the pack
  (stock models). Flying models include their exhaust plume (bright faces). Flares stay balls.
  Models are tinted 35 % towards the team colour, scaled by the weapon size.
- Trails show the weapon kind (user request): air-to-air solid from launch, AGM dashed (2 path
  samples on, 1 off), bombs dotted (last 3 s), dropped fuel tanks grey dots, rockets a 15 m
  streak, guns tracers; all in the shooter's team colour. The View tab explains it.
- View settings (user requests): the aircraft size scales only the aircraft (and the flight
  path vectors), not the ribbons or smoke: those have their own "Ribbon width" (default 1x).
  Weapon-end balls and kill crosses show only for "Markers stay" seconds (default 30).
- Review queue: marks (confirmed / rejected + note) for kills (`k<n>`), unconfirmed credits
  (`c<n>`) and endings (`d<aircraft id>`), saved on every change in `<event>.review.txt`
  (JSON `{"format": 1, "marks": [{kind, t, names, status, note, changed}]}`, next to the event;
  `.txt` so Notepad opens it and it stays out of the event lists). A mark re-attaches to the
  item of its kind with the same names within 3 s (event rebuilt); unmatched marks are kept and
  counted. Each scorer runs their own copy, so one review file per event copy. Notes save 0.8 s
  after typing stops. N / C jump to the next kill / CHECK still to review; right after a jump
  the next one counts from the item picked (the replay starts a few seconds early).
- Paths: every data file goes through `paths.gd` (`Paths.of("aircraft")` ...): the project
  folder from Godot, the .exe's folder when exported (an exported `res://` is inside the .exe).
- RvB rules from the user: over-G = a death (-100), no credit; RvB servers damage aircraft above
  about 11-12 G, one health point at a time (~every 0.3 s), so over-G can only finish an
  aircraft that is nearly out of health. A collision is a crash (kamikaze is judged by scorers).
  A leave = any exit in flight (game crash, network, exit key); leaving while threatened may earn
  the opponent a Kill Leave: the app lists the threats. Specials are manual.
- The event clock starts at the first aircraft seen in the replays used: scorers must build from
  the same replays (or share one event file), or their timestamps differ.
- No server replay until about May 2027. Then: a replay marked SERVER is the master (its
  removals = confirmed deaths); without one all replays are equal.
- Privacy: the scoring spreadsheet (`C:\rvb\scoring` on the user's PC) is private; don't copy it
  anywhere. Keep this repository private (replays hold player data; game files are third-party).

## Windows package (.exe)

`python tools/package.py [--python-zip <embeddable Python .zip or URL>]` (needs Godot 4.7.2 and
its export templates; preset "Windows Desktop" in `export_presets.cfg`: pck embedded, no rcedit,
`maps/ events/ Raw_Data/ build/ tools/` excluded) -> `build/YSFlight Replay Viewer/` and
`build/YSFlight-Replay-Viewer-win64.zip` (~47 MB): the .exe, the pipeline `.py` files,
`aircraft/ gamefiles/ maps/`, `YSFLIGHT-master/runtime/{ground,misc,scenery}`, empty `events/`
`Raw_Data/`, `README.txt`. The viewer runs `python/python.exe` next to it if present, else
`python` on the PATH. The cloud session's network policy blocks www.python.org, so the first
package (2026-09-24) has no Python: opening events works anywhere, building events needs Python
installed. Not run on Windows here (no Windows); the same export for Linux was run and checked.

## Testing

- Temporary scene: `_test_x.gd` with `extends "res://node_3d.gd"`, `super()` in `_ready`, and
  `func _set_setting(_k, _v): pass` (don't touch the user's settings). Drive `ui.*` / methods,
  `await RenderingServer.frame_post_draw`, save `get_viewport().get_texture().get_image()`.
- Run with `Start-Process ... -PassThru` + `WaitForExit(timeout)`; `--headless` for logic
  (no screenshots). A script error can leave Godot hanging: kill only the test's PIDs (find them
  by command line). Test windows appear on the user's screen. Delete test files and their `.uid`.
- Pipeline: rebuild RvB 6 (~70 s) from the 12 `Raw_Data/*20260718*` replays (11 used; Manish (5)
  is another match); expected: 210 sorties, 218 kills, 91 of 119 missile kills reproduced.
- Measure, don't guess: e.g. line widths were measured from screenshot pixels.
- Cloud sessions (no replays): `tools/make_test_replay.py OUT.yfs` writes a made-up 9-minute
  Luavi fight (7 sorties: 2 missile kills, an AGM kill, a crash, a leave under fire, an
  unconfirmed credit, bombs, rockets, guns, flares, a fuel tank, chat, loadouts); build it with
  the pipeline (-> 7 sorties, 3 kills, 3 of 3 reproduced). `tools/test_viewer.gd` (headless,
  TEST_EVENT=...) checks models, trails, markers, ribbons, lists, jumps and the review file;
  `tools/test_shots.gd` takes screenshots under `xvfb-run` with `--rendering-driver opengl3`
  (Compatibility renderer: not what the user's D3D12 PC shows, but fine for layout and models).
  `tools/test_main.gd` is the settings-safe viewer they use; `tools/` has a `.gdignore`. Godot
  4.7.2 Linux and its export templates come from github.com/godotengine/godot/releases (the
  user allowed Godot downloads).

## Pitfalls met

- GDScript: `:=` on Variant values won't compile; no tuple assignment; JSON numbers are floats
  (int() before using them as keys); bottom-anchored containers need grow_vertical BEGIN.
- Godot 4.7: a material with depth_draw DISABLED is drawn in the transparent pass; there is no
  line width (on the user's PC, D3D12 + Intel, 3D lines are 4 px: flight path vectors are
  camera-facing strips sized in `get_window().size` pixels; they are cut at 1 m in front of the
  camera, else a vector reaching past the camera blows up into a wide beam);
  `TreeItem.move_to_bottom()` does not exist; a `.csv` in the project gets imported as
  translations by the open editor (keep documents in `docs/`, which has a `.gdignore`);
  `get_visible_rect()` is in stretched units; export templates don't take `--script`;
  `SceneTree.process_frame` fires before the nodes' `_process`.
- The UI is ~1152 units wide at 1920x1080 (stretch canvas_items): the bottom bar is full.
- In `.srf`, `V` lines inside a face (`F` ... `E`) are point numbers, not points.
- YSFlight has no over-G breakup in its own code (only blackout); RvB's G-limiter is a server rule.

## Status (2026-09-24) and next steps

Done: merged events; playback UI (rewind, fast forward, frame steps, speeds, seconds in the
clock); start menu with `.fld` choice; Luavi map 1:1 with terrain; game models for aircraft
(gear/burner), ground objects and weapons (WPNSHAPE); trails by weapon kind, tethers,
detonation/kill markers (time-limited), energy ribbons (own width), flight path vectors, name
tags, black smoke for aircraft going down; fates with causes and likelihoods (Deaths tab, CHECK
marks, details box), kill confidence; review queue (confirm / reject + notes, file next to the
event); search, review filter, N / C jumps, loss ticks on the timeline; Messages tab; loadouts
in the sortie details; compressed event files; the Windows package (without Python so far).

Agreed next steps, in order:
1. Deeper evidence: re-fly missiles against the target as the shooter's replay saw it (should
   raise 91/119); gun checks in the shooter's world; "ghost" copies of an aircraft from each
   replay and a switch to see a moment as one player's game saw it; lag spikes per replay.
2. Cameras: top-down orthographic tactical map, kill review (frame shooter + victim, slow
   motion, loop), flight data strip (G, speed, height, throttle), engagement / missile cams,
   chase and cockpit views, declutter "only who's involved".
3. Package: bundle Python once www.python.org is allowed (or the user supplies the zip);
   maybe a GitHub Actions build. Later: server-replay master (May 2027).

## From the first chat (2026-09-23/24)

- The user sends batches of requests ("start all together; stop only if you need
  clarification"), tests each build on their PC and reports back. "No code, just answer" means
  answer only. Built last and not yet tested by them: fates, Deaths tab, details box, kill
  confidence, playback controls. Ask how they went.
- Models: the user only has Blender 2.49b and won't re-export 30 aircraft. .obj was dropped
  (it can't carry YSFlight's vertex paint), so they supply game files instead. Never hand-draw
  assets; ask for a picture or model. dronered / droneblue = one plane, two paints.
- There is no "right" replay (lower-latency players may be closer to the truth), so all
  replays count equally.
- The sheet is filled by hand AFTER the event (hours of replay watching); its times can be off
  by several seconds. The app comes first: no sheet export, no cross-check (the user: "bad idea").
- RvB 6 fates baseline: killed 92, ground exit 36, crashed 35, shot down 28, end 12, unknown 7,
  43 CHECK; 174 of 218 kills at confidence >= 0.7. No clear over-G death and no mid-flight
  leave (every aircraft that vanished without tumbling was 0-4 m above the ground).
- Cloud sessions: Linux, no replays (1 GB; ask the user if needed), no events, no Godot (ask
  before downloading anything). The Testing notes above are for the user's Windows PC. Work on
  a branch, open a PR, and tell the user in plain steps how to merge it on GitHub, pull it in
  GitHub Desktop, and what to test.

## From the second chat (cloud, 2026-09-24)

- The user tested the build above (fates, Deaths tab, details box, kill confidence, playback):
  "runs really well", no bugs. They asked how to test changes: merge the PR on GitHub, then
  Fetch/Pull origin in GitHub Desktop (only changed files download), start the viewer as usual.
- Each scorer runs their own copy of the app (so reviews are per copy, no merging).
- The user allowed Godot downloads (Linux or Windows) in cloud sessions, and said "yes to all"
  to: review queue, quick jumps + search + loss ticks, Messages tab, loadouts, the .exe sooner,
  compressed event files; plus: aircraft size must not widen the ribbons ("giant snakes"),
  weapon/kill markers must disappear after a while, weapons need their real models (WPNSHAPE)
  and A2A trails must differ from rockets, bombs, fuel tanks and AGMs.
