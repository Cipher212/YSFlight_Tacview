extends Node3D
# Energy ribbons: a strip behind each aircraft over the last few seconds, coloured by its speed
# (red slow, yellow, green fast) and turned with its wings, so rolls and turns show as well.
# Smoke trails: black smoke behind an aircraft from the moment it starts going down for good
# (flight state 4 or 5, tumbling, until its track ends) to where its track ends, so the exact point of death shows; the smoke stays a
# minute after the aircraft is gone, then fades.
# build_arrays() runs once per event on the loader thread; after that the only work per frame is
# one shader value, "now": the shaders hide every part of a strip outside its time window,
# cutting it exactly where the aircraft is.
#
# Speed is true airspeed from the track itself: the distance flown between the samples 0.15 s
# either side, over the time between them (YSFlight has no wind in RvB, so it is also the speed
# over the ground). On the ground, and once the aircraft is going down, the ribbon stops.

const Main = preload("res://node_3d.gd")
const STEP = 0.25            # seconds between ribbon points (the track has 20 per second)
const GAP = 2.0              # a longer gap in the track breaks the ribbon
const HALF_WIDTH = 4.0       # metres each side of the track at ribbon width 1
const MS_TO_KT = 1.943844
const SLOW_KT = 150.0        # red at or below
const FAST_KT = 550.0        # green at or above (yellow halfway)
const SMOKE_STEP = 0.1       # seconds between smoke points (a tumbling aircraft turns quickly)
const SMOKE_HALF_WIDTH = 8.0
const SMOKE_LINGER = 60.0    # seconds the smoke stays after the track ends (the last 15 fading)

const SMOKE_SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float now = 0.0;
uniform float linger = 60.0;
uniform float half_width = 5.0;

varying float t_point;
varying float t_end;

void vertex() {
	// a strip that always faces the camera (the mesh is in world space); NORMAL = the trail's direction
	vec3 side = cross(NORMAL, normalize(CAMERA_POSITION_WORLD - VERTEX));
	side = length(side) > 1e-4 ? normalize(side) : vec3(0.0, 1.0, 0.0);
	float spread = 1.0 + clamp((now - UV.x) / 20.0, 0.0, 2.0);   // smoke widens as it ages
	VERTEX += side * UV2.x * half_width * spread;
	t_point = UV.x;                                  // UV.x = time of the point, UV.y = end of the track
	t_end = UV.y;
}

void fragment() {
	if (t_point > now || now > t_end + linger) {
		discard;
	}
	ALBEDO = vec3(0.02);
	ALPHA = 0.85 * (1.0 - clamp((now - t_end - (linger - 15.0)) / 15.0, 0.0, 1.0));
}
"""

const SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform float now = 0.0;
uniform float window = 30.0;
uniform float half_width = 4.0;
uniform float slow_kt = 150.0;
uniform float fast_kt = 550.0;

varying float age;
varying float speed;

void vertex() {
	VERTEX += NORMAL * UV2.x * half_width;   // NORMAL carries the wing direction
	age = now - UV.x;                        // UV.x = time of the point, UV.y = its speed (kt)
	speed = UV.y;
}

void fragment() {
	if (age < 0.0 || age > window) {
		discard;
	}
	float s = clamp((speed - slow_kt) / (fast_kt - slow_kt), 0.0, 1.0);
	vec3 red = vec3(0.92, 0.12, 0.08);
	vec3 yellow = vec3(0.95, 0.82, 0.10);
	vec3 green = vec3(0.15, 0.82, 0.22);
	vec3 c = s < 0.5 ? mix(red, yellow, s * 2.0) : mix(yellow, green, s * 2.0 - 1.0);
	ALBEDO = pow(c, vec3(2.2));              // the colours above are screen (sRGB) values
}
"""

var material: ShaderMaterial
var smoke_material: ShaderMaterial
var smoke_node: Node3D

# {"ribbons": [...], "smoke": [...]}, each per aircraft [verts, normals, uvs, uv2s, indices].
# Plain arrays, so this can run on a thread.
static func build_arrays(entities: Dictionary) -> Dictionary:
	return {"ribbons": _ribbon_arrays(entities), "smoke": _smoke_arrays(entities)}

