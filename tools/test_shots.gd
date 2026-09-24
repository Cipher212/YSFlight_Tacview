extends SceneTree
# Screenshots of the weapons, trails, ribbons and side panel on the made-up test event:
#     TEST_EVENT=/abs/test.json.gz SHOTS_DIR=/abs/folder xvfb-run -a -s "-screen 0 1920x1080x24" \
#         godot --path . --rendering-driver opengl3 --resolution 1920x1080 --script tools/test_shots.gd

var main
var out_dir := ""

func shot(name: String) -> void:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("saved ", name)

func entity(player: String) -> String:
	for id in main.event_data["entities"]:
		if main.event_data["entities"][id]["player"] == player:
			return id
	return ""

# Free camera `back` metres from the head of the first weapon called `wname` launched after t0,
# seen from the side (offset: direction from the weapon to the camera, before normalising).
func look_at_weapon(wname: String, t: float, back: float, offset: Vector3) -> void:
	main.seek(t)
	main.tracked_id = ""
	for w in main.combat.path_weapons:
		if w["name"] == wname and w["t"] <= t and w["end"]["t"] >= t:
			var ts: PackedFloat64Array = w["_ts"]
			var k: int = clampi(ts.bsearch(t, false) - 1, 0, ts.size() - 2)
			var head: Vector3 = w["_pts"][k].lerp(w["_pts"][k + 1], clampf((t - ts[k]) / maxf(ts[k + 1] - ts[k], 0.001), 0.0, 1.0))
			if offset == Vector3.ZERO:          # from the side, a little above
				var dir: Vector3 = (w["_pts"][k + 1] - w["_pts"][k]).normalized()
				offset = dir.cross(Vector3.UP).normalized() + Vector3(0, 0.25, 0) - dir * 0.3
			place(head + offset.normalized() * back, head)
			return
	print("no weapon ", wname, " at ", t)

func look_at_shot(kind: int, t: float, back: float, offset: Vector3) -> void:
	main.seek(t)
	main.tracked_id = ""
	var c = main.combat
	for i in c.shot_t0.size():
		if c.shot_kind[i] == kind and c.shot_t0[i] <= t and c.shot_t1[i] >= t:
			var tau: float = t - c.shot_t0[i]
			var head: Vector3 = c.shot_pos[i] + c.shot_dir[i] * c._rocket_dist(c.shot_v0[i], c.shot_vmax[i], tau)
			place(head + offset.normalized() * back, head)
			return
	print("no shot kind ", kind, " at ", t)

func place(cam: Vector3, target: Vector3) -> void:
	main.camera.position = cam
	var d := (target - cam).normalized()
	main.cam_rot_x = asin(d.y)
	main.cam_rot_y = atan2(-d.x, -d.z)

