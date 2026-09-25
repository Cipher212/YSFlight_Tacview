extends Node
# Cinematic mode (M): the world only, for recording with OBS. Every panel, bar, name tag, line and
# marker is hidden (the mouse pointer too); cameras move like a film crew's; lens controls, a
# flyby shake, eased slow motion and pauses; and the effects of cinema_fx.gd (smoke, explosions,
# aircraft burning). The replay and the scoring views are untouched: leaving the mode puts them
# back as they were.
#
# Shots (keys 0-9; pressing 3 or 8 again starts it afresh):
#   1 Chase       the chase family; 1 again: the next kind (Shift+1: back):
#                   Chase        behind the aircraft, swinging out a little in turns; H: level
#                                horizon (the aircraft rolls in the picture) or rolling with it.
#                   Chase plane  a camera plane flying formation off the aircraft's tail (behind,
#                                to the right, a little high): it pulls at most 6 G, so it lags
#                                and catches up in hard turns, and it banks as it turns.
#                   Trailing     flies the aircraft's own path a little behind it (wheel: how
#                                far), looking at it; H: banking as the aircraft did there.
#                   Delayed      YSFlight's outside view with camera delay: fixed to the aircraft
#                                as it was 0.8 s before, so it swings round after it in turns.
#                   Outside      YSFlight's F7 outside view: from a direction fixed in the world
#                                (it doesn't turn when the aircraft turns); steer it round.
#   0 Ghost       a camera fixed on the aircraft, turning with it (0 again: the next spot): behind,
#                 wing, front, top, belly, tail, nose. Wheel: nearer / further out.
#   2 Wingman     beside the aircraft, keeping level: it follows where the aircraft goes, not
#                 how it pitches or rolls.
#   3 Flyby       parked just off the aircraft's path ahead (the replay knows where it will be);
#                 it roars past and the camera whips round after it. The next one is set up once
#                 it has gone. Steering: which side and how high.
#   4 Ground      stays where the camera was when 4 was pressed (fly there with the drone first;
#                 on a moving ship it rides along) and pans after the aircraft like someone with a
#                 long lens: the zoom keeps the aircraft the same size in the picture (wheel: how
#                 big). Steering: off-centre framing.
#   5 Orbit       round the aircraft from a direction fixed in the world, like the normal viewer's
#                 follow camera: it turns only when steered (not by itself, not with the
#                 aircraft), for watching calmly and finding the next shot. The mode starts in it,
#                 from where the camera was.
#   6 Weapon      rides behind the next missile or bomb the aircraft fires, to the end, stays
#                 there a moment, then goes back to the chase.
#   7 Lock-on     over the aircraft's shoulder with its target in the picture (the target of its
#                 missile in flight, else the enemy nearest ahead; R: the next one).
#   8 Crane       glides through the points set with K (2 to 6 of them), easing in and out, over
#                 the View tab's "Crane move" seconds ([ ]). Points set while following an
#                 aircraft move with it and the camera keeps it in the picture; set on the free
#                 camera, they stay put and the camera turns as it did at each point. K after a
#                 move: a new path. Helpers, while paused: the path and its numbered points on
#                 screen, a line of keys at the top; U: remove the last point, Delete: all,
#                 V: ready-made moves round the aircraft (sweep, rise, push in, pull out, circle).
#   9 Drone       a free camera with weight: WASD, E/Q, Shift = fast, steering to look, wheel:
#                 speed. With the stick on it flies like YSFlight's ghost view.
# Steering: right-drag turns the camera (round the aircraft, or the look of a free / fixed
# camera). F7 (or the View tab) makes the hidden mouse a stick, as YSFlight's old F7 / F8 view did:
# the further the mouse from the centre, the faster the camera turns (not at all near the middle),
# easing in and out; F8 or the middle button: back to the centre. Turning is as fast on screen at
# any zoom.
# T: the top view, as outside the mode (wheel, right-drag, click to follow); T or a shot key: back.
# B: smooth camera on / off (off: the cameras stick to the aircraft exactly, no easing).
# Every shot: wheel = closer / further, Ctrl+wheel = zoom (field of view), Alt+wheel = background
# blur (depth of field, focused on the aircraft), hold Z = snap zoom, hold X = slow motion (eases
# in and out), Space = pause (eases to a stop; the camera can still move: orbit, crane, drone),
# Backspace = retake (back to where Play was last pressed, the shot starting afresh), F11 = full
# screen, F1 = the key list, G = guides (crane path, names) on / off, M or Esc = leave. Tab picks
# the aircraft.
#
# Shake, only in the flyby (the user: in the other shots it was a nonstop earthquake - replays
# jitter the tracks of aircraft seen through the network, which read as aircraft rushing past
# the camera): aircraft rushing past the flyby camera and explosions near it, times the View tab's
# "Flyby shake". It runs on the replay's clock (slows down with slow motion, stops when paused)
# and is as big on screen at any zoom. The still cameras (flyby, ground) aim at a track smoothed
# more (node_3d.track_aim), so what jitter is left moves the aircraft, not the whole picture.
#
# Time: the camera eases along with the replay's clock (a follow camera lags the same in slow
# motion as at full speed); mouse moves, zooms and the orbit / crane / drone run on the real clock.

const Main = preload("res://node_3d.gd")
const FxScript = preload("res://cinema_fx.gd")
const GuidesScript = preload("res://cinema_guides.gd")
enum Shot {CHASE = 1, WINGMAN, FLYBY, GROUND, ORBIT, WEAPON, LOCK_ON, CRANE, DRONE, GHOST}
const SHOT_NAMES = {Shot.CHASE: "Chase", Shot.WINGMAN: "Wingman", Shot.FLYBY: "Flyby",
	Shot.GROUND: "Ground camera", Shot.ORBIT: "Orbit", Shot.WEAPON: "Weapon camera",
	Shot.LOCK_ON: "Lock-on", Shot.CRANE: "Crane", Shot.DRONE: "Drone", Shot.GHOST: "Ghost camera"}
