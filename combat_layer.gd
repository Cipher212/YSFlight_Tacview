extends Node3D
# Weapons, explosions and kills, drawn at the replay time.
# node_3d.gd calls setup(data, models) once, set_view(view) when the View settings change and
# update(replay_time, aircraft) every frame (aircraft: id -> position of those in the air now).
#
#   missiles, flares, bombs, fuel tanks: follow the "path" that weapon_sim.py re-flew
#       with YSFlight's own weapon code (the replay only stores launches)
#   guns   : straight line plus gravity until the recorded range is used up
#   rockets, and guided weapons fired without a target (they never steer, e.g. ships'
#   and tanks' guns): straight line, speeding up by 50 m/s^2 to their top speed
#   (all rules are FsWeapon::Move in YSFLIGHT-master/src/core/fsweapon.cpp)
#
# What is drawn: each weapon as its own YSFlight model (the one the shooter's .dat names,
# weapon_models.gd; a plain shape if there is none), tinted towards the shooter's team and
# scaled by the weapon-size setting; flares as bright balls. Each weapon's trail is in the
# shooter's team colour and its style tells the kind: air-to-air missiles a solid line from
# launch, air-to-ground missiles a dashed one, bombs dots (grey dots: a dropped fuel tank),
# rockets a short streak, gun rounds short tracers. A tether goes from each guided missile to its
# target (the one weapon_sim.py found it locked on, else the nearest enemy aircraft), labelled
# with the distance in metres. Markers stay for the View tab's "Markers stay" seconds where each
# weapon ended (ball: bright = hit, dark = missed/burnt out) and where each kill happened (cross).
# Lines are one mesh rebuilt per frame; shapes and markers are MultiMeshes (one draw call each).
#
# The kill feed and kill labels come from KILLCREDIT, i.e. what YSFlight decided. A missile kill
# that the re-flown missile could not reproduce is marked, so scorers know to check it by eye.

const Main = preload("res://node_3d.gd")
const Fmt = preload("res://fmt.gd")
const GRAVITY = 9.807
const TRAIL_LINGER = 4.0     # seconds a missile's smoke trail stays after it ends
const SPARK_TRAIL = 1.0      # seconds of trail behind flares
const BOMB_TRAIL = 3.0       # seconds of dotted trail behind bombs and dropped fuel tanks
const FEED_TIME = 20.0       # seconds a kill stays in the kill feed
const FEED_LINES = 8
const MARK_TIME = 8.0        # seconds a kill's name label stays where the kill happened
const TRACER_LEN = 30.0      # metres of tracer drawn behind each gun round
const ROCKET_LEN = 15.0
const FIREBALL_TIME = 2.0    # seconds an explosion's fireball is shown
const MAX_FIREBALLS = 128
const END_RADIUS = 3.0       # metres, weapon-end marker at weapon size 1
const KILL_ARM = 10.0        # metres, kill cross at weapon size 1
const KILL_PIXEL = 0.0006    # kill label size (times the text size setting)
const TETHER_PIXEL = 0.0005
const TETHER_COLOR = Color(1.0, 0.9, 0.35)
const TETHER_DASHES = 24     # a tether is dashed, so it can't be mistaken for a smoke trail
const LOCK_RANGE = 30000.0   # nearest-enemy tethers only within this distance
const MISSILES = ["AIM9", "AIM9X", "AIM120", "AGM65"]
const AIR_TO_AIR = ["AIM9", "AIM9X", "AIM120"]
const WEAPON_NAMES = {"AIM9": "AIM-9", "AIM9X": "AIM-9X", "AIM120": "AIM-120", "AGM65": "AGM-65",
	"GUN": "GUN", "ROCKET": "ROCKET", "BOMB500": "BOMB", "BOMB250": "BOMB", "BOMB500HD": "BOMB",
	"FUELTANK": "FUEL TANK"}
const FUEL_TANK_COLOR = Color(0.62, 0.62, 0.62)
const FLARE_COLOR = Color(1.0, 0.95, 0.7)
const MODEL_TINT = 0.35      # how far a weapon model's own colours lean towards its team's colour
const MODEL_ROOM = 256       # most of one weapon model drawn at once
enum Shape {MISSILE, BOMB, ROCKET, FLARE}     # the plain shapes; weapon models come after them
const SHAPE_ROOM = [512, 128, 512, 256]
enum Trail {SOLID, DASHED, DOTTED}

