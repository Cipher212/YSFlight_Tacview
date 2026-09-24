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
6. `fates.py`: how every sortie ended, with evidence and likely causes (%); kill confidence.
7. Writes the event JSON (entities with 20 Hz telemetry, weapons with re-flown paths, kills,
   explosions, ground objects, sources).

Viewer scripts: `node_3d.gd` (controller: clock, play/rewind/steps, loading on a thread,
aircraft, name tags, flight path vectors, camera, keys, view settings), `ui_layer.gd` (start
menu, bars, side tabs Pilots / Kills / Deaths / Files / View, details box), `combat_layer.gd`
(trails, weapon shapes, tethers, markers, fireballs, kill feed), `ribbon_layer.gd` (energy
ribbons + black smoke of aircraft going down; shader-windowed, built once on the loader
thread), `ground_layer.gd` (ground objects: game models as MultiMesh per type, blocks if none),
`map_layer.gd` (the map), `dnm_model.gd` (YSFlight `.dnm`/`.srf` models, cached in
`user://model_cache`, parsed on WorkerThreadPool), `event_builder.gd`, `fmt.gd`, `ys_air.gd`.
Settings (last event, panel, `view_*`) live in `user://settings.cfg`: the user's own; tests must
not write it.

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
  its normal. Ground objects use the model from column 2 of `gro*.lst`, static.
- Maps: colours carry YSFlight's default daylight (sun (0, .866, -.5), ambient .3 + diffuse .6)
  so everything is unlit; flat maps are painted in order per same-plane layer (transparent pass,
  render_priority from MIN+1; MIN is the ground backdrop). Luavi's black ground colour is
  replaced by the sea colour (the user asked: no black void).
- RvB rules from the user: over-G = a death (-100), no credit; RvB servers damage aircraft above
  about 11-12 G, one health point at a time (~every 0.3 s), so over-G can only finish an
  aircraft that is nearly out of health. A collision is a crash (kamikaze is judged by scorers).
  A leave = any exit in flight (game crash, network, exit key); leaving while threatened may earn
  the opponent a Kill Leave: the app lists the threats. Specials are manual.
- No server replay until about May 2027. Then: a replay marked SERVER is the master (its
  removals = confirmed deaths); without one all replays are equal.
- Privacy: the scoring spreadsheet (`C:\rvb\scoring` on the user's PC) is private; don't copy it
  anywhere. Keep this repository private (replays hold player data; game files are third-party).

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

## Pitfalls met

- GDScript: `:=` on Variant values won't compile; no tuple assignment; JSON numbers are floats
  (int() before using them as keys); bottom-anchored containers need grow_vertical BEGIN.
- Godot 4.7: a material with depth_draw DISABLED is drawn in the transparent pass; there is no
  line width (on the user's PC, D3D12 + Intel, 3D lines are 4 px: flight path vectors are
  camera-facing strips sized in `get_window().size` pixels); `TreeItem.move_to_bottom()` does
  not exist; a `.csv` in the project gets imported as translations by the open editor (keep
  documents in `docs/`, which has a `.gdignore`); `get_visible_rect()` is in stretched units.
- In `.srf`, `V` lines inside a face (`F` ... `E`) are point numbers, not points.
- YSFlight has no over-G breakup in its own code (only blackout); RvB's G-limiter is a server rule.

## Status (2026-09-24) and next steps

Done: merged events; playback UI (rewind, fast forward, frame steps, speeds, seconds in the
clock); start menu with `.fld` choice; Luavi map 1:1 with terrain; game models for aircraft
(gear/burner) and ground objects; trails, weapon shapes, tethers, detonation/kill markers,
energy ribbons, flight path vectors, name tags, black smoke for aircraft going down; fates with
causes and likelihoods (Deaths tab, CHECK marks, details box), kill confidence.

Agreed next steps, in order:
1. Review queue: scorers mark kills/deaths confirmed/rejected with notes, saved in a file next
   to the event (the event file itself is never changed). No sheet export (the user said no).
2. Deeper evidence: re-fly missiles against the target as the shooter's replay saw it (should
   raise 91/119); gun checks in the shooter's world; "ghost" copies of an aircraft from each
   replay and a switch to see a moment as one player's game saw it; lag spikes per replay.
3. Cameras: top-down orthographic tactical map, kill review (frame shooter + victim, slow
   motion, loop), flight data strip (G, speed, height, throttle), engagement / missile cams,
   chase and cockpit views, declutter "only who's involved".
4. Later: server-replay master (May 2027), packaging as an .exe with the Python pipeline
   bundled, weapon models from `aircraft/weapon` (ignored for now).
