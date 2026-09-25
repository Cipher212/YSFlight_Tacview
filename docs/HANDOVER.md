# Handover: from the cloud sessions to Claude on the user's PC

Read `CLAUDE.md` first (it is loaded automatically): it has how everything works, the user's
rules and the testing setup. This file adds what the cloud sessions could not do, and a code
review by Gemini (2026-09-25) with the cloud Claude's verdict on each point. The user asked for
the review's recommendations, amended, to be kept here and not in `CLAUDE.md`.

State at handover: v1.4.1 released (GitHub Release v1.4.1); pull request #1 merged into `main`.
From here the work happens on the user's Windows PC, with their real replays.

## 1. First job: measure on the real data

The cloud sessions had no replays, so these were never checked on RvB 6. Rebuild RvB 6 from the
`Raw_Data/*20260718*` replays (see `CLAUDE.md` > Testing) and report to the user:

- Missile kills reproduced: it was 91 of 119 before the "as the shooter's game saw it" re-flight.
- Ground objects destroyed, and credits on ground objects still standing.
- A few damage logs next to what the replay shows.
- Cinematic mode: are shots 3 (flyby) and 4 (ground camera) steady on real, jittery tracks? If
  not, F9 saves the followed aircraft's flight path next to the event file; tune the smoothing
  from that (`node_3d.gd`: SMOOTH_SIGMA, SMOOTH_SIGMA_ATT, AIM_SIGMA).
- Frame rate in the biggest furball, cinematic mode on and off.
- For point 2 below: the build's total time and peak memory (watch the python.exe processes
  in Task Manager during the build).

## 2. Code review (Gemini) and verdicts

Rule for all of these: measure before and after, change behaviour only where a measurement or a
real bug says so, and `tools/test_viewer.gd` must still pass (headless, on a built event).

### 2.1 Subprocess read loop (`event_builder.gd`) - DO, small

Gemini: when Python exits, `get_line()` returns "" while `OS.is_process_running()` may still be
true, "a tight infinite loop that pegs a CPU core".

Verdict: partly right. It is not infinite: the pipe is blocking, so `get_line()` waits while
Python is quiet, and once the process has exited `is_process_running()` turns false (Windows
reports the exit at once). But between Python closing its output and the process ending, the
loop can spin at full speed for a moment. Cheap fix:

```gdscript
		elif out.eof_reached() or not OS.is_process_running(p["pid"]):
			break
		else:
			OS.delay_msec(5)
```

Also worth it while there: after the loop, `OS.get_process_exit_code(pid)`; if it isn't 0 and
PROGRESS 100 never came, show the last lines of the output in the error message (today a
failed build only says it failed).

### 2.2 Python memory (`yfs_reader.py`) - DO the streaming, MEASURE the rest; NO numpy

Gemini: whole-file reads (`f.read().split("\n")` in `_lines`) and lists of tuples can use
gigabytes; bundle numpy; "vectorize the O(N^2) clock alignment".

Verdict:
- Whole-file read: right, and it matters on a weak laptop. Measured in the cloud: reading a
  3.9 MB replay peaks at about 4x the file size. RvB replays are up to ~130 MB and pass 1 runs
  up to 4 at once (`replay_parser.py`, ProcessPoolExecutor), so roughly 2 GB at the peak.
  `read_file` and `read_details` walk the lines with an index (`while i < n: lines[i]`) and
  look ahead for multi-line records; change them to pull lines from the open file (an iterator
  with one line of look-ahead) instead of a list. Same output: compare the event JSON before and
  after on RvB 6 (sorties, kills, reproduced count must not change).
- Also consider fewer workers when the PC has little memory (e.g. 2 when under 8 GB).
- Lists of tuples in `weapon_sim.py` (`self.p = [(x, y, z) ...]`) and the merge: measure first
  (point 1). If they matter, `array.array("d")` (standard library, compact) is enough.
- numpy: no. It adds a package to the embedded Windows Python and the release workflow for
  little gain. The alignment is not O(N^2): `densest_offset` sorts and slides a window
  (O(n log n)); `median_distance` uses `interp`, a binary search (O(n log n)).

### 2.3 Gun rounds and rockets (`combat_layer.gd`) - NO change unless a profile says so

Gemini: the per-frame loop iterates all 60,000+ rounds; move ballistics to a vertex shader.

Verdict: wrong about the cost. `_add_shots` starts with `shot_t0.bsearch(t - shot_longest)`,
so each frame touches only rounds fired within the longest flight time, not all of them. One
real weak spot: `shot_longest` is the longest flight of any round, so one long rocket flight
widens the window for every gun round. If the furball profile (point 1) shows
`combat_layer.update` above ~2 ms, first keep separate windows for guns and rockets; only then
consider the shader (MultiMesh custom data + vertex shader, as `ribbon_layer.gd` and the
cinematic trails already do).

### 2.4 Big scripts, UI built in code - NO .tscn rewrite; split scripts when touching them

Gemini: `ui_layer.gd` (~1,820 lines), `node_3d.gd` (~1,500), `cinema.gd` (~1,360) are
monolithic; rebuild the UI as `.tscn` scenes in the editor.

Verdict: building the UI in code is deliberate. Every change is a readable text diff, Claude can
test it headless (`test_viewer.gd` drives `ui.*` directly), and the user (not a developer) never
has to click through the Godot editor. Hand-editing `.tscn` files is error-prone for an AI, and a
big-bang rewrite would risk regressions for no visible gain. But the files are long: when a
change touches one, move a self-contained part into its own script first, behaviour unchanged,
for example:
- `ui_layer.gd`: the Ground, Files (replay summary), View and Keys builders -> their own scripts;
- `cinema.gd`: the shot functions (chase family, ghost mounts, crane) -> a shots script;
- `node_3d.gd`: the top view and the track smoothing (`_filtered`, `track_*`) -> helpers.

### 2.5 Static typing - YES in new code and hot loops; no project-wide pass

Gemini: untyped arrays and dictionaries block Godot 4's typed optimisations; type everything.

Verdict: typed GDScript helps in tight loops and catches mistakes earlier, so type new code and
the per-frame functions (`_process`, `combat_layer.update`, `cinema.update`, `cinema_fx.update`).
A full pass would change little: most data comes from the event JSON as Variant dictionaries, and
the heavy data already lives in Packed arrays. Remember the `CLAUDE.md` pitfall: `:=` on a
Variant value doesn't compile; give the type explicitly (`var x: float = d["x"]`).

## 3. Order of work

1. Point 1 (measure on RvB 6), and report the numbers to the user.
2. 2.1 (read loop) and 2.2 streaming: small, safe, useful on weak PCs. Release as a patch
   version (change `VERSION`, add `docs/release_notes/<v>.md`).
3. The rest only when a measurement asks for it, or when touching those files anyway.
4. Then whatever the user asks next. Keep `CLAUDE.md` up to date as before (new facts, new
   pitfalls, a short "From the ... chat" note per session).

## 4. Working locally (differences from the cloud sessions)

- Windows, PowerShell 5.1; Godot 4.7.2 at the path in `CLAUDE.md`; test windows appear on the
  user's screen; kill only the test's own Godot processes.
- `Raw_Data/` and `events/` exist here (not on GitHub). Never commit them, and never copy the
  scoring spreadsheet (`C:\rvb\scoring`) anywhere.
- Git: the user has GitHub Desktop (it brings its own git). GitHub stays the backup and builds
  the Windows package and releases (Actions). Ask before pushing.
- The user is not a developer: plain words, step-by-step instructions, and tell them what to test.
