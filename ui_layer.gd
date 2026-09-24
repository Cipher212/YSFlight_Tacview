extends CanvasLayer
# The viewer's controls. Plain Godot controls on purpose: this is a utility, not a game.
#   start menu : continue with the last event, open a saved one, or build a new one from
#                replays (.yfs) and the map (.fld) they were flown on
#   top bar    : menu, open event, side panel on/off, restart, jump to a time
#   bottom bar : kill ticks, full-length time slider, play/pause, -+10 s, clock, speed
#   side panel : Pilots (sorties and how they ended), Kills (click to jump there), Files,
#                View (sizes of aircraft / weapons / text, what is drawn)
#   top left   : the aircraft the camera follows (text set by the main scene)
# The main scene (node_3d.gd) listens to the signals and calls show_event() / refresh().

signal open_replays(paths: PackedStringArray, fld_path: String)
signal open_event(path: String)
signal view_changed(key: String, value)
signal play_toggled
signal restart
signal step(seconds: float)
signal rewind_pressed            # play backwards; again = faster
signal fast_forward_pressed      # play forwards fast; again = faster
signal frame_step(direction: int)
signal seek_requested(t: float)
signal speed_changed(speed: float)
signal aircraft_chosen(id: String)
signal kill_chosen(kill: Dictionary)
signal death_chosen(id: String, t: float)
signal layout_changed
signal panel_toggled(shown: bool)

const Main = preload("res://node_3d.gd")
const Fmt = preload("res://fmt.gd")
const SPEEDS = [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0]
const PANEL_W = 480.0
const TEAM_NAMES = {1: "BLUE (IFF 1)", 4: "RED (IFF 4)", 0: "OTHER / NEUTRAL"}
const DEATHS = ["killed", "shot_down", "collision", "crashed", "overg", "unknown", "went_down"]
const CHECK_COLOR = Color(1.0, 0.72, 0.35)
# View tab: [key, label, min, max, exponential, format] sliders and [key, label] switches
const VIEW_SLIDERS = [
	["aircraft_scale", "Aircraft size", 1.0, 50.0, true, "%.1fx"],
	["weapon_scale", "Weapon size", 1.0, 50.0, true, "%.1fx"],
	["text_scale", "Text size", 0.5, 3.0, false, "%.2fx"],
	["trail_seconds", "Ribbon length", 0.0, 120.0, false, "%d s"]]
const VIEW_SWITCHES = [
	["ribbons", "Energy ribbons (speed: red slow, yellow, green fast)"],
	["smoke", "Black smoke behind aircraft going down"],
	["vectors", "Flight path vectors (yellow) and nose lines (grey)"],
	["tags", "Name tags with altitude and speed"],
	["tethers", "Missile tethers with distance to target"],
	["markers", "Detonation and kill markers"],
	["ground", "Ground objects"],
	["clouds", "Clouds (see-through blocks)"],
	["blocky", "Blocky placeholder aircraft instead of the game models (faster)"]]

var top_bar: PanelContainer
var bottom_bar: PanelContainer
var side_panel: PanelContainer
var status: Label
var info: Label
var time_label: Label
var slider: HSlider
var ticks: Control
var play_button: Button
var play_state: Label
var panel_button: Button
var speed_menu: OptionButton
var speed_edit: LineEdit
var jump_edit: LineEdit
var pilots: Tree
var kills_tree: Tree
var deaths_tree: Tree
var details: RichTextLabel
var files_text: RichTextLabel
var busy: Control
var busy_label: Label
var busy_bar: ProgressBar
var replay_dialog: FileDialog
var event_dialog: FileDialog
var fld_dialog: FileDialog
var view_controls = {}    # key -> HSlider / CheckBox
var view_values = {}      # key -> Label showing a slider's value
var start_menu: Control
var menu_continue: Button
var menu_replays_label: Label
var menu_field: OptionButton
var menu_note: Label
var menu_last := ""
var menu_replays := PackedStringArray()
var fields = []           # [field name, .fld path] from the scenery lists (and any browsed to)

var _entities = {}
var _grounds = []
var _kill_marks = []      # [t, colour]
var _t_min := 0.0
var _t_max := 1.0

