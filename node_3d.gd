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
# Keys: Space play/pause, J play backwards (again: faster), K pause, L play fast (again: faster),
# , and . one frame back/forward (Shift: 1 s), Left/Right -+10 s (Shift: 60 s), Home restart,
# +/- speed, Tab / Shift+Tab next/previous aircraft in the air, Esc free camera, P side panel.
# Mouse: click an aircraft to follow it, right-drag to look around, wheel to zoom. Free camera:
# WASD, E/Q, Shift = fast.

const YsAir = preload("res://ys_air.gd")
const Fmt = preload("res://fmt.gd")
const DnmModel = preload("res://dnm_model.gd")
const SETTINGS = "user://settings.cfg"
const AIRCRAFT_DIR = "res://aircraft"   # the aircraft's game files (.dat + .dnm), in any subfolders
const TAG_PIXEL = 0.0007         # name tag size (times the text size setting)
const TAG_INTERVAL = 0.2         # seconds between name tag updates
const VECTOR_SECONDS = 1.0       # a flight path vector reaches where the aircraft will be in 1 s
const VECTOR_COLOR = Color(1.0, 0.9, 0.25)
const VECTOR_WIDTH_PX = 1.5
const NOSE_COLOR = Color(0.72, 0.72, 0.72)
# View settings (View tab, saved in settings.cfg as "view_<key>")
const VIEW_DEFAULTS = {"aircraft_scale": 1.0, "weapon_scale": 1.0, "text_scale": 1.0,
	"trail_seconds": 30.0, "ribbons": true, "vectors": true, "tags": true, "tethers": true,
	"markers": true, "ground": true, "clouds": true, "blocky": false, "smoke": true}

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
var telemetry_data = {}
var current_frame_indices = {}
var order: Array = []            # aircraft ids by start time (for Tab)
var tracked_id := ""             # aircraft the camera follows ("" = free camera)

var ui
var builder
var combat: Node3D
var ribbons: Node3D
var grounds: Node3D
var map_node: Node3D             # the YSFlight map (map_layer.gd); kept while the field stays the same
var ground_plane: MeshInstance3D # base plane beyond the drawn map
var sky_material: ProceduralSkyMaterial
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

func _ready():
	get_window().mode = Window.MODE_MAXIMIZED
	setup_environment()
	ui = load("res://ui_layer.gd").new()
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
	ui.rewind_pressed.connect(rewind)
	ui.fast_forward_pressed.connect(fast_forward)
	ui.frame_step.connect(func(d): frame_step(d, false))
	ui.layout_changed.connect(_place_feed)
	ui.panel_toggled.connect(func(shown): _set_setting("side_panel", shown))
	ui.set_panel_visible(_setting("side_panel", true))
	for key in view:
		view[key] = _setting("view_" + key, view[key])
	ui.show_view(view)
	ui.view_changed.connect(_on_view_changed)
	builder = load("res://event_builder.gd").new()
	add_child(builder)
	builder.progress.connect(func(p, text): ui.show_busy(p, "Building the event: " + text))
	builder.finished.connect(_on_build_finished)
	_ribbon_script = load("res://ribbon_layer.gd")
	_ground_script = load("res://ground_layer.gd")
	# start menu, offering the event used last time (else the newest one built)
	var last: String = _setting("last_event", "")
	if last == "" or not FileAccess.file_exists(last):
		last = _newest_event()
	ui.show_start_menu(last)

func _newest_event() -> String:
	var dir := ProjectSettings.globalize_path("res://events")
	var newest := ""
	var newest_time := 0
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".json"):
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

	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	add_child(light)

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
	var dir := ProjectSettings.globalize_path("res://events")
	DirAccess.make_dir_recursive_absolute(dir)
	if not FileAccess.file_exists(dir + "/.gdignore"):
		FileAccess.open(dir + "/.gdignore", FileAccess.WRITE)   # keep Godot from importing events
	var stem := replays[0].get_file().get_basename().validate_filename()
	if replays.size() > 1:
		stem += "_and_%d_more" % (replays.size() - 1)
	var out := "%s/%s.json" % [dir, stem]
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
	_dnm_index = DnmModel.index_models(ProjectSettings.globalize_path(AIRCRAFT_DIR))
	_ground_index = _ground_script.index_models()
	_load_thread = Thread.new()
	_load_thread.start(_read_event.bind(path, map_node.field if map_node != null else ""))