enum Kind {CHASE, PLANE, TRAILING, DELAYED, OUTSIDE}
const KIND_NAMES = ["Chase", "Chase plane", "Trailing", "Delayed", "Outside"]
enum Mount {BEHIND, WING, FRONT, TOP, BELLY, TAIL, NOSE}
const MOUNT_NAMES = ["Behind", "Wing", "Front", "Top", "Belly", "Tail", "Nose"]
const CRANE_PRESETS = ["Sweep", "Rise", "Push in", "Pull out", "Circle"]
# the wheel's setting per shot: [start, least, most]
const REACH = {
	Shot.CHASE: [26.0, 5.0, 3000.0],         # metres behind (trailing: 2.5 x that along the path)
	Shot.WINGMAN: [40.0, 6.0, 3000.0],       # metres to the side
	Shot.FLYBY: [25.0, 4.0, 1500.0],         # metres from the flight path
	Shot.GROUND: [0.3, 0.02, 0.9],           # how much of the picture's height the aircraft fills
	Shot.ORBIT: [45.0, 6.0, 5000.0],         # metres away
	Shot.WEAPON: [8.0, 2.0, 500.0],          # metres behind the weapon
	Shot.LOCK_ON: [32.0, 6.0, 3000.0],       # metres behind the shooter
	Shot.CRANE: [1.0, 1.0, 1.0],
	Shot.DRONE: [80.0, 2.0, 3000.0],         # metres a second
	Shot.GHOST: [1.0, 0.3, 5.0]}             # how far out from the aircraft (1 = as designed)
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
const SHAKE_HZ = 12.0            # how fast it shakes (noise features a second)
const RUMBLE_RANGE = 250.0       # aircraft rushing past closer than this shake the camera
const BLAST_RANGE = 900.0        # explosions closer than this shake the camera
const GROUND_CLEARANCE = 1.7     # metres: the lowest a camera goes above the ground
const PLANE_HOLD = 2.2           # chase plane: how firmly it keeps its place (1/s)
const PLANE_DAMPING = 0.8
const PLANE_MAX_G = 6.0          # the most the chase plane pulls; beyond it, it lags and catches up
const DELAY = 0.8                # delayed chase: seconds behind (YSFlight's camera delay)
const STICK_RANGE = 300.0        # mouse pixels from the centre for full stick
const STICK_DEAD = 0.06          # no turning within this much of the centre
const DECK_MARGIN = 25.0         # ground camera: rides a moving object only this close to its hull

var main                         # node_3d.gd
var on := false
var shot: int = Shot.ORBIT        # the calm one to start with: look round, find the shot
var chase_kind: int = Kind.CHASE
var ghost_kind: int = Mount.BEHIND
var rate := 1.0                  # how fast the replay's clock runs now (slow motion, pauses)
var level := true                # chase: the horizon stays level (H: rolls with the aircraft)
var fov := FOV
var blur := 0.0                  # depth of field, 0 (none) to 1
var reach := {}                  # shot -> the wheel's setting
var aim := {}                    # shot -> Vector2 steered (round / up-down, or pan / tilt)
var fx                           # cinema_fx.gd, made the first time the mode is used for an event
var guides                       # cinema_guides.gd: the crane path while setting it up
var base := Transform3D()        # the camera before the shake

var _reach_s := {}               # the same, eased (the wheel moves smoothly)
var _aim_s := {}
var _cut := true                 # the next frame goes straight to the shot (no easing)
var _subject_id := ""
var _q := Quaternion.IDENTITY    # chase (rolling), ghost: the aircraft's attitude, eased
var _dir := Vector3.FORWARD      # eased direction: flight path, weapon, towards the target
var _up := Vector3.UP            # up of the last frame (looking straight up or down)
var _yaw := 0.0                  # eased heading
var _rel := Vector3.ZERO         # eased offset from the aircraft (wingman)
var _look := Vector3.FORWARD     # eased look direction (flyby, ground camera)
var _pan_yaw := 0.0              # the still cameras' last pan (kept when looking straight up)
var _spot := Vector3.ZERO        # where the flyby / ground camera stands
var _spot_t := -INF              # replay time the flyby camera was set up
var _spot_dir := 1.0             # which way the replay was running then (1 forwards, -1 back)
var _deck := -1                  # ground camera: the ground object (ship) it stands on, -1 none
var _deck_local := Vector3.ZERO
var _auto_fov := FOV
var _focus := 300.0              # eased focus distance (background blur)
var _zoom := 0.0                 # snap zoom, 0..1
var _orb_yaw := 0.0              # orbit: the direction it looks from (world), turned only by hand
var _orb_pitch := -0.3
var _weapon = null               # weapon camera: the weapon followed (combat_layer's dictionary)
var _weapon_pos := Vector3.ZERO  # where it is (or ended)
var _target := ""                # lock-on target
var _plane_pos := Vector3.ZERO   # the chase plane: where it is, its speed, its top
var _plane_vel := Vector3.ZERO
var _plane_up := Vector3.UP
var _out_yaw := 0.0              # outside view: the direction it looks from (world)
var _out_pitch := -0.2
var _boxes := {}                 # aircraft id -> its model's box (ghost cameras)
var _crane := []                 # [{"pos", "basis", "id", "rel"}]
var _crane_clock := 0.0
var _crane_played := false
var _crane_running := false      # a glide is under way (8 pressed, not finished)
var _preset := -1                # the ready-made crane move last made
var _drone_pos := Vector3.ZERO
var _drone_vel := Vector3.ZERO
var _drone_yaw := 0.0
var _drone_pitch := 0.0
var _drone_yaw_to := 0.0
var _drone_pitch_to := 0.0
var _stick := Vector2.ZERO       # the stick: where the hidden mouse is from the centre (pixels)
var _stick_rate := Vector2.ZERO  # eased turning (rad/s; x right, y up)
var _trauma := 0.0               # explosions: shake that dies away
var _rumble := 0.0               # aircraft rushing past, eased
var _shake_t := 0.0
var _noise := FastNoiseLite.new()
var _last_t := 0.0               # replay time last frame
var _take_t := 0.0               # Retake: where Play was last pressed
var _take_cam := Transform3D()
var _take_orbit := []
var _attrs := CameraAttributesPractical.new()
var _overlay: CanvasLayer
var _hint: Label
var _hud: Label
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
	guides = GuidesScript.new()
	guides.visible = false
	add_child(guides)
	_overlay = CanvasLayer.new()
	_overlay.layer = 20
	_overlay.visible = false
	add_child(_overlay)
	_hint = _label(22)
	_hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_hint.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_hint.offset_top = 40
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay.add_child(_hint)
	_hud = _label(17)
	_hud.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_hud.offset_left = 16
	_hud.offset_top = 12
	_overlay.add_child(_hud)
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
	_help_text.add_theme_font_size_override("font_size", 15)
	_help_text.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cols.add_child(_help_text)
	_help_text2 = Label.new()
	_help_text2.add_theme_font_size_override("font_size", 15)
	_help_text2.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	cols.add_child(_help_text2)

func _label(size: int) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

# --- on / off (node_3d.gd set_cinema) ---

