extends Node
# Cinematic mode (M): the world only, for recording with OBS. Every panel, bar, name tag, line and
# marker is hidden (the mouse pointer too); cameras move like a film crew's; lens controls, camera
# shake, eased slow motion and pauses; and the effects of cinema_fx.gd (smoke, explosions,
# aircraft burning). The replay and the scoring views are untouched: leaving the mode puts them
# back as they were.
#
# Shots (keys 1-9; pressing a shot's key again starts it afresh):
#   1 Chase       behind the aircraft, swinging out a little in turns; H: level horizon (the
#                 aircraft rolls in the picture) or rolling with it. Right-drag: the angle.
#   2 Wingman     beside the aircraft, keeping level: it follows where the aircraft goes, not
#                 how it pitches or rolls.
#   3 Flyby       parked just off the aircraft's path ahead (the replay knows where it will be);
#                 it roars past and the camera whips round after it. The next one is set up once
#                 it has gone. Right-drag: which side and how high.
#   4 Ground      stays where the camera was when 4 was pressed (fly there with the drone first;
#                 on a moving ship it rides along) and pans after the aircraft like someone with a
#                 long lens: the zoom keeps the aircraft the same size in the picture (wheel: how
#                 big). Right-drag: off-centre framing.
#   5 Orbit       circles the aircraft (View tab: how fast; it keeps circling when paused).
#   6 Weapon      rides behind the next missile or bomb the aircraft fires, to the end, stays
#                 there a moment, then goes back to the chase.
#   7 Lock-on     over the aircraft's shoulder with its target in the picture (the target of its
#                 missile in flight, else the enemy nearest ahead; R: the next one).
#   8 Crane       glides through the points set with K (2 to 6 of them), easing in and out, over
#                 the View tab's "Crane move" seconds. Points set while following an aircraft move
#                 with it and the camera keeps it in the picture; set on the free camera, they stay
#                 put and the camera turns as it did at each point. K after a move: a new path.
#   9 Drone       a free camera with weight: WASD, E/Q, Shift = fast, right-drag to look, wheel:
#                 speed.
# Every shot: wheel = closer / further, Ctrl+wheel = zoom (field of view), Alt+wheel = background
# blur (depth of field, focused on the aircraft), hold Z = snap zoom, hold X = slow motion (eases
# in and out), Space = pause (eases to a stop; the camera can still move: orbit, crane, drone),
# Backspace = retake (back to where Play was last pressed, the shot starting afresh), F11 = full
# screen, F1 = the key list, M or Esc = leave. Tab picks the aircraft.
#
# Shake comes from what is happening, times the View tab's "Camera shake": the G the aircraft
# pulls (cameras riding with it), aircraft rushing past the camera, explosions nearby. It runs on
# the replay's clock, so it slows down with slow motion and stops when paused.
#
# Time: the camera eases along with the replay's clock (a follow camera lags the same in slow
# motion as at full speed); mouse moves, zooms and the orbit / crane / drone run on the real clock.

const Main = preload("res://node_3d.gd")
const FxScript = preload("res://cinema_fx.gd")
enum Shot {CHASE = 1, WINGMAN, FLYBY, GROUND, ORBIT, WEAPON, LOCK_ON, CRANE, DRONE}
const SHOT_NAMES = {Shot.CHASE: "Chase", Shot.WINGMAN: "Wingman", Shot.FLYBY: "Flyby",
	Shot.GROUND: "Ground camera", Shot.ORBIT: "Orbit", Shot.WEAPON: "Weapon camera",
	Shot.LOCK_ON: "Lock-on", Shot.CRANE: "Crane", Shot.DRONE: "Drone"}
# the wheel's setting per shot: [start, least, most]
const REACH = {
	Shot.CHASE: [26.0, 5.0, 3000.0],         # metres behind
	Shot.WINGMAN: [40.0, 6.0, 3000.0],       # metres to the side
	Shot.FLYBY: [25.0, 4.0, 1500.0],         # metres from the flight path
	Shot.GROUND: [0.3, 0.02, 0.9],           # how much of the picture's height the aircraft fills
	Shot.ORBIT: [45.0, 6.0, 5000.0],         # metres away
	Shot.WEAPON: [8.0, 2.0, 500.0],          # metres behind the weapon
	Shot.LOCK_ON: [32.0, 6.0, 3000.0],       # metres behind the shooter
	Shot.CRANE: [1.0, 1.0, 1.0],
	Shot.DRONE: [80.0, 2.0, 3000.0]}         # metres a second
const FOV = 55.0                 # degrees, top to bottom of the picture
const FOV_MIN = 4.0
const FOV_MAX = 110.0
const SNAP_ZOOM = 3.0            # hold Z: this much closer
const FLYBY_LEAD = 2.5           # replay seconds from setting up a flyby to the aircraft passing
const WEAPON_HOLD = 3.0          # replay seconds the weapon camera stays where the weapon ended
const AIRCRAFT_SIZE = 16.0       # metres: an aircraft's length, for the ground camera's zoom
const LOCK_RANGE = 30000.0       # lock-on: targets within this distance
const CRANE_POINTS = 6
const SHAKE_DEG = 1.4            # biggest shake at full strength
const RUMBLE_RANGE = 250.0       # aircraft rushing past closer than this shake the camera
const BLAST_RANGE = 900.0        # explosions closer than this shake the camera
const GROUND_CLEARANCE = 1.7     # metres: the lowest a camera goes above the ground