var entities = {}
var grounds = []
var wind = Vector3.ZERO

# weapons with a pre-computed path (missiles, flares, bombs, fuel tanks), by launch time
var path_weapons = []
var path_t0 = PackedFloat64Array()
var path_longest = 0.0
# guns and rockets are computed here; packed arrays since there are ~60,000 of them
var shot_t0 = PackedFloat64Array()
var shot_t1 = PackedFloat64Array()
var shot_pos = PackedVector3Array()
var shot_dir = PackedVector3Array()
var shot_v0 = PackedFloat64Array()
var shot_vmax = PackedFloat64Array()
var shot_kind = PackedByteArray()   # 0 gun, 1 rocket, 2 missile fired without a target
var shot_color = PackedColorArray()
var shot_shape = PackedInt32Array()
var shot_shape_color = PackedColorArray()
var shot_longest = 0.0

var explosions = []
var explosion_t0 = PackedFloat64Array()
var kills = []               # {"t", "text", "mark"} by time
var end_marks = []           # [t, position, colour] by time: where weapons ended
var end_times = PackedFloat64Array()
var kill_marks = []          # [t, position, colour] by time
var kill_times = PackedFloat64Array()

var lines: ArrayMesh
var line_material: StandardMaterial3D
var fireballs: MultiMesh
var shapes = []              # MultiMesh per shape: the plain ones (Shape), then one per weapon model
var shape_used = PackedInt32Array()
var ends: MultiMesh
var crosses: MultiMesh
var tether_labels = []
var feed: RichTextLabel
var feed_text = ""
var last_line_vertices = 0   # line vertices drawn last update (for performance checks)

var weapon_scale := 1.0
var text_scale := 1.0
var show_tethers := true
var show_markers := true
var marker_seconds := 30.0
var _end_shown := Vector2i(-1, -1)    # markers now in the MultiMeshes: [first, last + 1)
var _kill_shown := Vector2i(-1, -1)
var _label_ms := 0           # when the tether distances were last written