func enter() -> void:
	on = true
	_cut = true
	rate = 1.0 if main.playing else 0.0
	base = main.camera.global_transform
	_last_t = main.replay_time
	_take_t = main.replay_time
	_take_cam = base
	_stick = Vector2.ZERO
	_stick_rate = Vector2.ZERO
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
	elif shot == Shot.CHASE and chase_kind == Kind.OUTSIDE:
		_start_outside()
	elif shot == Shot.ORBIT:
		_start_orbit()
	main.camera.attributes = _attrs
	main.camera.near = 0.1
	_overlay.visible = true
	_help.visible = false
	show_hint("Cinematic mode   |   0-9: Shots   |   %s: Keys   |   %s or %s: Back" % [
		main.keys.short_name("help"), main.keys.short_name("cinema"), main.keys.short_name("free")], 4.0)

func leave() -> void:
	on = false
	if fx != null:
		fx.visible = false
	guides.hide_path()
	main.camera.attributes = null
	main.camera.fov = 75.0
	main.camera.near = 0.05
	main.camera.global_transform = base
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_overlay.visible = false

# The top view (T) in the cinematic mode: node_3d.gd moves the camera there (wheel, drag, click
# to follow, as outside the mode); back in 3D the shot carries on from where it was.
func top_view_changed(top: bool) -> void:
	if top:
		main.camera.attributes = null
		guides.hide_path()
		_help.visible = false
		show_hint("Top view   |   Wheel: Zoom   |   Right-drag: Move   |   Click: Follow   |   %s or 0-9: Back to 3D" %
			main.keys.short_name("top"), 4.0)
	else:
		main.camera.attributes = _attrs
		main.camera.near = 0.1
		_cut = true

# Each frame while the top view is on: the effects and hints go on; the mouse pointer shows.
func update_top(delta: float) -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_HIDDEN:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if fx != null:
		fx.update(main.replay_time, main.camera.global_position)
	_last_t = main.replay_time
	_cut = true
	if _hint_clock > 0.0:
		_hint_clock -= delta
		_hint.modulate.a = clampf(_hint_clock / 0.6, 0.0, 1.0)
		if _hint_clock <= 0.0:
			_hint.text = ""

# The event is being unloaded (its effects go with it).
func event_cleared() -> void:
	fx = null
	_weapon = null
	_target = ""
	_crane.clear()
	_deck = -1
	_boxes.clear()

# A jump in the replay (seek): the camera goes straight to its shot; a flyby is set up afresh.
func cut() -> void:
	_cut = true
	_spot_t = -INF
	_last_t = main.replay_time

# Playing started: Retake comes back here.
func note_play() -> void:
	_take_t = main.replay_time
	_take_cam = base
	_take_orbit = [_orb_yaw, _orb_pitch, aim[Shot.ORBIT], reach[Shot.ORBIT]]

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
func key(action: String, shift: bool) -> bool:
	if action.begins_with("shot_"):
		if main.top_view:                    # a shot key leaves the top view for that shot
			main.set_top_view(false)
		set_shot(int(action.substr(5)), shift)
		return true
	match action:
		"crane_point":
			add_crane_point()
		"crane_undo":
			if not _crane.is_empty():
				_crane.pop_back()
			_name_hint("Crane: %d point(s)" % _crane.size())
		"crane_clear":
			_crane.clear()
			_crane_played = false
			_name_hint("Crane: all points removed")
		"crane_shorter", "crane_longer":
			var s := float(main.view["cine_crane"]) + (0.5 if action == "crane_longer" else -0.5)
			_set_view("cine_crane", clampf(s, 1.0, 30.0))
			_name_hint("Crane move: %.1f s" % float(main.view["cine_crane"]))
		"crane_preset":
			_crane_preset()
		"smooth":
			_set_view("cine_smooth", not bool(main.view["cine_smooth"]))
			show_hint("Smooth camera %s" % ("on" if main.view["cine_smooth"] else
				"off: the camera sticks to the aircraft exactly"), 1.5)
		"guides":
			_set_view("cine_guides", not bool(main.view["cine_guides"]))
			show_hint("Guides %s" % ("on (crane path while paused, shot names)" if main.view["cine_guides"] else "off"), 1.5)
		"stick":
			_set_view("cine_stick", not bool(main.view["cine_stick"]))
			_stick = Vector2.ZERO
			show_hint("Stick %s" % (("on: move the mouse to turn, %s or the middle button: centre" %
				main.keys.short_name("stick_center")) if main.view["cine_stick"] else "off: right-drag to turn"), 3.0)
		"stick_center":
			_stick = Vector2.ZERO
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

# A setting of the View tab changed from here (saved, and the View tab shows it).
func _set_view(key_name: String, value) -> void:
	main._on_view_changed(key_name, value)
	main.ui.show_view(main.view)

# n: the shot key (0 is the ghost camera); pressing 1 or 0 again picks the next kind (back: the
# one before), 3 or 8 again starts it afresh.
func set_shot(n: int, back := false) -> void:
	if n == 0:
		n = Shot.GHOST
	if n < Shot.CHASE or n > Shot.GHOST:
		return
	var again := n == shot
	var from := base
	shot = n
	_stick = Vector2.ZERO
	match n:
		Shot.CHASE:
			if again:
				chase_kind = posmod(chase_kind + (-1 if back else 1), KIND_NAMES.size())
				aim[Shot.CHASE] = Vector2.ZERO
			if chase_kind == Kind.OUTSIDE:
				_start_outside()
			_name_hint("%s  Chase: %s" % [main.keys.short_name("shot_1"), KIND_NAMES[chase_kind]])
		Shot.GHOST:
			if again:
				ghost_kind = posmod(ghost_kind + (-1 if back else 1), MOUNT_NAMES.size())
				aim[Shot.GHOST] = Vector2.ZERO
			_name_hint("%s  Ghost camera: %s" % [main.keys.short_name("shot_0"), MOUNT_NAMES[ghost_kind]])
		Shot.ORBIT:
			_start_orbit()
		Shot.FLYBY:
			_spot_t = -INF
		Shot.GROUND:
			if not again:
				_park(from.origin)
		Shot.WEAPON:
			_weapon = null
		Shot.CRANE:
			_crane_clock = 0.0
			_crane_running = _crane.size() >= 2
			if _crane.is_empty():            # nothing to glide through: a drone where the camera is
				_start_drone(from)
			if _crane.size() < 2:
				show_hint("Crane: set 2 to %d points with %s (or %s: a ready-made move) first" % [
					CRANE_POINTS, main.keys.short_name("crane_point"), main.keys.short_name("crane_preset")], 3.0)
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
	_crane_running = shot == Shot.CRANE and _crane.size() >= 2
	if _take_orbit.size() == 4:
		_orb_yaw = _take_orbit[0]
		_orb_pitch = _take_orbit[1]
		aim[Shot.ORBIT] = _take_orbit[2]
		reach[Shot.ORBIT] = _take_orbit[3]
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
	_preset = -1
	_name_hint("Crane point %d  -  %s: Play the move" % [_crane.size(), main.keys.short_name("shot_8")])

