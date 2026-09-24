extends Node
# Runs the Python pipeline (replay_parser.py) that turns .yfs replays into an event file, on a
# background thread, and reports its progress. The pipeline prints "PROGRESS <percent> <text>".
# (For the finished .exe the pipeline will be a bundled program instead of "python".)

signal progress(percent: int, text: String)
signal finished(ok: bool, event_path: String, log_text: String)

var _thread: Thread
var _mutex := Mutex.new()
var _lines: Array = []
var _done := false
var _ok := false
var _out_path := ""
var _log := ""

func busy() -> bool:
	return _thread != null and _thread.is_started() and not _done

func build(replays: PackedStringArray, fld_path: String, out_path: String) -> bool:
	if busy():
		return false
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	var args := PackedStringArray(["-X", "utf8", ProjectSettings.globalize_path("res://replay_parser.py"),
		"--fld", fld_path, "-o", out_path])
	args.append_array(replays)
	_out_path = out_path
	_done = false
	_ok = false
	_log = ""
	_lines.clear()
	_thread = Thread.new()
	_thread.start(_run.bind(args))
	return true

func _run(args: PackedStringArray) -> void:   # background thread
	var p := OS.execute_with_pipe("python", args)
	if p.is_empty():
		_push("ERROR: could not start Python (is it installed and on the PATH?)")
		_finish(false)
		return
	var out: FileAccess = p["stdio"]      # the pipeline prints its errors here too
	var finished_ok := false
	while true:
		var line := out.get_line()
		if line != "":
			_push(line)
			finished_ok = finished_ok or line.begins_with("PROGRESS 100")
		elif not OS.is_process_running(p["pid"]):
			break
	_finish(finished_ok and FileAccess.file_exists(_out_path))

func _push(line: String) -> void:
	_mutex.lock()
	_lines.append(line)
	_mutex.unlock()

func _finish(ok: bool) -> void:
	_mutex.lock()
	_ok = ok
	_done = true
	_mutex.unlock()

func _process(_delta: float) -> void:
	if _thread == null:
		return
	_mutex.lock()
	var lines := _lines.duplicate()
	_lines.clear()
	var done := _done
	_mutex.unlock()
	for line in lines:
		if line.begins_with("PROGRESS "):
			var parts: PackedStringArray = line.split(" ", false, 2)
			progress.emit(int(parts[1]), parts[2] if parts.size() > 2 else "")
		else:
			_log += line + "\n"
	if done and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
		finished.emit(_ok, _out_path, _log)