# models: {"meshes": {model path: Mesh}, "paths": {index in data["weapons"]: model path}}
# (weapon_models.gd picks them; node_3d.gd reads them on its loader thread)
func setup(data, models := {}):
	entities = data["entities"]
	grounds = data["ground_objects"]
	var w3 = data.get("wind", [0, 0, 0])
	wind = Main.ys_vec(w3[0], w3[1], w3[2])
	_build_nodes()

	var meshes: Dictionary = models.get("meshes", {})
	var model_paths: Dictionary = models.get("paths", {})
	var shots = []
	var uses := {}                         # model path -> how many weapons use it
	var weapons: Array = data["weapons"]
	for i in weapons.size():
		var w = weapons[i]
		w["_model"] = model_paths.get(i, "")
		if meshes.get(w["_model"]) == null:
			w["_model"] = ""
		if w.has("path"):
			path_weapons.append(w)
		elif w["name"] == "GUN" or w["name"] == "ROCKET" or w["name"] in MISSILES:
			shots.append(w)
		else:
			continue
		if w["_model"] != "":
			uses[w["_model"]] = uses.get(w["_model"], 0) + 1
	var slot := {}                         # model path -> its MultiMesh in shapes
	for model_path in uses:
		slot[model_path] = shapes.size()
		shapes.append(_multimesh(meshes[model_path], null, mini(uses[model_path], MODEL_ROOM)))
	shape_used.resize(shapes.size())
	path_weapons.sort_custom(func(a, b): return a["t"] < b["t"])
	shots.sort_custom(func(a, b): return a["t"] < b["t"])

	for w in path_weapons:
		var ts = PackedFloat64Array()
		var pts = PackedVector3Array()
		for p in w["path"]:
			ts.append(p[0])
			pts.append(Main.ys_vec(p[1], p[2], p[3]))
		w["_ts"] = ts
		w["_pts"] = pts
		w["_missile"] = w["name"] in MISSILES
		w["_iff"] = _ref_iff(w.get("owner_ref"))
		w["_color"] = _path_color(w)
		w["_trail"] = Trail.SOLID if w["name"] in AIR_TO_AIR or w["name"] == "FLARE" else \
			(Trail.DASHED if w["name"] == "AGM65" else Trail.DOTTED)
		if w["_model"] != "":
			w["_shape"] = slot[w["_model"]]
			w["_shape_color"] = _model_color(w["_iff"])
		elif w["name"] == "FLARE":
			w["_shape"] = Shape.FLARE
			w["_shape_color"] = w["_color"]
		else:
			w["_shape"] = Shape.MISSILE if w["_missile"] else Shape.BOMB
			w["_shape_color"] = _team(w["_iff"])
		path_t0.append(w["t"])
		var shown = w["end"]["t"] - w["t"] + (TRAIL_LINGER if w["_missile"] else 0.0)
		path_longest = max(path_longest, shown)
		if w["name"] != "FLARE" and w["name"] != "FUELTANK" and pts.size() > 0:
			var hit: bool = w["end"].get("reason", "") == "hit"
			end_marks.append([w["end"]["t"], pts[pts.size() - 1], _end_color(w["_iff"], hit)])

	for w in shots:
		var kind = 0 if w["name"] == "GUN" else (1 if w["name"] == "ROCKET" else 2)
		var v0 = float(w["velocity"])
		var vmax = float(w.get("max_speed", v0))
		var flight = _rocket_time(v0, vmax, w["range"]) if kind > 0 else w["range"] / max(v0, 1.0)
		if w.has("end"):                     # weapon_sim.py found where it really ended
			flight = w["end"]["t"] - w["t"]
		var iff = _ref_iff(w.get("owner_ref"))
		var team = _team(iff)
		shot_t0.append(w["t"])
		shot_t1.append(w["t"] + flight)
		shot_pos.append(Main.ys_position(w))
		shot_dir.append(-Main.ys_basis(w).z)
		shot_v0.append(v0)
		shot_vmax.append(vmax)
		shot_kind.append(kind)
		shot_color.append(team.lightened(0.45) if kind == 0 else team.lightened(0.3))
		if w["_model"] != "":
			shot_shape.append(slot[w["_model"]])
			shot_shape_color.append(_model_color(iff))
		else:
			shot_shape.append(Shape.ROCKET if kind == 1 else Shape.MISSILE)
			shot_shape_color.append(team.lightened(0.1))
		shot_longest = max(shot_longest, flight)
		if kind > 0:
			var d = -Main.ys_basis(w).z
			var p_end = Main.ys_position(w) + d * _rocket_dist(v0, vmax, flight) + wind * flight
			end_marks.append([w["t"] + flight, p_end, _end_color(iff, false)])

	explosions = data["explosions"].duplicate()
	explosions.sort_custom(func(a, b): return a["t"] < b["t"])
	for e in explosions:
		explosion_t0.append(e["t"])
		e["_pos"] = Main.ys_vec(e["x"], e["y"], e["z"])

	for k in data["kills"]:
		var victim = _ref_name(k.get("victim_ref"))
		var text = "%s  [color=#%s]%s[/color]  %s ->  [color=#%s]%s[/color]" % [
			_clock(k["t"]),
			Main.iff_color(_ref_iff(k.get("killer_ref"))).lightened(0.35).to_html(false),
			_bb(_ref_name(k.get("killer_ref"))),
			WEAPON_NAMES.get(k["name"], k["name"]),
			Main.iff_color(_ref_iff(k.get("victim_ref"))).lightened(0.35).to_html(false),
			_bb(victim)]
		if k.has("reconstructed") and not k["reconstructed"]:
			text += "  [color=#a0a0a0](missile path not reproduced)[/color]"
		var pos = Main.ys_vec(k["x"], k["y"], k["z"])
		var mark = Label3D.new()
		mark.text = "X  " + victim
		mark.modulate = Color(1.0, 0.3, 0.25)
		mark.outline_modulate = Color(0, 0, 0)
		mark.font_size = 56
		mark.outline_size = 12
		mark.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		mark.fixed_size = true
		mark.pixel_size = KILL_PIXEL
		mark.no_depth_test = true
		mark.render_priority = 10          # drawn over the fireball
		mark.position = pos + Vector3(0, 25, 0)
		mark.visible = false
		add_child(mark)
		kills.append({"t": k["t"], "text": text, "mark": mark})
		kill_marks.append([k["t"], pos, _team(_ref_iff(k.get("killer_ref"))).lightened(0.15)])
	kills.sort_custom(func(a, b): return a["t"] < b["t"])
	end_marks.sort_custom(func(a, b): return a[0] < b[0])
	kill_marks.sort_custom(func(a, b): return a[0] < b[0])
	for m in end_marks:
		end_times.append(m[0])
	for m in kill_marks:
		kill_times.append(m[0])
	ends.instance_count = end_marks.size()
	crosses.instance_count = kill_marks.size()

