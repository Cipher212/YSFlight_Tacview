extends SceneTree

const Fmt = preload("res://fmt.gd")
const DnmModel = preload("res://dnm_model.gd")
# Logic checks of the viewer against the made-up test event (tools/make_test_replay.py):
#     TEST_EVENT=/abs/path/test.json.gz godot --headless --path . --script tools/test_viewer.gd
# Deletes the event's review file first (KEEP_REVIEW=1: keeps it). Exit code 1 if a check fails.

var main
var fails := 0

func check(ok: bool, what: String) -> void:
	print(("  ok    " if ok else "  FAIL  ") + what)
	if not ok:
		fails += 1

func _init():
	main = load(get_script().resource_path.get_base_dir().path_join("test_main.gd")).new()
	root.add_child(main)
	await process_frame
	var event: String = OS.get_environment("TEST_EVENT")
	var review_file := "%s.review.txt" % event.trim_suffix(".gz").trim_suffix(".json")
	if OS.get_environment("KEEP_REVIEW") == "":
		DirAccess.remove_absolute(review_file)
	main.load_event(event)
	var waited := 0
	while main.event_data == null and waited < 600:
		await process_frame
		waited += 1
	check(main.event_data != null, "event loaded from %s" % event.get_file())
	if main.event_data == null:
		quit(1)
		return
	var ui = main.ui
	var combat = main.combat

	print("weapon models:")
	var used := {}
	for w in main.event_data["weapons"]:
		if w.get("_model", "") != "":
			used[w["_model"].get_file()] = used.get(w["_model"].get_file(), 0) + 1
	print("    ", used)
	check(used.has("AIM-120B.srf"), "the F-16's AIM-120 uses AIM-120B.srf (its WPNSHAPE)")
	check(used.has("AIM-9L.srf"), "the F-15's AIM-9 uses AIM-9L.srf (WPNSHAPE names AIM-9.srf, not in the pack)")
	check(used.has("R-60.srf"), "the Su-25's AIM-9 uses R-60.srf")
	check(used.has("AGM-114A.srf"), "the A-10's AGM-65 uses AGM-114A.srf")
	check(used.has("CBU-59.srf") and used.has("Mk81.srf"), "the A-10's bombs use CBU-59 / Mk81")
	check(used.has("bomb500hd.srf"), "a high-drag bomb (no WPNSHAPE) uses the stock bomb500hd.srf")
	check(used.has("M261.srf"), "the A-10's rockets use M261.srf")
	check(used.has("AmericanFuelTank.srf"), "the F-16's dropped tank uses AmericanFuelTank.srf")
	check(combat.shapes.size() == 4 + used.size(), "one MultiMesh per model in use (%d)" % (combat.shapes.size() - 4))

	print("trails:")
	var styles := {}
	for w in combat.path_weapons:
		styles[w["name"]] = w["_trail"]
	check(styles.get("AIM120") == combat.Trail.SOLID and styles.get("AIM9") == combat.Trail.SOLID, "air-to-air: solid")
	check(styles.get("AGM65") == combat.Trail.DASHED, "air-to-ground: dashed")
	check(styles.get("BOMB500") == combat.Trail.DOTTED and styles.get("FUELTANK") == combat.Trail.DOTTED, "bombs, fuel tank: dotted")
	check(styles.get("FLARE") == combat.Trail.SOLID, "flares: short solid spark")

	print("markers (stay 30 s):")
	main.seek(200.0)
	await process_frame
	var ends: MultiMesh = combat.ends
	var in_window := 0
	for m in combat.end_marks:
		if m[0] <= 200.0 and m[0] >= 170.0:
			in_window += 1
	check(ends.visible_instance_count == in_window, "at 3:20 the %d weapon ends of the last 30 s show (%d)" % [in_window, ends.visible_instance_count])
	main._on_view_changed("marker_seconds", 300.0)
	await process_frame
	var all_before := 0
	for m in combat.end_marks:
		if m[0] <= 200.0:
			all_before += 1
	check(ends.visible_instance_count == all_before, "stay 300 s: all %d up to now (%d)" % [all_before, ends.visible_instance_count])
	main._on_view_changed("marker_seconds", 30.0)
	main.seek(530.0)
	await process_frame
	check(ends.visible_instance_count == 0 and combat.crosses.visible_instance_count == 0, "near the end, old markers are gone")

	print("ribbon width vs aircraft size:")
	var mat: ShaderMaterial = main.ribbons.material
	var w0: float = mat.get_shader_parameter("half_width")
	main._on_view_changed("aircraft_scale", 50.0)
	check(is_equal_approx(mat.get_shader_parameter("half_width"), w0), "aircraft size 50x leaves the ribbons %.1f m wide" % w0)
	main._on_view_changed("ribbon_width", 3.0)
	check(is_equal_approx(mat.get_shader_parameter("half_width"), w0 * 3.0), "ribbon width 3x makes them 3x wider")
	main._on_view_changed("aircraft_scale", 1.0)
	main._on_view_changed("ribbon_width", 1.0)

	print("lists, messages, loadouts:")
	check(ui.kills_tree.get_root().get_child_count() >= 3, "kills listed")
	var msgs := 0
	for it in ui.messages_tree.get_root().get_children():
		msgs += 1
	check(msgs == main.event_data["events"].size() and msgs >= 3, "Chat tab: %d messages" % msgs)
	var tip := ""
	for id in ui._pilot_items:
		tip += ui._pilot_items[id].get_tooltip_text(0)
	check(tip.contains("Loadout at 0:00: AIM-120 x4, AIM-9 x2, external fuel 1600, gun 510 rounds, flare x60"), "loadout shown for Tester's sortie")
	check(tip.contains("500 lb bomb x2") and tip.contains("rocket x19"), "Striker's loadout: bombs, rockets")
	ui.search.text = "bandit3"
	ui._refill()
	var shown := []
	for it in ui.kills_tree.get_root().get_children():
		shown.append(it.get_text(0))
	check(shown.size() == 1 and shown[0].contains("Bandit3"), "search 'bandit3': only its kill (%s)" % str(shown))
	ui.search.text = ""
	ui._refill()

	print("jumping:")
	main.seek(0.0)
	await process_frame
	ui.jump_kill(1)
	await process_frame
	var first: String = ui._selected
	check(first == ui._kill_order[0], "N from the start: the first kill (%s at %.1f)" % [first, ui._items[first]["t"]])
	check(absf(main.replay_time - (ui._items[first]["t"] - 5.0)) < 0.01, "replay 5 s before it")
	ui.jump_kill(1)
	await process_frame
	check(ui._selected == ui._kill_order[1], "N again: the second kill")
	ui.jump_kill(-1)
	await process_frame
	check(ui._selected == ui._kill_order[0], "Shift+N: back to the first")
	check(ui.kills_tree.get_selected() != null and ui.kills_tree.get_selected().get_metadata(0) == ui._selected, "it is selected in the Kills list")

	print("review:")
	var kid: String = ui._kill_order[0]
	ui._open(kid)
	ui._toggle_status("confirmed")
	check(ui.review.status(kid) == "confirmed", "Confirm marks the kill")
	check(ui._tree_items[kid].get_text(0).begins_with("CONFIRMED"), "its line starts with CONFIRMED")
	ui.note_edit.text = "saw the missile hit, checked from both sides"
	ui._on_note_changed("")
	await create_timer(1.2).timeout   # the note is saved once typing pauses (0.8 s)
	check(ui.review.note(kid) == "saw the missile hit, checked from both sides", "the note is saved")
	check(FileAccess.file_exists(review_file), "review file written: %s" % review_file.get_file())
	var did := "d" + str(int(main.event_data["kills"][0]["victim_ref"]["id"]))
	ui._open(did)
	ui._toggle_status("rejected")
	check(ui.review.status(did) == "rejected", "Reject marks the death")
	check(ui.deaths_tree.get_selected() != null, "the Deaths tab shows it selected")
	ui._toggle_status("rejected")
	check(ui.review.status(did) == "", "pressing Reject again undoes it")
	ui._toggle_status("rejected")
	print("    summary: ", ui.review_label.text)
	var to_review_before: int = ui._check_order.filter(func(id): return ui.review.status(id) == "").size()
	main.seek(0.0)
	await process_frame
	ui._selected = ""
	ui.jump_check(1)
	await process_frame
	check(to_review_before == 0 or (ui._selected in ui._check_order and ui.review.status(ui._selected) == ""), "C: the first CHECK still to review (%s)" % ui._selected)
	ui.show_filter.select(ui.Show.CONFIRMED)
	ui._refill()
	check(ui.kills_tree.get_root().get_child_count() == 1, "filter Confirmed: 1 kill listed")
	ui.show_filter.select(ui.Show.ALL)
	ui._refill()

	print("ground objects:")
	var gl = main.grounds
	var destroyed := []
	var standing := []
	for n in main.event_data["ground_objects"].size():
		var g: Dictionary = main.event_data["ground_objects"][n]
		if g.get("destroyed_t") != null:
			destroyed.append(n)
		elif g["type"] == "[GOP]SAM":
			standing.append(n)
	check(destroyed.size() >= 1, "%d ground object(s) destroyed" % destroyed.size())
	for n in destroyed:
		var item: Dictionary = gl.items[n]
		var t_d: float = main.event_data["ground_objects"][n]["destroyed_t"]
		main.seek(t_d - 5.0)
		await process_frame           # (process_frame comes before the viewer's _process:
		await process_frame           # the second one sees the frame drawn at the new time)
		var before: bool = item["dead"]
		main.seek(t_d + 5.0)
		await process_frame
		await process_frame
		# (headless Godot keeps no drawing data, so the despawn itself shows only in screenshots)
		check(not before and item["dead"],
			"%s drawn before %s, gone after" % [main.event_data["ground_objects"][n]["type"], Fmt.clock(t_d)])
	for n in standing:
		main.seek(400.0)
		await process_frame
		await process_frame
		var why := ""
		for id in ui._items:
			if ui._items[id]["kind"] == "claim" and ui._items[id]["about"]["victim"] == "[GOP]SAM":
				why = ui._items[id]["details"]
		if why == "":
			continue                  # (a test event without the false SAM kill)
		check(not gl.items[n]["dead"], "the SAM with a false kill credit is still drawn at 6:40")
		check(why.contains("fired"), "its credit is unconfirmed, with why: " + why.replace("\n", " / "))

	print("shadows:")
	main.seek(250.0)
	await process_frame
	await process_frame
	var n_shadows := get_nodes_in_group("aircraft_shadow").size()
	check(main.aircraft_shadows.size() == main.active_aircraft.size() and n_shadows > main.active_aircraft.size(),
		"every aircraft has a shadow (%d shadow parts)" % n_shadows)
	var some_id: String = main._in_air_now()[0]
	var sp: Vector3 = main.aircraft_shadows[some_id].get_shader_parameter("ground_point")
	var pos: Vector3 = main.active_aircraft[some_id].position
	var ground: Array = main.map_node.ground_at(pos.x, pos.z)
	check(is_equal_approx(sp.y, ground[0]) and is_equal_approx(sp.x, pos.x), "its ground point is under it (%.0f m, aircraft at %.0f m)" % [sp.y, pos.y])
	check(main.map_node.ground_at(22500.0, -15600.0)[0] > 100.0 and main.map_node.ground_at(0.0, 0.0)[0] == 0.0,
		"ground height: the island %.0f m, the sea 0 m" % main.map_node.ground_at(22500.0, -15600.0)[0])
	main._on_view_changed("shadows", false)
	check(get_nodes_in_group("aircraft_shadow").all(func(x): return not x.visible), "the View switch hides them")
	main._on_view_changed("shadows", true)

	print("Ground tab:")
	var gt: Tree = ui.ground_tree
	var lines := []
	var t80_id := ""
	for team_item in gt.get_root().get_children():
		for type_item in team_item.get_children():
			lines.append(type_item.get_text(0))
			for it in type_item.get_children():
				lines.append(it.get_text(0))
				if it.get_text(0).contains("T-80U #1 destroyed"):
					t80_id = str(it.get_metadata(0))
	var all_text := "\n".join(lines)
	check(all_text.contains("[GOP]T-80U   1 of 1 destroyed"), "type line: [GOP]T-80U 1 of 1 destroyed")
	check(t80_id != "" and all_text.contains("T-80U #1 destroyed  by [BLUE]Striker (AGM-65)"),
		"the tank: destroyed at 2:05 by [BLUE]Striker (AGM-65)")
	check(all_text.contains("[GOP]SAM #1  still there: 1 unconfirmed credit") or not all_text.contains("[GOP]SAM #1"),
		"the SAM: still there, with its unconfirmed credit")
	if t80_id != "":
		ui._ground_items[t80_id]
		ui.tabs.current_tab = ui.tabs.get_tab_idx_from_control(gt)
		for team_item in gt.get_root().get_children():
			for type_item in team_item.get_children():
				for it in type_item.get_children():
					if str(it.get_metadata(0)) == t80_id:
						it.select(0)
		await process_frame
		await process_frame
		var gi: Dictionary = ui._ground_items[t80_id]
		check(absf(main.replay_time - (gi["t"] - 5.0)) < 0.01 and main.tracked_id == "",
			"clicking it: 5 s before, free camera (%.1f)" % main.replay_time)
		check(ui.details.text.contains("How it was decided:") and ui.details.text.contains("Game data: strength"),
			"its details: how it was decided, game data")

	print("health and damage:")
	main.seek(150.0)
	await process_frame
	await process_frame
	var tester_id := ""
	for id in main.event_data["entities"]:
		if main.event_data["entities"][id]["player"] == "[BLUE]Tester":
			tester_id = id
	main._tag_clock = 1.0
	await process_frame
	await process_frame
	check(main.aircraft_tags[tester_id].text.contains("Health 40/40"), "Tester's tag at 2:30: Health 40/40")
	main.seek(210.0)
	main._tag_clock = 1.0
	await process_frame
	await process_frame
	check(main.aircraft_tags[tester_id].text.contains("Health 35/40"), "after Bandit3's gun hits: Health 35/40")
	var tip_all := ""
	for id in ui._pilot_items:
		tip_all += ui._pilot_items[id].get_tooltip_text(0) + "\n"
	check(tip_all.contains("Damage:") and tip_all.contains("round(s) from [RED]Bandit3"),
		"damage log: the gun rounds from Bandit3")
	check(tip_all.contains("pulling 11.8 G"), "damage log: Wingman's over-G")
	check(tip_all.contains("Nearest ground object then:"), "crash finder: Bandit2's crash lists the nearest ground object")
	var seen_kill := false
	for id in ui._kill_order:
		if ui._items[id]["details"].contains("as the shooter's game showed the victim"):
			seen_kill = true
	var two_files: bool = main.event_data.get("sources", []).filter(func(x): return x.get("included", false)).size() >= 2
	check(seen_kill == two_files, "Striker's kill re-flown only as Bandit2's game saw it (%s)" %
		("two replays" if two_files else "one replay: not possible"))

	print("smoke and keys:")
	var down := 0
	for id in main.event_data["entities"]:
		var e: Dictionary = main.event_data["entities"][id]
		if e.get("death_t") != null:
			down += 1
	check(main.ribbons.smoke_node.get_child_count() == down,
		"smoke only behind the %d aircraft that went down for good (Wingman's false tumble: none) (%d)" % [down, main.ribbons.smoke_node.get_child_count()])
	ui.search.grab_focus()
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.pressed = true
	var before_id: String = main.tracked_id
	Input.parse_input_event(tab)
	await process_frame
	await process_frame
	check(root.gui_get_focus_owner() == null and main.tracked_id != before_id and main.tracked_id != "",
		"Tab in the search box: leaves it and switches aircraft (%s)" % main.tracked_id)
	var p_key := InputEventKey.new()
	p_key.keycode = KEY_P
	p_key.pressed = true
	var panel_was: bool = ui.side_panel.visible
	Input.parse_input_event(p_key)
	await process_frame
	await process_frame
	check(ui.side_panel.visible != panel_was, "P then hides / shows the panel, not typed anywhere")
	ui.set_panel_visible(true)

	print("range rings:")
	check(gl.ring_nodes.size() == 2 and gl.ring_nodes.all(func(x): return not x.visible), "two ring layers, hidden at first")
	var n_rings := 0
	for item in gl.items:
		n_rings += item["rings"].size()
	check(n_rings >= 2, "%d rings (the SAM's missiles, the tank's gun ...)" % n_rings)
	main._on_view_changed("ranges", true)
	check(gl.ring_nodes.all(func(x): return x.visible), "the View switch shows them")
	main._on_view_changed("ranges", false)

	print("top view:")
	main.follow(tester_id)
	main.set_top_view(true)
	await process_frame
	await process_frame
	check(main.camera.projection == Camera3D.PROJECTION_ORTHOGONAL and main.camera.global_transform.basis.z.y > 0.99,
		"T: straight down, no perspective")
	var tp: Vector3 = main.active_aircraft[tester_id].position
	check(absf(main.camera.position.x - tp.x) < 1.0 and absf(main.camera.position.z - tp.z) < 1.0,
		"centred on the aircraft it follows")
	var scale_now: float = main.aircraft_models[tester_id].basis.get_scale().x
	check(scale_now > 1.5, "aircraft drawn bigger from above (x%.1f)" % scale_now)
	main.tracked_id = ""
	var screen: Vector2 = main.camera.unproject_position(main.active_aircraft[tester_id].global_position)
	main._pick(screen + Vector2(3, 2))
	check(main.tracked_id == tester_id, "clicking it in the top view follows it")
	main.set_top_view(false)
	await process_frame
	check(main.camera.projection == Camera3D.PROJECTION_PERSPECTIVE, "T again: back to 3D")

	print("better lighting:")
	var terrain: Array = main.map_node._terrain
	check(terrain.size() == 2 and terrain[1].visible and not terrain[0].visible, "on at first: the relief-shaded terrain")
	main._on_view_changed("lighting", false)
	check(terrain[0].visible and not terrain[1].visible and is_equal_approx(DnmModel._materials[0].roughness, 1.0),
		"off: YSFlight's daylight, matt models")
	main._on_view_changed("lighting", true)

	print("a whole event from a folder:")
	var dir := OS.get_user_data_dir().path_join("test_folder_pick")
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	var src := event.get_base_dir()
	var yfs := Array(DirAccess.get_files_at(src)).filter(func(f): return f.ends_with(".yfs"))
	for k in yfs.size():
		DirAccess.copy_absolute(src.path_join(yfs[k]), dir.path_join("RvB_20260718_%d.yfs" % k))
	DirAccess.copy_absolute(src.path_join(yfs[0]), dir.path_join("practice_2026-07-11.yfs"))
	ui._on_folder_picked(dir)
	check(ui.menu_groups.item_count == 2 and ui.menu_replays.size() == yfs.size(),
		"2 events found; the newest (2026-07-18, %d replays) chosen: %s" % [yfs.size(), ui.menu_groups.get_item_text(0)])
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)

	print("cinematic mode:")
	var cin = main.cinema
	main.follow(tester_id)
	main.seek(58.0)
	main.set_playing(true)
	await process_frame
	var m_key := InputEventKey.new()
	m_key.keycode = KEY_M
	m_key.pressed = true
	Input.parse_input_event(m_key)
	await process_frame
	await process_frame
	check(cin.on and not ui.visible, "M: cinematic mode on, the side panel and bars hidden")
	check(cin.shot == cin.Shot.ORBIT and absf(main.camera.global_position.distance_to(
		main.active_aircraft[tester_id].position) - main.cam_distance) < 0.15 * main.cam_distance,
		"it starts in the orbit, where the viewer's camera was (%.0f m, viewer %.0f m)" % [
		main.camera.global_position.distance_to(main.active_aircraft[tester_id].position), main.cam_distance])
	var tags_hidden := true
	for id in main.aircraft_tags:
		tags_hidden = tags_hidden and not main.aircraft_tags[id].visible
	check(tags_hidden and not main.vector_node.visible and combat.cinema and not combat.feed_layer.visible,
		"name tags, vectors, trails and kill feed hidden")
	check(not main.ribbons.get_child(0).visible and not main.ribbons.smoke_node.visible, "ribbons and black smoke ribbons hidden")
	if DisplayServer.get_name() != "headless":
		check(Input.mouse_mode == Input.MOUSE_MODE_HIDDEN, "mouse pointer hidden")
	check(main.keys.action_of(KEY_K, true) == "crane_point" and main.keys.action_of(KEY_K, false) == "pause",
		"K: a crane point in the cinematic mode, pause outside it")
	var dists := {}
	cin.set_shot(2)                    # (1 while in the chase picks the next kind of chase)
	for n in [1, 2, 5, 7]:
		cin.set_shot(n)
		for k in 6:
			await process_frame
		dists[n] = main.camera.global_position.distance_to(main.active_aircraft[tester_id].position)
	check(absf(dists[1] - 26.0) < 3.0 and absf(dists[2] - 40.0) < 4.0 and absf(dists[5] - 40.0) < 4.0,
		"chase %.0f m, wingman %.0f m, orbit %.0f m from the aircraft (it starts where the wingman was)" % [
		dists[1], dists[2], dists[5]])
	cin.set_shot(5)
	for k in 3:
		await process_frame
	var o0: Vector3 = (main.camera.global_position - main.active_aircraft[tester_id].position).normalized()
	var turn0: Vector3 = -main.aircraft_attitude[tester_id].z
	for k in 60:
		await process_frame
	var o1: Vector3 = (main.camera.global_position - main.active_aircraft[tester_id].position).normalized()
	check(rad_to_deg(o0.angle_to(o1)) < 0.5, "orbit: doesn't turn by itself (%.2f deg while the aircraft turned %.1f deg)" % [
		rad_to_deg(o0.angle_to(o1)), rad_to_deg(turn0.angle_to(-main.aircraft_attitude[tester_id].z))])
	cin._steer(Vector2(0.4, 0.0))
	for k in 30:
		await process_frame
	var o2: Vector3 = (main.camera.global_position - main.active_aircraft[tester_id].position).normalized()
	check(rad_to_deg(o1.angle_to(o2)) > 15.0, "orbit: steering turns it (%.0f deg)" % rad_to_deg(o1.angle_to(o2)))
	cin.key("smooth", false)
	check(not main.view["cine_smooth"] and cin._e(3.0, 0.016) == 1.0 and cin._k(3.0, 0.016) < 0.1,
		"B: smooth camera off (the camera's easing goes, the clock's stays)")
	cin.key("smooth", false)
	check(main.view["cine_smooth"] and cin._e(3.0, 0.016) < 0.1, "B again: smooth camera on")
	var t_key := InputEventKey.new()
	t_key.keycode = KEY_T
	t_key.pressed = true
	Input.parse_input_event(t_key)
	await process_frame
	await process_frame
	check(cin.on and main.top_view and main.camera.projection == Camera3D.PROJECTION_ORTHOGONAL and not ui.visible,
		"T: the top view inside the cinematic mode")
	var top_y: float = main.camera.global_position.y
	await process_frame
	check(main.camera.global_position.y > 50000.0 and absf(main.camera.global_position.y - top_y) < 1.0,
		"top view: the cinematic cameras leave it alone")
	cin.key("shot_5", false)
	await process_frame
	await process_frame
	check(not main.top_view and main.camera.projection == Camera3D.PROJECTION_PERSPECTIVE and main.camera.near < 0.2
		and main.camera.global_position.distance_to(main.active_aircraft[tester_id].position) < 5000.0,
		"a shot key: back to 3D, on that shot")
	check(cin._target != "" and main.event_data["entities"][cin._target]["iff"] != main.event_data["entities"][tester_id]["iff"],
		"lock-on: an enemy target (%s)" % main.event_data["entities"].get(cin._target, {}).get("player", "none"))
	main.seek(61.0)
	cin.set_shot(6)
	for k in 4:
		await process_frame
	check(cin._weapon != null and cin._weapon["name"] == "AIM120" and main.camera.global_position.distance_to(cin._weapon_pos) < 20.0,
		"weapon camera: rides behind Tester's AIM-120")
	check(cin.fx.last_trail_vertices > 0 and cin.fx.last_particles > 0, "its smoke trail and motor glow are drawn")
	main.seek(68.0)
	await process_frame
	await process_frame
	check(cin.fx.last_particles > 40, "the explosion at 1:07: %d particles" % cin.fx.last_particles)
	cin.set_shot(3)
	await process_frame
	await process_frame
	var spot: Vector3 = cin._spot
	var future: Vector3 = main.track_pos(tester_id, main.replay_time + cin.FLYBY_LEAD)
	check(absf(spot.distance_to(future) - cin.reach[3] * sqrt(1.0 + 0.04)) < 2.0,
		"flyby: the camera waits %.0f m off where the aircraft will be in %.1f s" % [spot.distance_to(future), cin.FLYBY_LEAD])
	cin.set_shot(4)
	for k in 4:
		await process_frame
	check(main.camera.global_position.distance_to(spot) < 1.0 and main.camera.fov < cin.fov,
		"ground camera: stays there, zoomed in on the aircraft (%.1f deg)" % main.camera.fov)
	# snap zoom and shake
	cin.set_shot(1)
	await process_frame
	var fov_before: float = main.camera.fov
	var z_key := InputEventKey.new()
	z_key.keycode = KEY_Z
	z_key.pressed = true
	Input.parse_input_event(z_key)
	await create_timer(0.6).timeout
	check(main.camera.fov < fov_before / 2.5, "hold Z: snap zoom (%.0f -> %.0f deg)" % [fov_before, main.camera.fov])
	z_key.pressed = false
	Input.parse_input_event(z_key)
	# network jitter (as YSFlight records an aircraft seen through the network: snapped a few metres
	# at each update, flown on between them) is smoothed out; only the flyby shakes
	var bandit3 := ""
	for id in main.event_data["entities"]:
		if main.event_data["entities"][id]["player"] == "[RED]Bandit3":
			bandit3 = id
	var b3: Array = main.telemetry_data[bandit3]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var err := Vector3.ZERO
	for k in b3.size():
		var tk: float = b3[k]["t"]
		if tk < 150.0 or tk > 200.0:
			continue
		if k % 2 == 0:                   # an update every 0.1 s: a new error of up to 4 m
			err = Vector3(rng.randf_range(-4.0, 4.0), rng.randf_range(-1.0, 1.0), rng.randf_range(-4.0, 4.0))
		b3[k]["x"] += err.x
		b3[k]["y"] += err.y
		b3[k]["z"] += err.z
	main.follow(bandit3)
	cin.set_shot(1)
	main.set_playing(false)
	cin.rate = 0.0
	var drawn := []
	var raw := []
	for k in 90:
		var tk := 170.0 + k / 60.0
		main.seek(tk)
		await process_frame          # (process_frame comes before the viewer's _process:
		await process_frame          # the second one sees the aircraft moved to the new time)
		drawn.append(main.active_aircraft[bandit3].position)
		raw.append(main._pos_at(b3, tk))
	var worst_drawn := 0.0
	var worst_raw := 0.0
	for k in range(1, 89):
		worst_drawn = maxf(worst_drawn, (drawn[k + 1] - drawn[k] * 2.0 + drawn[k - 1]).length())
		worst_raw = maxf(worst_raw, (raw[k + 1] - raw[k] * 2.0 + raw[k - 1]).length())
	check(worst_raw > 1.0 and worst_drawn < worst_raw / 50.0,
		"a jittery track (network updates) is drawn smoothly: %.3f m against %.1f m unsmoothed" % [worst_drawn, worst_raw])
	var shaken := false
	for n in [1, 2, 4, 5, 7]:
		cin.set_shot(n)
		main.set_playing(true)
		for k in 10:
			await process_frame
			shaken = shaken or not main.camera.global_transform.is_equal_approx(cin.base)
	check(not shaken, "no shake in the chase, wingman, ground camera, orbit or lock-on")
	main.follow(tester_id)
	main.seek(150.0)
	cin.set_shot(3)
	main.set_playing(true)
	var most := 0.0
	while main.replay_time < 150.0 + cin.FLYBY_LEAD + 0.6:
		await process_frame
		most = maxf(most, rad_to_deg(main.camera.global_transform.basis.z.angle_to(cin.base.basis.z)))
	check(most > 0.05, "the flyby shakes as the aircraft rushes past (up to %.2f deg)" % most)
	main.set_playing(false)
	# playing backwards the flyby camera stays put (it was set up afresh every frame: an earthquake)
	main.seek(160.0)
	cin.set_shot(3)
	main.set_playing(true)
	await create_timer(0.3).timeout
	main.rewind()
	var spot_was: Vector3 = cin._spot
	var moves := 0
	var t_back: float = main.replay_time
	while main.replay_time > t_back - 2.0:
		await process_frame
		if not cin._spot.is_equal_approx(spot_was):
			moves += 1
			spot_was = cin._spot
	check(moves <= 1, "playing backwards: the flyby camera set up again %d time(s) in 2 s (once at most)" % moves)
	main.set_playing(false)
	main.play_direction = 1
	# the still cameras aim at a track smoothed more: Bandit3's jittery track, seen from the ground
	main.follow(bandit3)
	main.seek(172.0)
	cin.rate = 0.0
	await process_frame
	await process_frame
	var b3_pos: Vector3 = main.active_aircraft[bandit3].position
	cin.set_shot(9)
	cin._start_drone(Transform3D(Basis.IDENTITY, b3_pos + Vector3(600.0, -150.0, 300.0)))
	await process_frame
	await process_frame
	cin.set_shot(4)
	var looks := []
	var drawn_dirs := []
	for k in 90:
		main.seek(172.0 + k / 60.0)
		await process_frame
		await process_frame
		looks.append(-main.camera.global_transform.basis.z)
		drawn_dirs.append((main._pos_at(b3, 172.0 + k / 60.0) - main.camera.global_position).normalized())
	var worst_look := 0.0
	var worst_drawn2 := 0.0
	for k in range(1, 89):
		worst_look = maxf(worst_look, rad_to_deg((looks[k + 1] - looks[k] * 2.0 + looks[k - 1]).length()))
		worst_drawn2 = maxf(worst_drawn2, rad_to_deg((drawn_dirs[k + 1] - drawn_dirs[k] * 2.0 + drawn_dirs[k - 1]).length()))
	check(worst_look < worst_drawn2 / 20.0,
		"ground camera on a jittery track: the picture turns %.4f deg a frame (aiming at the raw track: %.3f deg)" % [worst_look, worst_drawn2])
	# the chase family (1 again: the next kind)
	main.follow(tester_id)
	main.seek(150.0)
	main.set_playing(true)
	cin.set_shot(2)
	cin.set_shot(1)
	var kinds := {}
	for n in cin.KIND_NAMES.size():
		if n > 0:
			cin.set_shot(1)
		await create_timer(0.5).timeout
		kinds[cin.KIND_NAMES[cin.chase_kind]] = main.camera.global_position.distance_to(main.active_aircraft[tester_id].position)
	print("    ", kinds)
	check(kinds.size() == 5 and absf(kinds["Chase"] - 26.0) < 4.0 and kinds["Chase plane"] > 15.0 and kinds["Chase plane"] < 80.0
		and kinds["Trailing"] > 50.0 and kinds["Trailing"] < 200.0 and absf(kinds["Delayed"] - 26.0) < 2.0
		and absf(kinds["Outside"] - 26.0) < 2.0, "1 again: chase, chase plane, trailing, delayed, outside")
	# the ghost cameras (0): fixed on the aircraft, turning with it
	cin.set_shot(0)
	var rigid := true
	var near_all := true
	for n in cin.MOUNT_NAMES.size():
		if n > 0:
			cin.set_shot(0)
		await create_timer(0.3).timeout
		var att: Basis = main.aircraft_attitude[tester_id]
		var p0: Vector3 = att.inverse() * (main.camera.global_position - main.active_aircraft[tester_id].position)
		await create_timer(0.4).timeout
		att = main.aircraft_attitude[tester_id]
		var p1: Vector3 = att.inverse() * (main.camera.global_position - main.active_aircraft[tester_id].position)
		rigid = rigid and p0.distance_to(p1) < 1.5
		near_all = near_all and p1.length() < 40.0
	check(rigid and near_all and cin.ghost_kind == cin.MOUNT_NAMES.size() - 1,
		"0 and again: %d ghost cameras, each fixed on the aircraft" % cin.MOUNT_NAMES.size())
	# the stick: the hidden mouse's distance from the centre sets how fast the camera turns
	cin.set_shot(9)
	main.set_playing(false)
	cin.rate = 0.0
	main._on_view_changed("cine_stick", true)
	var push := InputEventMouseMotion.new()
	push.relative = Vector2(60.0, 0.0)
	cin.mouse(push)
	var yaw_a: float = cin._drone_yaw_to
	await create_timer(0.6).timeout
	var slow_turn: float = yaw_a - cin._drone_yaw_to
	push.relative = Vector2(240.0, 0.0)
	cin.mouse(push)
	yaw_a = cin._drone_yaw_to
	await create_timer(0.6).timeout
	var fast_turn: float = yaw_a - cin._drone_yaw_to
	check(slow_turn > 0.0 and fast_turn > slow_turn * 3.0,
		"stick right: the drone turns right, faster further out (%.2f then %.2f rad in 0.6 s)" % [slow_turn, fast_turn])
	var middle := InputEventMouseButton.new()
	middle.button_index = MOUSE_BUTTON_MIDDLE
	middle.pressed = true
	cin.mouse(middle)
	await create_timer(0.8).timeout
	yaw_a = cin._drone_yaw_to
	await create_timer(0.3).timeout
	check(cin._stick == Vector2.ZERO and absf(cin._drone_yaw_to - yaw_a) < 0.01, "middle button: the stick back to the centre, turning stops")
	main._on_view_changed("cine_stick", false)
	# crane helpers: ready-made moves, remove the last / all points, a longer move, guides while paused
	main.follow(tester_id)
	main.seek(150.0)
	cin.set_shot(1)
	await process_frame
	await process_frame
	cin.key("crane_preset", false)
	var sweep_n: int = cin._crane.size()
	cin.key("crane_preset", false)
	check(sweep_n == 3 and cin._crane.size() == 3 and cin.CRANE_PRESETS[cin._preset] == "Rise", "V: ready-made moves (Sweep, then Rise)")
	cin.key("crane_undo", false)
	var crane_was: float = main.view["cine_crane"]
	cin.key("crane_longer", false)
	await process_frame
	await process_frame
	check(cin._crane.size() == 2 and is_equal_approx(main.view["cine_crane"], crane_was + 0.5), "U: remove the last point; ]: a longer move")
	check(cin.guides.visible and cin._hud.text.contains("CRANE") and cin.guides.labels[1].visible, "paused: the path, its numbered points and the keys on screen")
	main.set_playing(true)
	await create_timer(0.3).timeout
	check(not cin.guides.visible and cin._hud.text == "", "playing: no guides (a clean recording)")
	cin.key("crane_clear", false)
	cin.key("crane_shorter", false)
	check(cin._crane.is_empty(), "Delete: all points removed")
	main.set_playing(false)
	# saving a flight path to check its jitter
	main.follow(tester_id)
	main.seek(100.0)
	main.save_track()
	var saved := ""
	for f in DirAccess.get_files_at(event.get_base_dir()):
		if f.contains(" track ") and f.ends_with(".txt"):
			saved = event.get_base_dir().path_join(f)
	var track_json := JSON.new()
	var parsed_ok := saved != "" and track_json.parse(FileAccess.get_file_as_string(saved)) == OK
	check(parsed_ok and track_json.data["samples"].size() > 500 and track_json.data["pilot"] == "[BLUE]Tester",
		"F9: the flight path around now saved (%s)" % saved.get_file())
	if saved != "":
		DirAccess.remove_absolute(saved)
	# slow motion, pause and retake
	main.seek(100.0)
	main.set_playing(true)
	cin.note_play()
	var x_key := InputEventKey.new()
	x_key.keycode = KEY_X
	x_key.pressed = true
	Input.parse_input_event(x_key)
	await create_timer(1.5).timeout
	check(absf(cin.rate - 0.25) < 0.02, "hold X: the replay eases down to 0.25x (%.2f)" % cin.rate)
	x_key.pressed = false
	Input.parse_input_event(x_key)
	await create_timer(1.5).timeout
	check(absf(cin.rate - 1.0) < 0.02, "let go: back to full speed")
	main.set_playing(false)
	var t_pause: float = main.replay_time
	await create_timer(1.5).timeout
	check(cin.rate == 0.0 and main.replay_time > t_pause and main.replay_time < t_pause + 0.5,
		"pause: eases to a stop (%.2f s more)" % (main.replay_time - t_pause))
	cin.set_shot(9)
	await process_frame
	var bs := InputEventKey.new()
	bs.keycode = KEY_BACKSPACE
	bs.pressed = true
	Input.parse_input_event(bs)
	await process_frame
	check(absf(main.replay_time - 100.0) < 0.2 and main.playing, "Backspace: retake from where Play was pressed (%.2f)" % main.replay_time)
	# crane
	main.set_playing(false)
	cin.rate = 0.0                       # (stopped at once: the points stay where they were set)
	main.view["cine_crane"] = 1.0
	cin.set_shot(1)
	await process_frame
	await process_frame
	cin.add_crane_point()
	var a_pos: Vector3 = cin.base.origin
	cin.aim[1] = Vector2(1.2, -0.3)
	for k in 30:
		await process_frame
	cin.add_crane_point()
	var b_pos: Vector3 = cin.base.origin
	cin.set_shot(8)
	await process_frame
	await process_frame
	var start_d: float = main.camera.global_position.distance_to(a_pos)
	await create_timer(1.3).timeout
	await process_frame
	check(start_d < 3.0 and main.camera.global_position.distance_to(b_pos) < 3.0,
		"crane: glides from point A (%.1f m) to point B (%.1f m)" % [start_d, main.camera.global_position.distance_to(b_pos)])
	# keys can be changed
	ui.show_keys_window()
	ui._capture_key("cinema")
	var b_key := InputEventKey.new()
	b_key.keycode = KEY_O
	b_key.pressed = true
	Input.parse_input_event(b_key)
	await process_frame
	await process_frame
	check(main.keys.keys["cinema"] == KEY_O and ui._key_buttons["cinema"].text == "O", "Keys window: the cinematic mode moved to O")
	ui._close_keys_window()
	await process_frame
	Input.parse_input_event(b_key)
	await process_frame
	await process_frame
	check(not cin.on and ui.visible, "O now leaves it; the panel is back")
	check(main.aircraft_tags[tester_id].visible and main.camera.attributes == null,
		"name tags and plain lens back")
	main._on_keys_reset()
	check(main.keys.keys["cinema"] == KEY_M, "defaults again: M")
	main.set_playing(false)

	print("review file after reload:")
	var text := FileAccess.get_file_as_string(review_file)
	print("    ", text.replace("\n", " ").replace("\t", "").left(300))
	main.load_event(event)
	waited = 0
	await process_frame
	while main._load_thread != null and waited < 600:
		await process_frame
		waited += 1
	await process_frame
	check(main.ui.review.status(kid) == "confirmed" and main.ui.review.status(did) == "rejected", "marks found again after reloading")
	check(main.ui.review.unmatched == 0, "no unmatched marks")
	print("")
	print("FAILS: %d" % fails)
	quit(1 if fails > 0 else 0)
