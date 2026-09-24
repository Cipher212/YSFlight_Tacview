# YSFlight RvB replay viewer

A Tacview-style viewer for scoring YSFlight Red vs Blue (RvB) events. It merges the replays
(`.yfs`) that several players recorded of the same event into one timeline, then shows it in 3D:
the map, every aircraft and ground object with its own game model, weapons, kills, and how each
aircraft went down, with the evidence. Scorers watch it and score by hand in the RvB sheet,
using the viewer's timestamps. It gathers the angles; scorers decide.

## What you need

- **Godot 4.7.2** (the standard build, not .NET). Open this folder as a project, or run
  `Godot_v4.7.2-stable_win64.exe --path <this folder>`.
- **Python 3** on the PATH (standard library only). The viewer runs it to build events.

## Using it

1. Start the viewer. The start menu offers the last event, a saved one, or a new one.
2. **New event:** choose the replays (`.yfs`) of one event (as many players' files as you
   have; they are merged), check the map (`.fld`, picked from what the replays say), then Build.
   The event file goes to `events/`.
3. **Watching:** the bottom bar has play/pause, rewind (plays backwards), fast forward, frame
   steps and jumps; the clock shows seconds too, for the scoring sheet. Keys: Space play/pause,
   J / K / L rewind / pause / fast, `,` `.` frame back / forward (Shift: 1 s), Left / Right 10 s
   (Shift: 60 s), Tab next aircraft, Esc free camera, P side panel. Click an aircraft to follow
   it; right-drag to look around; mouse wheel to zoom.
4. **Side panel:** Pilots (every sortie and how it ended), Kills (with how sure each one is),
   Deaths (every aircraft's ending with the likely causes and percentages; CHECK = worth a
   scorer's look; click to jump there), Files (which replays were used), View (sizes, what is
   drawn, game models or simple blocks).

## Folders

| Folder | What | In the repository |
|---|---|---|
| `*.gd`, `*.tscn` | the viewer (Godot) | yes |
| `*.py` | the pipeline: replays -> event file | yes |
| `aircraft/` | RvB aircraft game files (`.dat`, `.dnm`), by team | yes |
| `gamefiles/` | RvB game files: map (`.fld`), ground objects, scenery lists | yes |
| `maps/` | maps built from `.fld` files (made automatically) | yes |
| `YSFLIGHT-master/` | YSFlight's source (reference; stock ground objects) | yes |
| `docs/` | reference lists (e.g. Luavi's ground objects) | yes |
| `Raw_Data/` | the replays (`.yfs`) | no (too big) |
| `events/` | built events (`.json`) | no (too big; rebuild them) |

## Building an event from the command line

```
python -X utf8 replay_parser.py --fld gamefiles/user/RvB/ww3/Luavi.fld -o events/RvB6.json Raw_Data/*.yfs
```
