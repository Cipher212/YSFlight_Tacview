extends Node3D
# Ground objects with their own YSFlight models: the model the game's ground lists give for the
# object's .dat (gro*.lst lines: "<.dat> <model> <collision> <cockpit> <coarse>"), read by
# dnm_model.gd with every part in its first state. All objects of a type are one MultiMesh (one
# draw call). A destroyed object is gone from the moment the pipeline found it destroyed
# ("destroyed_t": the replays agree and it never fires again, event_merge.ground_fates; a kill
# credit alone doesn't do it); in events built before that, from when its own replay shows it
# destroyed. Clouds (RvB's low clouds, no collision) are drawn see-through by their own models
# and can be hidden on their own.
# A type without a model keeps a placeholder block the size of its box (gamedata.py), in its
# team's colour.

const Main = preload("res://node_3d.gd")
const Paths = preload("res://paths.gd")
const PACKS = ["gamefiles", "YSFLIGHT-master/runtime/ground"]
const NEUTRAL = Color(0.62, 0.6, 0.52)
const CLOUD = Color(1.0, 1.0, 1.0, 0.07)
const GONE = Transform3D(Basis(Vector3.ZERO, Vector3.ZERO, Vector3.ZERO), Vector3.ZERO)   # an instance not drawn

var items := []           # {"mm", "slot", "color", "model", "box", "t_dead", "dead", "times", "poses"}
var cloud_nodes := []

# --- which model belongs to which object ---

# {.dat path (lower case, "/") : model path} from every ground list in the game files
static func index_models() -> Dictionary:
	var out := {}
	var re := RegEx.new()
	re.compile("\"[^\"]*\"|\\S+")
	for pack in PACKS:
		var base := Paths.of(pack)
		if DirAccess.dir_exists_absolute(base):
			_scan(base, [base, base.get_base_dir()], re, out)
	return out

static func _scan(dir: String, roots: Array, re: RegEx, out: Dictionary) -> void:
	for f in DirAccess.get_files_at(dir):
		var low := f.to_lower()
		if not (low.begins_with("gro") and low.ends_with(".lst")):
			continue
		for line in FileAccess.get_file_as_string(dir.path_join(f)).split("\n"):
			var a := []
			for m in re.search_all(line):
				a.append(m.get_string().trim_prefix("\"").trim_suffix("\""))
			if a.size() < 2 or a[0].begins_with("#"):
				continue
			var dat := _find(a[0], roots)
			var model := _find(a[1], roots)
			if dat != "" and model != "" and not out.has(_key(dat)):
				out[_key(dat)] = model
	for d in DirAccess.get_directories_at(dir):
		_scan(dir.path_join(d), roots, re, out)

static func _find(rel: String, roots: Array) -> String:
	if rel == "":
		return ""
	for r in roots:
		var p: String = r.path_join(rel.replace("\\", "/"))
		if FileAccess.file_exists(p):
			return p
	return ""

static func _key(path: String) -> String:
	return path.replace("\\", "/").to_lower()

# The model file of a ground object from the event ("" if none).
static func model_path(g: Dictionary, index: Dictionary) -> String:
	var dat = g.get("dat")
	if typeof(dat) != TYPE_DICTIONARY:
		return ""
	for pack in PACKS:
		var p := Paths.of(pack).path_join(str(dat.get("file", "")).replace("\\", "/"))
		if FileAccess.file_exists(p):
			return index.get(_key(p), "")
	return ""

# --- drawing ---