func _ready() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_build_top(root)
	_build_bottom(root)
	_build_side(root)
	# the followed aircraft: bottom left, just above the timeline (the kill feed is top right)
	info = Label.new()
	info.add_theme_constant_override("outline_size", 6)
	info.add_theme_color_override("font_outline_color", Color.BLACK)
	info.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info.anchor_top = 1.0
	info.anchor_bottom = 1.0
	info.grow_vertical = Control.GROW_DIRECTION_BEGIN
	info.offset_left = 12
	root.add_child(info)
	_build_start_menu(root)
	_build_busy(root)
	_build_dialogs()
	get_viewport().size_changed.connect(_layout)
	top_bar.resized.connect(_layout)
	bottom_bar.resized.connect(_layout)
	_layout.call_deferred()

# --- called by the main scene ---

func show_event(data: Dictionary, t_min: float, t_max: float, path: String) -> void:
	_entities = data.get("entities", {})
	_grounds = data.get("ground_objects", [])
	_t_min = t_min
	_t_max = maxf(t_max, t_min + 1.0)
	slider.min_value = _t_min
	slider.max_value = _t_max
	var used := 0
	for s in data.get("sources", []):
		if s.get("included", false):
			used += 1
	status.text = "%s  |  %s  |  %d files  |  %d sorties  |  %d kills" % [
		path.get_file(), data.get("map", data.get("field", "")), maxi(used, 1),
		_entities.size(), data.get("kills", []).size()]
	_fill_pilots(data)
	_fill_kills(data)
	_fill_deaths(data)
	_fill_files(data)
	_kill_marks.clear()
	for k in data.get("kills", []):
		_kill_marks.append([k["t"], Main.iff_color(_ref_iff(k.get("killer_ref"))).lightened(0.2)])
	ticks.queue_redraw()

# direction: 1 forwards, -1 backwards; the clock also shows whole seconds (what scorers note down)
func refresh(t: float, playing: bool, speed := 1.0, direction := 1) -> void:
	slider.set_value_no_signal(t)
	time_label.text = "%s (%d s) / %s" % [Fmt.clock(t), int(t), Fmt.clock(_t_max)]
	play_button.text = "Pause" if playing else "Play"
	var state := "PAUSED"
	if playing:
		state = "%s %s" % ["PLAYING" if direction > 0 else "REWINDING", _speed_text(speed)]
	if play_state.text != state:
		play_state.text = state

func set_info(text: String) -> void:
	info.text = text

func set_status(text: String) -> void:
	status.text = text

func show_speed(speed: float) -> void:
	var i := SPEEDS.find(speed)
	speed_menu.select(i)
	speed_edit.text = "" if i >= 0 else str(speed)

func show_busy(percent: int, text: String) -> void:
	busy.visible = true
	busy_bar.value = percent
	busy_label.text = text

func hide_busy() -> void:
	busy.visible = false

# Puts the View tab's controls at these values (without sending view_changed).
func show_view(view: Dictionary) -> void:
	for key in view:
		var c = view_controls.get(key)
		if c is HSlider:
			c.set_value_no_signal(view[key])
			_show_view_value(key, view[key])
		elif c is CheckBox:
			c.set_pressed_no_signal(view[key])

func show_start_menu(last_event: String) -> void:
	menu_last = last_event
	menu_continue.text = "Continue:  " + last_event.get_file()
	menu_continue.visible = last_event != ""
	if fields.is_empty():
		_scan_fields()
	start_menu.visible = true

func hide_start_menu() -> void:
	start_menu.visible = false

func feed_margins() -> Vector2:
	# (right, top) space the live kill feed should keep clear of
	return Vector2((PANEL_W if side_panel.visible else 0.0) + 16.0, top_bar.size.y + 8.0)

# How a sortie ended, in a line: the most likely cause with its likelihood, and the runner-up if
# it is a real alternative (events built before the likelihoods: the old wording).
func fate_text(fate: Dictionary) -> String:
	var causes: Array = fate.get("causes", [])
	if not fate.has("causes"):
		match fate.get("kind", ""):
			"killed":
				return "shot down by %s (%s)" % [_ref_name(fate.get("by")), Fmt.weapon(fate.get("weapon", ""))]
			"went_down":
				return "went down, no kill credit"
			"crashed":
				return "crashed"
			"left":
				return "left / respawned"
		return ""
	if causes.is_empty():
		return fate.get("summary", "")
	var text := "%s %d%%" % [causes[0]["text"], roundi(causes[0]["p"] * 100.0)]
	if fate.get("kind", "") == "left_under_fire":
		text = "left the aircraft in flight UNDER FIRE %d%%" % roundi(causes[0]["p"] * 100.0)
	if causes.size() > 1 and causes[1]["p"] >= 0.15:
		text += ", or %s %d%%" % [causes[1]["text"], roundi(causes[1]["p"] * 100.0)]
	return text

