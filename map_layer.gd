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
# ground_at(x, z) gives the ground under a point (for the aircraft shadows): the terrain there,
# else sea level (the flat maps lie at 0).
# Better lighting (View tab): the terrain again, lit by a lower sun (RELIEF_SUN) with more
# contrast, so hills stand out (flat ground keeps its brightness); its colours are the daylight
# ones scaled by (new light / old light) at each point, with the smooth normals YSFlight uses.
# Off: YSFlight's own daylight.

const PICTURE_DROP = 0.1     # metres the maps sit below their true height
const LIGHT_LIFT = 0.3
const HEIGHT_CELL = 500.0    # metres: cell size of the terrain index
const YS_SUN = Vector3(0.0, 0.8660254, -0.5)     # YSFlight's sun (its axes): 60 degrees up, south
const RELIEF_SUN = Vector3(-0.4330127, 0.5, -0.75)   # better lighting: 30 degrees up, south-south-west
const RELIEF_AMBIENT = 0.37      # with RELIEF_DIFFUSE: flat ground as bright as in YSFlight (82 %)
const RELIEF_DIFFUSE = 0.9

var field := ""
var base_color := Color(0, 0, 0)      # the ground beyond the map (GND)
var sky_color := Color(0.32, 0.48, 0.64)
var _tris := PackedVector3Array()     # the terrain's upward-facing triangles (viewer axes), 3 points each
var _cells := {}                      # Vector2i cell -> [index in _tris of each triangle over it]
var _terrain := []                    # [YSFlight daylight node, better lighting node]

func build(data: Dictionary) -> void:
	field = data.get("field", "")
	sky_color = _color(data.get("sky", [82, 122, 163]))
	base_color = _color(data.get("ground", [0, 0, 0]))
	var solid: Dictionary = data.get("solid", {})
	for part in [solid, _relit(solid)]:
		if _add(Mesh.PRIMITIVE_TRIANGLES, part, _unlit(), 0.0) != null:
			_terrain.append(get_child(get_child_count() - 1))
	set_lighting(false)
	_index_terrain(solid.get("v", []))
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

func set_lighting(better: bool) -> void:
	for k in _terrain.size():
		_terrain[k].visible = (k == 1) == better or _terrain.size() == 1

# The terrain's colours under the better lighting: each up-facing triangle's points relit with the
# smooth normal there (the average of the up-facing triangles round the point, as fld_reader.py
# does); walls and signs keep theirs.
static func _relit(solid: Dictionary) -> Dictionary:
	var v: Array = solid.get("v", [])
	var c: Array = solid.get("c", [])
	if v.is_empty() or c.size() != v.size():
		return {}
	var sums := {}                  # point (to 1 cm) -> sum of the normals round it
	var faces := []                 # each triangle's up normal, or ZERO for a wall
	for i in range(0, v.size() - 8, 9):
		var a := Vector3(v[i], v[i + 1], v[i + 2])
		var n := (Vector3(v[i + 3], v[i + 4], v[i + 5]) - a).cross(Vector3(v[i + 6], v[i + 7], v[i + 8]) - a)
		if n.length_squared() < 1e-9:
			faces.append(Vector3.ZERO)
			continue
		n = n.normalized()
		if n.y < 0.0:
			n = -n
		if n.y < 0.2:
			faces.append(Vector3.ZERO)
			continue
		faces.append(n)
		for k in 3:
			var key := Vector3i(roundi(v[i + 3 * k] * 100.0), roundi(v[i + 3 * k + 1] * 100.0), roundi(v[i + 3 * k + 2] * 100.0))
			sums[key] = sums.get(key, Vector3.ZERO) + n
	var out := c.duplicate()
	for t in faces.size():
		if faces[t] == Vector3.ZERO:
			continue
		for k in 3:
			var i: int = 9 * t + 3 * k
			var n: Vector3 = sums[Vector3i(roundi(v[i] * 100.0), roundi(v[i + 1] * 100.0), roundi(v[i + 2] * 100.0))].normalized()
			var was := 0.3 + 0.6 * maxf(n.dot(YS_SUN), 0.0)
			var now := RELIEF_AMBIENT + RELIEF_DIFFUSE * maxf(n.dot(RELIEF_SUN), 0.0)
			for m in 3:
				out[i + m] = minf(float(c[i + m]) * now / was, 255.0)
	return {"v": v, "c": out}

# The ground under a point (viewer axes): [height, normal] of the highest terrain triangle there,
# else sea level [0, up] (also where the terrain dips below the sea).
func ground_at(x: float, z: float) -> Array:
	var best_y := -INF
	var best_n := Vector3.UP
	for k in _cells.get(Vector2i(floori(x / HEIGHT_CELL), floori(z / HEIGHT_CELL)), []):
		var a := _tris[k]
		var b := _tris[k + 1]
		var c := _tris[k + 2]
		var d := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
		if absf(d) < 1e-9:
			continue
		var u := ((x - a.x) * (c.z - a.z) - (c.x - a.x) * (z - a.z)) / d
		var w := ((b.x - a.x) * (z - a.z) - (x - a.x) * (b.z - a.z)) / d
		if u < 0.0 or w < 0.0 or u + w > 1.0:
			continue
		var y := a.y + u * (b.y - a.y) + w * (c.y - a.y)
		if y > best_y:
			best_y = y
			best_n = (b - a).cross(c - a).normalized()
	if best_y < 0.0:
		return [0.0, Vector3.UP]
	return [best_y, best_n if best_n.y > 0.0 else -best_n]

# The terrain's triangles that face up (not walls or sign boards), by the cells they cover.
func _index_terrain(v: Array) -> void:
	for i in range(0, v.size() - 8, 9):
		var a := Vector3(v[i], v[i + 1], -v[i + 2])
		var b := Vector3(v[i + 3], v[i + 4], -v[i + 5])
		var c := Vector3(v[i + 6], v[i + 7], -v[i + 8])
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-9 or absf(n.normalized().y) < 0.2:
			continue
		var k := _tris.size()
		_tris.append_array(PackedVector3Array([a, b, c]))
		for ix in range(floori(minf(a.x, minf(b.x, c.x)) / HEIGHT_CELL), floori(maxf(a.x, maxf(b.x, c.x)) / HEIGHT_CELL) + 1):
			for iz in range(floori(minf(a.z, minf(b.z, c.z)) / HEIGHT_CELL), floori(maxf(a.z, maxf(b.z, c.z)) / HEIGHT_CELL) + 1):
				var cell := Vector2i(ix, iz)
				if not _cells.has(cell):
					_cells[cell] = []
				_cells[cell].append(k)

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