# The falling part of each track that has one: the tumble the track ends in (the final stretch of
# states 3/4/5, if it has a 4 or 5; as event_merge.sortie_end). A replay can show an aircraft
# tumbling for a moment and then flying on (lag): that is no death and gets no smoke.
static func _smoke_arrays(entities: Dictionary) -> Array:
	var out := []
	for id in entities:
		var frames: Array = entities[id].get("telemetry", [])
		var start := frames.size()
		var tumbled := false
		while start > 0 and int(frames[start - 1]["ctrl"][0]) in [3, 4, 5]:
			start -= 1
			tumbled = tumbled or int(frames[start]["ctrl"][0]) != 3
		if not tumbled or start >= frames.size() - 1:
			continue
		var pts := PackedVector3Array()
		var ts := PackedFloat64Array()
		var last_t := -INF
		for i in range(start, frames.size()):
			var t: float = frames[i]["t"]
			if t - last_t >= SMOKE_STEP or i == frames.size() - 1:
				pts.append(Main.ys_position(frames[i]))
				ts.append(t)
				last_t = t
		if pts.size() < 2:
			continue
		var t_end: float = ts[ts.size() - 1]
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var uv2s := PackedVector2Array()
		var indices := PackedInt32Array()
		for k in pts.size():
			var along := (pts[mini(k + 1, pts.size() - 1)] - pts[maxi(k - 1, 0)])
			along = along.normalized() if along.length_squared() > 1e-6 else Vector3.DOWN
			for side in [-1.0, 1.0]:
				verts.append(pts[k])
				normals.append(along)
				uvs.append(Vector2(ts[k], t_end))
				uv2s.append(Vector2(side, 0.0))
			if k > 0:
				var n := 2 * k
				indices.append_array(PackedInt32Array([n - 2, n - 1, n, n - 1, n + 1, n]))
		out.append([verts, normals, uvs, uv2s, indices])
	return out

static func _ribbon_arrays(entities: Dictionary) -> Array:
	var out := []
	for id in entities:
		var frames: Array = entities[id].get("telemetry", [])
		var n := frames.size()
		if n < 2:
			continue
		var verts := PackedVector3Array()
		var normals := PackedVector3Array()
		var uvs := PackedVector2Array()
		var uv2s := PackedVector2Array()
		var indices := PackedInt32Array()
		var last_t := -INF
		var joined := false          # the previous point can be joined to the next one
		for i in n:
			var f: Dictionary = frames[i]
			var t: float = f["t"]
			if t - last_t < STEP and i < n - 1:
				continue
			var state := int(f["ctrl"][0])
			if state == 1 or state == 6 or (state >= 3 and state <= 5):   # ground, stopped, going down / dead
				joined = false
				last_t = t
				continue
			var i0 := maxi(i - 3, 0)
			var i1 := mini(i + 3, n - 1)
			var dt: float = frames[i1]["t"] - frames[i0]["t"]
			var speed := 0.0
			if dt > 0.0:
				speed = Main.ys_position(frames[i1]).distance_to(Main.ys_position(frames[i0])) / dt
			if t - last_t > GAP:
				joined = false
			var p := Main.ys_position(f)
			var wing := Main.ys_basis(f).x.normalized()
			var k := verts.size()
			for side in [-1.0, 1.0]:
				verts.append(p)
				normals.append(wing)
				uvs.append(Vector2(t, speed * MS_TO_KT))
				uv2s.append(Vector2(side, 0.0))
			if joined:
				indices.append_array(PackedInt32Array([k - 2, k - 1, k, k - 1, k + 1, k]))
			joined = true
			last_t = t
		if indices.size() > 0:
			out.append([verts, normals, uvs, uv2s, indices])
	return out

func setup(strips: Dictionary) -> void:
	material = _shader_material(SHADER)
	smoke_material = _shader_material(SMOKE_SHADER)
	smoke_material.set_shader_parameter("linger", SMOKE_LINGER)
	var ribbon_node := Node3D.new()
	add_child(ribbon_node)
	smoke_node = Node3D.new()
	add_child(smoke_node)
	for r in strips.get("ribbons", []):
		ribbon_node.add_child(_strip(r, material))
	for r in strips.get("smoke", []):
		smoke_node.add_child(_strip(r, smoke_material))

static func _shader_material(code: String) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = Shader.new()
	m.shader.code = code
	return m

static func _strip(r: Array, mat: Material) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = r[0]
	arrays[Mesh.ARRAY_NORMAL] = r[1]
	arrays[Mesh.ARRAY_TEX_UV] = r[2]
	arrays[Mesh.ARRAY_TEX_UV2] = r[3]
	arrays[Mesh.ARRAY_INDEX] = r[4]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.extra_cull_margin = 200.0           # the shader widens the strip beyond the mesh's own box
	return node

func update(t: float) -> void:
	material.set_shader_parameter("now", t)
	smoke_material.set_shader_parameter("now", t)

# ribbons on/off, their length, their width (the View tab's ribbon width, 1 = true size; the
# aircraft size setting does not widen them), smoke on/off
func set_view(ribbons_on: bool, seconds: float, width: float, smoke_on: bool) -> void:
	get_child(0).visible = ribbons_on
	smoke_node.visible = smoke_on
	material.set_shader_parameter("window", seconds)
	material.set_shader_parameter("half_width", HALF_WIDTH * width)
	material.set_shader_parameter("slow_kt", SLOW_KT)
	material.set_shader_parameter("fast_kt", FAST_KT)
	smoke_material.set_shader_parameter("half_width", SMOKE_HALF_WIDTH * width)