func _init():
	out_dir = OS.get_environment("SHOTS_DIR")
	if out_dir == "":
		out_dir = OS.get_user_data_dir().path_join("shots")
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load(get_script().resource_path.get_base_dir().path_join("test_main.gd")).new()
	root.add_child(main)
	await process_frame
	root.get_window().size = Vector2i(1920, 1080)
	main.load_event(OS.get_environment("TEST_EVENT"))
	while main.event_data == null:
		await process_frame
	await process_frame
	var ui = main.ui
	ui.tabs.current_tab = ui.tabs.get_tab_idx_from_control(ui.kills_tree)
	main._on_view_changed("weapon_scale", 10.0)
	main._on_view_changed("aircraft_scale", 4.0)
	main._on_view_changed("ribbons", false)
	main.cam_distance = 600.0

	look_at_weapon("AIM120", 63.0, 260.0, Vector3(1, 0.35, 0.2))
	await shot("1_aim120_model_solid_trail")
	main._on_view_changed("weapon_scale", 3.0)
	look_at_weapon("AIM120", 63.0, 30.0, Vector3.ZERO)
	await shot("1b_aim120_close")
	look_at_weapon("AGM65", 121.5, 25.0, Vector3.ZERO)
	await shot("1c_agm_close")
	main._on_view_changed("weapon_scale", 10.0)
	look_at_weapon("AIM9", 97.5, 160.0, Vector3(1, 0.3, 0.5))
	await shot("2_r60_flares")
	look_at_weapon("AGM65", 121.5, 260.0, Vector3(1, 0.4, 0.2))
	await shot("3_agm_dashed")
	look_at_weapon("BOMB500", 155.5, 220.0, Vector3(1, 0.2, 0.4))
	await shot("4_bombs_dotted")
	look_at_shot(1, 171.2, 160.0, Vector3(1, 0.3, 0.6))
	await shot("5_rockets")
	look_at_weapon("FUELTANK", 333.0, 90.0, Vector3(1, 0.3, 0.5))
	await shot("6_fuel_tank")

	# aircraft 50x, ribbons on at 1x: the ribbons stay thin
	main._on_view_changed("ribbons", true)
	main._on_view_changed("aircraft_scale", 50.0)
	main._on_view_changed("weapon_scale", 1.0)
	main._on_view_changed("trail_seconds", 120.0)
	main.seek(250.0)
	main.tracked_id = ""
	place(Vector3(19500, 17000, -1500), Vector3(19500, 3000, -9500))
	await shot("7_aircraft50_ribbons1")
	main._on_view_changed("aircraft_scale", 4.0)
	main._on_view_changed("weapon_scale", 10.0)

	# markers at the end of the replay: gone after 30 s
	main.seek(535.0)
	place(Vector3(19500, 17000, -1500), Vector3(19500, 3000, -9500))
	await shot("8_end_no_old_markers")

	# review: first kill confirmed with a note
	main.cam_distance = 600.0
	main.seek(0.0)
	await process_frame
	ui.jump_kill(1)
	ui._toggle_status("confirmed")
	ui.note_edit.text = "missile seen hitting from both sides"
	ui._commit_note()
	await shot("9_review_kill")
	ui.jump_check(1)
	await shot("10_deaths_check")
	ui.tabs.current_tab = ui.tabs.get_tab_idx_from_control(ui.messages_tree)
	await shot("11_messages")
	ui.tabs.current_tab = ui.tabs.get_child_count() - 1
	await shot("12_view_tab")
	ui.tabs.current_tab = 0
	ui.search.text = "bandit"
	ui._refill()
	await shot("13_pilots_search")
	ui.search.text = ""
	ui._refill()

	# shadows straight below: the A-10 over the island (1:55), the F-16 over the sea (4:10)
	ui.set_panel_visible(false)
	main._on_view_changed("ribbons", false)
	main._on_view_changed("trail_seconds", 30.0)
	main._on_view_changed("weapon_scale", 1.0)
	main._on_view_changed("aircraft_scale", 4.0)
	await frame_with_shadow(entity("[BLUE]Striker"), 115.0)
	await shot("14_shadow_island_4x")
	main._on_view_changed("aircraft_scale", 10.0)
	await frame_with_shadow(entity("[BLUE]Tester"), 250.0)
	await shot("15_shadow_sea_10x")
	main._on_view_changed("aircraft_scale", 1.0)
	var f16: Vector3 = main.active_aircraft[entity("[BLUE]Tester")].position
	place(Vector3(f16.x + 60, 90, f16.z + 80), Vector3(f16.x, 0, f16.z))
	await shot("15b_shadow_sea_close_1x")
	main._on_view_changed("shadows", false)
	await shot("15c_shadows_off")
	main._on_view_changed("shadows", true)
	ui.set_panel_visible(true)

	# the T-80U (destroyed at 2:05) before and after
	main.seek(120.0)
	main.tracked_id = ""
	place(Vector3(20700, 700, -15600), Vector3(21400, 560, -15750))
	await shot("16_tank_before")
	main.seek(130.0)
	await shot("17_tank_after")
	quit()

# Camera beside an aircraft, far enough to see it and its shadow on the ground straight below.
func frame_with_shadow(id: String, t: float) -> void:
	var a: Vector3 = await main_pos(id, t)
	var g: float = main.map_node.ground_at(a.x, a.z)[0]
	var mid := Vector3(a.x, (a.y + g) * 0.5, a.z)
	place(mid + Vector3(0.6, 0.25, 0.8).normalized() * (a.y - g) * 1.2, mid)

func main_pos(id: String, t: float) -> Vector3:
	main.seek(t)
	main.tracked_id = ""
	for i in 2:
		await process_frame
	return main.active_aircraft[id].position
