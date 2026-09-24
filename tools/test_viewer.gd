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
