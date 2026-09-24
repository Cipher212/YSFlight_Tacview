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
   loadouts, recorder, how each track ends (`end`: tumbled?), ground objects' launch times
   (`ground_fire`) and whom each aircraft aimed air-to-air missiles at (`a2a_targets`).
   `read_details` (pass 2): full tracks and weapon launches, only from the replay chosen for each
   sortie, plus the full tracks of its pilots' missile targets as that replay recorded them.
2. `event_merge.py`: clock alignment (anchors: kills, server-wide messages, spawns), match check
   by positions, per-replay delay, sortie identity across replays (label + position <500 m; the
   pilot's own replay preferred), ground objects and when each was destroyed (`ground_fates`,
   rule below), kills: **one death, one kill** (credit: the victim's game, else the shooter's,
   else most games; `other_claims`, unconfirmed credits).
3. `gamedata.py`: ground `.dat` (GUNRANGE, SAMRANGE, HTRADIUS, STRENGTH; a key given twice: the
   last wins, as in the game - the 2S6M's SAMRANGE 6000m then 2000m) and each object's box from
   the ground lists (`gro*.lst`: `<dat> <model> <collision> <cockpit> <coarse>`).
4. `fld_reader.py` (`load_map`): the `.fld` -> `maps/<FIELD>.json` (format 3) and a terrain
   height lookup; `--fld` picks the file (the start menu passes it).
5. `weapon_sim.py`: re-flies guided weapons with YSFlight's own rules (FsWeapon::Move/HitObject).
   The replay stores only launches (and KILLCREDIT / explosions); YSFlight's own replay re-flies
   them the same way. `refly_as_seen`: an air-to-air missile that missed its target is flown
   again against the target as the shooter's own replay recorded it (rule below).
6. `fates.py`: how every sortie ended, with evidence and likely causes (%); kill confidence;
   per sortie a damage log (`damage`); for crashes the nearest aircraft / ground object.
7. Writes the event JSON (entities with 20 Hz telemetry, weapons with re-flown paths, kills,
   explosions, ground objects, sources, `events` = text messages, `loadouts` = WPNCFG). An `-o`
   name ending in `.gz` is written gzip-compressed (level 5: ~7x smaller, a few seconds more);
   the viewer builds `events/<name>.json.gz` and reads both `.json.gz` and old plain `.json`.
   The pipeline puts its own folder on `sys.path` (Windows embeddable Python doesn't) and
   expands `*` / `?` in replay names itself (PowerShell passes `Raw_Data/*.yfs` on as it is).
   In the viewer: Menu > Choose files..., select all the event's replays at once (Ctrl / Shift
   click), Build event -> `events/<first>_and_<n>_more.json.gz`.

Viewer scripts: `node_3d.gd` (controller: clock, play/rewind/steps, loading on a thread,
aircraft and their shadows, name tags with health, flight path vectors, camera and the top view,
keys, view settings, better lighting), `ui_layer.gd` (start menu with the folder pick, bars, side
panel: search box, review filter, jump buttons, tabs Pilots / Kills / Deaths / Ground / Chat /
Files / View, details box with the review buttons and note), `review.gd` (the review
marks and their file), `combat_layer.gd` (trails, weapon models, tethers, markers, fireballs,
kill feed), `weapon_models.gd` (which model each weapon uses), `ribbon_layer.gd` (energy ribbons
+ black smoke of aircraft going down; shader-windowed, built once on the loader thread),
`ground_layer.gd` (ground objects: game models as MultiMesh per type, blocks if none; hidden
from `destroyed_t`; SAM / AAA range rings), `map_layer.gd` (the map, and its relief-shaded copy
for better lighting; `ground_at(x, z)` = height and slope of the ground under a point, for the
shadows), `dnm_model.gd` (YSFlight `.dnm`/`.srf` models, cached in
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
  same name, else the shortest starting with it (AIM-9 -> AIM-9L, 13 aircraft; the user: any
  AIM-9 model is fine), else at most 2 letters different (Phyton3 -> Python3). Files from another
  pack (the drones' `user/matrix_v2`, not here) get the team's weapon of that kind: aircraft in
  `aircraft/red` eastern (R-77, R-73, Kh-25ML, FAB), `aircraft/blue` western (AIM-120B, AIM-9L,
  AGM-114A, GBU-12, Mk81) - the user's rule for the drones. Flying models include their exhaust
  plume (bright faces). Flares stay balls. Models are tinted 35 % towards the team colour,
  scaled by the weapon size.
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
- Ground objects destroyed (user request: players got kill messages for objects still there
  and firing): a candidate is each time a replay switches the object to state 1 (destroyed).
  It is rejected if any replay records the object launching a weapon more than 3 s later (its
  own launches, counted per replay: `ground_fire` in `yfs_reader`) or if 10 s later more of the
  replays recording it show it standing than destroyed. The earliest accepted one is
  `destroyed_t` (drawn until then, then hidden); a tie or a rejected candidate sets
  `destroyed_check`; the reasons are in `destroyed_evidence`. A credit on an object never
  destroyed becomes an unconfirmed credit with those reasons (via `track_end` = last seen
  standing). Ground objects never come back once killed (the user: only a server reset would,
  and that doesn't happen in an RvB event). Events built before this fall back to the first
  state-1 sample of the object's own replay.
- Aircraft shadows (user request, "like YSFlight"), as FsSimulation::SimDrawComplexShadow: every
  part flattened straight down onto the plane of the ground under the aircraft (the terrain
  triangle there from `map_layer.ground_at`, else sea level 0), plain black, 0.4 m up and pulled
  0.1 % towards the eye (YSFlight: polygon offset). Drawn in the transparent pass right after the
  map's layers (render_priority -1, with depth writes): drawn opaque, OpenGL let the big flat sea
  shapes paint over it. View tab switch "Aircraft shadows". YSFlight also puts shadows on
  carrier decks (not done here).
- Deeper missile check (user request): an air-to-air missile whose re-flight misses its target is
  flown again against the target as the shooter's own replay recorded it (that game shows others
  `delay` late: the raw track, not delay-corrected, and the target's flares shifted by the delay),
  when the missile comes from the shooter's own replay and the target isn't that replay's
  recorder. A hit there gives `w["as_seen"]` and, for a kill within 2 s + delay,
  `k["reconstructed_as_seen"]`; the build log says "reproduced N of M (K only as the shooter's
  game saw them)". Fates give it P_MISSILE_HIT_SEEN (4 points).
- Damage log (user request; `e["damage"]`): every health drop before the aircraft went down;
  drops under 1 s apart of one kind (over-G or not) are one entry; the drop into tumbling is its
  own entry ("went down"). What was near: re-flown weapons that hit it or passed within 60 m
  (also as the shooter saw them), explosions within 100 m (not an unnamed one after a fatal drop:
  its own crash), gun rounds / rockets within 40 m, over-G (>= 11 G), another aircraft within
  30 m, the ground within 15 m. Health on the name tags: "Health 35/40" (against the health at
  the start of the track), "Going down" in states 4/5 (the game then sets health to 1).
- Crash finder (user: without cluttering the UI): only evidence lines in the details of crashed /
  collision / unclear endings: the nearest other aircraft (within 20 km, closing speed) and the
  nearest standing ground object (within 5 km).
- Ground tab: per team and type "x of y destroyed" (every solid object; clouds left out); under a
  type only the objects destroyed, damaged or credited; "#n" = the object's number among those of
  its type (fates.py names them the same way). Click: 5 s before, the free camera looks at it.
- Range rings (user: toggleable; off at first): SAMRANGE solid, GUNRANGE dashed, team colour,
  flat at the object + 3 m, drawn through everything at a fixed pixel width (a band mesh + shader,
  two MultiMeshes), only while the object stands.
- Top view (T, user request "snap to top-down"): orthographic, north up, camera 60 km up; wheel
  zooms (0.3 - 120 km), WASD / right-drag pans, following an aircraft keeps it centred; aircraft
  drawn at least 18 px long; vectors flat strips; clicks pick by screen distance.
- Better lighting (user: can be turned off; on at first): the terrain again with colours scaled
  by new / old light per point (sun 30 degrees up from the south-south-west, ambient .37 +
  diffuse .9: flat ground as bright as YSFlight's 82 %); models roughness .35, lit from that sun,
  casting self-shadows (600 m) that only models receive (the map is unlit), SSAO. Off: YSFlight's
  daylight, matt models, no shadows or SSAO (also lighter for the graphics card).
- Whole event from a folder: the .yfs files there (and one folder down) grouped by a date in the
  name (20260718, 2026-07-18 ...), else the day saved, and by map; newest first; the pipeline's
  match check still leaves out a replay of another match.
- Black smoke only behind the tumble a track ends in (the final stretch of states 3/4/5 with a
  4 or 5, as `event_merge.sortie_end`): replays can show an aircraft tumbling for a moment and
  then flying on (lag; the user saw smoke that never ended behind aircraft that kept flying).
  The damage log likewise counts only the final tumble as "went down".
- Keys (user request): the viewer takes keys in `_input`, before the side panel: Tab only ever
  switches aircraft (never moves the keyboard focus), shortcuts work whatever list or switch was
  clicked last; only while a text box is typed in do keys go to it (Tab / Esc leave it); a
  click in the 3D view drops the focus.
- Look (user requests): the font is ACES07 (`fonts/ACES07_Regular.ttf`, the project's
  `gui/theme/custom_font`; it reaches Label3Ds too; it has no "…" or dashes: Godot falls back);
  UI words start with a capital ("Throttle", "Health 35/40", "Gear up", "Not reviewed yet",
  endings "Shot down by ..."); the top bar button is "Start / Restart"; the window title is
  "YSFlight Replay Viewer <version>" (config/name stays "Tacview_App": it names the user://
  folder with the user's settings).
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

## Windows package (.exe) and releases

`python tools/package.py [--python-zip <embeddable Python .zip or URL>]` (needs Godot 4.7.2 and
its export templates; preset "Windows Desktop" in `export_presets.cfg`: pck embedded, no rcedit,
`maps/ events/ Raw_Data/ build/ tools/` excluded) -> `build/YSFlight Replay Viewer/` and
`build/YSFlight-Replay-Viewer-win64.zip` (~47 MB): the .exe, the pipeline `.py` files,
`aircraft/ gamefiles/ maps/`, `YSFLIGHT-master/runtime/{ground,misc,scenery}`, empty `events/`
`Raw_Data/`, `README.txt`. The viewer runs `python/python.exe` next to it if present, else
`python` on the PATH. GitHub Actions (`.github/workflows/package.yml`) builds it with Python
3.12.10 embedded on every push to main or a `claude/` branch (or by hand); the user downloads it
from the run's Artifacts (kept 30 days). The zip (~50 MB) is over the 30 MB file limit of the
chat, and the cloud session's network policy blocks www.python.org, so Actions is the way to
hand it over. Not run on Windows (no Windows here); the same export for Linux was run and checked.
Releases (permanent downloads): `.github/workflows/release.yml` runs when the `VERSION` file
changes (on main or a claude/ branch; by hand once it is on main): it builds the package with
`--version` (version.txt in it, shown in the start menu; zip `YSFlight-Replay-Viewer-<v>-win64.zip`)
and publishes the GitHub Release <v> with `docs/release_notes/<v>.md`; the same version again
replaces the zip. The package's README.txt is the scorers' one-page how-to. The repository is
private: other scorers need to be collaborators to download, or the user shares the zip.

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
- Cloud sessions (no replays): `tools/make_test_replay.py OUT.yfs [SECOND.yfs]` writes a
  made-up 9-minute Luavi fight (7 sorties: 3 missile kills, an AGM kill, a crash, a leave under
  fire at 7:01, an unconfirmed credit, bombs, rockets, guns, flares, a fuel tank, chat, loadouts,
  a SAM that keeps firing after Tester's replay shows it destroyed with a kill credit, Bandit3's
  gun run on Tester (40 -> 35 health), Wingman's 11.8 G pull (3 health) and a false 1 s tumble
  at 5:50 (no smoke), Striker killed at 4:35
  by Bandit2's AIM-9 that hits only as Bandit2's game (0.3 s lag) saw it) and optionally the same
  fight as Bandit2's replay (clock 37.25 s later, 0.3 s lag; there the SAM stands). Built
  together -> 7 sorties, 4 kills, 4 of 4 reproduced (1 only as the shooter's game saw it), 1
  ground object destroyed (the tank, 2:05), 1 credit on one still there (the SAM); tester.yfs
  alone -> 3 of 4. `tools/test_viewer.gd` (headless, TEST_EVENT=...) checks models, trails,
  markers, ribbons, lists, jumps, the review file, ground objects, shadows, the Ground tab,
  health tags, damage log, crash finder, rings, top view, lighting and the folder pick;
  `tools/test_shots.gd` takes screenshots under `xvfb-run`. The
  user's renderer (Forward+) runs here on lavapipe: `apt-get install mesa-vulkan-drivers`, then
  `VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json xvfb-run -a -s "-screen 0 1920x1080x24"
  godot --path . --rendering-driver vulkan --rendering-method forward_plus --resolution
  1920x1080 --script tools/test_shots.gd` (slow but right); `--rendering-driver opengl3` is the
  Compatibility renderer (what PCs without Vulkan/D3D12 fall back to) and draws differently.
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
  `SceneTree.process_frame` fires before the nodes' `_process`; the headless (dummy) renderer
  keeps no MultiMesh instance transforms (always identity): test logic state, not drawing data.
- OpenGL (Compatibility) only: an opaque shape lying just above the flat map layers (the sea)
  was painted over by the layer's big sea triangles at some camera distances (Forward+ fine);
  drawing it in the transparent pass after the layers fixed it. Unshaded ALBEDO is linear:
  0.05 shows as grey 63 in Forward+ but 7 in OpenGL.
- The UI is ~1152 units wide at 1920x1080 (stretch canvas_items): the bottom bar is full; the
  side panel's tab bar fits 7 short titles (with "Messages" the 7th went behind scroll arrows).
- In `.srf`, `V` lines inside a face (`F` ... `E`) are point numbers, not points.
- YSFlight has no over-G breakup in its own code (only blackout); RvB's G-limiter is a server rule.

## Status (2026-09-24) and next steps

Done: merged events; playback UI (rewind, fast forward, frame steps, speeds, seconds in the
clock); start menu with `.fld` choice; Luavi map 1:1 with terrain; game models for aircraft
(gear/burner), ground objects and weapons (WPNSHAPE); trails by weapon kind, tethers,
detonation/kill markers (time-limited), energy ribbons (own width), flight path vectors, name
tags, black smoke for aircraft going down; fates with causes and likelihoods (Deaths tab, CHECK
marks, details box), kill confidence; review queue (confirm / reject + notes, file next to the
event); search, review filter, N / C jumps, loss ticks on the timeline; Chat tab; loadouts
in the sortie details; compressed event files; the Windows package (built by GitHub Actions);
ground objects destroyed by a rule across replays, and hidden from then on; aircraft shadows;
Ground tab; health on name tags; damage log; crash finder; SAM / AAA range rings; top view (T);
better lighting; whole event from a folder; missiles re-flown as the shooter's game saw them;
v1.0 release workflow and the one-page how-to. Not yet measured on RvB 6 (no replays here): the
new "reproduced" count (was 91 of 119), the ground-object numbers, the damage logs.

Agreed next steps, in order:
1. Deeper evidence, the rest: gun checks in the shooter's world; "ghost" copies of an aircraft
   from each replay and a switch to see a moment as one player's game saw it; lag spikes per
   replay.
2. Cameras: kill review (frame shooter + victim, slow motion, loop), flight data strip (G, speed,
   height, throttle), engagement / missile cams, chase and cockpit views, declutter "only who's
   involved". (The top view is done.)
3. Later: server-replay master (May 2027).

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
- They tested that build: "works really well". Then: ground objects must disappear when
  destroyed, decided by a rule (players got kill messages for objects still there and firing),
  and aircraft need YSFlight-style shadows for depth. RvB 6 kill counts may drop when rebuilt:
  false ground kills become unconfirmed credits.

## From the third chat (cloud, 2026-09-24)

- The user answered the proposals: Ground tab yes; damage log "important", plus a simple health
  tally "9/10 health" next to the name; bookmarks no; range circles yes, toggleable; batch
  selection of all replays of one event yes; crash finder yes "but it should not impede on other
  things, UI may start to get cluttered"; v1 permanent release: go ahead. Also: snap to a
  top-down map view; deeper missile checks yes; settings for improved shading / lighting that
  can be turned off. They asked for the .exe to be repacked for testing after each batch.
- Answered: RvB ground objects never respawn once killed (only a server reset would, and that
  doesn't happen in an RvB event).

## From the fourth chat (cloud, 2026-09-24)

- The user ran v1.0 on RvB 6 rebuilt from 14 replays (loading took about 2 minutes) and asked,
  before calling it final: "Start / Restart" on the top bar (it is the only way to start the
  replay); black smoke that never ended behind aircraft that flew on after a false death
  ([RED]Crazy, a UCAV at 1/5 health) - "if it can't be fixed cheaply, remove it" (fixed: only
  the final tumble); Tab only for switching aircraft, never focusing buttons or text boxes; the
  ACES07 font; capitalised UI words. Released as v1.1.