# Everything slow happens here, off the main thread: reading the event and its map, building the
# ribbons, and reading the aircraft and ground-object models not read before. `extra` carries
# the results: ribbons, aircraft models, ground models, and each ground object's model path.
func _read_event(path: String, loaded_field: String) -> void:   # loader thread
	var json := JSON.new()
	var err := json.parse(FileAccess.get_file_as_string(path))
	var data = json.data if err == OK else null
	var map_data = null
	var extra := {"strips": {}, "aircraft": {}, "ground": {}, "ground_paths": {}}
	if typeof(data) == TYPE_DICTIONARY and data.has("entities"):
		if data.get("field", "") != loaded_field:
			var map_path := map_path_for(data)
			if FileAccess.file_exists(map_path):
				var mj := JSON.new()
				if mj.parse(FileAccess.get_file_as_string(map_path)) == OK:
					map_data = mj.data
		extra["strips"] = _ribbon_script.build_arrays(data["entities"])
		# models not read yet: [path, ground object?, result], read on all cores at once
		var jobs := []
		var queued := {}
		for id in data["entities"]:
			var model_path = _dnm_index.get(str(data["entities"][id].get("aircraft", "")).to_upper())
			if model_path != null and not _dnm_models.has(model_path) and not queued.has(model_path):
				queued[model_path] = true
				jobs.append([model_path, false, {}])
		for g in data.get("ground_objects", []):
			var model_path: String = _ground_script.model_path(g, _ground_index)
			if model_path == "":
				continue
			extra["ground_paths"][int(g["index"])] = model_path
			if not _ground_meshes.has(model_path) and not queued.has(model_path + "|g"):
				queued[model_path + "|g"] = true
				jobs.append([model_path, true, {}])
		if jobs.size() > 0:
			var task := WorkerThreadPool.add_group_task(
				func(i): jobs[i][2]["model"] = DnmModel.load_or_parse(jobs[i][0], jobs[i][1]), jobs.size())
			WorkerThreadPool.wait_for_group_task_completion(task)
		for job in jobs:
			extra["ground" if job[1] else "aircraft"][job[0]] = job[2]["model"]
	_event_read.call_deferred(path, data, json.get_error_message(), map_data, extra)

func _event_read(path: String, data, error_text: String, map_data, extra: Dictionary) -> void:
	_load_thread.wait_to_finish()
	_load_thread = null
	for model_path in extra["aircraft"]:
		_dnm_models[model_path] = DnmModel.build(extra["aircraft"][model_path])
	for model_path in extra["ground"]:
		_ground_meshes[model_path] = DnmModel.build(extra["ground"][model_path])["groups"][0]["mesh"]
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
	combat.setup(data)
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
	return ProjectSettings.globalize_path("res://maps/" + name)

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
	if event_root != null:
		event_root.queue_free()
	event_root = null
	combat = null
	ribbons = null
	grounds = null
	event_data = null
	active_aircraft.clear()
	aircraft_models.clear()
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
	playing = on and event_data != null
	if playing:
		play_direction = 1
		if replay_time >= t_max:
			seek(t_min)

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
	if playing:
		replay_time += delta * playback_speed * play_direction
		if replay_time >= t_max or replay_time <= t_min:
			replay_time = clampf(replay_time, t_min, t_max)
			playing = false

	var positions := {}          # aircraft in the air now: id -> position (for missile tethers)
	var vector_items := []       # [position, velocity, nose direction], drawn once the camera has moved
	_tag_clock += delta
	var tag_now: bool = _tag_clock >= TAG_INTERVAL and view["tags"]
	if tag_now:
		_tag_clock = 0.0
	var size: float = view["aircraft_scale"]
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

			marker.position = ys_position(f1).lerp(ys_position(f2), weight)
			# Both keyframes must go through the same conversion, or the
			# slerp swings between two different attitudes every frame.
			var attitude: Basis = ys_basis(f1).slerp(ys_basis(f2), weight)
			var model: Node3D = aircraft_models[air_id]
			model.basis = attitude.scaled(Vector3(size, size, size))
			if model.has_meta("dnm"):            # gear (0..255 up..down) and afterburner (flag bit 1)
				DnmModel.pose(model, f1["ctrl"][3] / 255.0, (int(f1["ctrl"][8]) & 1) == 1)
			positions[air_id] = marker.position
			var velocity := _velocity(frames, idx)
			if view["vectors"]:
				vector_items.append([marker.position, velocity, -attitude.z])
			if tag_now:
				_update_tag(air_id, marker.position.y, velocity.length())
		else:
			marker.visible = false

	if combat:
		combat.update(replay_time, positions)
	if ribbons:
		ribbons.update(replay_time)
	if grounds:
		grounds.update(replay_time)

	_update_camera(delta)
	_draw_vectors(vector_items, size)
	ui.refresh(replay_time, playing, playback_speed, play_direction)
	ui.set_info(_info_text())