# The next ready-made crane move, round the aircraft followed (points that move with it), at
# about the camera's distance now.
func _crane_preset() -> void:
	var s := _subject()
	if s.is_empty():
		show_hint("Crane: follow an aircraft first (%s), then pick a ready-made move" % main.keys.short_name("next_aircraft"), 3.0)
		return
	_preset = (_preset + 1) % CRANE_PRESETS.size()
	var d := clampf(base.origin.distance_to(s["pos"]), 25.0, 400.0)
	# [degrees round from behind (to the right +), degrees up, times the distance]
	var plan: Array = [
		[[150.0, 8.0, 1.0], [90.0, 10.0, 1.0], [20.0, 8.0, 1.0]],             # sweep: front to behind
		[[20.0, -25.0, 1.0], [20.0, 10.0, 1.0], [20.0, 55.0, 1.2]],           # rise: below to above
		[[15.0, 10.0, 4.0], [15.0, 8.0, 0.8]],                                # push in
		[[15.0, 5.0, 0.7], [30.0, 25.0, 3.5]],                                # pull out
		[[0.0, 10.0, 1.0], [90.0, 12.0, 1.0], [180.0, 14.0, 1.0], [270.0, 12.0, 1.0], [355.0, 10.0, 1.0]]
	][_preset]
	_crane.clear()
	_crane_played = false
	var heading := Basis.from_euler(Vector3(0.0, _heading(s), 0.0))
	for p in plan:
		var rel := Basis.from_euler(Vector3(-deg_to_rad(p[1]), deg_to_rad(p[0]), 0.0)) * Vector3(0.0, 0.0, d * p[2])
		var pos: Vector3 = s["pos"] + heading * rel
		_crane.append({"pos": pos, "basis": Basis.looking_at((s["pos"] - pos).normalized(), Vector3.UP),
			"id": s["id"], "rel": rel})
	show_hint("Crane: ready-made move \"%s\" (%s: the next one)  -  %s: Play" % [CRANE_PRESETS[_preset],
		main.keys.short_name("crane_preset"), main.keys.short_name("shot_8")], 3.0)

# Mouse in the cinematic mode (node_3d.gd passes them on): wheel, Ctrl+wheel, Alt+wheel,
# right-drag, the stick (mouse moves), middle button.
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
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_stick = Vector2.ZERO
	if event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_steer(Vector2(event.relative.x, -event.relative.y) * main.mouse_sensitivity * _zoom_factor())
		elif bool(main.view["cine_stick"]):
			_stick = (_stick + event.relative).limit_length(STICK_RANGE)

# Turns the camera: v.x to the right, v.y up (radians). Each shot turns what it can: round the
# aircraft, the look of a free or fixed camera, the framing of the ground camera, the flyby's side.
func _steer(v: Vector2) -> void:
	match shot:
		Shot.DRONE:
			_drone_yaw_to -= v.x
			_drone_pitch_to = clampf(_drone_pitch_to + v.y, -1.5, 1.5)
		Shot.CRANE:
			if _crane.is_empty():
				_drone_yaw_to -= v.x
				_drone_pitch_to = clampf(_drone_pitch_to + v.y, -1.5, 1.5)
		Shot.GROUND:                         # framing: fractions of half the picture
			var half := deg_to_rad(maxf(main.camera.fov, 1.0)) * 0.5
			var a: Vector2 = aim[shot] + Vector2(v.x, v.y) / half
			aim[shot] = Vector2(clampf(a.x, -1.5, 1.5), clampf(a.y, -1.5, 1.5))
		Shot.GHOST:                          # pan / tilt of the fixed camera
			var a2: Vector2 = aim[shot] + v
			aim[shot] = Vector2(wrapf(a2.x, -PI, PI), clampf(a2.y, -1.4, 1.4))
		_:                                   # round the aircraft (the view turns the way steered)
			var a3: Vector2 = aim[shot] + Vector2(-v.x, v.y)
			aim[shot] = Vector2(a3.x, clampf(a3.y, -1.4, 1.4))

# Turning slows down as the lens zooms in, so it is the same on screen.
func _zoom_factor() -> float:
	return clampf(main.camera.fov / FOV, 0.02, 2.0)

# The stick: how far the hidden mouse is from the centre sets how fast the camera turns (none in
# the middle, faster further out: a curve, as a flight stick feels), eased in and out.
func _update_stick(delta: float) -> void:
	var want := Vector2.ZERO
	if bool(main.view["cine_stick"]):
		var d := _stick / STICK_RANGE
		var m := d.length()
		if m > STICK_DEAD:
			var strength := pow((m - STICK_DEAD) / (1.0 - STICK_DEAD), 1.6)
			var dir := Vector2(d.x, -d.y if not bool(main.view["cine_stick_invert"]) else d.y) / m
			want = dir * strength * deg_to_rad(float(main.view["cine_stick_speed"]))
	_stick_rate = _stick_rate.lerp(want, _e(6.0, delta))
	if _stick_rate.length() > 1e-4:
		_steer(_stick_rate * delta * _zoom_factor())

# Right-drag and the stick need the mouse held in the window (it moves on for ever, hidden).
func _update_mouse_mode() -> void:
	var want := Input.MOUSE_MODE_CAPTURED if bool(main.view["cine_stick"]) or \
		Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) else Input.MOUSE_MODE_HIDDEN
	if Input.mouse_mode != want:
		Input.mouse_mode = want

# --- every frame ---

# Moves the camera (after the aircraft have moved) and the effects. delta: real seconds.
func update(delta: float) -> void:
	var t: float = main.replay_time
	var back := t < _last_t
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
	_update_mouse_mode()
	_update_stick(delta)
	for k in reach:
		_reach_s[k] = reach[k] if _cut else lerpf(_reach_s[k], reach[k], _e(8.0, delta))
		_aim_s[k] = aim[k] if _cut else _aim_s[k].lerp(aim[k], _e(12.0, delta))
	var focus := -1.0                                 # metres to what's in focus
	match shot:
		Shot.CHASE:
			if not s.is_empty():
				match chase_kind:
					Kind.PLANE:
						base = _chase_plane(s, dts, back)
					Kind.TRAILING:
						base = _trailing(s)
					Kind.DELAYED:
						base = _delayed(s)
					Kind.OUTSIDE:
						base = _outside(s)
					_:
						base = _chase(s, dts)
		Shot.GHOST:
			if not s.is_empty():
				base = _ghost(s, dts)
		Shot.WINGMAN:
			if not s.is_empty():
				base = _wingman(s, dts)
		Shot.FLYBY:
			if not s.is_empty():
				base = _flyby(s, dts, back)
		Shot.GROUND:
			base = _ground(s, dts)
		Shot.ORBIT:
			if not s.is_empty():
				base = _orbit_shot(s)
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
	_focus = focus if _cut else lerpf(_focus, focus, _k(5.0, delta))
	_lens(delta, _focus)
	var cam: Camera3D = main.camera
	cam.global_transform = _shaken(dts, t)
	if fx != null:
		fx.update(t, cam.global_position)
	_update_guides(s)
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
	var v: Vector3 = main.track_vel(id, main.replay_time)
	return {"id": id, "pos": main.active_aircraft[id].position, "basis": main.aircraft_attitude[id], "vel": v}