# The full story of an ending, for tooltips: every cause with its reasons, what the replays
# show, and (for a leave) what was threatening the aircraft.
func fate_details(fate: Dictionary) -> String:
	var lines := []
	for c in fate.get("causes", []):
		lines.append("%d%%  %s" % [roundi(c["p"] * 100.0), c["text"]])
		for w in c.get("why", []):
			lines.append("      - " + w)
	if not fate.get("evidence", []).is_empty():
		lines.append("What the replays show:")
		for ev in fate["evidence"]:
			lines.append("      " + ev)
	if not fate.get("threats", []).is_empty():
		lines.append("Threats when it left:")
		for th in fate["threats"]:
			lines.append("      " + th["text"])
	return "\n".join(lines)

# --- building ---

func _build_top(root: Control) -> void:
	top_bar = PanelContainer.new()
	top_bar.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	root.add_child(top_bar)
	var row := HBoxContainer.new()
	top_bar.add_child(row)
	_button(row, "Menu", func(): show_start_menu(menu_last))
	_button(row, "Open event...", _ask_event)
	panel_button = _button(row, "Hide panel", toggle_panel)
	row.add_child(VSeparator.new())
	_button(row, "Restart", restart.emit)
	row.add_child(_label("Jump to:"))
	jump_edit = LineEdit.new()
	jump_edit.placeholder_text = "mm:ss"
	jump_edit.custom_minimum_size.x = 90
	jump_edit.text_submitted.connect(_on_jump)
	row.add_child(jump_edit)
	_button(row, "Go", _on_go)
	row.add_child(VSeparator.new())
	status = _label("Menu: open an event, or build one from replays (.yfs)")
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.clip_text = true
	row.add_child(status)

func _build_bottom(root: Control) -> void:
	bottom_bar = PanelContainer.new()
	bottom_bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	bottom_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN   # grow up from the bottom edge
	root.add_child(bottom_bar)
	var col := VBoxContainer.new()
	bottom_bar.add_child(col)
	ticks = Control.new()
	ticks.custom_minimum_size.y = 8
	ticks.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ticks.draw.connect(_draw_ticks)
	ticks.resized.connect(ticks.queue_redraw)
	col.add_child(ticks)
	slider = HSlider.new()
	slider.step = 0.1
	slider.focus_mode = Control.FOCUS_NONE
	slider.value_changed.connect(seek_requested.emit)
	col.add_child(slider)
	var row := HBoxContainer.new()
	col.add_child(row)
	_tip(_button(row, "|<", restart.emit), "Back to the start and play (Home)")
	_tip(_button(row, "<<", rewind_pressed.emit), "Play backwards; press again for faster (J)")
	_tip(_button(row, "<|", func(): frame_step.emit(-1)), "One frame back (,)  -  Shift: 1 s")
	play_button = _button(row, "Play", play_toggled.emit)
	_tip(play_button, "Play / pause (Space; K pauses)")
	_tip(_button(row, "|>", func(): frame_step.emit(1)), "One frame forward (.)  -  Shift: 1 s")
	_tip(_button(row, ">>", fast_forward_pressed.emit), "Play fast; press again for faster (L)")
	row.add_child(VSeparator.new())
	_tip(_button(row, "-60 s", func(): step.emit(-60.0)), "Shift+Left")
	_tip(_button(row, "-10 s", _back_10), "Left")
	_tip(_button(row, "+10 s", _forward_10), "Right")
	_tip(_button(row, "+60 s", func(): step.emit(60.0)), "Shift+Right")
	row.add_child(VSeparator.new())
	time_label = _label("0:00 / 0:00")
	row.add_child(time_label)
	play_state = _label("")
	play_state.custom_minimum_size.x = 130
	row.add_child(play_state)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	row.add_child(_label("Speed:"))
	speed_menu = OptionButton.new()
	for s in SPEEDS:
		speed_menu.add_item(_speed_text(s))
	speed_menu.select(SPEEDS.find(1.0))
	speed_menu.focus_mode = Control.FOCUS_NONE
	speed_menu.item_selected.connect(_on_speed_item)
	row.add_child(speed_menu)
	speed_edit = LineEdit.new()
	speed_edit.placeholder_text = "any, e.g. 0.67"
	speed_edit.custom_minimum_size.x = 120
	speed_edit.text_submitted.connect(_on_speed_text)
	row.add_child(speed_edit)

