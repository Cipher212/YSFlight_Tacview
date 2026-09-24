extends RefCounted
# Which YSFlight model each weapon in flight is drawn with, picked the way the game picks it
# (FsWeapon::Draw, YSFLIGHT-master/src/graphics/gl2.0/fsweapongl2.0.cpp): the model the shooter's
# .dat names in a "WPNSHAPE <type> FLYING <file>" line, else the game's own model for that type
# (YSFLIGHT-master/runtime/misc). Ground objects have no such lines, so they get the game's own.
# The .dat files name files in the game's folders (user/RvB/weapon/AIM-120B.srf); here they are
# looked up by file name in aircraft/weapon. A name that isn't there goes to the closest one
# (AIM-9.srf -> AIM-9L.srf, the misspelt Phyton3.srf -> Python3.srf), else to the game's own
# model (the drones' user/matrix_v2 files).

const Paths = preload("res://paths.gd")
const WEAPON_DIR = "aircraft/weapon"
const STOCK_DIR = "YSFLIGHT-master/runtime/misc"
# weapon name in the event -> [WPNSHAPE keyword, the game's own model]
const TYPES = {"AIM9": ["AIM9", "aim9.srf"], "AIM9X": ["AIM9X", "aim9x.srf"],
	"AIM120": ["AIM120", "aim120.srf"], "AGM65": ["AGM65", "agm65.srf"],
	"BOMB500": ["B500", "bomb.srf"], "BOMB250": ["B250", "bomb250.srf"],
	"BOMB500HD": ["B500HD", "bomb500hd.srf"], "ROCKET": ["RKT", "rocket.srf"],
	"FUELTANK": ["FUEL", "fueltank.srf"]}

# {"aircraft": {IDENTIFY name (upper case): {WPNSHAPE keyword: model path}},
#  "stock": {weapon name: the game's own model path, or ""}}
static func index() -> Dictionary:
	var files := {}           # model file name (upper case, letters and digits only) -> path
	var dir := Paths.of(WEAPON_DIR)
	if DirAccess.dir_exists_absolute(dir):
		for f in DirAccess.get_files_at(dir):
			var low := f.to_lower()
			if low.ends_with(".srf") or low.ends_with(".dnm"):
				files[_plain(f.get_basename())] = dir.path_join(f)
	var re := RegEx.new()
	re.compile("\"[^\"]*\"|\\S+")
	var aircraft := {}
	_scan(Paths.of("aircraft"), files, re, aircraft)
	var stock := {}
	for name in TYPES:
		var p := Paths.of(STOCK_DIR).path_join(TYPES[name][1])
		stock[name] = p if FileAccess.file_exists(p) else ""
	return {"aircraft": aircraft, "stock": stock}

# The model a weapon is drawn with: `name` as in the event (AIM120, BOMB500 ...), `aircraft` the
# shooter's type as the replay names it ("" for a ground object). "" for weapons drawn without a
# model (guns, flares). Thread-safe.
static func model_for(name: String, aircraft: String, idx: Dictionary) -> String:
	var t = TYPES.get(name)
	if t == null:
		return ""
	var own: Dictionary = idx["aircraft"].get(aircraft.to_upper(), {})
	return own.get(t[0], idx["stock"].get(name, ""))

static func _scan(dir: String, files: Dictionary, re: RegEx, out: Dictionary) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		if f.to_lower().ends_with(".dat"):
			_read_dat(dir.path_join(f), files, re, out)
	for d in DirAccess.get_directories_at(dir):
		if not d.to_lower().begins_with("weapon"):
			_scan(dir.path_join(d), files, re, out)

static func _read_dat(path: String, files: Dictionary, re: RegEx, out: Dictionary) -> void:
	var name := ""
	var shapes := {}
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var a := []
		for m in re.search_all(line):
			a.append(m.get_string().trim_prefix("\"").trim_suffix("\""))
		if a.size() >= 2 and a[0] == "IDENTIFY":
			name = a[1]
		elif a.size() >= 4 and a[0] == "WPNSHAPE" and a[2] == "FLYING":
			var model := _resolve(a[3], files)
			if model != "":
				shapes[_keyword(a[1])] = model
	if name != "" and not out.has(name.to_upper()):
		out[name.to_upper()] = shapes

# A WPNSHAPE file: where the game's folder layout puts it under gamefiles, else by name in
# aircraft/weapon: the same name, else the shortest one starting with it, else one at most two
# letters different ("" if none).
static func _resolve(rel: String, files: Dictionary) -> String:
	rel = rel.replace("\\", "/")
	var direct := Paths.of("gamefiles").path_join(rel)
	if FileAccess.file_exists(direct):
		return direct
	var want := _plain(rel.get_file().get_basename())
	if want.length() < 3:
		return ""
	if files.has(want):
		return files[want]
	var best := ""
	for k in files:
		if k.begins_with(want) and (best == "" or k.length() < best.length() or (k.length() == best.length() and k < best)):
			best = k
	if best == "" and want.length() >= 5:
		var best_d := 3
		for k in files:
			var d := _distance(want, k)
			if d < best_d or (d == best_d and d < 3 and k < best):
				best = k
				best_d = d
	return files[best] if best != "" else ""

# "AIM9*..." -> "AIM9" (the game drops anything after *, &, | or @)
static func _keyword(s: String) -> String:
	for i in s.length():
		if s[i] in ["*", "&", "|", "@"]:
			return s.substr(0, i)
	return s

static func _plain(s: String) -> String:
	var out := ""
	for ch in s.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out

# Edit distance (letters added, removed or changed); 99 when the lengths differ by more than 2
static func _distance(a: String, b: String) -> int:
	if absi(a.length() - b.length()) > 2:
		return 99
	var prev := PackedInt32Array()
	for j in b.length() + 1:
		prev.append(j)
	for i in range(1, a.length() + 1):
		var cur := PackedInt32Array([i])
		for j in range(1, b.length() + 1):
			var cost := 0 if a[i - 1] == b[j - 1] else 1
			cur.append(mini(mini(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost))
		prev = cur
	return prev[b.length()]
