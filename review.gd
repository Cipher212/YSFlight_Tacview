extends RefCounted
# The review queue's marks: scorers mark each kill, each unconfirmed credit and each sortie's
# ending (death) as confirmed or rejected, with a note. The marks are saved in their own file
# next to the event, <event>.review.txt (JSON inside; .txt so it opens in Notepad and stays out
# of the event file lists); the event file itself is never changed. A mark keeps
# what it is about (who, and when), so it finds its kill or death again after the event is
# rebuilt (up to MATCH_SECONDS later or earlier); a mark that matches nothing stays in the file
# and is counted as not found.

const MATCH_SECONDS = 3.0

var path := ""
var marks := []           # {"kind", "t", names (see about()), "status", "note", "changed"}
var by_item := {}         # item id (ui_layer.gd: "k3", "c0", "d17") -> its mark
var unmatched := 0        # marks that match nothing in this event
var last_error := ""

# events/RvB6.json.gz -> events/RvB6.review.txt
static func file_for(event_path: String) -> String:
	var p := event_path
	for ext in [".gz", ".json"]:
		if p.to_lower().ends_with(ext):
			p = p.substr(0, p.length() - ext.length())
	return p + ".review.txt"

# items: {item id: what a mark stores about it}:
#   {"kind": "kill" / "claim", "t", "victim", "killer", "weapon"}  (claim: an unconfirmed credit)
#   {"kind": "death", "t", "player", "aircraft"}
func load_for(event_path: String, items: Dictionary) -> void:
	path = file_for(event_path)
	marks = []
	by_item = {}
	unmatched = 0
	last_error = ""
	if FileAccess.file_exists(path):
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(data) == TYPE_DICTIONARY:
			for m in data.get("marks", []):
				if typeof(m) == TYPE_DICTIONARY and m.has("kind"):
					marks.append(m)
		else:
			last_error = "could not read " + path.get_file()
	# each mark goes to the item of its kind with the same names that is nearest in time
	for m in marks:
		var best := ""
		var best_dt := MATCH_SECONDS
		for id in items:
			var a: Dictionary = items[id]
			if by_item.has(id) or not _same(a, m):
				continue
			var dt := absf(float(a["t"]) - float(m.get("t", 0.0)))
			if dt <= best_dt:
				best = id
				best_dt = dt
		if best != "":
			by_item[best] = m
		else:
			unmatched += 1

func status(id: String) -> String:
	return str(by_item[id].get("status", "")) if by_item.has(id) else ""

func note(id: String) -> String:
	return str(by_item[id].get("note", "")) if by_item.has(id) else ""

# Sets an item's status ("confirmed", "rejected" or "" for none) and note, and saves the file.
# No status and no note: the mark is removed. False if the file could not be written.
func set_mark(id: String, about: Dictionary, new_status: String, new_note: String) -> bool:
	var m = by_item.get(id)
	if new_status == "" and new_note.strip_edges() == "":
		if m != null:
			marks.erase(m)
			by_item.erase(id)
		return save()
	if m == null:
		m = {}
		marks.append(m)
		by_item[id] = m
	for k in about:
		m[k] = about[k]           # (re)anchored to this build's names and time
	m["status"] = new_status
	m["note"] = new_note
	m["changed"] = Time.get_datetime_string_from_system(false, true)
	return save()

# Written to a temporary file first, so a crash can't leave half a file.
func save() -> bool:
	if path == "":
		return false
	var text := JSON.stringify({"format": 1, "marks": marks}, "\t")
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
		if DirAccess.rename_absolute(tmp, path) == OK:
			last_error = ""
			return true
		DirAccess.remove_absolute(tmp)
	f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		last_error = "could not save " + path.get_file()
		return false
	f.store_string(text)
	f.close()
	last_error = ""
	return true

static func _same(a: Dictionary, m: Dictionary) -> bool:
	if a["kind"] != m.get("kind"):
		return false
	if a["kind"] == "death":
		return a["player"] == m.get("player") and a["aircraft"] == m.get("aircraft")
	return a["victim"] == m.get("victim") and a["killer"] == m.get("killer") and a["weapon"] == m.get("weapon")
