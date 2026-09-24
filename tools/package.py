"""Builds the Windows package of the viewer: a folder, and a .zip of it, that runs without Godot:
unzip it and double-click "YSFlight Replay Viewer.exe".

    python tools/package.py [--godot GODOT] [--python-zip ZIP_OR_URL] [--out DIR] [--version v1.0]

Needs Godot 4.7.2 and its export templates (Godot: Editor > Manage Export Templates). With
--python-zip (Windows' "embeddable" Python from python.org, e.g.
https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip) the package carries
its own Python, so building events needs nothing installed; without it, building events needs
Python on the PATH (opening events never does).

The package (--out, default build/):
    YSFlight Replay Viewer.exe      the viewer (the "Windows Desktop" export preset)
    python/                         Python for the pipeline, if --python-zip was given
    *.py                            the pipeline
    aircraft/ gamefiles/ maps/      game files and maps, as in this folder
    YSFLIGHT-master/runtime/        stock ground objects, weapons and maps (ground, misc, scenery)
    events/ Raw_Data/               built events go to events/; replays can go in Raw_Data/
    README.txt                      how to use it, on one page
    version.txt                     with --version (shown in the start menu)
The zip is build/YSFlight-Replay-Viewer-win64.zip (with --version: ...-<version>-win64.zip).
"""
import argparse
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
NAME = "YSFlight Replay Viewer"
PIPELINE = ["replay_parser.py", "yfs_reader.py", "event_merge.py", "gamedata.py", "fld_reader.py",
            "weapon_sim.py", "fates.py"]
DATA = ["aircraft", "gamefiles", "maps", "YSFLIGHT-master/runtime/ground", "YSFLIGHT-master/runtime/misc",
        "YSFLIGHT-master/runtime/scenery"]
README = """YSFlight Replay Viewer - how to use it
=================================

It merges the replays (.yfs) several players recorded of one RvB event into one timeline and
shows it in 3D with the evidence for every kill and death. It gathers the angles; the scorers
decide and fill in the scoring sheet by hand, with the viewer's times (seconds since the start).

1. START
   Double-click "YSFlight Replay Viewer.exe". If Windows says "Windows protected your PC",
   click More info > Run anyway (the program isn't signed; that is normal for home-made tools).
   Keep the folders next to the .exe (aircraft, gamefiles, maps, YSFLIGHT-master, python).

2. GET THE EVENT
   Best: one person builds the event and shares the event file (.json.gz) with the other
   scorers, so everyone's times match. Put it in the "events" folder, then Menu > Open a saved
   event. To build one: Menu > Whole event from a folder... and pick the folder with the
   replays (or Choose files... and select them all), check the map, then Build event (about a
   minute). %s

3. WATCH
   Bottom bar: play, rewind, fast forward, frame steps, jumps. The clock also shows seconds.
   Marks above the time bar: kills (top) and losses (bottom; orange = worth a look).
   Keys: Space play/pause, J / K / L rewind / pause / fast, , and . one frame (Shift: 1 s),
   Left / Right 10 s (Shift: 60 s), N next kill, C next item still to review (Shift: back),
   Tab next aircraft, Esc free camera, T top view (the map from above), P side panel.
   Mouse: click an aircraft to follow it, right-drag to look around, wheel to zoom.
   Name tags show pilot, health (Health 9/10), aircraft, height and speed.

4. SCORE
   Side panel tabs: Pilots (every sortie), Kills (with how sure each one is, in %%), Deaths
   (how each aircraft went down, with the likely causes; CHECK = worth a look), Ground (every
   ground target: destroyed when and by whom), Chat (the replays' messages), Files, View.
   Pick a kill or death: the replay goes a few seconds before it and the details box shows the
   evidence (damage log, re-flown missiles, nearby aircraft for crashes). Then press Confirm or
   Reject and type a note. Your marks are saved at once next to the event file
   (<event>.review.txt); the event file itself never changes. Show: "To review" lists what is
   left. Find: type a pilot's name.

5. WHAT THE EVIDENCE MEANS
   - Missiles are re-flown with YSFlight's own rules (the replays only store launches). "As the
     shooter's game saw it": the hit happened in the shooter's game, which saw the target a bit
     late (lag).
   - Unconfirmed credit: a game gave a kill but the victim didn't go down then (or a ground
     object kept firing).
   - Damage log: every time an aircraft lost health and what was near it (missile, gun rounds,
     over-G above about 11 G, another aircraft).
   - The app never decides a score: kamikaze, specials and every final call are the scorers'.

6. VIEW TAB
   Sizes of aircraft, weapons, text and ribbons; how long trails and markers stay; switches for
   shadows, SAM and AAA range rings, better lighting and more. Settings are remembered.
   Keys... changes which key does what (click a key, press the new one).

7. CINEMATIC MODE (for videos)
   M (or the Cinematic button) hides everything but the world, for recording with OBS; M or
   Esc brings the panels back, F11 is full screen, F1 lists its keys. Missiles smoke, things
   explode and aircraft burn as in the game, only better looking.
   Shots: 1 Chase, 2 Wingman, 3 Flyby (waits beside the aircraft's path), 4 Ground camera
   (stays where the camera is and zooms like a long lens: fly there with 9 first), 5 Orbit,
   6 Weapon (rides the next missile or bomb), 7 Lock-on (over the shoulder, target ahead; R:
   next target), 8 Crane (glides through points set with K), 9 Drone (WASD, E/Q, Shift).
   Tab picks the aircraft. Wheel: closer / further, Ctrl+wheel: zoom, Alt+wheel: background
   blur, right-drag: angle, hold Z: snap zoom, hold X: slow motion, Space: pause (eases to a
   stop), Backspace: retake from where you pressed Play. View tab: shake, slow motion speed,
   orbit speed, crane move time.
"""
PYTHON_NOTE_BUNDLED = "The Python it needs is included (the python folder)."
PYTHON_NOTE_PATH = ("This needs Python 3 installed (python.org; tick \"Add python.exe to PATH\"). "
                    "Opening events doesn't.")


