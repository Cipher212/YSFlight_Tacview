"""Builds the Windows package of the viewer: a folder, and a .zip of it, that runs without Godot:
unzip it and double-click "YSFlight Replay Viewer.exe".

    python tools/package.py [--godot GODOT] [--python-zip ZIP_OR_URL] [--out DIR]

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
    README.txt
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
README = """YSFlight replay viewer
======================

Start: double-click "YSFlight Replay Viewer.exe".

- Open an event someone built and shared (.json.gz or .json): Menu > Open a saved event.
  Put shared events in the "events" folder here to find them quickly.
- Build an event from replays (.yfs): Menu > New event from replays. %s
- Review: in the side panel, pick a kill or death (or press C for the next one marked CHECK),
  then Confirm / Reject and add a note. Your marks are saved next to the event file as
  <event>.review.txt; the event file itself is never changed.
- Keys: Space play/pause, J / K / L rewind / pause / fast, , and . one frame (Shift: 1 s),
  Left / Right 10 s (Shift: 60 s), N / Shift+N next / previous kill, C / Shift+C next / previous
  CHECK to review, Tab next aircraft, Esc free camera, P side panel. Click an aircraft to follow it,
  right-drag to look around, mouse wheel to zoom.

Folders: aircraft, gamefiles, maps and YSFLIGHT-master hold the game files the viewer draws with.
Keep them next to the .exe.
"""
PYTHON_NOTE_BUNDLED = "The Python it needs is included (the python folder)."
PYTHON_NOTE_PATH = ("This needs Python 3 installed (python.org; tick \"Add python.exe to PATH\"). "
                    "Opening events doesn't.")


def main():
    ap = argparse.ArgumentParser(description="Build the Windows package of the viewer")
    ap.add_argument("--godot", default=shutil.which("godot") or "godot", help="the Godot 4.7.2 program")
    ap.add_argument("--python-zip", default=None, help="Windows embeddable Python: a .zip file or its URL")
    ap.add_argument("--out", default=os.path.join(REPO, "build"))
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

    archive = os.path.join(args.out, "YSFlight-Replay-Viewer-win64.zip")
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
