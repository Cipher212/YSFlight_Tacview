# YSFlight RvB replay viewer

A Tacview-style viewer for scoring YSFlight Red vs Blue (RvB) events. It merges the replays
(`.yfs`) that several players recorded of the same event into one timeline, then shows it in 3D:
the map, every aircraft, ground object and weapon with its own game model, kills, and how each
aircraft went down, with the evidence. Scorers watch it, mark each kill and death confirmed or
rejected with a note, and score by hand in the RvB sheet using the viewer's timestamps. It
gathers the angles; scorers decide.

## What you need

- **The Windows package**: unzip it and double-click `YSFlight Replay Viewer.exe`. Nothing else
  to install: it carries its own Python for building events, and its `README.txt` explains how to
  use it on one page. Releases (permanent): this repository's **Releases** (right side of its
  main page) > the newest version > `YSFlight-Replay-Viewer-<version>-win64.zip`. Test builds of
  every change: **Actions** tab > **Windows package** > the newest run > **Artifacts** >
  `YSFlight-Replay-Viewer-win64` (kept 30 days).
- **Or this folder as a project**: **Godot 4.7.2** (the standard build, not .NET): open this
  folder as a project, or run `Godot_v4.7.2-stable_win64.exe --path <this folder>`; and
  **Python 3** on the PATH (standard library only), which the viewer runs to build events.

## Using it

1. Start the viewer. The start menu offers the last event, a saved one, or a new one.
2. **New event:** **Whole event from a folder...** and pick the folder with the replays (`.yfs`):
   they are sorted into events by the date in their names (else the day they were saved) and
   map, and the newest event is chosen (the list offers the others). Or Choose files... and pick
   all the replays of one event at once (Ctrl / Shift click, Ctrl+A). Check the map (`.fld`,
   picked from what the replays say), then Build.
   The event file (`.json.gz`) goes to `events/`. Everyone scoring should use the same replays,
   or share one event file: the clock starts at the first aircraft seen, so different replay
   sets can give different times.
3. **Watching:** the bottom bar has play/pause, rewind (plays backwards), fast forward, frame
   steps and jumps; the clock shows seconds too, for the scoring sheet. Above the time bar:
   kills (upper row, shooter's colour) and losses (lower row; orange = worth a look). Keys:
   Space play/pause, J / K / L rewind / pause / fast, `,` `.` frame back / forward (Shift: 1 s),
   Left / Right 10 s (Shift: 60 s), N / Shift+N next / previous kill, C / Shift+C next / previous
   kill or death still to review, Tab next aircraft, Esc free camera, P side panel, **T top
   view** (the map from straight above: WASD or right-drag to move, wheel to zoom). Click an
   aircraft to follow it; right-drag to look around; mouse wheel to zoom. Name tags show the
   pilot, health (`35/40 health`), aircraft, height and speed.
4. **Side panel:** Find (pilot names or words) and Show (all, still to review, confirmed ...)
   filter the lists; the buttons jump to the previous / next kill or CHECK. Tabs: Pilots (every
   sortie, how it ended, its damage log and loadout), Kills (with how sure each one is), Deaths
   (every aircraft's ending with the likely causes and percentages, the damage log, and for
   crashes the nearest aircraft and ground object; CHECK = worth a scorer's look), Ground (every
   ground target by team and type: destroyed when and by whom; click to look at it), Chat (the
   replays' text messages; click to go there), Files (which replays were used), View (sizes,
   ribbon width, how long markers stay, what is drawn: shadows, SAM / AAA range rings, better
   lighting ..., what the weapon trails mean).
5. **Review:** pick a kill or death, watch it, then Confirm or Reject (press again to undo) and
   type a note. Marks are saved at once in `<event>.review.txt` next to the event file (the
   event file itself is never changed); they stay attached if the event is rebuilt.

Weapon trails, in the shooter's team colour: solid line = air-to-air missile, dashed =
air-to-ground missile, dots = bomb (grey dots: a dropped fuel tank), short streak = rocket.

Ground objects disappear when the replays agree they were destroyed: a replay shows it
destroyed, nobody's replay shows it firing after that (3 s grace), and 10 s later most replays
that recorded it show it gone. A kill credit on an object that is still there (a player got the
kill message, but it kept firing) is listed as an unconfirmed credit, with the reasons. Events
built before this rule hide an object as soon as its replay shows it destroyed: rebuild them.

Aircraft cast a black shadow straight down on the ground or sea below them, as in YSFlight
(View > Aircraft shadows).

Missiles are re-flown with YSFlight's own rules; one that misses is also re-flown against the
target as the shooter's own game showed it (a little late, because of lag): a hit there counts
as reproduced "as the shooter's game saw it". The damage log lists every time an aircraft lost
health and what was near it then (a missile, gun rounds, over-G above about 11 G, another
aircraft, the ground). Better lighting (View tab, on at first) shades the hills with a lower sun
and makes the aircraft shinier, shading themselves; turn it off for YSFlight's flat daylight or
if the replay runs slowly.

## Folders

| Folder | What | In the repository |
|---|---|---|
| `*.gd`, `*.tscn` | the viewer (Godot) | yes |
| `*.py` | the pipeline: replays -> event file | yes |
| `aircraft/` | RvB aircraft game files (`.dat`, `.dnm`), by team; `weapon/` the weapon models | yes |
| `gamefiles/` | RvB game files: map (`.fld`), ground objects, scenery lists | yes |
| `maps/` | maps built from `.fld` files (made automatically) | yes |
| `YSFLIGHT-master/` | YSFlight's source (reference; stock ground objects and weapons) | yes |
| `docs/` | reference lists (e.g. Luavi's ground objects) | yes |
| `tools/` | making the Windows package; a made-up test replay and viewer tests | yes |
| `Raw_Data/` | the replays (`.yfs`) | no (too big) |
| `events/` | built events (`.json.gz`) and their review files | no (too big; rebuild them) |
| `build/` | the Windows package | no (made by `tools/package.py`) |

## Building an event from the command line

```
python -X utf8 replay_parser.py --fld gamefiles/user/RvB/ww3/Luavi.fld -o events/RvB6.json.gz Raw_Data/*.yfs
```

(Works in PowerShell too: the pipeline expands `*` itself.)

## Making the Windows package

GitHub does it on every change (`.github/workflows/package.yml`); a new `VERSION` (v1.1 ...)
also publishes it as a release (`.github/workflows/release.yml`, notes in
`docs/release_notes/<version>.md`). By hand:

```
python tools/package.py [--python-zip python-3.12.10-embed-amd64.zip] [--version v1.1]
```

Needs Godot 4.7.2 on the PATH (as `godot`, or `--godot <program>`) with its export templates
(Godot: Editor > Manage Export Templates). With `--python-zip` (Windows' "embeddable" Python
from python.org) the package carries its own Python. Result: `build/YSFlight-Replay-Viewer-win64.zip`.