def main():
    ap = argparse.ArgumentParser(description="Build the Windows package of the viewer")
    ap.add_argument("--godot", default=shutil.which("godot") or "godot", help="the Godot 4.7.2 program")
    ap.add_argument("--python-zip", default=None, help="Windows embeddable Python: a .zip file or its URL")
    ap.add_argument("--out", default=os.path.join(REPO, "build"))
    ap.add_argument("--version", default=None, help="e.g. v1.0: shown in the start menu and in the zip's name")
    args = ap.parse_args()

    folder = os.path.join(args.out, NAME)
    if os.path.isdir(folder):
        shutil.rmtree(folder)
    os.makedirs(folder)
    exe = os.path.join(folder, NAME + ".exe")
    print("exporting the viewer ...", flush=True)
    r = subprocess.run([args.godot, "--headless", "--path", REPO, "--export-release", "Windows Desktop", exe],
                       capture_output=True, text=True)
    if r.returncode != 0 or not os.path.isfile(exe):
        print(r.stdout[-3000:], r.stderr[-3000:])
        sys.exit("ERROR: the Godot export failed (are the 4.7.2 export templates installed?)")

    print("copying the pipeline and game files ...", flush=True)
    for f in PIPELINE:
        shutil.copy2(os.path.join(REPO, f), folder)
    for d in DATA:
        shutil.copytree(os.path.join(REPO, d), os.path.join(folder, d),
                        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".gdignore"))
    for d, note in (("events", "Built events (.json.gz) go here, with their review files (.review.txt)."),
                    ("Raw_Data", "You can keep the replays (.yfs) here.")):
        os.makedirs(os.path.join(folder, d))
        with open(os.path.join(folder, d, "README.txt"), "w", encoding="utf-8", newline="\r\n") as f:
            f.write(note + "\n")      # (also keeps the folder in zips that drop empty ones)

    bundled = False
    if args.python_zip:
        print("adding Python ...", flush=True)
        src = args.python_zip
        if src.startswith("http"):
            src = os.path.join(args.out, os.path.basename(src))
            if not os.path.isfile(src):
                urllib.request.urlretrieve(args.python_zip, src)
        with zipfile.ZipFile(src) as z:
            z.extractall(os.path.join(folder, "python"))
        bundled = True
    with open(os.path.join(folder, "README.txt"), "w", encoding="utf-8", newline="\r\n") as f:
        f.write(README % (PYTHON_NOTE_BUNDLED if bundled else PYTHON_NOTE_PATH))
    if args.version:
        with open(os.path.join(folder, "version.txt"), "w", encoding="utf-8", newline="\r\n") as f:
            f.write(args.version + "\n")

    archive = os.path.join(args.out, "YSFlight-Replay-Viewer-%swin64.zip" % (args.version + "-" if args.version else ""))
    print("zipping ...", flush=True)
    if os.path.exists(archive):
        os.remove(archive)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, _, files in os.walk(folder):
            for f in files:
                p = os.path.join(root, f)
                z.write(p, os.path.relpath(p, args.out))
    print("done: %s (%.0f MB)%s" % (archive, os.path.getsize(archive) / 1e6,
                                    "" if bundled else "  - without Python (see --python-zip)"))


if __name__ == "__main__":
    main()