func _build_side(root: Control) -> void:
	side_panel = PanelContainer.new()
	side_panel.anchor_left = 1.0
	side_panel.anchor_right = 1.0
	side_panel.anchor_bottom = 1.0
	side_panel.offset_left = -PANEL_W
	root.add_child(side_panel)
	# the tabs, and under them the full story of the kill or death picked in the Kills / Deaths tab
	var column := VBoxContainer.new()
	side_panel.add_child(column)
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(tabs)
	details = RichTextLabel.new()
	details.custom_minimum_size.y = 220
	details.selection_enabled = true
	details.scroll_active = true
	details.visible = false
	column.add_child(details)
	pilots = Tree.new()
	pilots.name = "Pilots"
	pilots.hide_root = true
	pilots.item_selected.connect(_on_pilot_item)
	tabs.add_child(pilots)
	kills_tree = Tree.new()
	kills_tree.name = "Kills"
	kills_tree.hide_root = true
	kills_tree.item_selected.connect(_on_kill_item)
	tabs.add_child(kills_tree)
	deaths_tree = Tree.new()
	deaths_tree.name = "Deaths"
	deaths_tree.hide_root = true
	deaths_tree.item_selected.connect(_on_death_item)
	tabs.add_child(deaths_tree)
	files_text = RichTextLabel.new()
	files_text.name = "Files"
	files_text.bbcode_enabled = true
	files_text.selection_enabled = true
	tabs.add_child(files_text)
	_build_view(tabs)

func _build_view(tabs: TabContainer) -> void:
	var scroll := ScrollContainer.new()
	scroll.name = "View"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(scroll)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 8)
	scroll.add_child(v)
	var head := _label("Sizes: 1x is true size; bigger keeps things visible from far away.")
	head.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(head)
	for s in VIEW_SLIDERS:
		var row := HBoxContainer.new()
		v.add_child(row)
		var name_label := _label(s[1])
		name_label.custom_minimum_size.x = 120
		row.add_child(name_label)
		var slider := HSlider.new()
		slider.min_value = s[2]
		slider.max_value = s[3]
		slider.exp_edit = s[4]
		slider.step = 0.05 if s[3] <= 50.0 else 1.0
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.focus_mode = Control.FOCUS_NONE
		slider.value_changed.connect(_on_view_slider.bind(s[0]))
		row.add_child(slider)
		var value := _label("")
		value.custom_minimum_size.x = 56
		row.add_child(value)
		view_controls[s[0]] = slider
		view_values[s[0]] = value
	v.add_child(HSeparator.new())
	v.add_child(_label("Show"))
	for s in VIEW_SWITCHES:
		var box := CheckBox.new()
		box.text = s[1]
		box.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.focus_mode = Control.FOCUS_NONE
		box.toggled.connect(func(on): view_changed.emit(s[0], on))
		v.add_child(box)
		view_controls[s[0]] = box

func _build_start_menu(root: Control) -> void:
	start_menu = CenterContainer.new()
	start_menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	start_menu.mouse_filter = Control.MOUSE_FILTER_STOP
	start_menu.visible = false
	root.add_child(start_menu)
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(640, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.14, 0.16)
	style.set_content_margin_all(18)
	box.add_theme_stylebox_override("panel", style)
	start_menu.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	box.add_child(v)
	var title := _label("YSFlight replay viewer")
	title.add_theme_font_size_override("font_size", 24)
	v.add_child(title)
	menu_continue = _button(v, "Continue", func(): open_event.emit(menu_last))
	_button(v, "Open a saved event...", _ask_event)
	v.add_child(HSeparator.new())
	v.add_child(_label("New event from replays"))
	var r1 := HBoxContainer.new()
	v.add_child(r1)
	r1.add_child(_label("1.  Replays (.yfs) of one event:"))
	_button(r1, "Choose files...", _ask_replays)
	menu_replays_label = _label("none chosen")
	menu_replays_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(menu_replays_label)
	var r2 := HBoxContainer.new()
	v.add_child(r2)
	r2.add_child(_label("2.  Map (.fld):"))
	menu_field = OptionButton.new()
	menu_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_field.focus_mode = Control.FOCUS_NONE
	menu_field.fit_to_longest_item = false
	r2.add_child(menu_field)
	_button(r2, "Browse...", func(): fld_dialog.popup_centered_ratio(0.7))
	menu_note = _label("")
	menu_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	menu_note.add_theme_color_override("font_color", Color(0.85, 0.8, 0.6))
	v.add_child(menu_note)
	var r3 := HBoxContainer.new()
	v.add_child(r3)
	_button(r3, "Build event", _on_build)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r3.add_child(spacer)
	_button(r3, "Close", hide_start_menu)