# --- shots ---

func _chase(s: Dictionary, dts: float) -> Transform3D:
	var d: float = _reach_s[Shot.CHASE]
	var a: Vector2 = _aim_s[Shot.CHASE]
	var frame: Basis
	var up := Vector3.UP
	if level:
		var f := _flight_dir(s)
		_dir = f if _cut else _slerp(_dir, f, _e(3.5, dts))
		frame = _frame_along(_dir)
	else:
		var q: Quaternion = s["basis"].get_rotation_quaternion()
		_q = q if _cut else _q.slerp(q, _e(3.5, dts))
		frame = Basis(_q)
		up = frame.y
	var pos: Vector3 = s["pos"] + frame * (Basis.from_euler(Vector3(-0.12 + a.y, a.x, 0.0)) * Vector3(0.0, 0.0, d))
	return _looking(pos, s["pos"] - frame.z * d * 0.4, up)

# A camera plane flying formation: it steers for its place off the aircraft's tail (behind, to
# the right, a little high) like a pilot would - matching the aircraft's own turns, pulled back
# into place when off it - but it pulls at most PLANE_MAX_G, so in hard turns it swings wide and
# catches up again. It banks with its turns. Backwards or after a jump it starts in its place.
func _chase_plane(s: Dictionary, dts: float, back: bool) -> Transform3D:
	var d: float = _reach_s[Shot.CHASE] * 1.3
	var a: Vector2 = _aim_s[Shot.CHASE]
	_ease_heading(s, dts, 1.5)
	var heading := Basis.from_euler(Vector3(0.0, _yaw, 0.0))
	var place: Vector3 = s["pos"] + heading * (Basis.from_euler(Vector3(-0.1 + a.y, 0.45 + a.x, 0.0)) * Vector3(0.0, 0.0, d))
	var v: Vector3 = s["vel"]
	var acc := Vector3.ZERO
	if _cut or back or _plane_pos.distance_to(place) > maxf(20.0 * d, 3000.0):
		_plane_pos = place
		_plane_vel = v
		_plane_up = Vector3.UP
	elif dts > 0.0:
		var t: float = main.replay_time
		var id: String = s["id"]
		var turn: Vector3 = (main.track_vel(id, t + 0.1) - main.track_vel(id, t - 0.1)) / 0.2   # the aircraft's
		var steps := maxi(1, ceili(dts / 0.01))
		var h := dts / steps
		for i in steps:
			acc = turn * 0.85 + (place - _plane_pos) * (PLANE_HOLD * PLANE_HOLD) + \
				(v - _plane_vel) * (2.0 * PLANE_DAMPING * PLANE_HOLD)
			acc = acc.limit_length(PLANE_MAX_G * 9.81)
			_plane_vel += acc * h
			_plane_pos += _plane_vel * h
		var lift := (acc + Vector3(0.0, 9.81, 0.0)).normalized()
		_plane_up = _slerp(_plane_up, Vector3.UP.lerp(lift, 0.6).normalized(), _k(4.0, dts))
	return _looking(_plane_pos, s["pos"], _plane_up)

# On the aircraft's own path, a little behind it (2.5 x the wheel's distance along the path: the
# aircraft stays the same size whatever its speed), a few metres above it (out of its wake),
# looking at it; H: banking as the aircraft did there.
func _trailing(s: Dictionary) -> Transform3D:
	var speed := maxf((s["vel"] as Vector3).length(), 40.0)
	var lag := clampf(float(_reach_s[Shot.CHASE]) * 2.5 / speed, 0.05, 8.0)
	var a: Vector2 = _aim_s[Shot.CHASE]
	var was: Array = main.track_state(s["id"], float(main.replay_time) - lag)
	var att: Basis = was[2]
	var lift := 3.0 + lag * 2.0
	var pos: Vector3 = was[0] + att * Vector3(a.x * 20.0, lift - a.y * 20.0, 0.0)
	return _looking(pos, s["pos"], Vector3.UP if level else att.y)

# YSFlight's outside view with camera delay (FSOUTSIDEPLAYER3): fixed to the aircraft as it was
# DELAY seconds before, so the aircraft swings round in the picture when it turns. H: level.
func _delayed(s: Dictionary) -> Transform3D:
	var d: float = _reach_s[Shot.CHASE]
	var a: Vector2 = _aim_s[Shot.CHASE]
	var att: Basis = main.track_state(s["id"], float(main.replay_time) - DELAY)[2]
	if level:                                    # its heading and pitch only
		att = _frame_along(-att.z)
	var view := att * Basis.from_euler(Vector3(-0.2 + a.y, a.x, 0.0))
	return Transform3D(view, s["pos"] + view.z * d)

# YSFlight's F7 outside view (FSOUTSIDEPLAYER2): the camera looks at the aircraft from a direction
# fixed in the world, whatever the aircraft does; steering turns that direction.
func _outside(s: Dictionary) -> Transform3D:
	var d: float = _reach_s[Shot.CHASE]
	var a: Vector2 = _aim_s[Shot.CHASE]
	var view := Basis.from_euler(Vector3(clampf(_out_pitch + a.y, -1.5, 1.5), _out_yaw + a.x, 0.0))
	return Transform3D(view, s["pos"] + view.z * d)

# The outside view starts looking the way the camera looks at the aircraft now.
func _start_outside() -> void:
	var s := _subject()
	var dir := -base.basis.z
	if not s.is_empty() and base.origin.distance_to(s["pos"]) > 1.0:
		dir = (s["pos"] - base.origin).normalized()
	_out_yaw = atan2(-dir.x, -dir.z)
	_out_pitch = asin(clampf(dir.y, -0.99, 0.99))
	aim[Shot.CHASE] = Vector2.ZERO
	_aim_s[Shot.CHASE] = Vector2.ZERO

