extends Node3D
# The YSFlight map, from maps/<FIELD>.json (made by fld_reader.py from the .fld), drawn the way
# YSFlight draws it (YSFLIGHT-master/src/scenery/ysscenerygl2.0.cpp). The colours already carry
# YSFlight's daylight, so nothing here is lit.
#   layers : the flat maps, one layer per plane. Each is painted in order, each shape over the
#            last, after everything solid; then its depth is written so later layers stay
#            behind it (YsScenery::DrawMapVisual).
#   solid  : terrain and sign boards
#   lights : runway and city lights
# Maps sit a few centimetres under their true height so terrain wins where they touch, as in
# YSFlight (it draws the terrain after the maps).

const PICTURE_DROP = 0.1     # metres the maps sit below their true height
const LIGHT_LIFT = 0.3

var field := ""
var base_color := Color(0, 0, 0)      # the ground beyond the map (GND)
var sky_color := Color(0.32, 0.48, 0.64)

func build(data: Dictionary) -> void:
	field = data.get("field", "")
	sky_color = _color(data.get("sky", [82, 122, 163]))
	base_color = _color(data.get("ground", [0, 0, 0]))
	_add(Mesh.PRIMITIVE_TRIANGLES, data.get("solid", {}), _unlit(), 0.0)
	_add(Mesh.PRIMITIVE_LINES, data.get("solid_lines", {}), _unlit(), 0.0)
	var light_mat := _unlit()
	light_mat.use_point_size = true
	light_mat.point_size = 3.0
	_add(Mesh.PRIMITIVE_POINTS, data.get("lights", {}), light_mat, LIGHT_LIFT)

	# transparent materials are drawn after all solid ones, lowest render priority first
	# (RENDER_PRIORITY_MIN is the ground beyond the map, in node_3d.gd)
	var priority := Material.RENDER_PRIORITY_MIN + 1
	var layers: Array = data.get("layers", [])
	for n in layers.size():
		var mesh := _add(Mesh.PRIMITIVE_TRIANGLES, layers[n].get("tris", {}), _painted(priority), -PICTURE_DROP)
		_add(Mesh.PRIMITIVE_LINES, layers[n].get("lines", {}), _painted(priority + 1), -PICTURE_DROP)
		if mesh != null and n < layers.size() - 1:
			_instance(mesh, _depth_only(priority + 2))
		priority = mini(priority + 3, Material.RENDER_PRIORITY_MAX - 2)

static func _color(c: Array) -> Color:
	return Color8(int(c[0]), int(c[1]), int(c[2]))

@warning_ignore("integer_division")
func _add(kind: int, part: Dictionary, mat: Material, lift: float) -> ArrayMesh:
	var v: Array = part.get("v", [])
	var c: Array = part.get("c", [])
	var n: int = v.size() / 3
	if n == 0:
		return null
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	verts.resize(n)
	cols.resize(n)
	for i in n:
		# YSFlight (x east, y up, z north) -> Godot: z flips (see ys_position in node_3d.gd)
		verts[i] = Vector3(v[3 * i], v[3 * i + 1] + lift, -v[3 * i + 2])
		cols[i] = Color8(int(c[3 * i]), int(c[3 * i + 1]), int(c[3 * i + 2]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(kind, arrays)
	_instance(mesh, mat)
	return mesh

func _instance(mesh: ArrayMesh, mat: Material) -> void:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)

func _unlit() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.vertex_color_is_srgb = true
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m

func _painted(priority: int) -> StandardMaterial3D:
	# no depth writes: later shapes simply paint over earlier ones
	var m := _unlit()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.render_priority = priority
	return m

func _depth_only(priority: int) -> StandardMaterial3D:
	# writes a layer's depth without changing its colours
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0, 0, 0, 0)
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_ALWAYS
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.render_priority = priority
	return m