var main                         # node_3d.gd
var on := false
var shot: int = Shot.CHASE
var rate := 1.0                  # how fast the replay's clock runs now (slow motion, pauses)
var level := true                # chase: the horizon stays level (H: rolls with the aircraft)
var fov := FOV
var blur := 0.0                  # depth of field, 0 (none) to 1
var reach := {}                  # shot -> the wheel's setting
var aim := {}                    # shot -> Vector2 from right-drag (x: round, y: up / down)
var fx                           # cinema_fx.gd, made the first time the mode is used for an event
var base := Transform3D()        # the camera before the shake

var _reach_s := {}               # the same, eased (the wheel moves smoothly)
var _aim_s := {}
var _cut := true                 # the next frame goes straight to the shot (no easing)
var _subject_id := ""
var _q := Quaternion.IDENTITY    # chase (rolling): the aircraft's attitude, eased
var _dir := Vector3.FORWARD      # eased direction: flight path, weapon, towards the target
var _up := Vector3.UP            # up of the last frame (looking straight up or down)
var _yaw := 0.0                  # eased heading
var _rel := Vector3.ZERO         # eased offset from the aircraft (wingman)
var _look := Vector3.FORWARD     # eased look direction (flyby, ground camera)
var _spot := Vector3.ZERO        # where the flyby / ground camera stands
var _spot_t := -INF              # replay time the flyby camera was set up
var _deck := -1                  # ground camera: the ground object (ship) it stands on, -1 none
var _deck_local := Vector3.ZERO
var _auto_fov := FOV
var _zoom := 0.0                 # snap zoom, 0..1
var _orbit := 0.0
var _weapon = null               # weapon camera: the weapon followed (combat_layer's dictionary)
var _weapon_pos := Vector3.ZERO  # where it is (or ended)
var _target := ""                # lock-on target
var _crane := []                 # [{"pos", "basis", "id", "rel"}]
var _crane_clock := 0.0
var _crane_played := false
var _drone_pos := Vector3.ZERO
var _drone_vel := Vector3.ZERO
var _drone_yaw := 0.0
var _drone_pitch := 0.0
var _drone_yaw_to := 0.0
var _drone_pitch_to := 0.0
var _trauma := 0.0               # explosions: shake that dies away
var _shake_t := 0.0
var _noise := FastNoiseLite.new()
var _last_t := 0.0               # replay time last frame
var _last_pos := Vector3.ZERO    # camera last frame (its speed, for aircraft rushing past)
var _take_t := 0.0               # Retake: where Play was last pressed
var _take_cam := Transform3D()
var _take_orbit := 0.0
var _attrs := CameraAttributesPractical.new()
var _overlay: CanvasLayer
var _hint: Label
var _help: PanelContainer
var _help_text: Label
var _help_text2: Label
var _hint_clock := 0.0

func _ready() -> void:
	for s in REACH:
		reach[s] = REACH[s][0]
		_reach_s[s] = REACH[s][0]
		aim[s] = Vector2.ZERO
		_aim_s[s] = Vector2.ZERO
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_overlay = CanvasLayer.new()
	_overlay.layer = 20
	_overlay.visible = false
	add_child(_overlay)
	_hint = Label.new()
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.offset_top = 40
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.add_theme_font_size_override("font_size", 22)
	_hint.add_theme_constant_override("outline_size", 8)
	_hint.add_theme_color_override("font_outline_color", Color.BLACK)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_hint)
	_help = PanelContainer.new()
	_help.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_help.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_help.grow_vertical = Control.GROW_DIRECTION_BOTH
	_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help.visible = false
	_overlay.add_child(_help)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	_help.add_child(margin)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 40)
	margin.add_child(cols)
	_help_text = Label.new()
	_help_text.add_theme_font_size_override("font_size", 16)
	_help_text.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cols.add_child(_help_text)
	_help_text2 = Label.new()
	_help_text2.add_theme_font_size_override("font_size", 16)
	_help_text2.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cols.add_child(_help_text2)

# --- on / off (node_3d.gd set_cinema) ---

func enter() -> void:
	on = true
	_cut = true
	rate = 1.0 if main.playing else 0.0
	base = main.camera.global_transform
	_last_pos = base.origin
	_last_t = main.replay_time
	_take_t = main.replay_time
	_take_cam = base
	if main.event_root != null and fx == null:
		fx = FxScript.new()
		main.event_root.add_child(fx)
		fx.setup(main.event_data, main.combat, main.map_node)
	if fx != null:
		fx.visible = true
	if shot == Shot.DRONE or main.tracked_id == "":
		_start_drone(base)
		if main.tracked_id == "":
			shot = Shot.DRONE
	elif shot == Shot.GROUND:
		_park(base.origin)
	main.camera.attributes = _attrs
	main.camera.near = 0.1
	Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
	_overlay.visible = true
	_help.visible = false
	_show_hint("Cinematic mode   |   1-9: Shots   |   %s: Keys   |   %s or %s: Back" % [
		main.keys.short_name("help"), main.keys.short_name("cinema"), main.keys.short_name("free")], 4.0)

