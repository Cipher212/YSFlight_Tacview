extends Node3D
# YSFlight replay viewer, main scene: the replay clock, the loaded event, the aircraft (model,
# name tag with altitude and speed, flight path vector) and the camera. The controls
# (ui_layer.gd), weapons and kill feed (combat_layer.gd), energy ribbons (ribbon_layer.gd),
# ground objects (ground_layer.gd), the map (map_layer.gd) and the Python pipeline runner
# (event_builder.gd) are separate scripts.
#
# Speeds come from the track itself: distance flown between the samples either side of now,
# over the time between them (true airspeed; YSFlight has no wind in RvB).
#
# Keys (the defaults; View tab > Keys... changes them, keys.gd): Space play/pause, J play backwards
# (again: faster), K pause, L play fast (again: faster), , and . one frame back/forward (Shift: 1 s),
# Left/Right -+10 s (Shift: 60 s), Home restart, +/- speed, Tab / Shift+Tab next/previous aircraft
# in the air, Esc free camera, P side panel, T top view, N / Shift+N next/previous kill, C / Shift+C
# next/previous kill or death still to review, M cinematic mode (cinema.gd), F11 full screen.
# Mouse: click an aircraft to follow it, right-drag to look around, wheel to zoom. Free camera:
# WASD, E/Q, Shift = fast.

const YsAir = preload("res://ys_air.gd")
const Fmt = preload("res://fmt.gd")
const Paths = preload("res://paths.gd")
const DnmModel = preload("res://dnm_model.gd")
const WeaponModels = preload("res://weapon_models.gd")
const Keys = preload("res://keys.gd")
const SETTINGS = "user://settings.cfg"
const AIRCRAFT_DIR = "aircraft"         # the aircraft's game files (.dat + .dnm), in any subfolders
const TAG_PIXEL = 0.0007         # name tag size (times the text size setting)
const TAG_INTERVAL = 0.2         # seconds between name tag updates
const VECTOR_SECONDS = 1.0       # a flight path vector reaches where the aircraft will be in 1 s
# The cinematic mode smooths the tracks (`_filtered`): an aircraft seen through the network jumps
# a few metres at each update in the replays (YSFlight's client snaps it to a blend of the last
# two updates, FsAirplaneProperty::NetworkDecode, and flies it on between them), which close
# cameras and long lenses showed as jitter. Seconds (Gaussian sigma): position, attitude. Measured
# on a test track with 4 m errors every 0.1 s: 0.2 s leaves ~1/100 of the jitter and pulls an
# 11.8 G turn 0.4 m inwards.
const SMOOTH_SIGMA = 0.2
const SMOOTH_SIGMA_ATT = 0.1
# Top view (T): the map from straight above, north up, drawn without perspective (orthographic)
const TOP_HEIGHT = 60000.0       # metres: the top view's camera height (above everything)
const TOP_SIZE_MIN = 300.0       # metres from the bottom to the top of the screen, zoomed in fully
const TOP_SIZE_MAX = 120000.0
const TOP_AIRCRAFT_PX = 18.0     # in the top view an aircraft is drawn at least this long on screen
const VECTOR_COLOR = Color(1.0, 0.9, 0.25)
const VECTOR_WIDTH_PX = 1.5
const STRIP_NEAR = 1.0           # metres in front of the camera where the vectors are cut off
const NOSE_COLOR = Color(0.72, 0.72, 0.72)
# Aircraft shadows as YSFlight draws them (FsSimulation::SimDrawComplexShadow): the aircraft
# flattened straight down (light from above) onto the plane of the ground under it, dark,
# a little above the ground so it isn't lost in it. Drawn with the see-through things (ALPHA),
# right after the map's painted layers: drawn with the solid things, OpenGL let the big sea
# shapes paint over it (seen in screenshots). It writes depth, so trails behind it stay behind.
const SHADOW_PRIORITY = -1       # after the map's layers (map_layer.gd: from RENDER_PRIORITY_MIN + 1)
const SHADOW_SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform, depth_draw_always;

uniform vec3 ground_point = vec3(0.0);
uniform vec3 ground_normal = vec3(0.0, 1.0, 0.0);

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n = ground_normal.y > 0.2 ? ground_normal : vec3(0.0, 1.0, 0.0);
	w.y = ground_point.y - (n.x * (w.x - ground_point.x) + n.z * (w.z - ground_point.z)) / n.y + 0.4;
	// a touch nearer the eye along its line of sight (the same place on screen), like YSFlight's
	// polygon offset: the ground under it doesn't show through at a distance
	VERTEX = (VIEW_MATRIX * vec4(w, 1.0)).xyz * 0.999;
	NORMAL = normalize(mat3(VIEW_MATRIX) * n);
}

