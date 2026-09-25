extends RefCounted
# The keyboard shortcuts by name: what each does, its default key and the key the user picked
# instead (View tab > Keys..., saved in settings.cfg as "key_<name>"). node_3d.gd asks which
# action a key press is (action_of) and whether a key is held (held); the Keys window and the
# cinematic mode's key list show the keys by name (key_name).
#
# Where each action works: "both" = the normal viewer and the cinematic mode (M), "viewer" = only
# the normal viewer, "cinema" = only the cinematic mode. In the cinematic mode its own actions
# come first, so one key can do one thing in each (K: pause, and in the cinematic mode a crane
# point).

# [name, what it does, default key, where]
const ACTIONS = [
	["play", "Play / pause", KEY_SPACE, "both"],
	["pause", "Pause", KEY_K, "viewer"],
	["rewind", "Play backwards (again: faster)", KEY_J, "both"],
	["fast", "Play fast (again: faster)", KEY_L, "both"],
	["frame_back", "One frame back (Shift: 1 s)", KEY_COMMA, "both"],
	["frame_forward", "One frame forward (Shift: 1 s)", KEY_PERIOD, "both"],
	["back", "10 s back (Shift: 60 s)", KEY_LEFT, "both"],
	["forward", "10 s forward (Shift: 60 s)", KEY_RIGHT, "both"],
	["restart", "Start / Restart", KEY_HOME, "both"],
	["faster", "Speed up", KEY_EQUAL, "both"],
	["slower", "Slow down", KEY_MINUS, "both"],
	["next_aircraft", "Next aircraft in the air (Shift: previous)", KEY_TAB, "both"],
	["free", "Free camera (in the cinematic mode: leave it)", KEY_ESCAPE, "both"],
	["panel", "Side panel", KEY_P, "viewer"],
	["top", "Top view", KEY_T, "viewer"],
	["next_kill", "Next kill (Shift: previous)", KEY_N, "both"],
	["next_check", "Next CHECK to review (Shift: previous)", KEY_C, "both"],
	["move_forward", "Camera forward", KEY_W, "both"],
	["move_back", "Camera back", KEY_S, "both"],
	["move_left", "Camera left", KEY_A, "both"],
	["move_right", "Camera right", KEY_D, "both"],
	["move_up", "Camera up", KEY_E, "both"],
	["move_down", "Camera down", KEY_Q, "both"],
	["fullscreen", "Full screen on / off", KEY_F11, "both"],
	["cinema", "Cinematic mode on / off", KEY_M, "both"],
	["save_track", "Save the followed aircraft's flight path (40 s, to check jitter)", KEY_F9, "both"],
	["shot_0", "Shot 0: Ghost camera fixed on the aircraft (again: next spot)", KEY_0, "cinema"],
	["shot_1", "Shot 1: Chase (again: Chase plane, Trailing, Delayed, Outside)", KEY_1, "cinema"],
	["shot_2", "Shot 2: Wingman", KEY_2, "cinema"],
	["shot_3", "Shot 3: Flyby", KEY_3, "cinema"],
	["shot_4", "Shot 4: Ground / deck camera", KEY_4, "cinema"],
	["shot_5", "Shot 5: Orbit", KEY_5, "cinema"],
	["shot_6", "Shot 6: Weapon camera", KEY_6, "cinema"],
	["shot_7", "Shot 7: Lock-on", KEY_7, "cinema"],
	["shot_8", "Shot 8: Crane move", KEY_8, "cinema"],
	["shot_9", "Shot 9: Free drone", KEY_9, "cinema"],
	["crane_point", "Crane: add a point here", KEY_K, "cinema"],
	["crane_undo", "Crane: remove the last point", KEY_U, "cinema"],
	["crane_clear", "Crane: remove all points", KEY_DELETE, "cinema"],
	["crane_shorter", "Crane: shorter move", KEY_BRACKETLEFT, "cinema"],
	["crane_longer", "Crane: longer move", KEY_BRACKETRIGHT, "cinema"],
	["crane_preset", "Crane: next ready-made move", KEY_V, "cinema"],
	["guides", "Guides on / off (crane path while paused, shot names)", KEY_G, "cinema"],
	["stick", "Mouse steers like a stick, on / off (YSFlight's F7 view)", KEY_F7, "cinema"],
	["stick_center", "Stick back to the centre (also: middle mouse button)", KEY_F8, "cinema"],
	["snap_zoom", "Snap zoom (hold)", KEY_Z, "cinema"],
	["slow_motion", "Slow motion (hold)", KEY_X, "cinema"],
	["retake", "Retake: back to where Play was pressed", KEY_BACKSPACE, "cinema"],
	["horizon", "Chase: level horizon / roll with the aircraft", KEY_H, "cinema"],
	["target", "Lock-on: next target", KEY_R, "cinema"],
	["help", "Show / hide this key list", KEY_F1, "cinema"]]
# more keys that do the same (not changeable): + and - on the number pad and Shift+=
const EXTRA = {"faster": [KEY_PLUS, KEY_KP_ADD], "slower": [KEY_KP_SUBTRACT]}

var keys := {}                   # action -> key (Key enum value)

func _init() -> void:
	reset()

func reset() -> void:
	for a in ACTIONS:
		keys[a[0]] = a[2]

static func default_of(action: String) -> int:
	for a in ACTIONS:
		if a[0] == action:
			return a[2]
	return KEY_NONE

static func label_of(action: String) -> String:
	for a in ACTIONS:
		if a[0] == action:
			return a[1]
	return action

static func where_of(action: String) -> String:
	for a in ACTIONS:
		if a[0] == action:
			return a[3]
	return "both"

# The action a key press stands for in the normal viewer (cinema false) or the cinematic mode;
# "" if none.
func action_of(keycode: int, cinema: bool) -> String:
	if keycode == KEY_NONE:
		return ""
	var found := ""
	for a in ACTIONS:
		var where: String = a[3]
		if where == ("viewer" if cinema else "cinema"):
			continue
		if keys[a[0]] == keycode or keycode in EXTRA.get(a[0], []):
			if where == "cinema":
				return a[0]          # the cinematic mode's own actions come first
			if found == "":
				found = a[0]
	return found

func held(action: String) -> bool:
	return Input.is_key_pressed(keys.get(action, KEY_NONE))

func key_name(action: String) -> String:
	var k: int = keys.get(action, KEY_NONE)
	return "-" if k == KEY_NONE else OS.get_keycode_string(k)

# The same, short, for the hints on screen (Esc, not Escape)
func short_name(action: String) -> String:
	var name := key_name(action)
	return {"Escape": "Esc", "Comma": ",", "Period": ".", "Equal": "=", "Minus": "-",
		"Backspace": "Bksp", "PageUp": "PgUp", "PageDown": "PgDn", "BracketLeft": "[",
		"BracketRight": "]", "Delete": "Del", "Semicolon": ";", "Apostrophe": "'", "Slash": "/",
		"Backslash": "\\"}.get(name, name)

# Other actions on the same key that work in a mode this one works in too (they clash: one of
# them can't be reached there).
func clashes(action: String) -> Array:
	var out := []
	var where := where_of(action)
	for a in ACTIONS:
		if a[0] == action or keys[a[0]] != keys[action] or keys[action] == KEY_NONE:
			continue
		var in_viewer: bool = where != "cinema" and a[3] != "cinema"
		var in_cinema: bool = where != "viewer" and a[3] != "viewer"
		if in_viewer or in_cinema:
			out.append(a[0])
	return out