# A camera fixed on the aircraft (it turns with it; its attitude eased a little, which smooths
# the jitter of tracks seen through the network): where, from the model's size.
func _ghost(s: Dictionary, dts: float) -> Transform3D:
	var box := _subject_box(s["id"])
	var q: Quaternion = s["basis"].get_rotation_quaternion()
	_q = q if _cut else _q.slerp(q, _e(9.0, dts))
	var att := Basis(_q)
	var mount := _mount(box, ghost_kind)
	var c := box.get_center()
	var at: Vector3 = c + (mount[0] - c) * float(_reach_s[Shot.GHOST])
	var look: Vector3 = mount[1]
	var a: Vector2 = _aim_s[Shot.GHOST]
	var b := Basis.looking_at(look, mount[2]) * Basis.from_euler(Vector3(a.y, -a.x, 0.0))
	return Transform3D(att * b, s["pos"] + att * at)

# [where in the aircraft's own frame (x right, y up, nose -z), which way it looks, its top].
static func _mount(box: AABB, kind: int) -> Array:
	var lo := box.position
	var hi := box.end
	var c := box.get_center()
	var l := maxf(box.size.z, 4.0)
	var h := maxf(box.size.y, 1.5)
	match kind:
		Mount.WING:                              # out on the right wing, looking in at the cockpit
			var p := Vector3(hi.x * 0.8, c.y + h * 0.15, c.z + l * 0.08)
			return [p, (Vector3(0.0, c.y + h * 0.3, lo.z * 0.45) - p).normalized(), Vector3.UP]
		Mount.FRONT:                             # ahead, looking back at the nose and cockpit
			var p := Vector3(0.0, c.y + h * 0.2 + l * 0.05, lo.z - l * 0.5)
			return [p, (Vector3(0.0, c.y + h * 0.2, c.z) - p).normalized(), Vector3.UP]
		Mount.TOP:                               # above, looking down, the nose up the picture
			var p := Vector3(0.0, hi.y + l * 0.8, c.z + l * 0.05)
			return [p, (c - p).normalized(), Vector3.FORWARD]
		Mount.BELLY:                             # below, looking up at the weapons
			var p := Vector3(0.0, lo.y - l * 0.5, c.z - l * 0.05)
			return [p, (c - p).normalized(), Vector3.FORWARD]
		Mount.TAIL:                              # above the fin, looking forward over the aircraft
			return [Vector3(0.0, hi.y + 0.6, hi.z - l * 0.08), Vector3(0.0, -0.08, -1.0).normalized(), Vector3.UP]
		Mount.NOSE:                              # just above the canopy, looking forward over the nose
			return [Vector3(0.0, c.y + h * 0.3, lo.z + l * 0.28), Vector3(0.0, -0.17, -1.0).normalized(), Vector3.UP]
		_:                                       # behind and above, looking at it
			var p := Vector3(0.0, hi.y + l * 0.15, hi.z + l * 0.55)
			return [p, (Vector3(0.0, c.y, c.z - l * 0.25) - p).normalized(), Vector3.UP]

# The aircraft model's box in its own frame (true size), from its parts; kept per aircraft.
func _subject_box(id: String) -> AABB:
	if _boxes.has(id):
		return _boxes[id]
	var box := AABB(Vector3(-5.0, -1.5, -8.0), Vector3(10.0, 3.0, 16.0))
	var model: Node3D = main.aircraft_models.get(id)
	if model != null:
		var inv := model.global_transform.affine_inverse()
		var first := true
		for part in model.find_children("*", "MeshInstance3D", true, false):
			if part.is_in_group("aircraft_shadow") or part.mesh == null:
				continue
			var bb: AABB = (inv * part.global_transform) * part.get_aabb()
			box = bb if first else box.merge(bb)
			first = false
	_boxes[id] = box
	return box

func _wingman(s: Dictionary, dts: float) -> Transform3D:
	var d: float = _reach_s[Shot.WINGMAN]
	var a: Vector2 = _aim_s[Shot.WINGMAN]
	_ease_heading(s, dts, 2.5)
	var off := Basis.from_euler(Vector3(-0.06 + a.y, _yaw + PI * 0.5 + a.x, 0.0)) * Vector3(0.0, 0.0, d)
	_rel = off if _cut else _rel.lerp(off, _e(3.0, dts))
	return _looking(s["pos"] + _rel, s["pos"] + _flight_dir(s) * d * 0.15)

func _flyby(s: Dictionary, dts: float, back: bool) -> Transform3D:
	if _cut or _flyby_due(s, back):
		_place_flyby(s, back)
	var target: Vector3 = main.track_aim(s["id"], main.replay_time)
	var to: Vector3 = (target - _spot).normalized()
	_look = to if _cut else _slerp(_look, to, _e(9.0, dts))
	return Transform3D(_pan_tilt(_look), _spot)

# A new flyby is due once the aircraft has gone well past, or never came (it turned away), or the
# replay was moved well away. Playing backwards it flies back through the same flyby.
func _flyby_due(s: Dictionary, back: bool) -> bool:
	var t: float = main.replay_time
	var gone := (t - _spot_t) * _spot_dir          # replay seconds since set up, the way it ran then
	if gone < -1.0 or gone > FLYBY_LEAD + 6.0:
		return true
	if back != (_spot_dir < 0.0):
		return false
	var d: float = reach[Shot.FLYBY]
	var rel: Vector3 = s["pos"] - _spot
	return rel.dot(s["vel"] * _spot_dir) > 0.0 and rel.length() > maxf(25.0 * d, 700.0)

# Where the aircraft will be FLYBY_LEAD seconds on (the replay knows; backwards: where it was),
# the camera that far off to one side (steering: the other side, higher or lower), above the
# ground.
func _place_flyby(s: Dictionary, back: bool) -> void:
	var id: String = s["id"]
	_spot_dir = -1.0 if back else 1.0
	var t: float = main.replay_time + FLYBY_LEAD * _spot_dir
	var p: Vector3 = main.track_aim(id, t)
	var v: Vector3 = main.track_vel(id, t)
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
	var target: Vector3 = main.track_aim(s["id"], main.replay_time)
	var to: Vector3 = (target - pos).normalized()
	_look = to if _cut else _slerp(_look, to, _e(3.5, dts))
	# long lens: the aircraft stays about the same size in the picture
	var dist: float = maxf(pos.distance_to(target), 1.0)
	var want := rad_to_deg(2.0 * atan(AIRCRAFT_SIZE * 0.5 / dist) / float(_reach_s[Shot.GROUND]))
	want = clampf(want, 1.0, fov)
	_auto_fov = want if _cut else lerpf(_auto_fov, want, _e(3.0, dts))
	# framing (steering): the aircraft off the centre, in fractions of half the picture
	var a: Vector2 = _aim_s[Shot.GROUND]
	var half := deg_to_rad(_auto_fov) * 0.5
	var b := _pan_tilt(_look) * Basis.from_euler(Vector3(a.y * half, -a.x * half, 0.0))
	return Transform3D(b, pos)