func leave() -> void:
	on = false
	if fx != null:
		fx.visible = false
	main.camera.attributes = null
	main.camera.fov = 75.0
	main.camera.near = 0.05
	main.camera.global_transform = base
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_overlay.visible = false

# The event is being unloaded (its effects go with it).
func event_cleared() -> void:
	fx = null
	_weapon = null
	_target = ""
	_crane.clear()
	_deck = -1

# A jump in the replay (seek): the camera goes straight to its shot; a flyby is set up afresh.
func cut() -> void:
	_cut = true
	_spot_t = -INF
	_last_t = main.replay_time

# Playing started: Retake comes back here.
func note_play() -> void:
	_take_t = main.replay_time
	_take_cam = base
	_take_orbit = _orbit

# How fast the replay's clock runs now: eases towards full speed, towards the slow motion speed
# while the slow motion key is held, and towards a stop when paused.
func time_rate(delta: float, playing: bool) -> float:
	var want := 0.0
	if playing:
		want = float(main.view["cine_slow"]) if main.keys.held("slow_motion") else 1.0
	rate = lerpf(rate, want, _k(4.0, delta))
	if absf(rate - want) < 0.003:
		rate = want
	return rate

func stop_now() -> void:
	rate = 0.0

# --- keys and mouse ---

# A key of the cinematic mode; false if the action isn't one.
func key(action: String, _shift: bool) -> bool:
	if action.begins_with("shot_"):
		set_shot(int(action.substr(5)))
		return true
	match action:
		"crane_point":
			add_crane_point()
		"retake":
			retake()
		"horizon":
			level = not level
			_cut = true
		"target":
			_next_target()
		"help":
			_help.visible = not _help.visible
			if _help.visible:
				var lists := _key_lists()
				_help_text.text = lists[0]
				_help_text2.text = lists[1]
		"free":
			main.set_cinema(false)
		_:
			return false
	return true

func set_shot(n: int) -> void:
	if n < Shot.CHASE or n > Shot.DRONE:
		return
	var again := n == shot
	var from := base
	shot = n
	match n:
		Shot.FLYBY:
			_spot_t = -INF
		Shot.GROUND:
			if not again:
				_park(from.origin)
		Shot.WEAPON:
			_weapon = null
		Shot.CRANE:
			_crane_clock = 0.0
			if _crane.is_empty():            # nothing to glide through: a drone where the camera is
				_start_drone(from)
			if _crane.size() < 2:
				_show_hint("Crane: set 2 to %d points with %s first (any shot, or the drone)" % [
					CRANE_POINTS, main.keys.short_name("crane_point")], 3.0)
		Shot.DRONE:
			if not again:
				_start_drone(from)
	_cut = true

func retake() -> void:
	var cam := _take_cam
	main.seek(_take_t)
	main.set_playing(true)
	rate = float(main.view["cine_slow"]) if main.keys.held("slow_motion") else 1.0
	_crane_clock = 0.0
	_orbit = _take_orbit
	_weapon = null
	if shot == Shot.DRONE:
		_start_drone(cam)
	_take_cam = cam
	_cut = true

func add_crane_point() -> void:
	if _crane_played:
		_crane.clear()
		_crane_played = false
	if _crane.size() >= CRANE_POINTS:
		_crane.pop_front()
	var point := {"pos": base.origin, "basis": base.basis.orthonormalized(), "id": "", "rel": Vector3.ZERO}
	var s := _subject()
	if not s.is_empty():
		point["id"] = s["id"]
		point["rel"] = Basis.from_euler(Vector3(0.0, _heading(s), 0.0)).inverse() * (base.origin - s["pos"])
	_crane.append(point)
	_show_hint("Crane point %d  -  %s: Play the move" % [_crane.size(), main.keys.short_name("shot_8")], 1.5)