func _build_busy(root: Control) -> void:
	busy = CenterContainer.new()
	busy.set_anchors_preset(Control.PRESET_FULL_RECT)
	busy.mouse_filter = Control.MOUSE_FILTER_STOP     # blocks the controls while working
	busy.visible = false
	root.add_child(busy)
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.14, 0.16)
	style.set_content_margin_all(12)
	box.add_theme_stylebox_override("panel", style)
	busy.add_child(box)
	var v := VBoxContainer.new()
	box.add_child(v)
	busy_label = _label("")
	busy_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(busy_label)
	busy_bar = ProgressBar.new()
	v.add_child(busy_bar)

func _build_dialogs() -> void:
	replay_dialog = FileDialog.new()
	replay_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	replay_dialog.access = FileDialog.ACCESS_FILESYSTEM
	replay_dialog.filters = PackedStringArray(["*.yfs ; YSFlight replays"])
	replay_dialog.use_native_dialog = true
	replay_dialog.title = "Replays of ONE event (several players' files are merged)"
	replay_dialog.current_dir = ProjectSettings.globalize_path("res://Raw_Data")
	replay_dialog.files_selected.connect(_on_replays_picked)
	add_child(replay_dialog)
	event_dialog = FileDialog.new()
	event_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	event_dialog.access = FileDialog.ACCESS_FILESYSTEM
	event_dialog.filters = PackedStringArray(["*.json ; Event files"])
	event_dialog.use_native_dialog = true
	event_dialog.title = "Open an event built earlier"
	event_dialog.current_dir = ProjectSettings.globalize_path("res://events")
	event_dialog.file_selected.connect(open_event.emit)
	add_child(event_dialog)
	fld_dialog = FileDialog.new()
	fld_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fld_dialog.access = FileDialog.ACCESS_FILESYSTEM
	fld_dialog.filters = PackedStringArray(["*.fld ; YSFlight maps"])
	fld_dialog.use_native_dialog = true
	fld_dialog.title = "The map (.fld) the replays were flown on"
	fld_dialog.current_dir = ProjectSettings.globalize_path("res://gamefiles")
	fld_dialog.file_selected.connect(_on_fld_picked)
	add_child(fld_dialog)

func _layout() -> void:
	# the side panel sits between the bars; the info text just above the bottom bar
	side_panel.offset_top = top_bar.size.y
	side_panel.offset_bottom = -bottom_bar.size.y
	info.offset_bottom = -bottom_bar.size.y - 6
	layout_changed.emit()

# --- lists ---

func _fill_pilots(data: Dictionary) -> void:
	pilots.clear()
	var root := pilots.create_item()
	var kills_by = {}
	var lost_by = {}
	for k in data.get("kills", []):
		var kr = k.get("killer_ref")
		if kr != null and kr["kind"] == "aircraft":
			var p = _entities.get(str(int(kr["id"])), {}).get("player", "?")
			kills_by[p] = kills_by.get(p, 0) + 1
	var teams = {}
	for id in _entities:
		var e = _entities[id]
		if e.get("telemetry", []).is_empty():
			continue
		var team := int(e.get("iff", 0))
		if team != 1 and team != 4:
			team = 0
		if not teams.has(team):
			teams[team] = {}
		if not teams[team].has(e["player"]):
			teams[team][e["player"]] = []
		teams[team][e["player"]].append(e)
		if e.get("fate", {}).get("kind", "") in DEATHS:
			lost_by[e["player"]] = lost_by.get(e["player"], 0) + 1
	for team in [1, 4, 0]:
		if not teams.has(team):
			continue
		var t_item := pilots.create_item(root)
		t_item.set_text(0, "%s  -  %d pilots" % [TEAM_NAMES[team], teams[team].size()])
		t_item.set_custom_color(0, Main.iff_color(team).lightened(0.35))
		t_item.set_selectable(0, false)
		var names = teams[team].keys()
		names.sort_custom(_players_first)      # people first, then the server's AI aircraft
		for pname in names:
			var sorties = teams[team][pname]
			sorties.sort_custom(func(a, b): return a["telemetry"][0]["t"] < b["telemetry"][0]["t"])
			var p_item := pilots.create_item(t_item)
			p_item.set_text(0, "%s   %d sorties, %d K, %d lost" % [pname, sorties.size(),
				kills_by.get(pname, 0), lost_by.get(pname, 0)])
			p_item.set_selectable(0, false)
			p_item.collapsed = true
			for e in sorties:
				var s_item := pilots.create_item(p_item)
				var fate: Dictionary = e.get("fate", {})
				s_item.set_text(0, "%s%s-%s  %s  %s" % ["CHECK  " if fate.get("check", false) else "",
					Fmt.clock(e["telemetry"][0]["t"]), Fmt.clock(e["telemetry"][-1]["t"]),
					Fmt.short_type(e["aircraft"]), fate_text(fate)])
				if fate.get("check", false):
					s_item.set_custom_color(0, CHECK_COLOR)
				s_item.set_metadata(0, str(int(e["id"])) if e.has("id") else "")
				var tip := fate_details(fate)
				var src = e.get("source", {})
				if not src.is_empty():
					tip += "\nTrack from %s%s" % [src.get("file", "?"),
						" (the pilot's own recording)" if src.get("own", false) else
						" (seen from that game, %.2f s delay removed)" % src.get("delay", 0.0)]
				s_item.set_tooltip_text(0, tip.strip_edges())

