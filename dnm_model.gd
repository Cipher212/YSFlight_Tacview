extends RefCounted
# YSFlight aircraft models (.dnm, DNMVER 1), read at run time and drawn as in the game: every face
# in its own colour, lit, smooth where its points are marked round ("R"), unlit where the face is
# marked bright ("B"), see-through where ZA says so.
#
# A .dnm is a tree of parts: "SRF name ... END" with FIL = the part's shape (a .srf packed in the
# file with "PCK name lines"), CLA = what moves it, POS x y z h p b = where it sits in its parent,
# CNT = the point it turns about, STA x y z h p b show = its states. The game blends a part between
# two states (fsairplaneproperty.cpp SetupVisual); whether a part shows comes from its states only
# (the RvB UCAV's body has POS ... 0 yet shows in the game). In RvB aircraft only the landing gear
# (class 0, by the gear position) and the afterburner (class 2, on/off) move, so those parts get
# their own node; every other part sits in its first state and is merged into one mesh per rigid
# group. IRST sensor / pipper parts are left out. Ground objects are read with static_only (every
# part in its first state, one mesh); a plain .srf model is one part.
#
# Which model goes with which aircraft: the IDENTIFY name in each .dat (the name the replay uses);
# a .dat pairs with the .dnm of the same file name, else the one starting with it (J7 -> J7E), else
# the one named after the aircraft (Q-5 -> Q5). The weapon folder is skipped.
#
# parse() only makes arrays, so it can run on the loader thread; build() makes the meshes once per
# model; instance() makes the nodes of one aircraft; pose() moves its gear and burner.

const ANGLE = PI / 32768.0
const GEAR = 0
const AFTERBURNER = 2
const CACHE_DIR = "user://model_cache"
const CACHE_FORMAT = 2       # raise when parse() changes, so old cached models are read again
# .srf keywords come short or long (weapon models use both): V/VER point (inside a face: its
# point numbers), F/FAC face, C/COL colour, N/NOR normal, B/BRI bright, E/END end of face
const SRF_WORDS = {"VER": "V", "FAC": "F", "COL": "C", "NOR": "N", "BRI": "B", "END": "E"}
enum Kind {LIT, BRIGHT, CLEAR}

static var _materials := []
static var glossy := false    # better lighting (View tab): shinier faces, so the shape reads

# Better lighting on or off for every model made from here (aircraft, ground objects, weapons).
static func set_lighting(better: bool) -> void:
	glossy = better
	for k in [Kind.LIT, Kind.CLEAR]:
		if k < _materials.size():
			_materials[k].roughness = 0.35 if better else 1.0

# parse(), from a cache file when the model was read before (user://model_cache, one file per
# model, kept while the model file is unchanged): reading a model is slow in GDScript, loading
# the cached arrays is not. Thread-safe.
static func load_or_parse(path: String, static_only := false) -> Dictionary:
	var cache := "%s/%s_%d.bin" % [CACHE_DIR, path.md5_text(), 1 if static_only else 0]
	var stamp := [CACHE_FORMAT, FileAccess.get_modified_time(path)]
	var f := FileAccess.open(cache, FileAccess.READ)
	if f != null:
		var cached = f.get_var()
		if typeof(cached) == TYPE_DICTIONARY and cached.get("stamp") == stamp:
			return cached["model"]
	var model := parse(path, static_only)
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	f = FileAccess.open(cache, FileAccess.WRITE)
	if f != null:
		f.store_var({"stamp": stamp, "model": model})
	return model

# --- which model belongs to which aircraft ---

# {IDENTIFY name (upper case): .dnm path} for every aircraft folder under root
static func index_models(root: String) -> Dictionary:
	var out := {}
	for dir in _folders(root):
		var dats := []
		var dnms := []
		for f in DirAccess.get_files_at(dir):
			var low := f.to_lower()
			if low.ends_with(".dat"):
				dats.append(f)
			elif low.ends_with(".dnm"):
				dnms.append(f)
		var names := {}
		for dat in dats:
			names[dat] = _identify(dir.path_join(dat))
		var left := dnms.duplicate()
		var unpaired := []
		for rule in 3:
			for dat in dats:
				if names[dat] == "" or out.has(names[dat].to_upper()):
					continue
				var dnm := _pair(dat, names[dat], left, rule)
				if dnm != "":
					out[names[dat].to_upper()] = dir.path_join(dnm)
					left.erase(dnm)
		for dat in dats:
			if names[dat] != "" and not out.has(names[dat].to_upper()):
				unpaired.append(dat)
		if unpaired.size() == 1 and left.size() == 1:
			out[names[unpaired[0]].to_upper()] = dir.path_join(left[0])
	return out

static func _folders(root: String) -> Array:
	var out := [root]
	for d in DirAccess.get_directories_at(root):
		if not d.to_lower().begins_with("weapon"):
			out.append_array(_folders(root.path_join(d)))
	return out