# meshes: model path -> Mesh (or null); paths: object index -> model path
func setup(grounds: Array, meshes: Dictionary, paths: Dictionary) -> void:
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var groups := {}          # model path, "box" or "cloud box" -> {"mm", "count"}
	var todo := []
	for g in grounds:
		var samples: Array = g.get("samples", [])
		if samples.is_empty():
			continue
		var dat = g.get("dat")
		var info: Dictionary = dat if typeof(dat) == TYPE_DICTIONARY else {}
		var is_cloud: bool = not info.get("solid", true)
		var path: String = paths.get(int(g.get("index", -1)), "")
		var mesh = meshes.get(path)
		var key: String = path if mesh != null else ("cloud box" if is_cloud else "box")
		if not groups.has(key):
			var mat: Material = null
			if mesh == null:
				mat = _cloud_material() if is_cloud else _solid_material()
			groups[key] = {"mm": _multimesh(mesh if mesh != null else box, mat), "count": 0}
			if is_cloud:
				cloud_nodes.append(get_child(get_child_count() - 1))
		var grp: Dictionary = groups[key]
		var item := {"mm": grp["mm"], "slot": grp["count"], "model": mesh != null, "box": _box(info),
			"t_dead": INF, "dead": false}
		grp["count"] += 1
		if mesh != null:
			item["color"] = Color.WHITE
		else:
			item["color"] = CLOUD if is_cloud else _team_color(int(g.get("iff", 0)))
		if g.has("destroyed_t"):
			item["t_dead"] = INF if g["destroyed_t"] == null else float(g["destroyed_t"])
		else:
			for s in samples:
				if int(s.get("state", 0)) == 1:
					item["t_dead"] = s["t"]
					break
		var times := PackedFloat64Array()
		var poses := []
		for s in samples:
			if poses.is_empty() or Main.ys_position(s) != poses[-1].origin:
				times.append(s["t"])
				poses.append(Transform3D(Main.ys_basis(s), Main.ys_position(s)))
		item["times"] = times
		item["poses"] = poses
		todo.append(item)
	for key in groups:
		groups[key]["mm"].instance_count = groups[key]["count"]
	for item in todo:
		_place(item, item["poses"][0])
		item["mm"].set_instance_color(item["slot"], item["color"])
		items.append(item)

func show_clouds(on: bool) -> void:
	for n in cloud_nodes:
		n.visible = on

func update(t: float) -> void:
	for item in items:
		var dead: bool = t >= item["t_dead"]
		var times: PackedFloat64Array = item["times"]
		if dead != item["dead"]:
			item["dead"] = dead
			if dead:
				item["mm"].set_instance_transform(item["slot"], GONE)
			elif times.size() <= 1:
				_place(item, item["poses"][0])
		if dead:
			continue
		if times.size() > 1:                  # a mover (ships, vehicles): between its samples
			var k := clampi(times.bsearch(t, false) - 1, 0, times.size() - 1)
			var a: Transform3D = item["poses"][k]
			if k + 1 < times.size() and t > times[k]:
				var w := clampf((t - times[k]) / (times[k + 1] - times[k]), 0.0, 1.0)
				a = a.interpolate_with(item["poses"][k + 1], w)
			_place(item, a)

# The object's box in its own frame: YSFlight's model box (x right, y up, z forward) turned into
# the viewer's (z flips); a cube of the hit radius if the model is unknown.
static func _box(info: Dictionary) -> AABB:
	var b = info.get("box")
	if typeof(b) == TYPE_ARRAY and b.size() == 6:
		return AABB(Vector3(b[0], b[1], -b[5]), Vector3(b[3] - b[0], b[4] - b[1], b[5] - b[2]))
	var r := maxf(float(info.get("hit_radius", 5.0)), 2.0)
	return AABB(Vector3(-r, 0.0, -r), Vector3(2.0 * r, r, 2.0 * r))

func _place(item: Dictionary, pose: Transform3D) -> void:
	if item["model"]:
		item["mm"].set_instance_transform(item["slot"], pose)
		return
	var b: AABB = item["box"]
	var t := Transform3D(pose.basis * Basis.from_scale(b.size), pose.origin + pose.basis * b.get_center())
	item["mm"].set_instance_transform(item["slot"], t)

static func _team_color(iff: int) -> Color:
	return Main.iff_color(iff) if iff == 1 or iff == 4 else NEUTRAL

func _multimesh(mesh: Mesh, mat: Material) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	if mat != null:
		node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return mm

func _solid_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true
	return m

func _cloud_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