func _fill_kills(data: Dictionary) -> void:
	kills_tree.clear()
	var root := kills_tree.create_item()
	for k in data.get("kills", []):
		var item := kills_tree.create_item(root)
		var text := "%s%s (%d s)  %s  %s ->  %s" % ["CHECK  " if k.get("check", false) else "",
			Fmt.clock(k["t"]), int(k["t"]), _ref_name(k.get("killer_ref")), Fmt.weapon(k["name"]),
			_ref_name(k.get("victim_ref"))]
		if k.has("confidence"):
			text += "  %d%%" % roundi(k["confidence"] * 100.0)
		var notes := []
		if k.get("other_claims", []).size() > 0:
			notes.append("disputed")
		if not k.get("verified", true):
			notes.append("death not seen")
		if notes.size() > 0:
			text += "  (" + ", ".join(notes) + ")"
		item.set_text(0, text)
		item.set_custom_color(0, CHECK_COLOR if k.get("check", notes.size() > 0)
			else Main.iff_color(_ref_iff(k.get("killer_ref"))).lightened(0.45))
		item.set_metadata(0, k)
		var tip := "Credit from %s; recorded in %d of %d games that were there" % [
			k.get("basis", "the replay"), k.get("seen_by", 1), maxi(int(k.get("covered_by", 1)), 1)]
		for c in k.get("other_claims", []):
			tip += "\nAlso claimed: %s  %s  (%d games)" % [_ref_name(c.get("killer_ref")),
				Fmt.weapon(c["name"]), c.get("recorded_in", []).size()]
		if k.has("reconstructed"):
			tip += "\nMissile path " + ("re-flown to the kill" if k["reconstructed"] else "could not be reproduced")
		if k.has("evidence"):
			tip += "\n\nHow sure (%d%%):" % roundi(k.get("confidence", 0.0) * 100.0)
			for ev in k["evidence"]:
				tip += "\n  " + ev
		item.set_tooltip_text(0, tip)
	var unconfirmed = data.get("unconfirmed_kills", [])
	if unconfirmed.size() > 0:
		var head := kills_tree.create_item(root)
		head.set_text(0, "Unconfirmed credits (%d): the victim did not go down then" % unconfirmed.size())
		head.set_selectable(0, false)
		head.collapsed = true
		for k in unconfirmed:
			var item := kills_tree.create_item(head)
			item.set_text(0, "%s  %s  %s ->  %s" % [Fmt.clock(k["t"]), _ref_name(k.get("killer_ref")),
				Fmt.weapon(k["name"]), _ref_name(k.get("victim_ref"))])
			item.set_custom_color(0, Color(0.6, 0.6, 0.6))
			item.set_metadata(0, k)
			item.set_tooltip_text(0, "Recorded in %d game(s): %s" % [k.get("recorded_in", []).size(),
				k.get("reason", "")])

# Every sortie's ending in time order: deaths and leaves first (CHECK = worth a scorer's look),
# then the harmless ones (left on the ground, still there at the end) folded away.
func _fill_deaths(data: Dictionary) -> void:
	deaths_tree.clear()
	var root := deaths_tree.create_item()
	var ends := []
	for id in _entities:
		var fate: Dictionary = _entities[id].get("fate", {})
		if not fate.is_empty() and fate.get("kind", "") != "none":
			ends.append([float(fate.get("t", 0.0)), id])
	ends.sort_custom(func(a, b): return a[0] < b[0])
	var quiet := []
	for pair in ends:
		if _entities[pair[1]]["fate"].get("kind", "") in ["end", "ground_exit"]:
			quiet.append(pair)
		else:
			_death_item(root, pair)
	if not quiet.is_empty():
		var group := deaths_tree.create_item(root)
		group.set_text(0, "Left on the ground or still there at the end (%d)" % quiet.size())
		group.set_selectable(0, false)
		group.collapsed = true
		for pair in quiet:
			_death_item(group, pair)