# The ground camera stands here: where the camera was, at least eye height above the ground; on
# a ground object that moves (a ship) it rides along, if it stands on it or right next to it.
func _park(p: Vector3) -> void:
	p.y = maxf(p.y, _ground_y(p) + GROUND_CLEARANCE)
	_spot = p
	_deck = -1
	var best := INF
	var grounds: Array = main.event_data.get("ground_objects", []) if main.event_data != null else []
	for g in grounds:
		var samples: Array = g.get("samples", [])
		if samples.size() < 2 or Main.ys_position(samples[0]).distance_to(Main.ys_position(samples[-1])) < 30.0:
			continue
		var pose := _deck_pose(samples, main.replay_time)
		var d := Vector2(pose.origin.x - p.x, pose.origin.z - p.z).length()
		if d < _hull_radius(g) + DECK_MARGIN and d < best:
			best = d
			_deck = int(g["index"])
			_deck_local = pose.affine_inverse() * p

static func _hull_radius(g: Dictionary) -> float:
	var info = g.get("dat")
	if typeof(info) == TYPE_DICTIONARY and typeof(info.get("box")) == TYPE_ARRAY and info["box"].size() == 6:
		var b: Array = info["box"]
		return maxf(maxf(absf(b[0]), absf(b[3])), maxf(absf(b[2]), absf(b[5])))
	return 40.0

func _deck_spot() -> Vector3:
	if _deck < 0:
		return _spot
	var samples: Array = main.event_data["ground_objects"][_deck].get("samples", [])
	return _deck_pose(samples, main.replay_time) * _deck_local

# A moving ground object's pose at t, smoothed over about a second (its samples come through the
# network too): the weighted mean of the samples near t, position and heading.
static func _deck_pose(samples: Array, t: float) -> Transform3D:
	var sum := Vector3.ZERO
	var fwd := Vector3.ZERO
	var total := 0.0
	var near := Main.frame_index_at(samples, t)   # (samples in time order, like a track's)
	for k in range(maxi(near - 40, 0), mini(near + 41, samples.size())):
		var d: float = float(samples[k]["t"]) - t
		var w := exp(-d * d / 2.0)
		sum += Main.ys_position(samples[k]) * w
		fwd -= Main.ys_basis(samples[k]).z * w
		total += w
	if total < 1e-6 or fwd.length_squared() < 1e-8:
		return Transform3D(Main.ys_basis(samples[near]), Main.ys_position(samples[near]))
	fwd.y = 0.0
	return Transform3D(Basis.looking_at(fwd.normalized(), Vector3.UP), sum / total)

# Like the normal viewer's follow camera: round the aircraft from a direction fixed in the world
# (it doesn't turn when the aircraft turns, nor by itself); only steering turns it.
func _orbit_shot(s: Dictionary) -> Transform3D:
	var a: Vector2 = _aim_s[Shot.ORBIT]
	var view := Basis.from_euler(Vector3(clampf(_orb_pitch + a.y, -1.5, 1.5), _orb_yaw + a.x, 0.0))
	return Transform3D(view, s["pos"] + view.z * float(_reach_s[Shot.ORBIT]))

# The orbit starts where the camera is now (direction and distance), so switching to it is calm.
func _start_orbit() -> void:
	var s := _subject()
	if s.is_empty():
		return
	var d: float = base.origin.distance_to(s["pos"])
	if d > 1.0:
		var dir: Vector3 = (s["pos"] - base.origin) / d
		_orb_yaw = atan2(-dir.x, -dir.z)
		_orb_pitch = asin(clampf(dir.y, -0.99, 0.99))
		reach[Shot.ORBIT] = clampf(d, REACH[Shot.ORBIT][1], REACH[Shot.ORBIT][2])
		_reach_s[Shot.ORBIT] = reach[Shot.ORBIT]
	aim[Shot.ORBIT] = Vector2.ZERO
	_aim_s[Shot.ORBIT] = Vector2.ZERO

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
		_dir = head[1] if _cut else _slerp(_dir, head[1], _e(5.0, dts))
		var d: float = _reach_s[Shot.WEAPON]
		var a: Vector2 = _aim_s[Shot.WEAPON]
		var frame := _frame_along(_dir)
		var pos: Vector3 = _weapon_pos + frame * (Basis.from_euler(Vector3(-0.25 + a.y, a.x, 0.0)) * Vector3(0.0, 0.0, d))
		return _looking(pos, _weapon_pos + _dir * d * 2.5)
	if _weapon != null and t > float(_weapon["end"]["t"]) and t < float(_weapon["end"]["t"]) + WEAPON_HOLD:
		var to := (_weapon_pos - base.origin).normalized()
		_look = to if _cut else _slerp(_look, to, _e(4.0, dts))
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
	_dir = to if _cut else _slerp(_dir, to, _e(4.0, dts))
	var d: float = _reach_s[Shot.LOCK_ON]
	var a: Vector2 = _aim_s[Shot.LOCK_ON]
	var frame := _frame_along(_dir)
	var off := frame * (Basis.from_euler(Vector3(-0.26 + a.y, 0.34 + a.x, 0.0)) * Vector3(0.0, 0.0, d))
	_rel = off if _cut else _rel.lerp(off, _e(5.0, dts))
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
		_crane_running = false
	var e := u * u * u * (u * (u * 6.0 - 15.0) + 10.0)
	var x := e * (n - 1)
	var k := mini(int(x), maxi(n - 2, 0))
	var f := x - k if n > 1 else 0.0
	if _crane_moves_with(s):
		_ease_heading(s, dts, 2.5)
		var rel := _catmull(_crane.map(func(p): return p["rel"]), k, f)
		var pos: Vector3 = s["pos"] + Basis.from_euler(Vector3(0.0, _yaw, 0.0)) * rel
		return _looking(pos, s["pos"])
	var pos2 := _catmull(_crane.map(func(p): return p["pos"]), k, f)
	var b: Basis = _crane[k]["basis"] if n == 1 else _crane[k]["basis"].slerp(_crane[k + 1]["basis"], f)
	return Transform3D(b, pos2)

# Whether the crane points move with the aircraft followed (all set while following it).
func _crane_moves_with(s: Dictionary) -> bool:
	if s.is_empty() or _crane.is_empty():
		return false
	for p in _crane:
		if p["id"] != s["id"]:
			return false
	return true

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
	_drone_vel = _drone_vel.lerp(push.normalized() * speed, _e(2.5, delta))
	_drone_pos += _drone_vel * delta
	_drone_pos.y = maxf(_drone_pos.y, _ground_y(_drone_pos) + GROUND_CLEARANCE * 0.5)
	_drone_yaw = lerp_angle(_drone_yaw, _drone_yaw_to, _e(10.0, delta))
	_drone_pitch = lerpf(_drone_pitch, _drone_pitch_to, _e(10.0, delta))
	return Transform3D(Basis.from_euler(Vector3(_drone_pitch, _drone_yaw, 0.0)), _drone_pos)