static func _identify(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	while f != null and not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("IDENTIFY"):
			return line.substr(8).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""

static func _pair(dat: String, name: String, dnms: Array, rule: int) -> String:
	var stem := dat.get_basename().to_upper()
	var plain := _alnum(name.split("(")[0])
	var best := ""
	for d in dnms:
		var s: String = d.get_basename().to_upper()
		var ok := (rule == 0 and s == stem) or (rule == 1 and s.begins_with(stem)) or \
			(rule == 2 and _alnum(s) == plain)
		if ok and (best == "" or s.length() < best.length()):
			best = d
	return best

static func _alnum(s: String) -> String:
	var out := ""
	for ch in s.to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out

# --- reading a .dnm (thread-safe: arrays only) ---

# {"groups": [{"parent", "pre", "back", "cla", "sta", "arrays"}]}; group 0 is the fixed body.
# static_only: nothing moves, everything is in group 0 (ground objects).
static func parse(path: String, static_only := false) -> Dictionary:
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var model := {"groups": [_group(-1, Transform3D.IDENTITY, Transform3D.IDENTITY, -1, [])],
		"packs": {}, "shapes": {}, "dir": path.get_base_dir(), "static": static_only}
	var first := ""
	for line in lines:
		first = line.strip_edges()
		if first != "":
			break
	if first != "DYNAMODEL":                     # a plain .srf: one part
		model["packs"]["_"] = lines
		_add_shape(model, "_", 0, Transform3D.IDENTITY)
		model.erase("packs")
		model.erase("shapes")
		return model
	var re := RegEx.new()
	re.compile("\"[^\"]*\"|\\S+")
	var packs := {}
	var parts := {}
	var order := []
	var cur = null
	var i := 0
	while i < lines.size():
		var a := _args(re, lines[i])
		i += 1
		if a.is_empty():
			continue
		match a[0]:
			"PCK":
				var n: int = a[2].to_int() if a.size() > 2 else 0
				packs[a[1]] = lines.slice(i, i + n)
				i += n
			"SRF":
				cur = {"name": a[1] if a.size() > 1 else "", "fil": "", "cla": -1,
					"pos": _nums(a, 7, [0, 0, 0, 0, 0, 0, 1]), "cnt": [0.0, 0.0, 0.0], "sta": [], "children": []}
				parts[cur["name"]] = cur
				order.append(cur)
			"FIL":
				if cur != null and a.size() > 1:
					cur["fil"] = a[1]
			"CLA":
				if cur != null and a.size() > 1:
					cur["cla"] = a[1].to_int()
			"POS":
				if cur != null:
					cur["pos"] = _nums(a, 7, [0, 0, 0, 0, 0, 0, 1])
			"CNT":
				if cur != null:
					cur["cnt"] = _nums(a, 3, [0, 0, 0])
			"STA":
				if cur != null:
					cur["sta"].append(_nums(a, 7, [0, 0, 0, 0, 0, 0, 1]))
			"CLD":
				if cur != null and a.size() > 1:
					cur["children"].append(a[1])
			"END":
				cur = null
	var is_child := {}
	for p in order:
		for c in p["children"]:
			is_child[c] = true
	model["packs"] = packs
	for p in order:
		if not is_child.has(p["name"]):
			_walk(model, parts, p, 0, Transform3D.IDENTITY, 0)
	model.erase("packs")
	model.erase("shapes")
	return model

static func _group(parent: int, pre: Transform3D, back: Transform3D, cla: int, sta: Array) -> Dictionary:
	var arrays := []
	for k in Kind.size():
		arrays.append([PackedVector3Array(), PackedVector3Array(), PackedColorArray()])
	return {"parent": parent, "pre": pre, "back": back, "cla": cla, "sta": sta, "arrays": arrays}

# Adds part p (and its children) to group g; chain = g's frame -> p's parent frame.
static func _walk(model: Dictionary, parts: Dictionary, p: Dictionary, g: int, chain: Transform3D, depth: int) -> void:
	var name: String = p["name"].to_lower()
	if depth > 32 or name.begins_with("irst") or name.contains("pipper"):
		return
	var pos: Array = p["pos"]
	var place := chain * Transform3D(_att(pos[3], pos[4], pos[5]), _vec(pos[0], pos[1], pos[2]))
	var cnt := _vec(p["cnt"][0], p["cnt"][1], p["cnt"][2])
	var sta: Array = p["sta"]
	var moving: bool = not model["static"] and (p["cla"] == GEAR or p["cla"] == AFTERBURNER) \
		and sta.size() >= 2 and sta[0] != sta[1]
	if moving:
		var states := []
		for s in [sta[0], sta[1]]:
			states.append([_vec(s[0], s[1], s[2]), Vector3(s[3], s[4], s[5]) * ANGLE, s[6] != 0])
		model["groups"].append(_group(g, place * Transform3D(Basis(), cnt), Transform3D(Basis(), -cnt),
			p["cla"], states))
		var gi: int = model["groups"].size() - 1
		_add_shape(model, p["fil"], gi, Transform3D.IDENTITY)
		for c in p["children"]:
			if parts.has(c):
				_walk(model, parts, parts[c], gi, Transform3D.IDENTITY, depth + 1)
		return
	var tf := place
	if sta.size() > 0:
		var s: Array = sta[0]
		if s[6] == 0:
			return                                   # hidden in its first state
		tf = place * Transform3D(Basis(), cnt) * Transform3D(_att(s[3], s[4], s[5]), _vec(s[0], s[1], s[2])) \
			* Transform3D(Basis(), -cnt)
	_add_shape(model, p["fil"], g, tf)
	for c in p["children"]:
		if parts.has(c):
			_walk(model, parts, parts[c], g, tf, depth + 1)

static func _add_shape(model: Dictionary, fil: String, g: int, tf: Transform3D) -> void:
	if fil == "":
		return
	if not model["shapes"].has(fil):
		var body = model["packs"].get(fil)
		if body == null:
			var file: String = model["dir"].path_join(fil)
			body = FileAccess.get_file_as_string(file).split("\n") if FileAccess.file_exists(file) else PackedStringArray()
		model["shapes"][fil] = _surf(body)
	var shape: Dictionary = model["shapes"][fil]
	var out: Array = model["groups"][g]["arrays"]
	for tri in shape["tris"]:
		var arr: Array = out[tri[0]]
		for k in 3:
			arr[0].append(tf * tri[1][k])
			arr[1].append((tf.basis * tri[2][k]).normalized())
			arr[2].append(tri[3])

# One .srf: its triangles as [kind, [3 points], [3 normals], colour], in the viewer's axes.
static func _surf(lines: PackedStringArray) -> Dictionary:
	var pts := PackedVector3Array()
	var round := PackedByteArray()
	var faces := []
	var face = null
	var alpha := {}
	for line in lines:
		var a := line.strip_edges().split(" ", false)
		if a.is_empty():
			continue
		match SRF_WORDS.get(a[0].to_upper(), a[0]):
			"V":
				if face == null:
					if a.size() >= 4:
						pts.append(_vec(a[1].to_float(), a[2].to_float(), a[3].to_float()))
						round.append(1 if a.size() > 4 and a[4] == "R" else 0)
				else:
					for k in range(1, a.size()):
						face["idx"].append(a[k].to_int())
			"F":
				face = {"idx": PackedInt32Array(), "c": Color(0.6, 0.6, 0.6), "n": Vector3.ZERO, "bright": false}
			"C":
				if face != null:
					if a.size() >= 4:
						face["c"] = Color8(a[1].to_int(), a[2].to_int(), a[3].to_int())
					elif a.size() == 2:                  # 15-bit colour: GGGGGRRRRRBBBBB
						var n := a[1].to_int()
						face["c"] = Color(((n >> 5) & 31) / 31.0, ((n >> 10) & 31) / 31.0, (n & 31) / 31.0)
			"N":
				if face != null and a.size() >= 7:
					face["n"] = _vec(a[4].to_float(), a[5].to_float(), a[6].to_float())
			"B":
				if face != null:
					face["bright"] = true
			"E":
				if face != null:
					faces.append(face)
				face = null
			"ZA":
				for k in range(1, a.size() - 1, 2):
					alpha[a[k].to_int()] = a[k + 1].to_int()
	# face normals (the file's, else from the points), then smooth normals for round points
	var smooth := PackedVector3Array()
	smooth.resize(pts.size())
	var normals := []
	for f in faces:
		var idx: PackedInt32Array = f["idx"]
		var n: Vector3 = f["n"]
		if idx.size() >= 3 and n.length_squared() < 1e-8:
			n = _newell(pts, idx)
		n = n.normalized() if n.length_squared() > 1e-12 else Vector3.UP
		normals.append(n)
		for v in idx:
			if v >= 0 and v < pts.size():
				smooth[v] += n
	var tris := []
	for fi in faces.size():
		var f: Dictionary = faces[fi]
		var idx: PackedInt32Array = f["idx"]
		var ok := idx.size() >= 3
		for v in idx:
			ok = ok and v >= 0 and v < pts.size()
		if not ok:
			continue
		var n: Vector3 = normals[fi]
		var c: Color = f["c"]
		var kind := Kind.BRIGHT if f["bright"] else Kind.LIT
		if alpha.get(fi, 0) > 0:
			c.a = 1.0 - alpha[fi] / 255.0
			kind = Kind.CLEAR
		for k in range(1, idx.size() - 1):
			var t := [idx[0], idx[k], idx[k + 1]]
			# Godot's front faces are clockwise: turn the triangle to face along the face normal
			if (pts[t[1]] - pts[t[0]]).cross(pts[t[2]] - pts[t[0]]).dot(n) > 0.0:
				t = [t[0], t[2], t[1]]
			var p3 := []
			var n3 := []
			for v in t:
				p3.append(pts[v])
				n3.append(smooth[v].normalized() if round[v] == 1 and smooth[v].length_squared() > 1e-12 else n)
			tris.append([kind, p3, n3, c])
	return {"tris": tris}

# A face's normal from its points. In the viewer's axes the points run counter-clockwise seen from
# the side the face's own N normal points to (checked: 31,303 of 31,331 faces of the RvB aircraft).
static func _newell(pts: PackedVector3Array, idx: PackedInt32Array) -> Vector3:
	var n := Vector3.ZERO
	for k in idx.size():
		var a := pts[idx[k]]
		var b := pts[idx[(k + 1) % idx.size()]]
		n += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
	return n

static func _args(re: RegEx, line: String) -> Array:
	var out := []
	for m in re.search_all(line):
		out.append(m.get_string().trim_prefix("\"").trim_suffix("\""))
	return out

static func _nums(a: Array, n: int, fallback: Array) -> Array:
	var out := fallback.duplicate()
	for k in mini(n, a.size() - 1):
		out[k] = a[k + 1].to_float()
	return out

# YSFlight (x right, y up, z forward) -> viewer (z flips), and YSFlight attitudes (1/65536 turn)
# the same way as node_3d.gd's ys_basis.
static func _vec(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, y, -z)

static func _att(h: float, p: float, b: float) -> Basis:
	return Basis.from_euler(Vector3(p, h, b) * ANGLE)

# --- meshes and nodes (main thread) ---

# Turns parse()'s arrays into meshes: {"groups": [... with "mesh"]}.
static func build(model: Dictionary) -> Dictionary:
	if _materials.is_empty():
		_materials = [_material(false, false), _material(true, false), _material(false, true)]
	for g in model["groups"]:
		var mesh := ArrayMesh.new()
		for k in Kind.size():
			var arr: Array = g["arrays"][k]
			if arr[0].is_empty():
				continue
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = arr[0]
			arrays[Mesh.ARRAY_NORMAL] = arr[1]
			arrays[Mesh.ARRAY_COLOR] = arr[2]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, _materials[k])
		g["mesh"] = mesh if mesh.get_surface_count() > 0 else null
		g.erase("arrays")
	return model

