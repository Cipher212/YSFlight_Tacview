extends SceneTree
# Screenshots of the cinematic mode (cinema.gd, cinema_fx.gd) on the made-up test event: shots,
# smoke, explosions (air, ground), burning aircraft, a wreck, the lens. ONLY=abc... picks parts.
#     TEST_EVENT=/abs/two.json.gz SHOTS_DIR=/abs/folder VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/lvp_icd.json \
#         xvfb-run -a -s "-screen 0 1920x1080x24" godot --path . --rendering-driver vulkan \
#         --rendering-method forward_plus --resolution 1920x1080 --script tools/test_cinema_shots.gd
var main
var out_dir := ""
func shot(name: String) -> void:
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(out_dir.path_join(name + ".png"))
	print("saved ", name, "  trails ", main.cinema.fx.last_trail_vertices, " particles ", main.cinema.fx.last_particles)

func at(t: float) -> void:
	main.set_playing(false)
	main.seek(t)
	main.cinema.rate = 0.0

func drone_at(pos: Vector3, target: Vector3) -> void:
	var c = main.cinema
	c.set_shot(9)
	pos.y = maxf(pos.y, main.map_node.ground_at(pos.x, pos.z)[0] + 40.0)
	var b := Basis.looking_at((target - pos).normalized(), Vector3.UP)
	c._start_drone(Transform3D(b, pos))

func _init():
	out_dir = OS.get_environment("SHOTS_DIR")
	DirAccess.make_dir_recursive_absolute(out_dir)
	main = load(get_script().resource_path.get_base_dir().path_join("test_main.gd")).new()
	root.add_child(main)
	await process_frame
	root.get_window().size = Vector2i(1920, 1080)
	main.load_event(OS.get_environment("TEST_EVENT"))
	while main.event_data == null:
		await process_frame
	await process_frame
	var only := OS.get_environment("ONLY")
	main.follow("1")
	at(62.5)
	main.set_cinema(true)
	var c = main.cinema
	c._hint_clock = 0.01
	if only == "" or only.contains("a"):
		c.set_shot(1)
		at(62.5)
		await shot("c01_chase_missile_smoke")
		c.set_shot(7)
		at(63.5)
		await shot("c02_lockon")
		c.set_shot(6)
		at(64.0)
		await shot("c03_weapon_cam")
		at(65.5)
		await shot("c03b_weapon_cam_later")
	if only == "" or only.contains("b"):
		var e: Dictionary = main.event_data["explosions"][0]
		var ep := Vector3(e["x"], e["y"], -e["z"])
		for tt in [67.6, 67.75, 68.2, 69.0, 71.0, 75.0]:
			drone_at(ep + Vector3(260, 60, 180), ep)
			at(tt)
			await shot("c04_blast_%.2f" % tt)
	if only == "" or only.contains("c"):
		main.follow("6")
		c.set_shot(1)
		at(254.5)
		await shot("c05_burning_chase")
		var p: Vector3 = main.track_pos("6", 254.5)
		drone_at(p + Vector3(250, 40, 250), p)
		at(255.8)
		await shot("c06_burning_side")
	if only == "" or only.contains("d"):
		var e2: Dictionary = main.event_data["explosions"][1]
		var ep2 := Vector3(e2["x"], e2["y"], -e2["z"])
		for tt in [125.35, 125.8, 127.0, 131.0]:
			drone_at(ep2 + Vector3(300, 80, 200), ep2 + Vector3(0, 20, 0))
			at(tt)
			await shot("c07_ground_blast_%.2f" % tt)
	if only == "" or only.contains("e"):
		var e3: Dictionary = main.event_data["explosions"][4]
		var ep3 := Vector3(e3["x"], e3["y"], -e3["z"])
		for tt in [301.3, 306.0, 318.0]:
			drone_at(ep3 + Vector3(330, 60, 260), ep3 + Vector3(0, 60, 0))
			at(tt)
			await shot("c08_wreck_%.1f" % tt)
	if only == "" or only.contains("f"):
		main.follow("4")
		c.set_shot(2)
		at(98.0)
		await shot("c09_wingman_flares")
		c.set_shot(5)
		at(98.5)
		await shot("c10_orbit")
		main.follow("6")
		c.set_shot(1)
		at(201.0)
		await shot("c11_guns_chase")
	if only == "" or only.contains("g"):
		main.follow("1")
		c.set_shot(1)
		c.blur = 1.0
		at(150.0)
		await shot("c12_chase_blur")
		c.blur = 0.0
		c.set_shot(3)
		at(150.0)
		await shot("c13_flyby")
		c.set_shot(4)
		at(152.0)
		await shot("c14_ground_cam")
	quit()