# Where the live kill feed goes: right-aligned, keeping `right` pixels free on the right
# (for the side panel) and starting `top` pixels down (below the top bar).
func set_feed_box(right: float, top: float) -> void:
	feed.offset_right = -right
	feed.offset_left = -right - 624.0
	feed.offset_top = top

func set_view(view: Dictionary) -> void:
	var redo: bool = view["weapon_scale"] != weapon_scale or view["marker_seconds"] != marker_seconds \
		or view["markers"] != show_markers
	weapon_scale = view["weapon_scale"]
	text_scale = view["text_scale"]
	show_tethers = view["tethers"]
	show_markers = view["markers"]
	marker_seconds = view["marker_seconds"]
	if redo:
		_end_shown = Vector2i(-1, -1)
		_kill_shown = Vector2i(-1, -1)
	for k in kills:
		k["mark"].pixel_size = KILL_PIXEL * text_scale
	for l in tether_labels:
		l.pixel_size = TETHER_PIXEL * text_scale

func update(t: float, aircraft: Dictionary) -> void:
	var pts = PackedVector3Array()
	var cols = PackedColorArray()
	shape_used.fill(0)
	var tethers = []
	_add_path_weapons(t, pts, cols, tethers, aircraft)
	_add_shots(t, pts, cols)
	_add_tethers(pts, cols, tethers)
	last_line_vertices = pts.size()
	lines.clear_surfaces()
	if pts.size() > 0:
		# one call hands Godot every line at once (far faster than vertex-by-vertex)
		var arrays = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = pts
		arrays[Mesh.ARRAY_COLOR] = cols
		lines.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
		lines.surface_set_material(0, line_material)
	for s in shapes.size():
		shapes[s].visible_instance_count = shape_used[s]
	_end_shown = _show_marks(ends, end_marks, end_times, t, END_RADIUS, _end_shown)
	_kill_shown = _show_marks(crosses, kill_marks, kill_times, t, KILL_ARM, _kill_shown)
	_update_fireballs(t)
	_update_kills(t)

# --- drawing ---

func _add_path_weapons(t, pts, cols, tethers, aircraft):
	var i = path_t0.bsearch(t - path_longest)
	while i < path_weapons.size() and path_t0[i] <= t:
		var w = path_weapons[i]
		i += 1
		var end_t = w["end"]["t"]
		if t > end_t + (TRAIL_LINGER if w["_missile"] else 0.0):
			continue
		var ts: PackedFloat64Array = w["_ts"]
		var wp: PackedVector3Array = w["_pts"]
		var col: Color = w["_color"]
		var style: int = w["_trail"]
		# trail: missiles from launch, bombs and fuel tanks the last few seconds, flares the last one
		var from_t = w["t"] if w["_missile"] else t - (SPARK_TRAIL if w["name"] == "FLARE" else BOMB_TRAIL)
		var k0 = max(ts.bsearch(from_t) - 1, 0)
		var k1 = ts.bsearch(t, false) - 1          # last point at or before t
		for k in range(k0, min(k1, wp.size() - 1)):
			_trail_seg(pts, cols, wp[k], wp[k + 1], k, style, col)
		if t <= end_t and k1 >= 0 and k1 < wp.size() - 1:
			var a = (t - ts[k1]) / max(ts[k1 + 1] - ts[k1], 0.001)
			var head = wp[k1].lerp(wp[k1 + 1], a)
			_trail_seg(pts, cols, wp[k1], head, k1, style, col)
			_shape(w["_shape"], head, wp[k1 + 1] - wp[k1], w["_shape_color"])
			if w["_missile"] and show_tethers:
				var target = _target_position(w, t, head, aircraft)
				if target != null:
					tethers.append([head, target, i - 1])

# One piece of a trail, between path points k and k + 1, in the weapon's style: solid, dashed
# (two pieces on, one off) or dotted (the first third of each piece).
func _trail_seg(pts, cols, a: Vector3, b: Vector3, k: int, style: int, c: Color) -> void:
	if style == Trail.DASHED:
		if k % 3 != 2:
			_seg(pts, cols, a, b, c)
	elif style == Trail.DOTTED:
		_seg(pts, cols, a, a.lerp(b, 0.3), c)
	else:
		_seg(pts, cols, a, b, c)

