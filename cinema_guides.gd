extends Node3D
# Guides for setting up a crane move (cinema.gd; only while the replay is paused, and G hides
# them): the path the camera will glide along (dashed), each point as a small cross with its
# number, and a short line showing which way the camera looks there. Drawn over everything, so
# points behind a hill still show. Hidden while the move plays, so recordings stay clean.

const COLOR = Color(1.0, 0.85, 0.3)
const LOOK_COLOR = Color(0.55, 0.9, 1.0)
const LABEL_PIXEL = 0.0009

var mesh := ImmediateMesh.new()
var labels := []

func _ready() -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-1e6, -1e5, -1e6), Vector3(2e6, 2e5, 2e6))
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true
	mat.render_priority = 20
	node.material_override = mat
	add_child(node)

# points: camera positions; looks: the direction the camera looks from each (unit vectors);
# path: the glide as a line of points (from the first point to the last); size: metres, how big
# the crosses and look lines are (about the distance to the aircraft).
func show_path(points: Array, looks: Array, path: PackedVector3Array, size: float) -> void:
	visible = true
	mesh.clear_surfaces()
	if points.is_empty():
		_labels(0)
		return
	mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	for k in range(0, path.size() - 1):
		if k % 2 == 0:                           # dashed
			_line(path[k], path[k + 1], COLOR)
	var arm := maxf(size * 0.06, 0.5)
	for i in points.size():
		var p: Vector3 = points[i]
		for axis in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
			_line(p - axis * arm, p + axis * arm, COLOR)
		if i < looks.size():
			_line(p, p + looks[i] * size * 0.35, LOOK_COLOR)
	mesh.surface_end()
	_labels(points.size())
	for i in points.size():
		labels[i].position = points[i] + Vector3.UP * arm * 1.6

func hide_path() -> void:
	visible = false

func _line(a: Vector3, b: Vector3, c: Color) -> void:
	mesh.surface_set_color(c)
	mesh.surface_add_vertex(a)
	mesh.surface_set_color(c)
	mesh.surface_add_vertex(b)

func _labels(n: int) -> void:
	while labels.size() < n:
		var l := Label3D.new()
		l.text = str(labels.size() + 1)
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.pixel_size = LABEL_PIXEL
		l.font_size = 40
		l.outline_size = 10
		l.modulate = COLOR
		l.outline_modulate = Color.BLACK
		l.no_depth_test = true
		l.render_priority = 21
		add_child(l)
		labels.append(l)
	for i in labels.size():
		labels[i].visible = i < n