func _update_camera(delta):
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
		if Input.is_key_pressed(KEY_W): dir -= camera.global_transform.basis.z
		if Input.is_key_pressed(KEY_S): dir += camera.global_transform.basis.z
		if Input.is_key_pressed(KEY_A): dir -= camera.global_transform.basis.x
		if Input.is_key_pressed(KEY_D): dir += camera.global_transform.basis.x
		if Input.is_key_pressed(KEY_E): dir += Vector3.UP
		if Input.is_key_pressed(KEY_Q): dir += Vector3.DOWN

		var current_speed = move_speed
		if Input.is_key_pressed(KEY_SHIFT):
			current_speed *= 10.0

		camera.position += dir.normalized() * current_speed * delta

# Jump the replay clock to time t, forwards or backwards. Every aircraft is put
# back on the right frame (_process only ever steps frames forwards, so after a
# jump back the others would otherwise sit at future positions).
func seek(t):
	replay_time = clamp(t, t_min, t_max)
	for air_id in telemetry_data:
		current_frame_indices[air_id] = frame_index_at(telemetry_data[air_id], replay_time)

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
	# size of one screen pixel 1 m in front of the camera (window height in real pixels: the UI's
	# stretch mode gives the viewport rect in scaled units)
	var pixel := 2.0 * tan(deg_to_rad(camera.fov) * 0.5) / maxf(get_window().size.y, 1.0)
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
		var side := dir.cross(cam - tip)             # arrow head flat towards the camera
		side = side.normalized() * length * 0.05 if side.length_squared() > 1e-9 else Vector3.ZERO
		var back := tip - dir * length * 0.12
		_strip(verts, cols, p, tip, VECTOR_COLOR, cam, half)
		_strip(verts, cols, tip, back + side, VECTOR_COLOR, cam, half)
		_strip(verts, cols, tip, back - side, VECTOR_COLOR, cam, half)
		_strip(verts, cols, p, p + it[2].normalized() * length, NOSE_COLOR, cam, half)
	if verts.is_empty():
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	vectors.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

# A line from a to b as two triangles facing the camera; each end as wide as `half` times its
# distance from the camera (so the same number of pixels everywhere).
static func _strip(verts: PackedVector3Array, cols: PackedColorArray, a: Vector3, b: Vector3, c: Color,
		cam: Vector3, half: float) -> void:
	var d := b - a
	if d.length_squared() < 1e-6:
		return
	var sa := d.cross(cam - a)
	var sb := d.cross(cam - b)
	if sa.length_squared() < 1e-12 or sb.length_squared() < 1e-12:
		return
	sa = sa.normalized() * half * a.distance_to(cam)
	sb = sb.normalized() * half * b.distance_to(cam)
	for v in [a - sa, a + sa, b + sb, a - sa, b + sb, b - sb]:
		verts.append(v)
		cols.append(c)

# Name tag: pilot, aircraft, then altitude (ft) and true airspeed (kt) from the track.
func _update_tag(id: String, alt_m: float, speed_ms: float) -> void:
	var e = event_data["entities"][id]
	var text := "%s\n%s\n%s ft   %d kt" % [e["player"], Fmt.short_type(e["aircraft"]),
		Fmt.thousands(int(round(alt_m * YsAir.M_TO_FT))), int(round(speed_ms * YsAir.MS_TO_KT))]
	var tag: Label3D = aircraft_tags[id]
	if tag.text != text:
		tag.text = text