func _add_shots(t, pts, cols):
	var i = shot_t0.bsearch(t - shot_longest)
	while i < shot_t0.size() and shot_t0[i] <= t:
		if t <= shot_t1[i]:
			var tau = t - shot_t0[i]
			var d = shot_dir[i]
			var p: Vector3
			var back: Vector3
			if shot_kind[i] > 0:
				p = shot_pos[i] + d * _rocket_dist(shot_v0[i], shot_vmax[i], tau) + wind * tau
				back = d * ROCKET_LEN
			else:
				p = shot_pos[i] + d * shot_v0[i] * tau + Vector3(0, -0.5 * GRAVITY * tau * tau, 0) + wind * tau
				back = (d * shot_v0[i] + Vector3(0, -GRAVITY * tau, 0)).normalized() * TRACER_LEN * maxf(weapon_scale, 1.0)
			if p.y > 0.0:
				_seg(pts, cols, p - back, p, shot_color[i])
				if shot_kind[i] > 0:
					_shape(shot_shape[i], p, d, shot_shape_color[i])
		i += 1

# Tether lines, with the distance written at the middle of each (text refreshed 10 times a
# second, so the labels are not re-drawn every frame).
func _add_tethers(pts, cols, tethers):
	var now_ms := Time.get_ticks_msec()
	var refresh := now_ms - _label_ms >= 100
	if refresh:
		_label_ms = now_ms
	while tether_labels.size() < tethers.size():
		tether_labels.append(_tether_label())
	for n in tether_labels.size():
		var label: Label3D = tether_labels[n]
		if n >= tethers.size():
			label.visible = false
			continue
		var a: Vector3 = tethers[n][0]
		var b: Vector3 = tethers[n][1]
		for d in TETHER_DASHES:
			_seg(pts, cols, a.lerp(b, float(d) / TETHER_DASHES), a.lerp(b, (d + 0.55) / TETHER_DASHES), TETHER_COLOR)
		label.visible = true
		label.position = (a + b) * 0.5
		if refresh or label.get_meta("weapon", -1) != tethers[n][2]:
			label.set_meta("weapon", tethers[n][2])
			label.text = "%s m" % Fmt.thousands(int(round(a.distance_to(b))))

# Where a missile's target is now: the aircraft or ground object it was locked on, else the
# nearest aircraft of another team within LOCK_RANGE (null if none).
func _target_position(w, t, head: Vector3, aircraft: Dictionary):
	var ref = w.get("target_ref")
	if ref != null:
		if ref["kind"] == "aircraft":
			return aircraft.get(str(int(ref["id"])))
		var samples: Array = grounds[int(ref["index"])].get("samples", [])
		if samples.is_empty():
			return null
		return Main.ys_position(samples[clampi(_sample_at(samples, t), 0, samples.size() - 1)])
	var best = null
	var best_d := LOCK_RANGE
	for id in aircraft:
		if entities[id].get("iff") == w["_iff"]:
			continue
		var d: float = head.distance_to(aircraft[id])
		if d < best_d:
			best_d = d
			best = aircraft[id]
	return best

func _shape(kind: int, pos: Vector3, dir: Vector3, color: Color) -> void:
	var n: int = shape_used[kind]
	var mm: MultiMesh = shapes[kind]
	if n >= mm.instance_count:
		return
	var basis := Basis.from_scale(Vector3.ONE * weapon_scale)
	if dir.length_squared() > 1e-6:
		var f := dir.normalized()
		basis = Basis.looking_at(f, Vector3.BACK if absf(f.y) > 0.999 else Vector3.UP) * basis
	mm.set_instance_transform(n, Transform3D(basis, pos))
	mm.set_instance_color(n, color)
	shape_used[kind] = n + 1

# Shows the markers of the last marker_seconds (marks and times sorted by time); the MultiMesh is
# only rewritten when that set changes. Returns the set now shown, [first, last + 1).
func _show_marks(mm: MultiMesh, marks: Array, times: PackedFloat64Array, t: float, size: float,
		shown: Vector2i) -> Vector2i:
	var now := Vector2i(times.bsearch(t - marker_seconds), times.bsearch(t, false)) if show_markers \
		else Vector2i.ZERO
	if now == shown:
		return shown
	var s := size * weapon_scale
	var n := 0
	for k in range(now.x, now.y):
		mm.set_instance_transform(n, Transform3D(Basis.from_scale(Vector3(s, s, s)), marks[k][1]))
		mm.set_instance_color(n, marks[k][2])
		n += 1
	mm.visible_instance_count = n
	return now