static func _material(bright: bool, clear: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED      # YSFlight draws both sides of a face
	if bright:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	else:
		m.roughness = 0.35 if glossy else 1.0
	if clear:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m

# The nodes of one aircraft: the fixed body, and a node per moving part (gear legs, burners).
static func instance(model: Dictionary) -> Node3D:
	var root := Node3D.new()
	var nodes := []
	var groups: Array = model["groups"]
	for gi in groups.size():
		var g: Dictionary = groups[gi]
		var node: Node3D = root if gi == 0 else Node3D.new()
		if gi > 0:
			nodes[g["parent"]].add_child(node)
		if g["mesh"] != null:
			var mi := MeshInstance3D.new()
			mi.mesh = g["mesh"]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			node.add_child(mi)
		nodes.append(node)
	root.set_meta("dnm", {"groups": groups, "nodes": nodes, "gear": -1.0, "burner": -1})
	return root

# Gear (0 up .. 1 down, as recorded) and afterburner, the way the game moves the parts: the gear
# legs swing during the middle 60 % of the gear's travel; a part shows if it shows at either end
# of its swing (so a leg folding away stays visible until it is fully up).
static func pose(root: Node3D, gear: float, burner: bool) -> void:
	var m: Dictionary = root.get_meta("dnm")
	var b := 1 if burner else 0
	if m["gear"] == gear and m["burner"] == b:
		return
	m["gear"] = gear
	m["burner"] = b
	var t_gear := clampf((gear - 0.2) / 0.6, 0.0, 1.0)
	var groups: Array = m["groups"]
	for gi in range(1, groups.size()):
		var g: Dictionary = groups[gi]
		var t: float = t_gear if g["cla"] == GEAR else float(b)
		var s0: Array = g["sta"][0]
		var s1: Array = g["sta"][1]
		var ang: Vector3 = s0[1].lerp(s1[1], t)
		var state := Transform3D(Basis.from_euler(Vector3(ang.y, ang.x, ang.z)), s0[0].lerp(s1[0], t))
		var node: Node3D = m["nodes"][gi]
		node.transform = g["pre"] * state * g["back"]
		node.visible = s0[2] if t <= 0.0 else (s1[2] if t >= 1.0 else (s0[2] or s1[2]))