# --- VIEW SETTINGS (View tab) ---

func _on_view_changed(key: String, value) -> void:
	view[key] = value
	_set_setting("view_" + key, value)
	if key == "blocky":
		_rebuild_models()
	_apply_view()

func _apply_view() -> void:
	for id in aircraft_tags:
		aircraft_tags[id].pixel_size = TAG_PIXEL * view["text_scale"]
		aircraft_tags[id].visible = view["tags"]
	vector_node.visible = view["vectors"]
	if combat:
		combat.set_view(view)
	if ribbons:
		ribbons.set_view(view["ribbons"], view["trail_seconds"], view["aircraft_scale"], view["smoke"])
	if grounds:
		grounds.visible = view["ground"]
		grounds.show_clouds(view["clouds"])

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

func _in_air_now() -> Array:
	return order.filter(func(id): return active_aircraft[id].visible)

func _info_text() -> String:
	if event_data == null:
		return ""
	var hint := "Zoom %d m  |  Tab: next aircraft  |  Esc: free camera  |  click an aircraft to follow it" % cam_distance
	if tracked_id == "":
		return "Free camera (WASD, E/Q, Shift)  |  Tab or click an aircraft to follow it"
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
		return "%s\nnot in the air yet: starts at %s\n%s" % [text, Fmt.clock(frames[0]["t"]), hint]
	if replay_time > frames[-1]["t"]:
		return "%s\ngone since %s\n%s" % [text, Fmt.clock(frames[-1]["t"]), hint]
	var p0 := _pos_at(frames, replay_time - 0.25)
	var p1 := _pos_at(frames, replay_time + 0.25)
	var tas := p0.distance_to(p1) / 0.5
	var alt: float = active_aircraft[tracked_id].position.y
	var f = frames[current_frame_indices[tracked_id]]
	var ctrl = f["ctrl"]
	var state: String = {0: "flying", 1: "on the ground", 2: "STALLED", 3: "gone", 4: "GOING DOWN",
		5: "GOING DOWN", 6: "stopped", 7: "overrun"}.get(int(ctrl[0]), "")
	text += "\nIAS %d kt   TAS %d kt   M %.2f   ALT %d ft   G %.1f" % [
		YsAir.ias(tas, alt) * YsAir.MS_TO_KT, tas * YsAir.MS_TO_KT, tas / YsAir.mach_one(alt),
		alt * YsAir.M_TO_FT, f.get("g", 0.0)]
	text += "\nthrottle %d%%%s   gear %s   %s" % [ctrl[10], " + afterburner" if int(ctrl[8]) & 1 else "",
		"down" if int(ctrl[3]) > 127 else "up", state]
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

func _unhandled_input(event):
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_TAB:
				var ids := _in_air_now()
				if ids.size() > 0:
					var i := ids.find(tracked_id)
					follow(ids[posmod(i + (-1 if event.shift_pressed else 1), ids.size())])
			KEY_ESCAPE:
				tracked_id = ""
			KEY_P:
				ui.toggle_panel()
			KEY_SPACE:
				set_playing(not playing)
			KEY_J:
				rewind()
			KEY_K:
				set_playing(false)
			KEY_L:
				fast_forward()
			KEY_COMMA:
				frame_step(-1, event.shift_pressed)
			KEY_PERIOD:
				frame_step(1, event.shift_pressed)
			KEY_LEFT:
				seek(replay_time - (60.0 if event.shift_pressed else 10.0))
			KEY_RIGHT:
				seek(replay_time + (60.0 if event.shift_pressed else 10.0))
			KEY_HOME:
				restart()
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				playback_speed = min(playback_speed * 2.0, 512.0)
				ui.show_speed(playback_speed)
			KEY_MINUS, KEY_KP_SUBTRACT:
				playback_speed = max(playback_speed / 2.0, 0.01)
				ui.show_speed(playback_speed)

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
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

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		cam_rot_y -= event.relative.x * mouse_sensitivity
		cam_rot_x -= event.relative.y * mouse_sensitivity
		cam_rot_x = clamp(cam_rot_x, -1.5, 1.5)

# Click-to-follow: the aircraft closest to the click direction, within about 1.5 degrees.
func _pick(screen_pos: Vector2) -> void:
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