func _death_item(parent: TreeItem, pair: Array) -> void:
	var e = _entities[pair[1]]
	var fate: Dictionary = e["fate"]
	var item := deaths_tree.create_item(parent)
	item.set_text(0, "%s%s (%d s)  %s (%s):  %s" % ["CHECK  " if fate.get("check", false) else "",
		Fmt.clock(pair[0]), int(pair[0]), e["player"], Fmt.short_type(e["aircraft"]), fate_text(fate)])
	item.set_custom_color(0, CHECK_COLOR if fate.get("check", false)
		else Main.iff_color(int(e.get("iff", 0))).lightened(0.45))
	item.set_metadata(0, [str(pair[1]), pair[0]])
	item.set_tooltip_text(0, fate_details(fate))

func _on_death_item() -> void:
	var item := deaths_tree.get_selected()
	var m = item.get_metadata(0)
	if m != null:
		_show_details(item.get_text(0), item.get_tooltip_text(0))
		death_chosen.emit(m[0], m[1])

func _show_details(title: String, text: String) -> void:
	details.text = title + "\n\n" + text
	details.visible = true
	details.scroll_to_line(0)

func _fill_files(data: Dictionary) -> void:
	var text := ""
	var sources = data.get("sources", [])
	if sources.is_empty():
		text = "Older event file: no details about the replay files."
	for s in sources:
		if s.get("included", false):
			text += "[color=#7fdc8a]USED[/color]  %s\n   recorded by %s, %s-%s, delay %.2f s, %d sorties taken\n   %s\n" % [
				s["file"], s.get("recorded_by", "?"), Fmt.clock(s.get("from", 0.0)), Fmt.clock(s.get("to", 0.0)),
				s.get("delay", 0.0), s.get("sorties_used", 0), s.get("check", "")]
		else:
			text += "[color=#e08a7a]LEFT OUT[/color]  %s\n   recorded by %s: %s\n" % [
				s["file"], s.get("recorded_by", "?"), s.get("reason", "")]
	files_text.text = text

func _draw_ticks() -> void:
	var w := ticks.size.x
	var span := _t_max - _t_min
	for m in _kill_marks:
		var x: float = (m[0] - _t_min) / span * w
		ticks.draw_line(Vector2(x, 0), Vector2(x, ticks.size.y), m[1], 2.0)

# --- input handlers ---

func _ask_replays() -> void:
	replay_dialog.popup_centered_ratio(0.7)

func _ask_event() -> void:
	event_dialog.popup_centered_ratio(0.7)

func _on_replays_picked(paths: PackedStringArray) -> void:
	menu_replays = paths
	var names := []
	for p in paths:
		names.append(p.get_file())
	menu_replays_label.text = "%d file(s): %s" % [paths.size(), ", ".join(names)]
	# pick the map the replay itself names (its FIELDNAM line)
	var field := _replay_field(paths[0])
	var found := -1
	for n in fields.size():
		if fields[n][0].to_upper() == field.to_upper():
			found = n
	if found >= 0:
		menu_field.select(found)
		menu_note.text = "The replays were flown on %s." % field
	else:
		menu_note.text = "The replays name the map %s, which is not in the scenery lists: pick its .fld with Browse..." % field

func _on_fld_picked(path: String) -> void:
	for n in fields.size():
		if fields[n][1] == path:
			menu_field.select(n)
			return
	fields.append([path.get_file().get_basename(), path])
	menu_field.add_item("%s   (%s)" % [path.get_file(), path.get_base_dir()])
	menu_field.select(fields.size() - 1)

func _on_build() -> void:
	if menu_replays.is_empty():
		menu_note.text = "Choose the replay files first."
		return
	if menu_field.selected < 0 or menu_field.selected >= fields.size():
		menu_note.text = "Choose the map (.fld) first."
		return
	hide_start_menu()
	open_replays.emit(menu_replays, fields[menu_field.selected][1])