# Mouse in the cinematic mode (node_3d.gd passes them on): wheel, Ctrl+wheel, Alt+wheel, right-drag.
func mouse(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		var up: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			if event.ctrl_pressed:
				fov = clampf(fov * (1.0 / 1.1 if up else 1.1), FOV_MIN, FOV_MAX)
			elif event.alt_pressed:
				blur = clampf(blur + (0.1 if up else -0.1), 0.0, 1.0)
			elif shot == Shot.GROUND:        # how big the aircraft is in the picture
				reach[shot] = clampf(reach[shot] * (1.15 if up else 1.0 / 1.15), REACH[shot][1], REACH[shot][2])
			elif shot == Shot.DRONE:         # speed
				reach[shot] = clampf(reach[shot] * (1.25 if up else 1.0 / 1.25), REACH[shot][1], REACH[shot][2])
			else:                            # distance
				reach[shot] = clampf(reach[shot] * (1.0 / 1.15 if up else 1.15), REACH[shot][1], REACH[shot][2])
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if event.pressed else Input.MOUSE_MODE_HIDDEN
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var d: Vector2 = event.relative * main.mouse_sensitivity
		if shot == Shot.DRONE or (shot == Shot.CRANE and _crane.is_empty()):
			_drone_yaw_to -= d.x
			_drone_pitch_to = clampf(_drone_pitch_to - d.y, -1.5, 1.5)
		else:
			var a: Vector2 = aim[shot] - d
			aim[shot] = Vector2(a.x, clampf(a.y, -1.4, 1.4))

# --- every frame ---

# Moves the camera (after the aircraft have moved) and the effects. delta: real seconds.
func update(delta: float) -> void:
	var t: float = main.replay_time
	var dts := absf(t - _last_t)                     # replay seconds since last frame
	if dts > 1.0:
		_cut = true
		dts = 0.0
	var s := _subject()
	if s.get("id", _subject_id) != _subject_id:
		_subject_id = s.get("id", _subject_id)
		_cut = true
		_target = ""
		_weapon = null
	for k in reach:
		_reach_s[k] = reach[k] if _cut else lerpf(_reach_s[k], reach[k], _k(8.0, delta))
		_aim_s[k] = aim[k] if _cut else _aim_s[k].lerp(aim[k], _k(12.0, delta))
	var focus := -1.0                                 # metres to what's in focus
	match shot:
		Shot.CHASE:
			if not s.is_empty():
				base = _chase(s, dts)
		Shot.WINGMAN:
			if not s.is_empty():
				base = _wingman(s, dts)
		Shot.FLYBY:
			if not s.is_empty():
				base = _flyby(s, dts)
		Shot.GROUND:
			base = _ground(s, dts)
		Shot.ORBIT:
			_orbit += deg_to_rad(float(main.view["cine_orbit"])) * delta
			if not s.is_empty():
				base = _orbit_shot(s, dts)
		Shot.WEAPON:
			var b = _weapon_shot(s, dts, t)
			if b != null:
				base = b
				focus = base.origin.distance_to(_weapon_pos)
		Shot.LOCK_ON:
			if not s.is_empty():
				base = _lock_on(s, dts)
		Shot.CRANE:
			base = _crane_shot(s, dts, delta)
		Shot.DRONE:
			base = _drone(delta)
	base.origin.y = maxf(base.origin.y, _ground_y(base.origin) + GROUND_CLEARANCE * 0.5)
	if focus < 0.0:
		focus = base.origin.distance_to(s["pos"]) if not s.is_empty() else 300.0
	_lens(delta, focus)
	var cam: Camera3D = main.camera
	cam.global_transform = _shaken(s, dts, t)
	if fx != null:
		fx.update(t, cam.global_position)
	_last_pos = base.origin
	_last_t = t
	_cut = false
	if _hint_clock > 0.0:
		_hint_clock -= delta
		_hint.modulate.a = clampf(_hint_clock / 0.6, 0.0, 1.0)
		if _hint_clock <= 0.0:
			_hint.text = ""

# The aircraft the camera is on, if it is in the air now: {"id", "pos", "basis", "vel"}; {} if not.
func _subject() -> Dictionary:
	var id: String = main.tracked_id
	if id == "" or not main.active_aircraft.has(id) or not main.active_aircraft[id].visible \
			or not main.aircraft_attitude.has(id):
		return {}
	var t: float = main.replay_time
	var v: Vector3 = (main.track_pos(id, t + 0.1) - main.track_pos(id, t - 0.1)) / 0.2
	return {"id": id, "pos": main.active_aircraft[id].position, "basis": main.aircraft_attitude[id], "vel": v}

# --- shots ---

func _chase(s: Dictionary, dts: float) -> Transform3D:
	var d: float = _reach_s[Shot.CHASE]
	var a: Vector2 = _aim_s[Shot.CHASE]
	var frame: Basis
	var up := Vector3.UP
	if level:
		var f := _flight_dir(s)
		_dir = f if _cut else _slerp(_dir, f, _k(3.5, dts))
		frame = _frame_along(_dir)
	else:
		var q: Quaternion = s["basis"].get_rotation_quaternion()
		_q = q if _cut else _q.slerp(q, _k(3.5, dts))
		frame = Basis(_q)
		up = frame.y
	var pos: Vector3 = s["pos"] + frame * (Basis.from_euler(Vector3(-0.12 + a.y, a.x, 0.0)) * Vector3(0.0, 0.0, d))
	return _looking(pos, s["pos"] - frame.z * d * 0.4, up)

func _wingman(s: Dictionary, dts: float) -> Transform3D:
	var d: float = _reach_s[Shot.WINGMAN]
	var a: Vector2 = _aim_s[Shot.WINGMAN]
	_ease_heading(s, dts, 2.5)
	var off := Basis.from_euler(Vector3(-0.06 + a.y, _yaw + PI * 0.5 + a.x, 0.0)) * Vector3(0.0, 0.0, d)
	_rel = off if _cut else _rel.lerp(off, _k(3.0, dts))
	return _looking(s["pos"] + _rel, s["pos"] + _flight_dir(s) * d * 0.15)

func _flyby(s: Dictionary, dts: float) -> Transform3D:
	if _cut or _flyby_due(s):
		_place_flyby(s)
	var to: Vector3 = (s["pos"] - _spot).normalized()
	_look = to if _cut else _slerp(_look, to, _k(9.0, dts))
	return _looking(_spot, _spot + _look)

# A new flyby is due once the aircraft has gone well past, or never came (it turned away).
func _flyby_due(s: Dictionary) -> bool:
	var t: float = main.replay_time
	if t < _spot_t or t > _spot_t + FLYBY_LEAD + 6.0:
		return true
	var d: float = reach[Shot.FLYBY]
	var rel: Vector3 = s["pos"] - _spot
	return rel.dot(s["vel"]) > 0.0 and rel.length() > maxf(25.0 * d, 700.0)

# Where the aircraft will be FLYBY_LEAD seconds from now (the replay knows), the camera that far
# off to one side (right-drag: the other side, higher or lower), above the ground.
func _place_flyby(s: Dictionary) -> void:
	var id: String = s["id"]
	var t: float = main.replay_time + FLYBY_LEAD
	var p: Vector3 = main.track_pos(id, t)
	var v: Vector3 = (main.track_pos(id, t + 0.1) - main.track_pos(id, t - 0.1)) / 0.2
	var f: Vector3 = v.normalized() if v.length() > 5.0 else _flight_dir(s)
	var side := f.cross(Vector3.UP)
	side = side.normalized() if side.length() > 0.1 else Vector3.RIGHT
	var a: Vector2 = aim[Shot.FLYBY]
	if a.x > 0.0:
		side = -side
	var d: float = reach[Shot.FLYBY]
	_spot = p + side * d + Vector3.UP * d * (0.2 - a.y)
	_spot.y = maxf(_spot.y, _ground_y(_spot) + GROUND_CLEARANCE)
	_spot_t = main.replay_time

func _ground(s: Dictionary, dts: float) -> Transform3D:
	var pos := _deck_spot()
	if s.is_empty():
		return Transform3D(base.basis, pos)
	var to: Vector3 = (s["pos"] - pos).normalized()
	_look = to if _cut else _slerp(_look, to, _k(3.5, dts))
	var t := _looking(pos, pos + _look)
	var a: Vector2 = _aim_s[Shot.GROUND] * (_auto_fov / FOV)
	t.basis = t.basis * Basis.from_euler(Vector3(-a.y * 0.3, -a.x * 0.3, 0.0))
	# long lens: the aircraft stays about the same size in the picture
	var dist: float = maxf(pos.distance_to(s["pos"]), 1.0)
	var want := rad_to_deg(2.0 * atan(AIRCRAFT_SIZE * 0.5 / dist) / float(_reach_s[Shot.GROUND]))
	want = clampf(want, 1.0, fov)
	_auto_fov = want if _cut else lerpf(_auto_fov, want, _k(3.0, dts))
	return t

# The ground camera stands here: where the camera was, at least eye height above the ground; on
# a moving ground object (a ship) within 300 m it rides along.
func _park(p: Vector3) -> void:
	p.y = maxf(p.y, _ground_y(p) + GROUND_CLEARANCE)
	_spot = p
	_deck = -1
	var best := 300.0
	var grounds: Array = main.event_data.get("ground_objects", []) if main.event_data != null else []
	for g in grounds:
		var samples: Array = g.get("samples", [])
		if samples.size() < 2 or Main.ys_position(samples[0]).distance_to(Main.ys_position(samples[-1])) < 30.0:
			continue
		var pose := _ground_pose(samples, main.replay_time)
		var d := Vector2(pose.origin.x - p.x, pose.origin.z - p.z).length()
		if d < best:
			best = d
			_deck = int(g["index"])
			_deck_local = pose.affine_inverse() * p

func _deck_spot() -> Vector3:
	if _deck < 0:
		return _spot
	var samples: Array = main.event_data["ground_objects"][_deck].get("samples", [])
	return _ground_pose(samples, main.replay_time) * _deck_local

static func _ground_pose(samples: Array, t: float) -> Transform3D:
	var i := 0
	while i < samples.size() - 1 and float(samples[i + 1]["t"]) <= t:
		i += 1
	var a := Transform3D(Main.ys_basis(samples[i]), Main.ys_position(samples[i]))
	if i + 1 < samples.size() and t > float(samples[i]["t"]):
		var b := Transform3D(Main.ys_basis(samples[i + 1]), Main.ys_position(samples[i + 1]))
		var w := clampf((t - float(samples[i]["t"])) / maxf(float(samples[i + 1]["t"]) - float(samples[i]["t"]), 0.001), 0.0, 1.0)
		a = a.interpolate_with(b, w)
	return a

func _orbit_shot(s: Dictionary, dts: float) -> Transform3D:
	var d: float = _reach_s[Shot.ORBIT]
	var a: Vector2 = _aim_s[Shot.ORBIT]
	_ease_heading(s, dts, 2.0)
	var off := Basis.from_euler(Vector3(-0.22 + a.y, _yaw + _orbit + a.x, 0.0)) * Vector3(0.0, 0.0, d)
	return _looking(s["pos"] + off, s["pos"])

# Behind the weapon the aircraft fired last (still flying), looking the way it flies; after it
# ends, a moment looking at where it ended; with none, the chase.
func _weapon_shot(s: Dictionary, dts: float, t: float):
	var w = _weapon if _weapon != null and t >= float(_weapon["t"]) and t <= float(_weapon["end"]["t"]) else null
	if w == null and not s.is_empty():
		w = _newest_weapon(s["id"], t)
	if w != null:
		if w != _weapon:
			_weapon = w
			_cut = true
		var head: Array = main.combat.weapon_head(w, t)
		_weapon_pos = head[0]
		_dir = head[1] if _cut else _slerp(_dir, head[1], _k(5.0, dts))
		var d: float = _reach_s[Shot.WEAPON]
		var a: Vector2 = _aim_s[Shot.WEAPON]
		var frame := _frame_along(_dir)
		var pos: Vector3 = _weapon_pos + frame * (Basis.from_euler(Vector3(-0.25 + a.y, a.x, 0.0)) * Vector3(0.0, 0.0, d))
		return _looking(pos, _weapon_pos + _dir * d * 2.5)
	if _weapon != null and t > float(_weapon["end"]["t"]) and t < float(_weapon["end"]["t"]) + WEAPON_HOLD:
		var to := (_weapon_pos - base.origin).normalized()
		_look = to if _cut else _slerp(_look, to, _k(4.0, dts))
		return _looking(base.origin, base.origin + _look)
	if _weapon != null:
		_weapon = null
		_cut = true
	if s.is_empty():
		return null
	return _chase(s, dts)

func _newest_weapon(id: String, t: float):
	var combat = main.combat
	if combat == null:
		return null
	var i: int = combat.path_t0.bsearch(t, false) - 1
	while i >= 0 and float(combat.path_t0[i]) >= t - 90.0:
		var w: Dictionary = combat.path_weapons[i]
		i -= 1
		if w["name"] in ["FLARE", "FUELTANK"] or t > float(w["end"]["t"]):
			continue
		var owner = w.get("owner_ref")
		if owner != null and owner["kind"] == "aircraft" and str(int(owner["id"])) == id:
			return w
	return null

func _lock_on(s: Dictionary, dts: float) -> Transform3D:
	var tg := _pick_target(s)
	if tg == "":
		return _chase(s, dts)
	var target: Vector3 = main.active_aircraft[tg].position
	var to: Vector3 = (target - s["pos"]).normalized()
	_dir = to if _cut else _slerp(_dir, to, _k(4.0, dts))
	var d: float = _reach_s[Shot.LOCK_ON]
	var a: Vector2 = _aim_s[Shot.LOCK_ON]
	var frame := _frame_along(_dir)
	var off := frame * (Basis.from_euler(Vector3(-0.26 + a.y, 0.34 + a.x, 0.0)) * Vector3(0.0, 0.0, d))
	_rel = off if _cut else _rel.lerp(off, _k(5.0, dts))
	var pos: Vector3 = s["pos"] + _rel
	return _looking(pos, pos + _dir * 100.0 + (s["pos"] - pos) * 0.35)

# The lock-on target: kept while it is in the air and in range; else the aircraft the subject's
# missile in flight is after, else the enemy nearest ahead.
func _pick_target(s: Dictionary) -> String:
	if _target != "" and _valid_target(s, _target):
		return _target
	_target = ""
	var w = _newest_weapon(s["id"], main.replay_time)
	if w != null:
		var ref = w.get("target_ref")
		if ref != null and ref["kind"] == "aircraft" and _valid_target(s, str(int(ref["id"]))):
			_target = str(int(ref["id"]))
			return _target
	var options := _targets(s)
	if not options.is_empty():
		_target = options[0]
	return _target

func _next_target() -> void:
	var s := _subject()
	if s.is_empty():
		return
	var options := _targets(s)
	if options.is_empty():
		return
	var i := options.find(_target)
	_target = options[(i + 1) % options.size()]
	_cut = true

# Enemy aircraft in the air within range, best first: near and ahead of the subject.
func _targets(s: Dictionary) -> Array:
	var scored := []
	var nose: Vector3 = -s["basis"].z
	for id in main.active_aircraft:
		if id == s["id"] or not _valid_target(s, id):
			continue
		var to: Vector3 = main.active_aircraft[id].position - s["pos"]
		var d := to.length()
		scored.append([d * (2.0 - nose.dot(to / maxf(d, 1.0))), id])
	scored.sort_custom(func(x, y): return x[0] < y[0])
	return scored.map(func(x): return x[1])

func _valid_target(s: Dictionary, id: String) -> bool:
	if id == s["id"] or not main.active_aircraft.has(id) or not main.active_aircraft[id].visible:
		return false
	var mine := int(main.event_data["entities"][s["id"]].get("iff", 0))
	var theirs := int(main.event_data["entities"][id].get("iff", 0))
	if mine == theirs and mine in [1, 4]:
		return false
	return main.active_aircraft[id].position.distance_to(s["pos"]) < LOCK_RANGE

# Through the crane points (a smooth curve, easing in at the start and out at the end).
func _crane_shot(s: Dictionary, dts: float, delta: float) -> Transform3D:
	var n := _crane.size()
	if n == 0:
		return _drone(delta)
	_crane_clock += delta
	var u := clampf(_crane_clock / maxf(float(main.view["cine_crane"]), 0.1), 0.0, 1.0)
	if u >= 1.0:
		_crane_played = true
	var e := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
	var x := e * (n - 1)
	var k := mini(int(x), maxi(n - 2, 0))
	var f := x - k if n > 1 else 0.0
	var moving := not s.is_empty()
	for p in _crane:
		moving = moving and p["id"] == s.get("id", "")
	if moving:
		_ease_heading(s, dts, 2.5)
		var rel := _catmull(_crane.map(func(p): return p["rel"]), k, f)
		var pos: Vector3 = s["pos"] + Basis.from_euler(Vector3(0.0, _yaw, 0.0)) * rel
		return _looking(pos, s["pos"])
	var pos2 := _catmull(_crane.map(func(p): return p["pos"]), k, f)
	var b: Basis = _crane[k]["basis"] if n == 1 else _crane[k]["basis"].slerp(_crane[k + 1]["basis"], f)
	return Transform3D(b, pos2)

func _start_drone(from: Transform3D) -> void:
	_drone_pos = from.origin
	_drone_vel = Vector3.ZERO
	var e := from.basis.get_euler()
	_drone_yaw = e.y
	_drone_pitch = e.x
	_drone_yaw_to = e.y
	_drone_pitch_to = e.x

func _drone(delta: float) -> Transform3D:
	var k = main.keys
	var look := Basis.from_euler(Vector3(_drone_pitch, _drone_yaw, 0.0))
	var push := Vector3.ZERO
	if k.held("move_forward"): push -= look.z
	if k.held("move_back"): push += look.z
	if k.held("move_left"): push -= look.x
	if k.held("move_right"): push += look.x
	if k.held("move_up"): push += Vector3.UP
	if k.held("move_down"): push += Vector3.DOWN
	var speed: float = reach[Shot.DRONE] * (5.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	_drone_vel = _drone_vel.lerp(push.normalized() * speed, _k(2.5, delta))
	_drone_pos += _drone_vel * delta
	_drone_pos.y = maxf(_drone_pos.y, _ground_y(_drone_pos) + GROUND_CLEARANCE * 0.5)
	_drone_yaw = lerp_angle(_drone_yaw, _drone_yaw_to, _k(10.0, delta))
	_drone_pitch = lerpf(_drone_pitch, _drone_pitch_to, _k(10.0, delta))
	return Transform3D(Basis.from_euler(Vector3(_drone_pitch, _drone_yaw, 0.0)), _drone_pos)

# --- lens and shake ---

func _lens(delta: float, focus: float) -> void:
	_zoom = lerpf(_zoom, 1.0 if main.keys.held("snap_zoom") else 0.0, _k(14.0, delta))
	var f := _auto_fov if shot == Shot.GROUND else fov
	main.camera.fov = clampf(f / (1.0 + (SNAP_ZOOM - 1.0) * _zoom), 1.0, FOV_MAX)
	var on_blur := blur > 0.01
	_attrs.dof_blur_far_enabled = on_blur
	_attrs.dof_blur_near_enabled = on_blur
	if on_blur:
		focus = maxf(focus, 1.0)
		_attrs.dof_blur_far_distance = focus * 1.25 + 4.0
		_attrs.dof_blur_far_transition = focus * 1.5 + 30.0
		_attrs.dof_blur_near_distance = focus * 0.6
		_attrs.dof_blur_near_transition = focus * 0.45
		_attrs.dof_blur_amount = blur * 0.22

# The camera with its shake: small turns (and a little movement) following smooth noise, as
# strong as the strongest cause now.
func _shaken(s: Dictionary, dts: float, t: float) -> Transform3D:
	var strength: float = main.view["cine_shake"]
	if strength <= 0.0:
		return base
	_trauma = maxf(_trauma - dts * 0.8, 0.0)
	var combat = main.combat
	if combat != null and t > _last_t:           # explosions since last frame
		var i: int = combat.explosion_t0.bsearch(_last_t, false)
		while i < combat.explosions.size() and float(combat.explosion_t0[i]) <= t:
			var dist: float = combat.explosions[i]["_pos"].distance_to(base.origin)
			if dist < BLAST_RANGE:
				_trauma = minf(_trauma + 0.95 * pow(1.0 - dist / BLAST_RANGE, 2.0), 1.0)
			i += 1
	var floor_ := 0.0
	if not s.is_empty() and shot in [Shot.CHASE, Shot.WINGMAN, Shot.LOCK_ON]:
		var frames: Array = main.telemetry_data[s["id"]]
		var f: Dictionary = frames[main.current_frame_indices[s["id"]]]
		floor_ = clampf((absf(float(f.get("g", 1.0))) - 2.0) / 8.0, 0.0, 1.0) * 0.55
		if (int(f["ctrl"][8]) & 1) == 1:
			floor_ = maxf(floor_, 0.16)
	if dts > 0.0:                                # aircraft rushing past the camera
		var cam_v := (base.origin - _last_pos) / dts
		for id in main.active_aircraft:
			var m: Node3D = main.active_aircraft[id]
			if not m.visible:
				continue
			var dist := m.position.distance_to(base.origin)
			if dist > RUMBLE_RANGE or dist < 0.5:
				continue
			var v: Vector3 = (main.track_pos(id, t + 0.1) - main.track_pos(id, t - 0.1)) / 0.2
			var rush := clampf((v - cam_v).length() / 220.0, 0.0, 1.0)
			floor_ = maxf(floor_, rush * pow(1.0 - dist / RUMBLE_RANGE, 2.0))
	_shake_t += dts
	var amount := strength * pow(clampf(maxf(_trauma, floor_), 0.0, 1.0), 2.0)
	if amount <= 0.0001:
		return base
	var turn := Vector3(_wobble(0), _wobble(1), _wobble(2) * 1.3) * deg_to_rad(SHAKE_DEG) * amount
	var move := Vector3(_wobble(3), _wobble(4), 0.0) * 0.25 * amount
	return Transform3D(base.basis * Basis.from_euler(turn), base.origin + base.basis * move)

func _wobble(axis: int) -> float:
	return _noise.get_noise_2d(_shake_t * 16.0, axis * 37.0) * 0.7 + _noise.get_noise_2d(_shake_t * 3.5, axis * 37.0 + 200.0) * 0.3

# --- helpers ---

# How far to move towards a target this frame: time-constant easing (1 / rate seconds).
static func _k(speed: float, dt: float) -> float:
	return 1.0 - exp(-speed * dt)

static func _slerp(a: Vector3, b: Vector3, w: float) -> Vector3:
	if a.length_squared() < 1e-8 or b.length_squared() < 1e-8:
		return b
	if a.dot(b) < -0.999:                        # opposite: turn through the side
		return b
	return a.slerp(b, w).normalized()

static func _flight_dir(s: Dictionary) -> Vector3:
	var v: Vector3 = s["vel"]
	return v.normalized() if v.length() > 15.0 else -s["basis"].z

static func _heading(s: Dictionary) -> float:
	var f := _flight_dir(s)
	return atan2(-f.x, -f.z)

func _ease_heading(s: Dictionary, dts: float, speed: float) -> void:
	var h := _heading(s)
	_yaw = h if _cut else lerp_angle(_yaw, h, _k(speed, dts))

# A frame looking along dir, without roll (up as near world up as it can be).
func _frame_along(dir: Vector3) -> Basis:
	var up := Vector3.UP if absf(dir.y) < 0.97 else _up
	var b := Basis.looking_at(dir, up)
	_up = b.y
	return b

# The camera at `from` looking at `at`, `up` as near its top as possible (straight up or down:
# the top it had last frame).
func _looking(from: Vector3, at: Vector3, up := Vector3.UP) -> Transform3D:
	var d := at - from
	if d.length_squared() < 1e-6:
		return Transform3D(base.basis, from)
	d = d.normalized()
	if absf(d.dot(up.normalized())) > 0.985:
		up = base.basis.y
		if absf(d.dot(up)) > 0.999:
			up = base.basis.z
	return Transform3D(Basis.looking_at(d, up), from)

func _ground_y(p: Vector3) -> float:
	if main.map_node == null:
		return 0.0
	return float(main.map_node.ground_at(p.x, p.z)[0])

# Catmull-Rom through points (ends held), segment k, fraction f.
static func _catmull(pts: Array, k: int, f: float) -> Vector3:
	var n := pts.size()
	if n == 1:
		return pts[0]
	var p0: Vector3 = pts[maxi(k - 1, 0)]
	var p1: Vector3 = pts[k]
	var p2: Vector3 = pts[mini(k + 1, n - 1)]
	var p3: Vector3 = pts[mini(k + 2, n - 1)]
	var f2 := f * f
	var f3 := f2 * f
	return 0.5 * ((2.0 * p1) + (p2 - p0) * f + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * f2 + (3.0 * p1 - p0 - 3.0 * p2 + p3) * f3)

func _show_hint(text: String, seconds: float) -> void:
	_hint.text = text
	_hint.modulate.a = 1.0
	_hint_clock = seconds

# The key list (F1), in two columns: the replay and camera keys, the cinematic mode's own.
func _key_lists() -> Array:
	var k = main.keys
	var left := ["CINEMATIC MODE  (%s: close this list)" % k.short_name("help"), ""]
	var right := ["", ""]
	for a in k.ACTIONS:
		if a[3] == "cinema":
			right.append("%s  -  %s" % [k.short_name(a[0]), a[1]])
		elif a[3] == "both" and a[0] not in ["next_kill", "next_check"]:
			left.append("%s  -  %s" % [k.short_name(a[0]), a[1]])
	right.append("")
	right.append("Wheel  -  Closer / further (Ground camera: how big;")
	right.append("            Drone: speed)")
	right.append("Ctrl+Wheel  -  Zoom")
	right.append("Alt+Wheel  -  Background blur")
	right.append("Right-drag  -  The camera's angle")
	left.append("")
	left.append("View tab: Camera shake, Slow motion speed,")
	left.append("Orbit speed, Crane move seconds; Keys...")
	return ["\n".join(left), "\n".join(right)]