# --- crane guides and the line of keys (while paused) ---

func _update_guides(s: Dictionary) -> void:
	var paused: bool = not main.playing and rate == 0.0
	var show: bool = bool(main.view["cine_guides"]) and paused and not (shot == Shot.CRANE and _crane_running)
	if not show or (_crane.is_empty() and shot != Shot.CRANE):
		guides.hide_path()
		_hud.text = ""
		return
	var moving := _crane_moves_with(s)
	var world := []
	var looks := []
	var heading := Basis.from_euler(Vector3(0.0, _heading(s), 0.0)) if moving else Basis.IDENTITY
	for p in _crane:
		var at: Vector3 = s["pos"] + heading * p["rel"] if moving else p["pos"]
		world.append(at)
		looks.append((s["pos"] - at).normalized() if moving else -p["basis"].z)
	var path := PackedVector3Array()
	var n := world.size()
	if n >= 2:
		for i in range((n - 1) * 16 + 1):
			var x := i / 16.0
			var k := mini(int(x), n - 2)
			path.append(_catmull(world, k, x - k))
	var size := 50.0
	if not s.is_empty() and n > 0:
		size = clampf(world[0].distance_to(s["pos"]), 10.0, 500.0)
	guides.show_path(world, looks, path, size)
	var k2 = main.keys
	var about := "no points yet" if n == 0 else ("%d point%s, %s" % [n, "" if n == 1 else "s",
		("moving with " + str(main.event_data["entities"][s["id"]]["player"])) if moving else "fixed in place"])
	_hud.text = "CRANE  %s  |  Move %.1f s (%s %s)\n%s: Add a point here   %s: Remove the last   %s: Remove all   %s: Ready-made move%s   %s: Play   %s: Hide guides" % [
		about, float(main.view["cine_crane"]), k2.short_name("crane_shorter"), k2.short_name("crane_longer"),
		k2.short_name("crane_point"), k2.short_name("crane_undo"), k2.short_name("crane_clear"),
		k2.short_name("crane_preset"), (" (" + CRANE_PRESETS[_preset] + ")") if _preset >= 0 else "",
		k2.short_name("shot_8"), k2.short_name("guides")]

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

# The camera with its shake (the flyby only): small turns (and a little movement) following
# smooth noise, as strong as the strongest cause now: an aircraft rushing past the (still)
# camera, eased in and out, or an explosion nearby.
func _shaken(dts: float, t: float) -> Transform3D:
	var strength: float = main.view["cine_shake"]
	if strength <= 0.0 or shot != Shot.FLYBY:
		_trauma = 0.0
		_rumble = 0.0
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
	var rush_now := 0.0                          # aircraft rushing past (the flyby camera stands still)
	for id in main.active_aircraft:
		var m: Node3D = main.active_aircraft[id]
		if not m.visible:
			continue
		var dist := m.position.distance_to(base.origin)
		if dist > RUMBLE_RANGE or dist < 0.5:
			continue
		var rush := clampf(main.track_vel(id, t).length() / 220.0, 0.0, 1.0)
		rush_now = maxf(rush_now, minf(rush * pow(1.0 - dist / RUMBLE_RANGE, 2.0), 0.85))
	_rumble = lerpf(_rumble, rush_now, _k(12.0 if rush_now > _rumble else 3.0, dts))
	_shake_t += dts
	var amount := strength * pow(clampf(maxf(_trauma, _rumble), 0.0, 1.0), 2.0)
	if amount <= 0.0001:
		return base
	amount *= main.camera.fov / FOV              # the same size on screen when zoomed in
	var turn := Vector3(_wobble(0), _wobble(1), _wobble(2) * 1.3) * deg_to_rad(SHAKE_DEG) * amount
	var move := Vector3(_wobble(3), _wobble(4), 0.0) * 0.25 * amount
	return Transform3D(base.basis * Basis.from_euler(turn), base.origin + base.basis * move)

func _wobble(axis: int) -> float:
	return _noise.get_noise_2d(_shake_t * SHAKE_HZ, axis * 37.0) * 0.7 + _noise.get_noise_2d(_shake_t * 3.5, axis * 37.0 + 200.0) * 0.3

# --- helpers ---

# How far to move towards a target this frame: time-constant easing (1 / rate seconds).
static func _k(speed: float, dt: float) -> float:
	return 1.0 - exp(-speed * dt)

# The same for the camera's own easing: with View "Smooth camera" off (B) the camera sticks to
# what it follows exactly (no lag; steering and the wheel act at once).
func _e(speed: float, dt: float) -> float:
	return _k(speed, dt) if bool(main.view["cine_smooth"]) else 1.0

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
	_yaw = h if _cut else lerp_angle(_yaw, h, _e(speed, dts))

# A frame looking along dir, without roll (up as near world up as it can be).
func _frame_along(dir: Vector3) -> Basis:
	var up := Vector3.UP if absf(dir.y) < 0.97 else _up
	var b := Basis.looking_at(dir, up)
	_up = b.y
	return b

# A still camera's pan and tilt head looking along dir: never rolls (straight up or down it keeps
# the pan it had).
func _pan_tilt(dir: Vector3) -> Basis:
	if Vector2(dir.x, dir.z).length() > 0.02:
		_pan_yaw = atan2(-dir.x, -dir.z)
	return Basis.from_euler(Vector3(asin(clampf(dir.y, -1.0, 1.0)), _pan_yaw, 0.0))

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

func show_hint(text: String, seconds: float) -> void:
	_hint.text = text
	_hint.modulate.a = 1.0
	_hint_clock = seconds

# A shot's name and the like: only with the guides on (G off: nothing on screen for recording).
func _name_hint(text: String) -> void:
	if bool(main.view["cine_guides"]):
		show_hint(text, 1.5)

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
	left.append("")
	left.append("Wheel  -  Closer / further (Ground camera: how big;")
	left.append("            Drone: speed; Ghost: nearer / further out)")
	left.append("Ctrl+Wheel  -  Zoom")
	left.append("Alt+Wheel  -  Background blur")
	left.append("Right-drag  -  Turn the camera")
	left.append("Middle button  -  Stick back to the centre")
	left.append("")
	left.append("View tab: Flyby shake, Slow motion, Crane move, Smooth camera,")
	left.append("Stick speed and more; Keys...")
	return ["\n".join(left), "\n".join(right)]