# The fields in the game files' scenery lists (sce*.lst lines: "<field> <.fld> <.stp> ..."),
# paths relative to the game files folder.
func _scan_fields() -> void:
	fields.clear()
	var base := ProjectSettings.globalize_path("res://gamefiles")
	_scan_dir(base, base)
	menu_field.clear()
	for f in fields:
		menu_field.add_item("%s   (%s)" % [f[0], f[1].get_file()])
	menu_field.select(-1)

func _scan_dir(dir: String, base: String) -> void:
	var re := RegEx.new()
	re.compile("\"[^\"]*\"|\\S+")
	for f in DirAccess.get_files_at(dir):
		var low := f.to_lower()
		if not (low.begins_with("sce") and low.ends_with(".lst")):
			continue
		for line in FileAccess.get_file_as_string(dir.path_join(f)).split("\n"):
			var a := []
			for m in re.search_all(line):
				a.append(m.get_string().trim_prefix("\"").trim_suffix("\""))
			if a.size() < 2 or a[0].begins_with("#"):
				continue
			var fld := base.path_join(a[1])
			if FileAccess.file_exists(fld) and fields.all(func(x): return x[0] != a[0]):
				fields.append([a[0], fld])
	for d in DirAccess.get_directories_at(dir):
		_scan_dir(dir.path_join(d), base)

# The map a replay was flown on: its "FIELDNAM <field> ..." line, near the top.
static func _replay_field(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	for i in 40:
		if f.eof_reached():
			break
		var line := f.get_line()
		if line.begins_with("FIELDNAM"):
			var a := line.split(" ", false)
			return a[1] if a.size() > 1 else ""
	return ""

func _on_view_slider(value: float, key: String) -> void:
	_show_view_value(key, value)
	view_changed.emit(key, value)

func _show_view_value(key: String, value: float) -> void:
	for s in VIEW_SLIDERS:
		if s[0] == key:
			view_values[key].text = s[5] % value

func toggle_panel() -> void:
	set_panel_visible(not side_panel.visible)
	panel_toggled.emit(side_panel.visible)

func set_panel_visible(shown: bool) -> void:
	side_panel.visible = shown
	panel_button.text = "Hide panel (P)" if shown else "Show panel (P)"
	_layout()

func _back_10() -> void:
	step.emit(-10.0)

func _forward_10() -> void:
	step.emit(10.0)

func _on_go() -> void:
	_on_jump(jump_edit.text)

func _on_jump(text: String) -> void:
	var t := Fmt.parse_time(text)
	if t >= 0.0:
		seek_requested.emit(t)
	jump_edit.release_focus()

func _on_speed_item(i: int) -> void:
	speed_edit.text = ""
	speed_changed.emit(SPEEDS[i])

func _on_speed_text(text: String) -> void:
	var v := text.strip_edges().trim_suffix("x").to_float()
	if v > 0.0:
		speed_menu.select(-1)
		speed_changed.emit(clampf(v, 0.01, 512.0))
	speed_edit.release_focus()

func _on_pilot_item() -> void:
	var item := pilots.get_selected()
	var id = item.get_metadata(0)
	if id != null and str(id) != "":
		_show_details(item.get_text(0), item.get_tooltip_text(0))
		aircraft_chosen.emit(str(id))

func _on_kill_item() -> void:
	var item := kills_tree.get_selected()
	var k = item.get_metadata(0)
	if k != null:
		_show_details(item.get_text(0), item.get_tooltip_text(0))
		kill_chosen.emit(k)

# --- helpers ---

func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE     # keyboard shortcuts stay with the viewer
	b.pressed.connect(action)
	parent.add_child(b)
	return b

func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l

func _tip(c: Control, text: String) -> Control:
	c.tooltip_text = text
	return c

func _ref_iff(ref):
	if ref == null:
		return null
	if ref["kind"] == "aircraft":
		return _entities.get(str(int(ref["id"])), {}).get("iff")
	return _grounds[int(ref["index"])].get("iff")

func _ref_name(ref) -> String:
	if ref == null:
		return "?"
	if ref["kind"] == "aircraft":
		return _entities.get(str(int(ref["id"])), {}).get("player", "?")
	var g = _grounds[int(ref["index"])]
	return g["name"] if g["name"] != "" else g["type"]

static func _players_first(a: String, b: String) -> bool:
	var ai_a := a.begins_with("[AI]")
	var ai_b := b.begins_with("[AI]")
	if ai_a != ai_b:
		return ai_b
	return a.to_lower() < b.to_lower()

static func _speed_text(s: float) -> String:
	return ("%sx" % str(s)).replace(".0x", "x")