func _update_fireballs(t):
	var n = 0
	var i = explosion_t0.bsearch(t - FIREBALL_TIME)
	while i < explosions.size() and explosion_t0[i] <= t and n < MAX_FIREBALLS:
		var e = explosions[i]
		i += 1
		var tau = t - e["t"]
		var r = lerpf(e["start_radius"], e["radius"], clamp(tau / 0.6, 0.0, 1.0))
		fireballs.set_instance_transform(n, Transform3D(Basis().scaled(Vector3(r, r, r)), e["_pos"]))
		fireballs.set_instance_color(n, Color(1.0, 0.55, 0.15, 0.85 * (1.0 - tau / FIREBALL_TIME)))
		n += 1
	fireballs.visible_instance_count = n

func _update_kills(t):
	var recent = []
	for k in kills:
		var age = t - k["t"]
		k["mark"].visible = age >= 0.0 and age <= MARK_TIME
		if age >= 0.0 and age <= FEED_TIME:
			recent.push_front(k["text"])
	var text = "[right][b]REPLAY  %s[/b]" % _clock(t)
	for line in recent.slice(0, FEED_LINES):
		text += "\n" + line
	text += "[/right]"
	if text != feed_text:
		feed_text = text
		feed.text = text

func _seg(pts, cols, a, b, c):
	pts.append(a)
	pts.append(b)
	cols.append(c)
	cols.append(c)