void fragment() {
	ALBEDO = vec3(0.0);             // black, as in YSFlight
	ALPHA = 1.0;
}
"""
# View settings (View tab, saved in settings.cfg as "view_<key>")
const VIEW_DEFAULTS = {"aircraft_scale": 1.0, "weapon_scale": 1.0, "text_scale": 1.0,
	"trail_seconds": 30.0, "ribbon_width": 1.0, "marker_seconds": 30.0, "ribbons": true,
	"vectors": true, "tags": true, "tethers": true, "markers": true, "ground": true, "clouds": true,
	"blocky": false, "smoke": true, "shadows": true, "ranges": false, "lighting": true,
	"cine_shake": 1.0, "cine_slow": 0.25, "cine_orbit": 12.0, "cine_crane": 5.0}

var camera: Camera3D
var cam_rot_x: float = -0.5
var cam_rot_y: float = 0.0
var move_speed: float = 1000.0
var mouse_sensitivity: float = 0.005
var cam_distance: float = 300.0

var replay_time: float = 0.0
var playback_speed: float = 1.0
var play_direction := 1          # 1 forwards, -1 backwards
var playing: bool = false
var t_min: float = 0.0
var t_max: float = 0.0

var event_data = null
var event_root: Node3D           # everything that belongs to the loaded event
var active_aircraft = {} # marker nodes: position only, label rides on these
var aircraft_models = {} # model inside each marker: gets the attitude
var aircraft_tags = {}   # name tag on each marker
var aircraft_shadows = {} # shadow material of each aircraft (its ground plane is set every frame)
var aircraft_attitude = {} # attitude of each aircraft in the air now (for the cinematic cameras)
var full_health = {}     # aircraft id -> its health when whole (at the start of its track)
var telemetry_data = {}
var current_frame_indices = {}
var order: Array = []            # aircraft ids by start time (for Tab)
var tracked_id := ""             # aircraft the camera follows ("" = free camera)
var top_view := false            # the map from straight above (T)
var _saved_view := {}            # the 3D camera while the top view is on

var ui
var builder
var keys = Keys.new()            # the keyboard shortcuts (the user's own choice of keys)
var cinema                       # cinematic mode (cinema.gd)
var combat: Node3D
var ribbons: Node3D
var grounds: Node3D
var map_node: Node3D             # the YSFlight map (map_layer.gd); kept while the field stays the same
var ground_plane: MeshInstance3D # base plane beyond the drawn map
var sky_material: ProceduralSkyMaterial
var sun: DirectionalLight3D      # lights the models (the map carries its own daylight)
var world_env: WorldEnvironment
var vectors: ArrayMesh           # flight path vectors and nose lines, rebuilt every frame
var vector_node: MeshInstance3D
var view := VIEW_DEFAULTS.duplicate()
var _load_thread: Thread
var _ribbon_script: GDScript
var _tag_clock := 0.0
var _dnm_index := {}             # aircraft name (as in the replay, upper case) -> .dnm path
var _dnm_models := {}            # .dnm path -> built model, shared by every aircraft of that type
var _ground_script: GDScript
var _ground_index := {}          # ground object .dat -> its model file (from the ground lists)
var _ground_meshes := {}         # ground model path -> mesh (null if it has no faces)
var _weapon_index := {}          # which model each aircraft's weapons use (weapon_models.gd)
var _weapon_meshes := {}         # weapon model path -> mesh (null if it has no faces)
var _shadow_shader: Shader

func _ready():
	get_window().mode = Window.MODE_MAXIMIZED
	# the window's title shows which version this is (version.txt comes with a release)
	var version_file := Paths.of("version.txt")
	get_window().title = "YSFlight Replay Viewer" + (("  " + FileAccess.get_file_as_string(version_file).strip_edges())
		if FileAccess.file_exists(version_file) else "")
	setup_environment()
	for a in Keys.ACTIONS:
		keys.keys[a[0]] = int(_setting("key_" + a[0], a[2]))
	ui = load("res://ui_layer.gd").new()
	ui.keys = keys
	add_child(ui)
	ui.open_replays.connect(build_event)
	ui.open_event.connect(load_event)
	ui.play_toggled.connect(func(): set_playing(not playing))
	ui.restart.connect(restart)
	ui.step.connect(func(s): seek(replay_time + s))
	ui.seek_requested.connect(seek)
	ui.speed_changed.connect(_set_speed)
	ui.aircraft_chosen.connect(_on_aircraft_chosen)
	ui.kill_chosen.connect(_on_kill_chosen)
	ui.death_chosen.connect(_on_death_chosen)
	ui.ground_chosen.connect(_on_ground_chosen)
	ui.rewind_pressed.connect(rewind)
	ui.fast_forward_pressed.connect(fast_forward)
	ui.frame_step.connect(func(d): frame_step(d, false))
	ui.layout_changed.connect(_place_feed)
	ui.panel_toggled.connect(func(shown): _set_setting("side_panel", shown))
	ui.top_view_toggled.connect(func(): set_top_view(not top_view))
	ui.cinema_pressed.connect(func(): set_cinema(true))
	ui.key_chosen.connect(_on_key_chosen)
	ui.keys_reset.connect(_on_keys_reset)
	ui.set_panel_visible(_setting("side_panel", true))
	for key in view:
		view[key] = _setting("view_" + key, view[key])
	ui.show_view(view)
	ui.view_changed.connect(_on_view_changed)
	cinema = load("res://cinema.gd").new()
	cinema.main = self
	add_child(cinema)
	builder = load("res://event_builder.gd").new()
	add_child(builder)
	builder.progress.connect(func(p, text): ui.show_busy(p, "Building the event: " + text))
	builder.finished.connect(_on_build_finished)
	_ribbon_script = load("res://ribbon_layer.gd")
	_shadow_shader = Shader.new()
	_shadow_shader.code = SHADOW_SHADER
	_ground_script = load("res://ground_layer.gd")
	# start menu, offering the event used last time (else the newest one built)
	var last: String = _setting("last_event", "")
	if last == "" or not FileAccess.file_exists(last):
		last = _newest_event()
	ui.show_start_menu(last)

func _newest_event() -> String:
	var dir := Paths.of("events")
	var newest := ""
	var newest_time := 0
	if not DirAccess.dir_exists_absolute(dir):
		return ""
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".json") or f.ends_with(".json.gz"):
			var when := FileAccess.get_modified_time(dir + "/" + f)
			if when > newest_time:
				newest = dir + "/" + f
				newest_time = when
	return newest

func setup_environment():
	var env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky = Sky.new()
	sky_material = ProceduralSkyMaterial.new()
	sky.sky_material = sky_material
	env.sky = sky

	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 45, 0)
	add_child(sun)

	camera = Camera3D.new()
	camera.current = true
	camera.far = 150000.0
	add_child(camera)

	ground_plane = MeshInstance3D.new()
	var plane_mesh = PlaneMesh.new()
	plane_mesh.size = Vector2(600000, 600000)
	var ground_mat = StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.15, 0.3, 0.15)
	ground_plane.mesh = plane_mesh
	ground_plane.material_override = ground_mat
	add_child(ground_plane)

	vectors = ArrayMesh.new()
	vector_node = MeshInstance3D.new()
	vector_node.mesh = vectors
	vector_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var vector_mat := StandardMaterial3D.new()
	vector_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	vector_mat.vertex_color_use_as_albedo = true
	vector_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	vector_node.material_override = vector_mat
	add_child(vector_node)

# The aircraft's own YSFlight model (dnm_model.gd), true size; the blocky placeholder if the View
# tab asks for it (faster) or there is no model for that aircraft.
func create_aircraft_model(entity: Dictionary) -> Node3D:
	var path = _dnm_index.get(str(entity.get("aircraft", "")).to_upper())
	if not view["blocky"] and path != null and _dnm_models.has(path):
		return DnmModel.instance(_dnm_models[path])
	return _box_model(iff_color(entity.get("iff")))

# Swaps every aircraft's model (after the placeholder setting changed).
func _rebuild_models() -> void:
	if event_data == null:
		return
	for id in aircraft_models:
		var old: Node3D = aircraft_models[id]
		var model := create_aircraft_model(event_data["entities"][id])
		model.transform = old.transform
		active_aircraft[id].add_child(model)
		old.queue_free()
		aircraft_models[id] = model
		_cast_shadows(model, view["lighting"])
		_add_shadow(model, aircraft_shadows[id])

func _box_model(team_color: Color) -> Node3D:
	var root = Node3D.new()
	var mat = StandardMaterial3D.new()
	mat.albedo_color = team_color

	var fuse = MeshInstance3D.new()
	var f_mesh = BoxMesh.new()
	f_mesh.size = Vector3(4, 4, 20)
	fuse.mesh = f_mesh
	fuse.material_override = mat
	root.add_child(fuse)

	var wings = MeshInstance3D.new()
	var w_mesh = BoxMesh.new()
	w_mesh.size = Vector3(20, 0.5, 6)
	wings.mesh = w_mesh
	wings.position = Vector3(0, 0, 2)
	wings.material_override = mat
	root.add_child(wings)

	var tail = MeshInstance3D.new()
	var t_mesh = BoxMesh.new()
	t_mesh.size = Vector3(0.5, 5, 4)
	tail.mesh = t_mesh
	tail.position = Vector3(0, 2.5, 8)
	tail.material_override = mat
	root.add_child(tail)

	var cockpit = MeshInstance3D.new()
	var c_mesh = BoxMesh.new()
	c_mesh.size = Vector3(2.5, 2, 5)
	cockpit.mesh = c_mesh
	var c_mat = StandardMaterial3D.new()
	c_mat.albedo_color = Color(0, 0, 0)
	cockpit.material_override = c_mat
	cockpit.position = Vector3(0, 2, -4)
	root.add_child(cockpit)

	return root

# A shadow for every part of an aircraft's model (the afterburner flame casts none): the same mesh
# drawn with the aircraft's shadow material, which flattens it onto the ground (SHADOW_SHADER).
func _add_shadow(model: Node3D, material: ShaderMaterial) -> void:
	var flames := {}
	if model.has_meta("dnm"):
		var m: Dictionary = model.get_meta("dnm")
		for gi in m["groups"].size():
			if m["groups"][gi]["cla"] == DnmModel.AFTERBURNER:
				flames[m["nodes"][gi]] = true
	for part in model.find_children("*", "MeshInstance3D", true, false):
		if flames.has(part.get_parent()):
			continue
		var s := MeshInstance3D.new()
		s.mesh = part.mesh
		s.material_override = material
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		s.extra_cull_margin = 16384.0          # drawn on the ground, far below the aircraft's own box
		s.visible = view["shadows"]
		s.add_to_group("aircraft_shadow")
		part.add_child(s)

# --- YSFLIGHT -> GODOT CONVERSION ---
# YSFlight's world is left-handed (x east, y up, z north) and Godot's is
# right-handed, so z flips. With that flip, YSFlight's attitude (heading, pitch,
# bank in radians) is exactly Godot's default YXZ Euler order with NO sign
# changes, for a model whose nose points -Z. Checked against 1-WW3_event.yfs
# (noses follow the flight path, lift leans into turns, pitch is + at liftoff;
# other orders such as YZX fail in steep turns) and against YSFlight's own
# heathrow.stp (runway 9L starts at -x with heading -90deg, i.e. faces east).
static func ys_position(f) -> Vector3:
	return ys_vec(f["x"], f["y"], f["z"])

static func ys_vec(x, y, z) -> Vector3:
	return Vector3(x, y, -z)

static func ys_basis(f) -> Basis:
	return Basis.from_euler(Vector3(f["pitch"], f["yaw"], f["roll"]))

# Team colour from the IFF the game itself used for friend/foe: Blue flies IFF 1,
# Red flies IFF 4. Name tags aren't reliable ("[RED]Decaff_42" flew IFF 1 at RvB 1).
static func iff_color(iff) -> Color:
	if iff == 1: return Color(0.1, 0.5, 1.0)
	if iff == 4: return Color(1.0, 0.1, 0.1)
	return Color(0.5, 0.5, 0.5)

# --- EVENTS: build from replays, load, clear ---

func build_event(replays: PackedStringArray, fld_path: String) -> void:
	var dir := Paths.of("events")
	DirAccess.make_dir_recursive_absolute(dir)
	if not FileAccess.file_exists(dir + "/.gdignore"):
		FileAccess.open(dir + "/.gdignore", FileAccess.WRITE)   # keep Godot from importing events
	var stem := replays[0].get_file().get_basename().validate_filename()
	if replays.size() > 1:
		stem += "_and_%d_more" % (replays.size() - 1)
	var out := "%s/%s.json.gz" % [dir, stem]      # compressed: several times smaller
	set_playing(false)
	ui.show_busy(0, "Building the event from %d replay file(s)..." % replays.size())
	builder.build(replays, fld_path, out)

func _on_build_finished(ok: bool, out_path: String, log_text: String) -> void:
	if ok:
		load_event(out_path)
	else:
		ui.hide_busy()
		var tail := log_text.strip_edges().split("\n")
		ui.set_status("Could not build the event: " + (tail[tail.size() - 1] if tail.size() > 0 else "unknown error"))
		push_warning(log_text)

# Reading a 100-200 MB event file takes a few seconds, so it happens off the main thread.
func load_event(path: String) -> void:
	if _load_thread != null and _load_thread.is_started():
		return
	set_playing(false)
	ui.hide_start_menu()
	ui.show_busy(50, "Loading %s ..." % path.get_file())
	_dnm_index = DnmModel.index_models(Paths.of(AIRCRAFT_DIR))
	_ground_index = _ground_script.index_models()
	_weapon_index = WeaponModels.index()
	_load_thread = Thread.new()
	_load_thread.start(_read_event.bind(path, map_node.field if map_node != null else ""))

# An event file's text: gzip-compressed (.json.gz, what the pipeline writes now) or plain (.json).
static func read_event_text(path: String) -> String:
	if path.to_lower().ends_with(".gz"):
		var packed := FileAccess.get_file_as_bytes(path)
		return packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	return FileAccess.get_file_as_string(path)

# Everything slow happens here, off the main thread: reading the event and its map, building the
# ribbons, and reading the aircraft, ground-object and weapon models not read before. `extra`
# carries the results: ribbons, the models, each ground object's and each weapon's model path.
func _read_event(path: String, loaded_field: String) -> void:   # loader thread
	var json := JSON.new()
	var err := json.parse(read_event_text(path))
	var data = json.data if err == OK else null
	var map_data = null
	var extra := {"strips": {}, "aircraft": {}, "ground": {}, "weapon": {}, "ground_paths": {},
		"weapon_paths": {}}
	if typeof(data) == TYPE_DICTIONARY and data.has("entities"):
		if data.get("field", "") != loaded_field:
			var map_path := map_path_for(data)
			if FileAccess.file_exists(map_path):
				var mj := JSON.new()
				if mj.parse(FileAccess.get_file_as_string(map_path)) == OK:
					map_data = mj.data
		extra["strips"] = _ribbon_script.build_arrays(data["entities"])
		# models not read yet: [path, "aircraft" / "ground" / "weapon", result], read on all
		# cores at once
		var jobs := []
		var queued := {}
		for id in data["entities"]:
			var model_path = _dnm_index.get(str(data["entities"][id].get("aircraft", "")).to_upper())
			if model_path != null and not _dnm_models.has(model_path) and not queued.has(model_path):
				queued[model_path] = true
				jobs.append([model_path, "aircraft", {}])
		for g in data.get("ground_objects", []):
			var model_path: String = _ground_script.model_path(g, _ground_index)
			if model_path == "":
				continue
			extra["ground_paths"][int(g["index"])] = model_path
			if not _ground_meshes.has(model_path) and not queued.has(model_path + "|g"):
				queued[model_path + "|g"] = true
				jobs.append([model_path, "ground", {}])
		var weapons: Array = data.get("weapons", [])
		for i in weapons.size():
			var w: Dictionary = weapons[i]
			var owner = w.get("owner_ref")
			var shooter := ""
			if owner != null and owner["kind"] == "aircraft":
				shooter = str(data["entities"].get(str(int(owner["id"])), {}).get("aircraft", ""))
			var model_path := WeaponModels.model_for(str(w.get("name", "")), shooter, _weapon_index)
			if model_path == "":
				continue
			extra["weapon_paths"][i] = model_path
			if not _weapon_meshes.has(model_path) and not queued.has(model_path + "|w"):
				queued[model_path + "|w"] = true
				jobs.append([model_path, "weapon", {}])
		if jobs.size() > 0:
			var task := WorkerThreadPool.add_group_task(
				func(i): jobs[i][2]["model"] = DnmModel.load_or_parse(jobs[i][0], jobs[i][1] != "aircraft"),
				jobs.size())
			WorkerThreadPool.wait_for_group_task_completion(task)
		for job in jobs:
			extra[job[1]][job[0]] = job[2]["model"]
	_event_read.call_deferred(path, data, json.get_error_message(), map_data, extra)

func _event_read(path: String, data, error_text: String, map_data, extra: Dictionary) -> void:
	_load_thread.wait_to_finish()
	_load_thread = null
	for model_path in extra["aircraft"]:
		_dnm_models[model_path] = DnmModel.build(extra["aircraft"][model_path])
	for model_path in extra["ground"]:
		_ground_meshes[model_path] = DnmModel.build(extra["ground"][model_path])["groups"][0]["mesh"]
	for model_path in extra["weapon"]:
		_weapon_meshes[model_path] = DnmModel.build(extra["weapon"][model_path])["groups"][0]["mesh"]
	if typeof(data) != TYPE_DICTIONARY or not data.has("entities"):
		ui.hide_busy()
		ui.set_status("Could not read %s: %s" % [path.get_file(), error_text])
		ui.show_start_menu(ui.menu_last)
		return
	if typeof(map_data) == TYPE_DICTIONARY:
		show_map(map_data)
	elif map_node != null and map_node.field != data.get("field", ""):
		show_map(null)               # different field and no map file for it: plain ground
	clear_event()
	event_data = data
	event_root = Node3D.new()
	add_child(event_root)
	spawn_aircraft(data)
	combat = load("res://combat_layer.gd").new()
	event_root.add_child(combat)
	combat.setup(data, {"meshes": _weapon_meshes, "paths": extra["weapon_paths"]})
	ribbons = _ribbon_script.new()
	event_root.add_child(ribbons)
	ribbons.setup(extra["strips"])
	grounds = _ground_script.new()
	event_root.add_child(grounds)
	grounds.setup(data.get("ground_objects", []), _ground_meshes, extra["ground_paths"])
	_apply_view()
	_place_feed()
	ui.show_event(data, t_min, t_max, path)
	ui.hide_busy()
	ui.menu_last = path
	_set_setting("last_event", path)
	seek(t_min)

# --- MAP ---

# maps/<FIELD>.json, made by fld_reader.py; "[RVB]LUAVI" -> "RVB_LUAVI.json" (same rule there)
static func map_path_for(data: Dictionary) -> String:
	var name: String = data.get("map_file", "")
	if name == "":
		var re := RegEx.new()
		re.compile("[^A-Za-z0-9]+")
		name = re.sub(str(data.get("field", "")), "_", true).lstrip("_").rstrip("_").to_upper() + ".json"
	return Paths.of("maps/" + name)

func show_map(data) -> void:
	if map_node != null:
		map_node.queue_free()
		map_node = null
	var mat: StandardMaterial3D = ground_plane.material_override
	if data == null:
		mat.albedo_color = Color(0.15, 0.3, 0.15)
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
		mat.render_priority = 0
		ground_plane.position.y = 0.0
		var plain := ProceduralSkyMaterial.new()
		for key in ["sky_top_color", "sky_horizon_color", "ground_horizon_color", "ground_bottom_color"]:
			sky_material.set(key, plain.get(key))
		return
	map_node = load("res://map_layer.gd").new()
	add_child(map_node)
	map_node.build(data)
	map_node.set_lighting(view["lighting"])
	# beyond the drawn map: the field's ground colour (GND), unlit, as a backdrop that hides
	# nothing, like YSFlight's. Without depth writes Godot draws it in the transparent pass: first
	# there, so the map's layers (map_layer.gd) paint over it.
	mat.albedo_color = map_node.base_color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.render_priority = Material.RENDER_PRIORITY_MIN
	ground_plane.position.y = -0.5
	sky_material.sky_top_color = map_node.sky_color
	sky_material.sky_horizon_color = map_node.sky_color.lightened(0.3)
	sky_material.ground_horizon_color = map_node.base_color
	sky_material.ground_bottom_color = map_node.base_color

func clear_event() -> void:
	if cinema.on:
		set_cinema(false)
	cinema.event_cleared()
	if event_root != null:
		event_root.queue_free()
	event_root = null
	combat = null
	ribbons = null
	grounds = null
	event_data = null
	active_aircraft.clear()
	aircraft_models.clear()
	aircraft_shadows.clear()
	aircraft_attitude.clear()
	full_health.clear()
	aircraft_tags.clear()
	telemetry_data.clear()
	current_frame_indices.clear()
	order.clear()
	tracked_id = ""

func spawn_aircraft(data):
	var entities = data["entities"]
	t_min = INF
	t_max = -INF

	for air_id in entities:
		var entity = entities[air_id]
		var t_frames = entity["telemetry"]

		if t_frames.size() > 0:
			t_min = min(t_min, t_frames[0]["t"])
			t_max = max(t_max, t_frames[-1]["t"])
			var spawn_pos = ys_position(t_frames[0])
			var team_color = iff_color(entity.get("iff"))

			# The marker only moves; the model inside it also rotates. The name tag
			# hangs off the marker so it stays above the aircraft in any attitude.
			var marker = Node3D.new()
			marker.position = spawn_pos
			event_root.add_child(marker)

			var plane_model = create_aircraft_model(entity)
			marker.add_child(plane_model)
			_cast_shadows(plane_model, view["lighting"])
			var shadow := ShaderMaterial.new()
			shadow.shader = _shadow_shader
			shadow.render_priority = SHADOW_PRIORITY
			_add_shadow(plane_model, shadow)
			aircraft_shadows[air_id] = shadow

			# same size on screen at any distance, just above the aircraft, seen through terrain
			var tag = Label3D.new()
			tag.text = "%s\n%s" % [entity["player"], Fmt.short_type(entity["aircraft"])]
			tag.font_size = 32
			tag.outline_size = 8
			tag.modulate = team_color.lightened(0.45)
			tag.outline_modulate = Color.BLACK
			tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			tag.fixed_size = true
			tag.pixel_size = TAG_PIXEL * view["text_scale"]
			tag.no_depth_test = true
			tag.render_priority = 5
			tag.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
			tag.offset = Vector2(0, 24)
			marker.add_child(tag)

			active_aircraft[air_id] = marker
			aircraft_models[air_id] = plane_model
			aircraft_tags[air_id] = tag
			var most := 0                # whole at the start (the first 2 s: a quick look, big events)
			for k in mini(t_frames.size(), 40):
				most = maxi(most, int(t_frames[k]["ctrl"][9]))
			full_health[air_id] = most
			telemetry_data[air_id] = t_frames
			current_frame_indices[air_id] = 0

	if t_min == INF:
		t_min = 0.0
		t_max = 1.0
	order = active_aircraft.keys()
	order.sort_custom(func(a, b): return telemetry_data[a][0]["t"] < telemetry_data[b][0]["t"])

# --- PLAYBACK ---

# Play (forwards, at the chosen speed) or pause. Playing from the very end starts again.
func set_playing(on: bool) -> void:
	var was := playing
	playing = on and event_data != null
	if playing:
		play_direction = 1
		if replay_time >= t_max:
			seek(t_min)
		if not was and cinema.on:
			cinema.note_play()           # Retake comes back here

func restart() -> void:
	seek(t_min)
	set_playing(true)

func _set_speed(s: float) -> void:
	playback_speed = s

# Play backwards; pressed again while going backwards, twice as fast (1x, 2x, 4x ... 128x).
func rewind() -> void:
	if event_data == null:
		return
	if playing and play_direction < 0:
		playback_speed = minf(playback_speed * 2.0, 128.0)
	else:
		playback_speed = maxf(playback_speed, 1.0)
	play_direction = -1
	playing = true
	ui.show_speed(playback_speed)

# Play forwards fast; pressed again, twice as fast (2x, 4x ... 128x).
func fast_forward() -> void:
	if event_data == null:
		return
	if playing and play_direction > 0 and playback_speed >= 2.0:
		playback_speed = minf(playback_speed * 2.0, 128.0)
	else:
		playback_speed = maxf(playback_speed * 2.0, 2.0)
	play_direction = 1
	playing = true
	if replay_time >= t_max:
		seek(t_min)
	ui.show_speed(playback_speed)

# Pause and move one recorded frame (1/20 s), or a whole second.
func frame_step(direction: int, whole_second: bool) -> void:
	playing = false
	seek(replay_time + direction * (1.0 if whole_second else 0.05))

func _process(delta):
	# the cinematic mode eases the clock into and out of slow motion and pauses
	var run: float = (1.0 if playing else 0.0) if not cinema.on else cinema.time_rate(delta, playing)
	if run > 0.0:
		replay_time += delta * playback_speed * play_direction * run
		if replay_time >= t_max or replay_time <= t_min:
			replay_time = clampf(replay_time, t_min, t_max)
			playing = false
			if cinema.on:
				cinema.stop_now()

	var positions := {}          # aircraft in the air now: id -> position (for missile tethers)
	var vector_items := []       # [position, velocity, nose direction], drawn once the camera has moved
	_tag_clock += delta
	var tag_now: bool = _tag_clock >= TAG_INTERVAL and view["tags"]
	if tag_now:
		_tag_clock = 0.0
	var size: float = view["aircraft_scale"] if not cinema.on else 1.0   # the cinematic mode: true size
	var model_size := size
	if top_view:                   # big enough to see from above (a 15 m aircraft TOP_AIRCRAFT_PX long)
		model_size = maxf(size, _metres_per_pixel() * TOP_AIRCRAFT_PX / 15.0)
	for air_id in active_aircraft.keys():
		var marker = active_aircraft[air_id]
		var frames = telemetry_data[air_id]
		var idx = current_frame_indices[air_id]

		if replay_time < frames[idx]["t"] and idx > 0:
			idx = frame_index_at(frames, replay_time)      # time went backwards
		while idx < frames.size() - 2 and replay_time >= frames[idx + 1]["t"]:
			idx += 1

		current_frame_indices[air_id] = idx

		if replay_time >= frames[0]["t"] and replay_time <= frames[frames.size()-1]["t"]:
			marker.visible = true
			var f1 = frames[idx]
			var f2 = frames[idx + 1] if idx + 1 < frames.size() else f1

			var time_gap = f2["t"] - f1["t"]
			var weight = 0.0
			if time_gap > 0:
				weight = clamp((replay_time - f1["t"]) / time_gap, 0.0, 1.0)

			var attitude: Basis
			if cinema.on:                # smoothed (network jitter out): slow motion, close cameras
				var sm := _filtered(frames, idx, replay_time)
				marker.position = sm[0]
				attitude = sm[2]
			else:
				marker.position = ys_position(f1).lerp(ys_position(f2), weight)
				# Both keyframes must go through the same conversion, or the
				# slerp swings between two different attitudes every frame.
				attitude = ys_basis(f1).slerp(ys_basis(f2), weight)
			aircraft_attitude[air_id] = attitude
			var model: Node3D = aircraft_models[air_id]
			model.basis = attitude.scaled(Vector3(model_size, model_size, model_size))
			if model.has_meta("dnm"):            # gear (0..255 up..down) and afterburner (flag bit 1)
				DnmModel.pose(model, f1["ctrl"][3] / 255.0, (int(f1["ctrl"][8]) & 1) == 1)
			positions[air_id] = marker.position
			if view["shadows"]:
				var ground: Array = map_node.ground_at(marker.position.x, marker.position.z) if map_node != null \
					else [0.0, Vector3.UP]
				var shadow: ShaderMaterial = aircraft_shadows[air_id]
				shadow.set_shader_parameter("ground_point", Vector3(marker.position.x, ground[0], marker.position.z))
				shadow.set_shader_parameter("ground_normal", ground[1])
			var velocity := _velocity(frames, idx)
			if view["vectors"] and not cinema.on:
				vector_items.append([marker.position, velocity, -attitude.z])
			if tag_now:
				_update_tag(air_id, marker.position.y, velocity.length(), f1["ctrl"])
		else:
			marker.visible = false

	if combat:
		combat.update(replay_time, positions)
	if ribbons:
		ribbons.update(replay_time)
	if grounds:
		grounds.update(replay_time)

	if cinema.on:
		cinema.update(delta)
	else:
		_update_camera(delta)
	_draw_vectors(vector_items, size)
	ui.refresh(replay_time, playing, playback_speed, play_direction)
	ui.set_info(_info_text())

func _update_camera(delta):
	if top_view:
		if tracked_id != "" and active_aircraft.has(tracked_id):
			var p := _pos_at(telemetry_data[tracked_id], replay_time)
			camera.position = Vector3(p.x, TOP_HEIGHT, p.z)
		else:
			var move := Vector3.ZERO           # north is up on the screen (-z)
			if keys.held("move_forward"): move.z -= 1.0
			if keys.held("move_back"): move.z += 1.0
			if keys.held("move_left"): move.x -= 1.0
			if keys.held("move_right"): move.x += 1.0
			var pace := camera.size * (1.8 if Input.is_key_pressed(KEY_SHIFT) else 0.6)
			camera.position += move.normalized() * pace * delta
		camera.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
		return
	if tracked_id != "" and active_aircraft.has(tracked_id):
		var target_pos = _pos_at(telemetry_data[tracked_id], replay_time)
		var offset = Vector3(0, 0, cam_distance)
		offset = offset.rotated(Vector3.RIGHT, cam_rot_x)
		offset = offset.rotated(Vector3.UP, cam_rot_y)
		camera.position = target_pos + offset
		camera.look_at(target_pos, Vector3.UP)
	else:
		camera.rotation = Vector3(cam_rot_x, cam_rot_y, 0)

		var dir = Vector3.ZERO
		if keys.held("move_forward"): dir -= camera.global_transform.basis.z
		if keys.held("move_back"): dir += camera.global_transform.basis.z
		if keys.held("move_left"): dir -= camera.global_transform.basis.x
		if keys.held("move_right"): dir += camera.global_transform.basis.x
		if keys.held("move_up"): dir += Vector3.UP
		if keys.held("move_down"): dir += Vector3.DOWN

		var current_speed = move_speed
		if Input.is_key_pressed(KEY_SHIFT):
			current_speed *= 10.0

		camera.position += dir.normalized() * current_speed * delta

# The top view on or off. On: straight down on what the camera was looking at (the aircraft it
# follows, else the ground ahead), about as wide as the view was; off: the 3D camera as it was.
func set_top_view(on: bool) -> void:
	if on == top_view:
		return
	top_view = on
	if on:
		_saved_view = {"position": camera.position, "rot_x": cam_rot_x, "rot_y": cam_rot_y}
		var centre := camera.position
		var span := 2.0 * cam_distance
		if tracked_id != "" and active_aircraft.has(tracked_id):
			centre = _pos_at(telemetry_data[tracked_id], replay_time)
			span = maxf(cam_distance * 12.0, 8000.0)
		else:
			var fwd := -camera.global_transform.basis.z
			if fwd.y < -0.05:                  # where the view meets sea level
				centre = camera.position + fwd * (camera.position.y / -fwd.y)
			else:
				centre = camera.position + Vector3(fwd.x, 0.0, fwd.z).normalized() * 5000.0
			span = 2.0 * camera.position.distance_to(centre)
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = clampf(span, 4000.0, 60000.0)
		camera.near = 1.0
		camera.position = Vector3(centre.x, TOP_HEIGHT, centre.z)
		camera.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	else:
		camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		camera.near = 0.05
		if not _saved_view.is_empty():
			camera.position = _saved_view["position"]
			cam_rot_x = _saved_view["rot_x"]
			cam_rot_y = _saved_view["rot_y"]
	ui.show_top_view(on)

# Better lighting (View tab) or YSFlight's flat daylight: the hills lit by a lower sun
# (map_layer.gd); the models shinier, lit from that same sun, shading themselves (their own
# shadows reach only models: the map is unlit, so the ground keeps just the YSFlight shadow)
# and darker in their creases (ambient occlusion). Off also saves the graphics card that work.
func _apply_lighting(better: bool) -> void:
	DnmModel.set_lighting(better)
	if map_node != null:
		map_node.set_lighting(better)
	if better:
		var s: Vector3 = map_layer_sun()
		sun.basis = Basis.looking_at(-s, Vector3.UP)
		sun.light_energy = 1.15
	else:
		sun.rotation_degrees = Vector3(-45, 45, 0)
		sun.light_energy = 1.0
	sun.shadow_enabled = better
	sun.directional_shadow_max_distance = 600.0
	world_env.environment.ssao_enabled = better
	for id in aircraft_models:
		_cast_shadows(aircraft_models[id], better)

# Whether an aircraft's own parts cast (self-)shadows; its YSFlight-style shadow never does.
static func _cast_shadows(model: Node3D, on: bool) -> void:
	for part in model.find_children("*", "MeshInstance3D", true, false):
		if not part.is_in_group("aircraft_shadow"):
			part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if on \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

# The better lighting's sun in viewer axes (z flips).
static func map_layer_sun() -> Vector3:
	var s: Vector3 = load("res://map_layer.gd").RELIEF_SUN
	return Vector3(s.x, s.y, -s.z)

# Metres per screen pixel in the top view (window height in real pixels).
func _metres_per_pixel() -> float:
	return camera.size / maxf(get_window().size.y, 1.0)

# Jump the replay clock to time t, forwards or backwards. Every aircraft is put
# back on the right frame (_process only ever steps frames forwards, so after a
# jump back the others would otherwise sit at future positions).
func seek(t):
	replay_time = clamp(t, t_min, t_max)
	for air_id in telemetry_data:
		current_frame_indices[air_id] = frame_index_at(telemetry_data[air_id], replay_time)
	if cinema.on:
		cinema.cut()
	ui.refresh(replay_time, playing, playback_speed, play_direction)   # (its clock is "now" for N / C)

# Index of the last frame at or before time t (0 if t is before the first frame).
static func frame_index_at(frames, t) -> int:
	var lo = 0
	var hi = frames.size() - 1
	while lo < hi:
		var mid = (lo + hi + 1) >> 1
		if frames[mid]["t"] <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo

# Position on a track at time t (held at the ends).
static func _pos_at(frames, t) -> Vector3:
	var i = frame_index_at(frames, t)
	var f1 = frames[i]
	var f2 = frames[min(i + 1, frames.size() - 1)]
	var gap = f2["t"] - f1["t"]
	var w = clamp((t - f1["t"]) / gap, 0.0, 1.0) if gap > 0 else 0.0
	return ys_position(f1).lerp(ys_position(f2), w)

# The track at time t, smoothed (the cinematic mode): [position, velocity, attitude]. Position and
# velocity: a straight line fitted to the samples within 3 sigma of t, the nearer the more
# weight (Gaussian; local linear regression, so it doesn't lag or drift at the ends and copes
# with uneven sample times); attitude: the weighted mean of the nose and top directions.
# i: the last sample at or before t.
static func _filtered(frames: Array, i: int, t: float) -> Array:
	var n := frames.size()
	var reach := 3.0 * SMOOTH_SIGMA
	var a := i
	while a > 0 and float(frames[a - 1]["t"]) >= t - reach:
		a -= 1
	var b := i
	while b < n - 1 and float(frames[b + 1]["t"]) <= t + reach:
		b += 1
	var k_pos := 1.0 / (2.0 * SMOOTH_SIGMA * SMOOTH_SIGMA)
	var k_att := 1.0 / (2.0 * SMOOTH_SIGMA_ATT * SMOOTH_SIGMA_ATT)
	var s0 := 0.0
	var s1 := 0.0
	var s2 := 0.0
	var sp := Vector3.ZERO
	var sdp := Vector3.ZERO
	var nose := Vector3.ZERO
	var top := Vector3.ZERO
	for k in range(a, b + 1):
		var f: Dictionary = frames[k]
		var d: float = float(f["t"]) - t
		var w := exp(-d * d * k_pos)
		var p := Vector3(f["x"], f["y"], -f["z"])
		s0 += w
		s1 += w * d
		s2 += w * d * d
		sp += p * w
		sdp += p * (w * d)
		var wa := exp(-d * d * k_att)
		var att := ys_basis(f)
		nose -= att.z * wa
		top += att.y * wa
	var pos := sp / s0
	var vel := Vector3.ZERO
	var det := s0 * s2 - s1 * s1
	if det > 1e-9 * s0 * s0:
		pos = (sp * s2 - sdp * s1) / det
		vel = (sdp * s0 - sp * s1) / det
	var basis := ys_basis(frames[i])
	if nose.length_squared() > 1e-8 and top.length_squared() > 1e-8 and absf(nose.normalized().dot(top.normalized())) < 0.99:
		basis = Basis.looking_at(nose.normalized(), top.normalized())
	return [pos, vel, basis]

# An aircraft's smoothed position / velocity (m/s) at any time t (the cinematic mode's cameras).
func track_pos(id: String, t: float) -> Vector3:
	var frames: Array = telemetry_data[id]
	return _filtered(frames, frame_index_at(frames, t), t)[0]

func track_vel(id: String, t: float) -> Vector3:
	var frames: Array = telemetry_data[id]
	return _filtered(frames, frame_index_at(frames, t), t)[1]

# Velocity (m/s) around track sample idx: the move from two samples before it to three after
# (about 0.25 s at 20 samples a second), over the time between them.
static func _velocity(frames: Array, idx: int) -> Vector3:
	var i0 := maxi(idx - 2, 0)
	var i1 := mini(idx + 3, frames.size() - 1)
	var dt: float = frames[i1]["t"] - frames[i0]["t"]
	if dt <= 0.0:
		return Vector3.ZERO
	return (ys_position(frames[i1]) - ys_position(frames[i0])) / dt

# Flight path vectors: from each aircraft to where it will be in VECTOR_SECONDS, with an arrow
# head; and a grey nose line of the same length, so the angle between them (angle of attack,
# sideslip) shows. Both grow with the aircraft size setting. They are thin strips facing the
# camera, VECTOR_WIDTH_PX wide on screen: plain 3D lines come out 4 px wide with some graphics
# drivers (Direct3D 12 on Intel here), and Godot has no line width setting.
func _draw_vectors(items: Array, size: float) -> void:
	vectors.clear_surfaces()
	if items.is_empty():
		return
	var cam := camera.global_position
	var fwd := -camera.global_transform.basis.z
	# size of one screen pixel 1 m in front of the camera (window height in real pixels: the UI's
	# stretch mode gives the viewport rect in scaled units); in the top view the same everywhere
	var pixel := _metres_per_pixel() if top_view else \
		2.0 * tan(deg_to_rad(camera.fov) * 0.5) / maxf(get_window().size.y, 1.0)
	var half := 0.5 * VECTOR_WIDTH_PX * pixel     # half the width, per metre from the camera
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	for it in items:
		var p: Vector3 = it[0]
		var velocity: Vector3 = it[1]
		var speed := velocity.length()
		if speed < 5.0:
			continue
		var length := speed * VECTOR_SECONDS * size
		var dir := velocity / speed
		var tip := p + dir * length
		var side := dir.cross(-fwd if top_view else cam - tip)   # arrow head flat towards the camera
		side = side.normalized() * length * 0.05 if side.length_squared() > 1e-9 else Vector3.ZERO
		var back := tip - dir * length * 0.12
		_strip(verts, cols, p, tip, VECTOR_COLOR, cam, fwd, half, top_view)
		_strip(verts, cols, tip, back + side, VECTOR_COLOR, cam, fwd, half, top_view)
		_strip(verts, cols, tip, back - side, VECTOR_COLOR, cam, fwd, half, top_view)
		_strip(verts, cols, p, p + it[2].normalized() * length, NOSE_COLOR, cam, fwd, half, top_view)
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	vectors.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

# A line from a to b as two triangles facing the camera; each end as wide as `half` times its
# distance from the camera (so the same number of pixels everywhere; flat: `half` metres, the
# top view has no perspective). Only the part in front of the camera (fwd: where it looks) is
# drawn: a line reaching past the camera would otherwise blow up into a wide beam across the screen.
static func _strip(verts: PackedVector3Array, cols: PackedColorArray, a: Vector3, b: Vector3, c: Color,
		cam: Vector3, fwd: Vector3, half: float, flat := false) -> void:
	var da := (a - cam).dot(fwd)
	var db := (b - cam).dot(fwd)
	if da < STRIP_NEAR and db < STRIP_NEAR:
		return
	if da < STRIP_NEAR:
		a = a.lerp(b, (STRIP_NEAR - da) / (db - da))
	elif db < STRIP_NEAR:
		b = b.lerp(a, (STRIP_NEAR - db) / (da - db))
	var d := b - a
	if d.length_squared() < 1e-6:
		return
	var sa := d.cross(-fwd if flat else cam - a)
	var sb := d.cross(-fwd if flat else cam - b)
	if sa.length_squared() < 1e-12 or sb.length_squared() < 1e-12:
		return
	sa = sa.normalized() * half * (1.0 if flat else a.distance_to(cam))
	sb = sb.normalized() * half * (1.0 if flat else b.distance_to(cam))
	for v in [a - sa, a + sa, b + sb, a - sa, b + sb, b - sb]:
		verts.append(v)
		cols.append(c)

# Name tag: pilot, aircraft, then altitude (ft) and true airspeed (kt) from the track.
func _update_tag(id: String, alt_m: float, speed_ms: float, ctrl: Array) -> void:
	var e = event_data["entities"][id]
	var text := "%s  %s\n%s\n%s ft   %d kt" % [e["player"], health_text(id, ctrl), Fmt.short_type(e["aircraft"]),
		Fmt.thousands(int(round(alt_m * YsAir.M_TO_FT))), int(round(speed_ms * YsAir.MS_TO_KT))]
	var tag: Label3D = aircraft_tags[id]
	if tag.text != text:
		tag.text = text

# "Health 9/10" (the replay's health against the health at the start), "Going down" once hit
# for good (the game then sets health to 1).
func health_text(id: String, ctrl: Array) -> String:
	if int(ctrl[0]) in [4, 5]:
		return "Going down"
	return "Health %d/%d" % [int(ctrl[9]), full_health.get(id, int(ctrl[9]))]

# --- VIEW SETTINGS (View tab) ---

func _on_view_changed(key: String, value) -> void:
	view[key] = value
	_set_setting("view_" + key, value)
	if key == "blocky":
		_rebuild_models()
	_apply_view()

# (the cinematic mode hides the name tags, vectors, ribbons, black smoke ribbons, rings, and in
# combat_layer.gd the trails, tethers, markers and kill feed: the world only)
func _apply_view() -> void:
	var cine: bool = cinema.on
	for id in aircraft_tags:
		aircraft_tags[id].pixel_size = TAG_PIXEL * view["text_scale"]
		aircraft_tags[id].visible = view["tags"] and not cine
	vector_node.visible = view["vectors"] and not cine
	if combat:
		combat.set_view(view)
		combat.set_cinema(cine)
	if ribbons:
		ribbons.set_view(view["ribbons"] and not cine, view["trail_seconds"], view["ribbon_width"],
			view["smoke"] and not cine)
	if grounds:
		grounds.visible = view["ground"]
		grounds.show_clouds(view["clouds"])
		grounds.show_ranges(view["ranges"] and not cine)
	_apply_lighting(view["lighting"])
	get_tree().call_group("aircraft_shadow", "set_visible", view["shadows"])

# --- WHICH AIRCRAFT ---

func follow(id: String) -> void:
	tracked_id = id if active_aircraft.has(id) else ""

func _on_aircraft_chosen(id: String) -> void:
	follow(id)
	var frames = telemetry_data.get(id)
	if frames and (replay_time < frames[0]["t"] or replay_time > frames[-1]["t"]):
		seek(frames[0]["t"])        # not in the air now: go to where that sortie starts

func _on_kill_chosen(k: Dictionary) -> void:
	seek(k["t"] - 5.0)
	for ref in [k.get("killer_ref"), k.get("victim_ref")]:
		if ref != null and ref["kind"] == "aircraft":
			follow(str(int(ref["id"])))
			return

# From the Deaths list: a few seconds before that aircraft went down or disappeared, following it.
func _on_death_chosen(id: String, t: float) -> void:
	seek(t - 8.0)
	follow(id)

# From the Ground list: the free camera looks at the object, a few seconds before it was destroyed
# (or credited, or damaged); t < 0: the time stays.
func _on_ground_chosen(index: int, t: float) -> void:
	if t >= 0.0:
		seek(t - 5.0)
	var g: Dictionary = event_data["ground_objects"][index]
	var samples: Array = g.get("samples", [])
	if samples.is_empty():
		return
	var at: Dictionary = samples[0]
	for sm in samples:
		if float(sm["t"]) <= replay_time:
			at = sm
	var p := Vector3(at["x"], at["y"], -at["z"])
	var info = g.get("dat")
	var size := 20.0
	if info != null and info.get("box") != null:
		var b: Array = info["box"]
		size = maxf(maxf(b[3] - b[0], b[4] - b[1]), b[5] - b[2])
	var back := clampf(size * 5.0, 150.0, 3000.0)
	tracked_id = ""
	if top_view:
		camera.position = Vector3(p.x, TOP_HEIGHT, p.z)
		return
	camera.position = p + Vector3(0.55, 0.45, 0.7).normalized() * back
	var d := (p - camera.position).normalized()
	cam_rot_x = asin(d.y)
	cam_rot_y = atan2(-d.x, -d.z)

# --- CINEMATIC MODE, KEYS, FULL SCREEN ---

# The cinematic mode (cinema.gd) on or off: the side panel, bars, tags, lines and markers hidden
# (put back when it goes off). Only with an event loaded; it leaves the top view.
func set_cinema(on: bool) -> void:
	if on == cinema.on:
		return
	if on and (event_data == null or ui.start_menu.visible):
		return
	if on:
		set_top_view(false)
		if tracked_id == "" or not active_aircraft[tracked_id].visible:
			var near := ""
			var near_d := INF
			for id in _in_air_now():                 # the aircraft nearest the camera
				var d: float = active_aircraft[id].position.distance_to(camera.global_position)
				if d < near_d:
					near = id
					near_d = d
			if near != "":
				follow(near)
		cinema.enter()
	else:
		cinema.leave()
		var e := camera.global_transform.basis.get_euler()   # the free / follow camera from here
		cam_rot_x = clampf(e.x, -1.5, 1.5)
		cam_rot_y = e.y
	ui.visible = not on
	_apply_view()

func toggle_fullscreen() -> void:
	var w := get_window()
	if w.mode == Window.MODE_FULLSCREEN or w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		w.mode = Window.MODE_MAXIMIZED
	else:
		w.mode = Window.MODE_FULLSCREEN

func _on_key_chosen(action: String, keycode: int) -> void:
	keys.keys[action] = keycode
	_set_setting("key_" + action, keycode)
	ui.show_keys()

func _on_keys_reset() -> void:
	keys.reset()
	for a in Keys.ACTIONS:
		_set_setting("key_" + a[0], a[2])
	ui.show_keys()

func _in_air_now() -> Array:
	return order.filter(func(id): return active_aircraft[id].visible)

func _info_text() -> String:
	if event_data == null:
		return ""
	var k = keys
	var hint := "Zoom %d m  |  %s: Next aircraft  |  %s: Free camera  |  Click: Follow  |  %s: Cinematic" % [
		cam_distance, k.short_name("next_aircraft"), k.short_name("free"), k.short_name("cinema")]
	if top_view:
		hint = "Top view %.1f km  |  Wheel: Zoom  |  %s: Next  |  %s: Stop following  |  %s: 3D" % [camera.size / 1000.0,
			k.short_name("next_aircraft"), k.short_name("free"), k.short_name("top")]
	if tracked_id == "":
		if top_view:
			return "Top view %.1f km  |  %s%s%s%s / Right-drag: Move  |  Wheel: Zoom  |  Click: Follow  |  %s: 3D" % [
				camera.size / 1000.0, k.short_name("move_forward"), k.short_name("move_left"), k.short_name("move_back"),
				k.short_name("move_right"), k.short_name("top")]
		return "Free camera (%s%s%s%s, %s/%s, Shift)  |  %s or click an aircraft to follow it  |  %s: Top view  |  %s: Cinematic" % [
			k.short_name("move_forward"), k.short_name("move_left"), k.short_name("move_back"), k.short_name("move_right"),
			k.short_name("move_up"), k.short_name("move_down"), k.short_name("next_aircraft"), k.short_name("top"),
			k.short_name("cinema")]
	var e = event_data["entities"][tracked_id]
	var frames = telemetry_data[tracked_id]
	var iff := int(e.get("iff", 0))
	var team: String = {1: "Blue", 4: "Red"}.get(iff, "IFF %d" % iff)
	var text := "%s   %s   %s" % [e["player"], Fmt.short_type(e["aircraft"]), team]
	var src = e.get("source", {})
	var where := ""
	if not src.is_empty():
		where = "Track: the pilot's own recording" if src.get("own") else \
			"Track: seen from %s (%.2f s delay removed)" % [src.get("file", "?"), src.get("delay", 0.0)]
	var fate = e.get("fate", {})
	if replay_time < frames[0]["t"]:
		return "%s\nNot in the air yet: starts at %s\n%s" % [text, Fmt.clock(frames[0]["t"]), hint]
	if replay_time > frames[-1]["t"]:
		return "%s\nGone since %s\n%s" % [text, Fmt.clock(frames[-1]["t"]), hint]
	var p0 := _pos_at(frames, replay_time - 0.25)
	var p1 := _pos_at(frames, replay_time + 0.25)
	var tas := p0.distance_to(p1) / 0.5
	var alt: float = active_aircraft[tracked_id].position.y
	var f = frames[current_frame_indices[tracked_id]]
	var ctrl = f["ctrl"]
	var state: String = {0: "Flying", 1: "On the ground", 2: "STALLED", 3: "Gone", 4: "GOING DOWN",
		5: "GOING DOWN", 6: "Stopped", 7: "Overrun"}.get(int(ctrl[0]), "")
	text += "\nIAS %d kt   TAS %d kt   M %.2f   ALT %d ft   G %.1f" % [
		YsAir.ias(tas, alt) * YsAir.MS_TO_KT, tas * YsAir.MS_TO_KT, tas / YsAir.mach_one(alt),
		alt * YsAir.M_TO_FT, f.get("g", 0.0)]
	text += "\nThrottle %d%%%s   Gear %s   %s   %s" % [ctrl[10], " + Afterburner" if int(ctrl[8]) & 1 else "",
		"down" if int(ctrl[3]) > 127 else "up", state,
		health_text(tracked_id, ctrl) if int(ctrl[0]) not in [4, 5] else ""]
	if where != "":
		text += "\n" + where
	if fate.get("kind", "") != "":
		text += "\nThis sortie: %s at %s" % [ui.fate_text(fate), Fmt.clock(fate.get("t", 0.0))]
	return text + "\n" + hint

func _place_feed() -> void:
	if combat != null:
		var m: Vector2 = ui.feed_margins()
		combat.set_feed_box(m.x, m.y)

# --- INPUT ---

# Keys reach the viewer before the side panel and menus: Tab only ever switches aircraft (Godot
# would otherwise move the keyboard focus to a button or text box, and later keys would go
# there), and the shortcuts work whatever list or switch was clicked last. Only while a text box
# is being typed in do the other keys go to it; Tab and Esc leave it.
func _input(event):
	if not (event is InputEventKey and event.pressed):
		return
	var focus := get_viewport().gui_get_focus_owner()
	var typing := focus is LineEdit or focus is TextEdit
	if typing and event.keycode not in [KEY_TAB, KEY_ESCAPE]:
		return
	if typing and event.keycode == KEY_ESCAPE:
		focus.release_focus()
		get_viewport().set_input_as_handled()
		return
	if ui.start_menu.visible:
		if event.keycode == KEY_TAB:
			get_viewport().set_input_as_handled()
		return
	if _key(event):
		if focus != null:
			focus.release_focus()
		get_viewport().set_input_as_handled()

# A shortcut key (keys.gd says which action it is); false if it isn't one. Held keys (moving the
# camera, the cinematic mode's slow motion and snap zoom) are read where they are used.
func _key(event: InputEventKey) -> bool:
	var action: String = keys.action_of(event.keycode, cinema.on)
	if action == "" or action.begins_with("move_"):
		return false
	if cinema.on and cinema.key(action, event.shift_pressed):
		return true
	match action:
		"next_aircraft":
			var ids := _in_air_now()
			if ids.size() > 0:
				var i := ids.find(tracked_id)
				follow(ids[posmod(i + (-1 if event.shift_pressed else 1), ids.size())])
		"free":
			tracked_id = ""
		"panel":
			ui.toggle_panel()
		"top":
			set_top_view(not top_view)
		"cinema":
			set_cinema(not cinema.on)
		"fullscreen":
			toggle_fullscreen()
		"play":
			set_playing(not playing)
		"rewind":
			rewind()
		"pause":
			set_playing(false)
		"fast":
			fast_forward()
		"frame_back":
			frame_step(-1, event.shift_pressed)
		"frame_forward":
			frame_step(1, event.shift_pressed)
		"back":
			seek(replay_time - (60.0 if event.shift_pressed else 10.0))
		"forward":
			seek(replay_time + (60.0 if event.shift_pressed else 10.0))
		"restart":
			restart()
		"next_kill":
			ui.jump_kill(-1 if event.shift_pressed else 1)
		"next_check":
			ui.jump_check(-1 if event.shift_pressed else 1)
		"faster":
			playback_speed = min(playback_speed * 2.0, 512.0)
			ui.show_speed(playback_speed)
		"slower":
			playback_speed = max(playback_speed / 2.0, 0.01)
			ui.show_speed(playback_speed)
		_:
			return false
	return true

func _unhandled_input(event):
	if cinema.on:
		cinema.mouse(event)
		return
	if event is InputEventMouseButton and event.pressed:
		get_viewport().gui_release_focus()     # a click in the 3D view leaves any list or text box
	if event is InputEventMouseButton and event.pressed:
		if top_view and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var k := 1.0 / 1.15 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.15
			camera.size = clampf(camera.size * k, TOP_SIZE_MIN, TOP_SIZE_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_distance = clamp(cam_distance / 1.15, 15.0, 80000.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_distance = clamp(cam_distance * 1.15, 15.0, 80000.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			_pick(event.position)

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and top_view:
		tracked_id = ""                         # dragging the map: stop following
		var per := camera.size / maxf(get_viewport().get_visible_rect().size.y, 1.0)
		camera.position -= Vector3(event.relative.x, 0.0, event.relative.y) * per
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		cam_rot_y -= event.relative.x * mouse_sensitivity
		cam_rot_x -= event.relative.y * mouse_sensitivity
		cam_rot_x = clamp(cam_rot_x, -1.5, 1.5)

# Click-to-follow: the aircraft closest to the click direction, within about 1.5 degrees (in the
# top view: within 14 screen units of the click).
func _pick(screen_pos: Vector2) -> void:
	if top_view:
		var near := ""
		var near_d := 14.0
		for id in active_aircraft:
			var m: Node3D = active_aircraft[id]
			if m.visible:
				var d := camera.unproject_position(m.global_position).distance_to(screen_pos)
				if d < near_d:
					near = id
					near_d = d
		if near != "":
			follow(near)
		return
	var origin := camera.project_ray_origin(screen_pos)
	var ray := camera.project_ray_normal(screen_pos)
	var best := ""
	var best_angle := deg_to_rad(1.5)
	for id in active_aircraft:
		var m: Node3D = active_aircraft[id]
		if not m.visible:
			continue
		var to: Vector3 = m.global_position - origin
		var angle := ray.angle_to(to)
		if angle < best_angle:
			best = id
			best_angle = angle
	if best != "":
		follow(best)

# --- SETTINGS ---

func _setting(key: String, default):
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS) != OK:
		return default
	return cfg.get_value("viewer", key, default)

func _set_setting(key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS)
	cfg.set_value("viewer", key, value)
	cfg.save(SETTINGS)