func _build_nodes():
	line_material = StandardMaterial3D.new()
	line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	line_material.vertex_color_use_as_albedo = true
	lines = ArrayMesh.new()
	var line_node = MeshInstance3D.new()
	line_node.mesh = lines
	add_child(line_node)

	var sphere = SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8
	fireballs = MultiMesh.new()
	fireballs.transform_format = MultiMesh.TRANSFORM_3D
	fireballs.use_colors = true
	fireballs.mesh = sphere
	fireballs.instance_count = MAX_FIREBALLS
	fireballs.visible_instance_count = 0
	var fire_material = StandardMaterial3D.new()
	fire_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fire_material.vertex_color_use_as_albedo = true
	fire_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var fire_node = MultiMeshInstance3D.new()
	fire_node.multimesh = fireballs
	fire_node.material_override = fire_material
	add_child(fire_node)

	# plain weapon shapes (for weapons without a model), long axis along -Z (the weapon's nose),
	# true size at weapon size 1
	var lit := _instance_material(false)
	var to_nose := Transform3D(Basis(Vector3.RIGHT, -PI / 2.0), Vector3.ZERO)   # +Y -> -Z
	var missile := CylinderMesh.new()
	missile.top_radius = 0.04
	missile.bottom_radius = 0.13
	missile.height = 3.2
	missile.radial_segments = 8
	missile.rings = 1
	var bomb := CapsuleMesh.new()
	bomb.radius = 0.22
	bomb.height = 2.2
	bomb.radial_segments = 8
	bomb.rings = 2
	var rocket := CylinderMesh.new()
	rocket.top_radius = 0.03
	rocket.bottom_radius = 0.06
	rocket.height = 1.8
	rocket.radial_segments = 6
	rocket.rings = 1
	var flare := SphereMesh.new()
	flare.radius = 0.5
	flare.height = 1.0
	flare.radial_segments = 8
	flare.rings = 4
	for s in Shape.size():
		var mesh: Mesh = [missile, bomb, rocket, flare][s]
		if s != Shape.FLARE:
			mesh = _turned(mesh, to_nose)
		shapes.append(_multimesh(mesh, _instance_material(true) if s == Shape.FLARE else lit, SHAPE_ROOM[s]))

	# markers: a small ball where a weapon ended, a cross where a kill happened
	var ball := SphereMesh.new()
	ball.radius = 1.0
	ball.height = 2.0
	ball.radial_segments = 6
	ball.rings = 3
	ends = _multimesh(ball, _instance_material(true), 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for axis in [Vector3(1, 0.08, 0.08), Vector3(0.08, 1, 0.08), Vector3(0.08, 0.08, 1)]:
		var bar := BoxMesh.new()
		bar.size = axis * 2.0
		st.append_from(bar, 0, Transform3D.IDENTITY)
	crosses = _multimesh(st.commit(), _instance_material(true), 0)

	var canvas = CanvasLayer.new()
	add_child(canvas)
	feed = RichTextLabel.new()
	feed.bbcode_enabled = true
	feed.fit_content = true
	feed.scroll_active = false
	feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# top right, below the two-line tracking label on the left (which can run long)
	feed.anchor_left = 1.0
	feed.anchor_right = 1.0
	feed.offset_left = -640
	feed.offset_right = -16
	feed.offset_top = 96
	feed.add_theme_font_size_override("normal_font_size", 20)
	feed.add_theme_font_size_override("bold_font_size", 22)
	feed.add_theme_constant_override("outline_size", 6)
	feed.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	canvas.add_child(feed)

# mat null: the mesh's own materials (weapon models)
func _multimesh(mesh: Mesh, mat: Material, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	var node := MultiMeshInstance3D.new()
	node.multimesh = mm
	if mat != null:
		node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return mm

func _instance_material(unshaded: bool) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.vertex_color_use_as_albedo = true      # the MultiMesh instance colour
	if unshaded:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m

static func _turned(mesh: Mesh, tf: Transform3D) -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(mesh, 0, tf)
	return st.commit()

func _tether_label() -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = TETHER_PIXEL * text_scale
	l.font_size = 40
	l.outline_size = 10
	l.modulate = TETHER_COLOR
	l.outline_modulate = Color(0, 0, 0)
	l.no_depth_test = true
	l.render_priority = 9
	l.offset = Vector2(0, 28)                # just above the line
	add_child(l)
	return l

# --- helpers ---

func _path_color(w) -> Color:
	if w["name"] == "FLARE":
		return FLARE_COLOR
	if w["name"] == "FUELTANK":
		return FUEL_TANK_COLOR
	return _team(w["_iff"]).lightened(0.3)

# A weapon model's own colours, leaning towards the shooter's team colour.
static func _model_color(iff) -> Color:
	return Color.WHITE.lerp(_team(iff), MODEL_TINT)

# Team colours from the IFF (Blue 1, Red 4); anything else (pirates, unknown) grey.
static func _team(iff) -> Color:
	return Main.iff_color(int(iff) if iff != null else 0)

static func _end_color(iff, hit: bool) -> Color:
	return _team(iff).lightened(0.25) if hit else _team(iff).darkened(0.45)

static func _sample_at(samples: Array, t: float) -> int:
	var lo := 0
	var hi := samples.size() - 1
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if samples[mid]["t"] <= t:
			lo = mid
		else:
			hi = mid - 1
	return lo

func _ref_iff(ref):
	if ref == null:
		return null
	if ref["kind"] == "aircraft":
		var e = entities.get(str(int(ref["id"])))
		return e["iff"] if e else null
	return grounds[int(ref["index"])]["iff"]

func _ref_name(ref) -> String:
	if ref == null:
		return "?"
	if ref["kind"] == "aircraft":
		var e = entities.get(str(int(ref["id"])))
		return e["player"] if e else "?"
	var g = grounds[int(ref["index"])]
	return g["name"] if g["name"] != "" else g["type"]

# Time for a rocket to fly `dist` metres, speeding up by 50 m/s^2 to vmax.
static func _rocket_time(v0, vmax, dist) -> float:
	if v0 >= vmax:
		return dist / max(v0, 1.0)
	var t_acc = (vmax - v0) / 50.0
	var d_acc = v0 * t_acc + 25.0 * t_acc * t_acc
	if dist <= d_acc:
		return (-v0 + sqrt(v0 * v0 + 100.0 * dist)) / 50.0
	return t_acc + (dist - d_acc) / vmax

# Distance a rocket has flown after tau seconds.
static func _rocket_dist(v0, vmax, tau) -> float:
	if v0 >= vmax:
		return v0 * tau
	var t_acc = (vmax - v0) / 50.0
	if tau <= t_acc:
		return v0 * tau + 25.0 * tau * tau
	return v0 * t_acc + 25.0 * t_acc * t_acc + vmax * (tau - t_acc)

static func _clock(t) -> String:
	var s = int(max(t, 0.0))
	return "%d:%02d" % [int(s / 60.0), s % 60]

# Escape [ and ] so player tags like "[RED]" show up instead of being read as BBCode.
static func _bb(s: String) -> String:
	var out = ""
	for ch in s:
		if ch == "[":
			out += "[lb]"
		elif ch == "]":
			out += "[rb]"
		else:
			out += ch
	return out
