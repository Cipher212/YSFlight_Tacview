extends Node3D
# The cinematic mode's effects, all worked out from the replay's clock, so they scrub, run
# backwards, slow down and freeze with the replay:
#   smoke   behind missiles, flares and rockets: soft, billowing, widening as it drifts off with
#           the wind and thins out (YSFlight's OpenGL 2.0 look: white puffs growing from the
#           missile's tail, 6 s long; flares start red). A strip facing the camera, one per
#           weapon, with the motor's glow at the head.
#   explosions  a white flash, a fireball of billowing puffs going from yellow-white through
#           orange and red to soot, dark smoke rising and spreading for several seconds, and
#           sparks flying out (YSFlight: a dome going from red to black). On the ground, dust as
#           well, and the fireball stays above it; over water, a white splash (YSFlight's water
#           plume).
#   burning aircraft going down (only the final tumble: see ribbon_layer.gd): fire and thick
#           black smoke along their fall (YSFlight: square sprites), and a column of smoke from
#           the wreck when it came down on the ground.
# The particles are camera-facing quads in one MultiMesh (one draw call); each carries where and
# when it started, its speed, sizes and life, and the shader moves, grows, colours and fades it
# for the replay time. They are made once per explosion / falling aircraft, when first needed.

const Main = preload("res://node_3d.gd")
enum Kind {FLASH, FIRE, SMOKE, SPARK, GLOW, SPRAY}
const STRIDE = 20                # floats per particle in the MultiMesh buffer (transform, colour, custom)
const TRAIL_LIFE = [6.0, 4.5, 2.0]   # seconds of smoke: missiles, flares, rockets (the shader has them too)
const MISSILES = ["AIM9", "AIM9X", "AIM120", "AGM65"]
const PUFF_SPACING = 4.5         # metres between the puffs of a falling aircraft
const WRECK_TIME = 35.0          # seconds of smoke from a wreck on the ground
const MAX_LIFE = 16.0            # longest-lived particle (wreck smoke)

const TRAIL_SHADER = """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, skip_vertex_transform, fog_disabled;

uniform float now = 0.0;
uniform vec3 wind = vec3(0.0);
uniform vec3 sun = vec3(0.0, 1.0, 0.0);

varying float v_x;
varying float v_a;
varying vec3 v_col;
varying float v_d;
varying float v_age;
varying float v_ls;
varying float v_lv;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	float age = now - UV2.x;
	float kind = UV2.y;
	float t = max(age, 0.0);
	float life = kind < 0.5 ? 6.0 : (kind < 1.5 ? 4.5 : 2.0);
	float u = clamp(age / life, 0.0, 1.0);
	float w;
	float a;
	vec3 col;
	if (kind < 0.5) {            // missile: white smoke
		w = 0.9 + 7.0 * pow(t, 0.7);
		a = 0.8 * pow(1.0 - u, 1.6) * smoothstep(0.0, 0.05, t);
		col = vec3(0.86);
	} else if (kind < 1.5) {     // flare: red at first, then white
		w = 0.6 + 3.5 * pow(t, 0.7);
		a = 0.85 * (t < 0.5 ? 1.0 : exp(-(t - 0.5) * 1.3)) * (1.0 - u);
		col = mix(vec3(1.0, 0.3, 0.12), vec3(0.9), smoothstep(0.03, 0.18, t));
	} else {                     // rocket: thin grey smoke
		w = 0.5 + 3.0 * pow(t, 0.7);
		a = 0.55 * pow(1.0 - u, 1.5);
		col = vec3(0.75);
	}
	if (age < 0.0 || age > life) {
		a = 0.0;
	}
	vec3 p = VERTEX + wind * t + vec3(0.0, 0.35 * t, 0.0);
	vec3 pv = (VIEW_MATRIX * vec4(p, 1.0)).xyz;
	vec3 tv = mat3(VIEW_MATRIX) * NORMAL;
	vec3 side = cross(tv, pv);
	float sl = length(side);
	side = sl > 1e-5 ? side / sl : vec3(1.0, 0.0, 0.0);
	VERTEX = pv + side * UV.x * w * 0.5;
	a *= smoothstep(0.3 * w, 1.5 * w + 1.0, length(pv));   // thins out right at the camera
	vec3 sv = normalize(mat3(VIEW_MATRIX) * sun);
	v_ls = dot(side, sv);
	v_lv = dot(normalize(-pv), sv);
	v_x = UV.x;
	v_a = a;
	v_col = col;
	v_d = UV.y;
	v_age = t;
}

void fragment() {
	float x = v_x;
	float across = sqrt(max(1.0 - x * x, 0.0));
	float n = 0.6 * vnoise(vec2(v_d * 0.07 - v_age * 0.25, x * 1.3 + v_age * 0.2))
		+ 0.4 * vnoise(vec2(v_d * 0.19 + v_age * 0.1, x * 2.7 - v_age * 0.3));
	float a = v_a * across * across * (0.45 + 0.8 * n);
	float light = 0.7 + 0.32 * (x * v_ls + across * v_lv);
	ALBEDO = v_col * light;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	ALBEDO = pow(ALBEDO, vec3(0.4545));   // it shows colours as they are; Forward+ converts them
#endif
	ALPHA = clamp(a, 0.0, 1.0);
}
"""

# (the Compatibility renderer multiplies the colour by alpha again in blend_premul_alpha, which
# made the smoke black: there it blends plainly, and glows cover a little instead of adding light;
# it also shows the colours without Forward+'s conversion from linear, so they are converted here)
const PUFF_SHADER = """
shader_type spatial;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
render_mode unshaded, cull_disabled, depth_draw_never, blend_mix, skip_vertex_transform, fog_disabled;
#else
render_mode unshaded, cull_disabled, depth_draw_never, blend_premul_alpha, skip_vertex_transform, fog_disabled;
#endif

uniform float now = 0.0;
uniform vec3 wind = vec3(0.0);
uniform vec3 sun = vec3(0.0, 1.0, 0.0);

varying vec2 v_q;
varying vec2 v_sq;
varying vec3 v_col;
varying float v_a;
varying float v_kind;
varying float v_u;
varying float v_seed;
varying vec3 v_sun;
varying float v_floor;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 vel = MODEL_MATRIX[0].xyz;
	vec3 sz = MODEL_MATRIX[1].xyz;     // size at the start, size at the end, life (s)
	vec3 prm = MODEL_MATRIX[2].xyz;    // drag, rise (m/s), kind
	float age = now - INSTANCE_CUSTOM.x;
	float seed = INSTANCE_CUSTOM.y;
	float life = max(sz.z, 0.001);
	float u = age / life;
	float kind = prm.z;
	v_kind = kind;
	v_u = u;
	v_seed = seed;
	v_col = COLOR.rgb;
	v_q = VERTEX.xy;
	v_sq = VERTEX.xy;
	v_floor = kind > 2.5 && kind < 3.5 ? -1e5 : INSTANCE_CUSTOM.w;
	if (age < 0.0 || u > 1.0) {
		VERTEX = vec3(0.0, 0.0, 10.0);  // behind the camera: not drawn
		v_a = 0.0;
	} else {
		float drag = prm.x;
		float slow = drag > 0.001 ? (1.0 - exp(-drag * age)) / drag : age;
		bool falls = kind > 2.5 && kind < 3.5 || kind > 4.5;       // sparks and spray fall
		vec3 p = origin + vel * slow + vec3(0.0, prm.y * age, 0.0) + wind * age;
		vec3 v_now = vel * exp(-drag * age);
		if (falls) {
			p.y -= 4.9 * age * age;
			v_now.y -= 9.8 * age;
		}
		float s = mix(sz.x, sz.y, 1.0 - pow(1.0 - u, 2.5)) * 0.5;
		p.y = max(p.y, v_floor + s * 0.7);   // kept above the ground (no hard edge where it cuts in)
		vec3 c = (VIEW_MATRIX * vec4(p, 1.0)).xyz;
		vec2 q = VERTEX.xy;
		if (kind > 2.5 && kind < 3.5) {        // spark: a streak along its flight
			vec2 d = (mat3(VIEW_MATRIX) * v_now).xy;
			float dl = length(d);
			d = dl > 1e-4 ? d / dl : vec2(1.0, 0.0);
			float len = max(length(v_now) * INSTANCE_CUSTOM.w, s);
			c.xy += d * q.x * len * 0.5 + vec2(-d.y, d.x) * q.y * s;
		} else {
			float ang = seed * 6.2832 + INSTANCE_CUSTOM.z * age;
			q = mat2(vec2(cos(ang), sin(ang)), vec2(-sin(ang), cos(ang))) * q;
			v_sq = q;
			c.xy += q * s;
		}
		VERTEX = c;
		// fades right at the camera (flying through smoke: no wall filling the screen)
		v_a = COLOR.a * smoothstep(0.2 * s, 1.2 * s + 0.5, length(c));
	}
	v_sun = normalize(mat3(VIEW_MATRIX) * sun);
}

void fragment() {
	float r = length(v_q);
	if (r > 1.0 || v_a <= 0.0) {
		discard;
	}
	float u = clamp(v_u, 0.0, 1.0);
	vec2 np = v_q * 1.8 + vec2(v_seed * 31.0, v_seed * 17.0);
	float n = 0.6 * vnoise(np + u * 1.5) + 0.4 * vnoise(np * 2.3 - u * 2.0);
	float edge = smoothstep(1.0, 0.35, r + (n - 0.5) * 0.55);
	vec3 nrm = normalize(vec3(v_sq, sqrt(max(1.0 - r * r, 0.0)) + 0.2));
	float lit = 0.55 + 0.6 * max(dot(nrm, v_sun), 0.0);
	vec3 col;
	float a;
	float cover;                          // 0: adds light (glow), 1: covers what is behind
	if (v_kind < 0.5) {                   // flash
		col = vec3(1.0, 0.93, 0.78) * 1.6;
		a = max(exp(-r * r * 4.0) - 0.0183, 0.0) * 1.02 * pow(1.0 - u, 1.5);
		cover = 0.2;
	} else if (v_kind < 1.5) {            // fireball: white-yellow, orange, red, soot
		vec3 c0 = vec3(1.0, 0.92, 0.7);
		vec3 c1 = vec3(1.0, 0.5, 0.1);
		vec3 c2 = vec3(0.55, 0.1, 0.02);
		vec3 soot = vec3(0.045, 0.04, 0.035) * lit;
		vec3 hot = u < 0.15 ? mix(c0, c1, u / 0.15) : (u < 0.45 ? mix(c1, c2, (u - 0.15) / 0.3) : c2);
		float glow = 1.0 - smoothstep(0.35, 0.85, u);
		col = mix(soot, hot * (0.65 + 0.7 * n) * (1.15 - 0.45 * r) * (0.85 + 0.3 * v_seed), glow);
		a = edge * smoothstep(0.0, 0.04, u) * (1.0 - smoothstep(0.6, 1.0, u));
		cover = mix(0.35, 1.0, smoothstep(0.25, 0.75, u));
	} else if (v_kind < 2.5) {            // smoke
		col = v_col * lit * (0.85 + 0.3 * n);
		a = edge * smoothstep(0.0, 0.06, u) * (1.0 - smoothstep(0.35, 1.0, u)) * (0.6 + 0.5 * n);
		cover = 1.0;
	} else if (v_kind < 3.5) {            // spark
		float along = abs(v_q.x);
		float across_ = abs(v_q.y);
		col = mix(vec3(1.0, 0.85, 0.5), vec3(1.0, 0.35, 0.05), u) * 1.3;
		a = (1.0 - along * along) * (1.0 - across_) * (1.0 - u);
		cover = 0.0;
	} else if (v_kind < 4.5) {            // glow: missile motor, flare
		float fl = 0.8 + 0.2 * sin(now * 47.0 + v_seed * 40.0);
		col = v_col * fl * 1.5;
		a = max(exp(-r * r * 5.0) - 0.0067, 0.0);
		cover = 0.0;
	} else {                              // spray (water)
		col = vec3(0.92, 0.95, 1.0) * lit;
		a = edge * (1.0 - u) * (0.6 + 0.5 * n);
		cover = 1.0;
	}
	// what would reach under the ground fades out (softly, not in a hard line)
	float y = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).y;
	a *= smoothstep(v_floor - 1.0, v_floor + 6.0, y);
	a = clamp(a * v_a, 0.0, 1.0);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	ALBEDO = pow(col, vec3(0.4545));      // it shows colours as they are; Forward+ converts them
	ALPHA = a * max(cover, 0.55);
#else
	ALBEDO = col * a;
	ALPHA = a * cover;
#endif
}
"""

var combat                       # combat_layer.gd: the weapons and explosions
var entities := {}
var map                          # map_layer.gd (ground heights), null on the plain ground
var wind := Vector3.ZERO
var trails := []                 # {"t0", "t1", "kind", "ts", "pts"} (+ the strip, made when first needed)
var trail_t0 := PackedFloat64Array()
var trail_longest := 0.0
var sources := []                # particle sources: {"t0", "t1", "kind": "blast" / "burn", ...}
var source_t0 := PackedFloat64Array()
var source_longest := 0.0
var trail_mesh: ArrayMesh
var trail_mat: ShaderMaterial
var puffs: MultiMesh
var puff_mat: ShaderMaterial
var capacity := 1024
var flash: OmniLight3D           # lights the aircraft near an explosion for a moment
var last_trail_vertices := 0     # (tests)
var last_particles := 0

func setup(data: Dictionary, combat_node, map_node) -> void:
	combat = combat_node
	map = map_node
	entities = data.get("entities", {})
	var w3 = data.get("wind", [0, 0, 0])
	wind = Main.ys_vec(w3[0], w3[1], w3[2])
	_build_nodes()
	_collect_trails()
	_collect_sources(data)

func _build_nodes() -> void:
	var sun: Vector3 = Main.map_layer_sun()
	trail_mat = ShaderMaterial.new()
	trail_mat.shader = Shader.new()
	trail_mat.shader.code = TRAIL_SHADER
	trail_mat.set_shader_parameter("wind", wind)
	trail_mat.set_shader_parameter("sun", sun)
	trail_mesh = ArrayMesh.new()
	var t_node := MeshInstance3D.new()
	t_node.mesh = trail_mesh
	t_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	t_node.custom_aabb = AABB(Vector3(-1e6, -1e5, -1e6), Vector3(2e6, 2e5, 2e6))
	add_child(t_node)

	puff_mat = ShaderMaterial.new()
	puff_mat.shader = Shader.new()
	puff_mat.shader.code = PUFF_SHADER
	puff_mat.set_shader_parameter("wind", wind)
	puff_mat.set_shader_parameter("sun", sun)
	puff_mat.render_priority = 1                 # over the smoke trails
	var quad := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(-1, -1, 0), Vector3(1, -1, 0), Vector3(1, 1, 0),
		Vector3(-1, -1, 0), Vector3(1, 1, 0), Vector3(-1, 1, 0)])
	quad.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	puffs = MultiMesh.new()
	puffs.transform_format = MultiMesh.TRANSFORM_3D
	puffs.use_colors = true
	puffs.use_custom_data = true
	puffs.mesh = quad
	puffs.instance_count = capacity
	puffs.visible_instance_count = 0
	puffs.custom_aabb = AABB(Vector3(-1e6, -1e5, -1e6), Vector3(2e6, 2e5, 2e6))
	var p_node := MultiMeshInstance3D.new()
	p_node.multimesh = puffs
	p_node.material_override = puff_mat
	p_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(p_node)

	flash = OmniLight3D.new()
	flash.light_color = Color(1.0, 0.62, 0.3)
	flash.shadow_enabled = false
	flash.visible = false
	add_child(flash)

# --- what smokes and burns ---

func _collect_trails() -> void:
	for w in combat.path_weapons:
		var kind := 0 if w["name"] in MISSILES else (1 if w["name"] == "FLARE" else -1)
		if kind < 0 or w["_pts"].size() < 2:
			continue
		trails.append({"t0": float(w["t"]), "t1": float(w["end"]["t"]), "kind": kind, "ts": w["_ts"],
			"pts": w["_pts"]})
	# rockets, and missiles fired without a target: the straight flight combat_layer.gd works out
	for i in combat.shot_t0.size():
		var k: int = combat.shot_kind[i]
		if k == 0:
			continue
		var t0: float = combat.shot_t0[i]
		var flight: float = combat.shot_t1[i] - t0
		var ts := PackedFloat64Array()
		var pts := PackedVector3Array()
		var tau := 0.0
		while true:
			ts.append(t0 + tau)
			pts.append(combat.shot_pos[i] + combat.shot_dir[i] * combat._rocket_dist(combat.shot_v0[i],
				combat.shot_vmax[i], tau) + wind * tau)
			if tau >= flight:
				break
			tau = minf(tau + 0.1, flight)
		if pts.size() >= 2:
			trails.append({"t0": t0, "t1": t0 + flight, "kind": 2 if k == 1 else 0, "ts": ts, "pts": pts})
	trails.sort_custom(func(a, b): return a["t0"] < b["t0"])
	for tr in trails:
		trail_t0.append(tr["t0"])
		trail_longest = maxf(trail_longest, tr["t1"] - tr["t0"] + TRAIL_LIFE[tr["kind"]])

func _collect_sources(data: Dictionary) -> void:
	for e in data.get("explosions", []):
		sources.append({"t0": float(e["t"]), "t1": float(e["t"]) + 12.0, "kind": "blast", "e": e})
	for id in entities:
		var frames: Array = entities[id].get("telemetry", [])
		# the final tumble only, as the black smoke in ribbon_layer.gd
		var start := frames.size()
		var tumbled := false
		while start > 0 and int(frames[start - 1]["ctrl"][0]) in [3, 4, 5]:
			start -= 1
			tumbled = tumbled or int(frames[start]["ctrl"][0]) != 3
		if not tumbled or start >= frames.size() - 1:
			continue
		var t_a: float = frames[start]["t"]
		var t_b: float = frames[-1]["t"]
		sources.append({"t0": t_a, "t1": t_b + WRECK_TIME + MAX_LIFE, "kind": "burn", "id": id,
			"from": t_a, "to": t_b})
	sources.sort_custom(func(a, b): return a["t0"] < b["t0"])
	for s in sources:
		source_t0.append(s["t0"])
		source_longest = maxf(source_longest, s["t1"] - s["t0"])

# --- every frame ---

func update(t: float, cam_pos: Vector3) -> void:
	trail_mat.set_shader_parameter("now", t)
	puff_mat.set_shader_parameter("now", t)
	var heads := []                  # [position, direction, trail kind] of the weapons in flight
	_update_trails(t, heads)
	_update_puffs(t, heads)
	_update_flash(t, cam_pos)

func _update_trails(t: float, heads: Array) -> void:
	var v := PackedVector3Array()
	var nm := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var i := trail_t0.bsearch(t - trail_longest)
	while i < trails.size() and trail_t0[i] <= t:
		var tr: Dictionary = trails[i]
		i += 1
		var life: float = TRAIL_LIFE[tr["kind"]]
		if t > tr["t1"] + life:
			continue
		if not tr.has("v"):
			_make_strip(tr)
		var ts: PackedFloat64Array = tr["ts"]
		var pts: PackedVector3Array = tr["pts"]
		var head_t := minf(t, tr["t1"])
		var k0 := maxi(ts.bsearch(t - life) - 1, 0)
		var k1 := mini(ts.bsearch(head_t, false) - 1, ts.size() - 1)
		if k1 < 0:
			continue
		# the weapon now, between two path points (as combat_layer.gd draws it)
		var head := pts[k1]
		var dir: Vector3 = tr["nm"][2 * k1]
		var head_d: float = tr["uv"][2 * k1].y
		if k1 + 1 < ts.size() and head_t > ts[k1]:
			var a := clampf((head_t - ts[k1]) / maxf(ts[k1 + 1] - ts[k1], 0.001), 0.0, 1.0)
			head = pts[k1].lerp(pts[k1 + 1], a)
			dir = (pts[k1 + 1] - pts[k1]).normalized()
			head_d += pts[k1].distance_to(head)
		if t <= tr["t1"]:
			heads.append([head, dir, tr["kind"]])
		var sv: PackedVector3Array = tr["v"]
		# strips joined by repeating the last point of one and the first of the next (the
		# triangles between them have no area)
		if v.size() > 0:
			v.append(v[v.size() - 1])
			nm.append(nm[nm.size() - 1])
			uv.append(uv[uv.size() - 1])
			uv2.append(uv2[uv2.size() - 1])
			v.append(sv[2 * k0])
			nm.append(tr["nm"][2 * k0])
			uv.append(tr["uv"][2 * k0])
			uv2.append(tr["uv2"][2 * k0])
		v.append_array(sv.slice(2 * k0, 2 * k1 + 2))
		nm.append_array(tr["nm"].slice(2 * k0, 2 * k1 + 2))
		uv.append_array(tr["uv"].slice(2 * k0, 2 * k1 + 2))
		uv2.append_array(tr["uv2"].slice(2 * k0, 2 * k1 + 2))
		if head_t > ts[k1]:
			var kind := float(tr["kind"])
			for side in [-1.0, 1.0]:
				v.append(head)
				nm.append(dir if dir.length_squared() > 0.5 else Vector3.UP)
				uv.append(Vector2(side, head_d))
				uv2.append(Vector2(head_t, kind))
	trail_mesh.clear_surfaces()
	last_trail_vertices = v.size()
	if v.size() >= 3:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = nm
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		trail_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLE_STRIP, arrays)
		trail_mesh.surface_set_material(0, trail_mat)

# A trail's strip, made once: every path point twice (the two edges; the shader spreads them
# apart facing the camera), its direction, how far along the path, and when the weapon was there.
func _make_strip(tr: Dictionary) -> void:
	var pts: PackedVector3Array = tr["pts"]
	var ts: PackedFloat64Array = tr["ts"]
	var n := pts.size()
	var v := PackedVector3Array()
	var nm := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	v.resize(2 * n)
	nm.resize(2 * n)
	uv.resize(2 * n)
	uv2.resize(2 * n)
	var dist := 0.0
	var kind := float(tr["kind"])
	for i in n:
		var d := pts[mini(i + 1, n - 1)] - pts[maxi(i - 1, 0)]
		d = d.normalized() if d.length_squared() > 1e-8 else Vector3.UP
		if i > 0:
			dist += pts[i].distance_to(pts[i - 1])
		for e in 2:
			v[2 * i + e] = pts[i]
			nm[2 * i + e] = d
			uv[2 * i + e] = Vector2(-1.0 if e == 0 else 1.0, dist)
			uv2[2 * i + e] = Vector2(ts[i], kind)
	tr["v"] = v
	tr["nm"] = nm
	tr["uv"] = uv
	tr["uv2"] = uv2

func _update_puffs(t: float, heads: Array) -> void:
	var buf := PackedFloat32Array()
	var i := source_t0.bsearch(t - source_longest)
	while i < sources.size() and source_t0[i] <= t:
		var s: Dictionary = sources[i]
		i += 1
		if t > s["t1"]:
			continue
		if not s.has("data"):
			if s["kind"] == "blast":
				_make_blast(s)
			else:
				_make_burn(s)
		var births: PackedFloat32Array = s["births"]
		var a := 0                   # an explosion: all of it (the shader hides what hasn't started)
		var b := births.size()
		if s["kind"] == "burn":
			a = births.bsearch(t - MAX_LIFE)
			b = births.bsearch(t, false)
		if b > a:
			buf.append_array(s["data"].slice(a * STRIDE, b * STRIDE))
	for h in heads:                  # motor glows and burning flares
		var kind: int = h[2]
		var size: float = [1.7, 5.0, 1.1][kind]
		var col: Color = [Color(1.0, 0.7, 0.35), Color(1.0, 0.88, 0.65), Color(1.0, 0.75, 0.4)][kind]
		var at: Vector3 = h[0] - h[1] * (1.6 if kind != 1 else 0.0)
		_put(buf, at, Vector3.ZERO, size, size, 1000.0, 0.0, 0.0, Kind.GLOW, col, t - 0.001,
			fmod(at.x * 0.013, 1.0), 0.0)
	var n := buf.size() / STRIDE
	last_particles = n
	if n > capacity:
		while capacity < n:
			capacity *= 2
		puffs.instance_count = capacity
	buf.resize(capacity * STRIDE)
	RenderingServer.multimesh_set_buffer(puffs.get_rid(), buf)
	puffs.visible_instance_count = n

# The brightest explosion of the last half second lights up the aircraft near it.
func _update_flash(t: float, cam_pos: Vector3) -> void:
	var best := -1.0
	var i: int = combat.explosion_t0.bsearch(t - 0.45)
	while i < combat.explosions.size() and combat.explosion_t0[i] <= t:
		var e: Dictionary = combat.explosions[i]
		i += 1
		var age: float = t - float(e["t"])
		var power: float = (1.0 - age / 0.45) / (1.0 + e["_pos"].distance_to(cam_pos) / 3000.0)
		if power > best:
			best = power
			var r := clampf(float(e["radius"]), 10.0, 80.0)
			flash.position = e["_pos"] + Vector3(0.0, r * 0.3, 0.0)
			flash.omni_range = r * 7.0
			flash.light_energy = 9.0 * pow(1.0 - age / 0.45, 2.0)
	flash.visible = best > 0.0

# --- making the particles ---

# One particle into buf: where it starts, its speed (m/s), size at the start and the end, life,
# drag, rise (m/s), kind, colour (alpha: how dense), when it starts, a random 0..1, spin (rad/s)
# and, for sparks, how long a streak (seconds of flight), for the others the ground height under
# it (it stays above that).
static func _put(buf: PackedFloat32Array, p: Vector3, v: Vector3, s0: float, s1: float, life: float,
		drag: float, rise: float, kind: int, c: Color, birth: float, seed: float, spin: float,
		stretch: float = -1e5) -> void:
	# MultiMesh 3D transform rows: (basis.x.x, basis.y.x, basis.z.x, origin.x), ... - the columns
	# carry the speed, the sizes and life, and drag / rise / kind (the shader reads them back)
	buf.append(v.x); buf.append(s0); buf.append(drag); buf.append(p.x)
	buf.append(v.y); buf.append(s1); buf.append(rise); buf.append(p.y)
	buf.append(v.z); buf.append(life); buf.append(float(kind)); buf.append(p.z)
	buf.append(c.r); buf.append(c.g); buf.append(c.b); buf.append(c.a)
	buf.append(birth); buf.append(seed); buf.append(spin); buf.append(stretch)

static func _rand_dir(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var a := rng.randf_range(0.0, TAU)
	var r := sqrt(1.0 - z * z)
	return Vector3(r * cos(a), z, r * sin(a))

func _ground_y(p: Vector3) -> float:
	return float(map.ground_at(p.x, p.z)[0]) if map != null else 0.0

# An explosion: flash, fireball, smoke and sparks (splash over water), made once.
func _make_blast(s: Dictionary) -> void:
	var e: Dictionary = s["e"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(e["t"]) + str(e["x"]))
	var at := Main.ys_vec(e["x"], e["y"], e["z"])
	var r := clampf(float(e.get("radius", 40.0)), 6.0, 90.0)
	var t0 := float(e["t"])
	var ground := _ground_y(at)
	var low := at.y - ground < r * 0.6
	var buf := PackedFloat32Array()
	if int(e.get("type", 0)) == 1:                     # water: a white splash
		for k in 22:
			var d := _rand_dir(rng)
			d.y = absf(d.y) * 2.5 + 0.8
			d = d.normalized()
			_put(buf, at + Vector3(0, 1, 0), d * rng.randf_range(15.0, 45.0), r * 0.15, r * rng.randf_range(0.5, 0.8),
				rng.randf_range(1.6, 2.8), 0.6, 0.0, Kind.SPRAY, Color(1, 1, 1, 0.8), t0 + rng.randf_range(0.0, 0.2),
				rng.randf(), rng.randf_range(-0.5, 0.5), at.y - 1e4)
		for k in 8:
			var p := at + Vector3(rng.randf_range(-r, r) * 0.4, r * 0.1, rng.randf_range(-r, r) * 0.4)
			_put(buf, p, _rand_dir(rng) * 3.0, r * 0.5, r * 1.5, rng.randf_range(4.0, 6.0), 0.8, 1.5, Kind.SMOKE,
				Color(0.7, 0.72, 0.75, 0.5), t0 + rng.randf_range(0.1, 0.5), rng.randf(), rng.randf_range(-0.2, 0.2),
				ground)
	else:
		var centre := at
		if low:                                        # on the ground: the fireball sits on it
			centre.y = maxf(at.y, ground + r * 0.25)
		# smoke first (drawn under the fire), rising and spreading
		for k in 12:
			var d := _rand_dir(rng)
			if low:
				d.y = absf(d.y)
			var gray := rng.randf_range(0.07, 0.13)
			_put(buf, centre + d * r * rng.randf_range(0.0, 0.35), d * r * rng.randf_range(0.5, 1.1),
				r * rng.randf_range(0.45, 0.65), r * rng.randf_range(1.3, 1.9), rng.randf_range(6.0, 10.0), 1.4,
				rng.randf_range(2.5, 5.0), Kind.SMOKE, Color(gray, gray * 0.97, gray * 0.92, 0.7),
				t0 + rng.randf_range(0.15, 0.6), rng.randf(), rng.randf_range(-0.25, 0.25), ground)
		if low:                                        # dust thrown up round it
			for k in 7:
				var d := Vector3(rng.randf_range(-1, 1), 0.15, rng.randf_range(-1, 1)).normalized()
				var p := Vector3(centre.x, ground + r * 0.2, centre.z)
				_put(buf, p, d * r * rng.randf_range(1.0, 2.0), r * 0.5, r * rng.randf_range(1.6, 2.3),
					rng.randf_range(6.0, 9.0), 1.2, 1.0, Kind.SMOKE, Color(0.16, 0.13, 0.09, 0.6),
					t0 + rng.randf_range(0.0, 0.3), rng.randf(), rng.randf_range(-0.15, 0.15), ground)
		for k in 16:                                   # the fireball
			var d := _rand_dir(rng)
			if low:
				d.y = absf(d.y)
			_put(buf, centre + d * r * rng.randf_range(0.0, 0.2), d * r * rng.randf_range(1.2, 2.6),
				r * rng.randf_range(0.3, 0.45), r * rng.randf_range(0.75, 1.05), rng.randf_range(0.9, 1.7), 3.2,
				rng.randf_range(1.0, 4.0), Kind.FIRE, Color(1, 1, 1, 1), t0 + rng.randf_range(0.0, 0.12),
				rng.randf(), rng.randf_range(-0.8, 0.8), ground)
		for k in 22:                                   # sparks
			var d := _rand_dir(rng)
			if low:
				d.y = absf(d.y) + 0.2
			_put(buf, centre, d.normalized() * rng.randf_range(70.0, 170.0), 0.9, 0.5, rng.randf_range(0.5, 1.4), 1.1,
				0.0, Kind.SPARK, Color(1, 1, 1, 1), t0 + rng.randf_range(0.0, 0.08), rng.randf(), 0.0, 0.045)
		_put(buf, centre, Vector3.ZERO, r * 0.7, r * 2.0, 0.25, 0.0, 0.0, Kind.FLASH, Color(1, 1, 1, 1), t0,
			rng.randf(), 0.0, ground)
	_finish(s, buf)

# An aircraft going down: fire and black smoke every few metres of its fall (in time order), and,
# if it came down on the ground, a column of smoke rising from the wreck.
func _make_burn(s: Dictionary) -> void:
	var frames: Array = entities[s["id"]]["telemetry"]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(str(s["id"]) + str(s["from"]))
	var buf := PackedFloat32Array()
	var te: float = s["from"]
	var t_end: float = s["to"]
	var last: Vector3 = Main.ys_position(frames[-1])
	var last_ground := _ground_y(last)
	while te <= t_end:
		var at: Array = Main._filtered(frames, Main.frame_index_at(frames, te), te)   # as drawn
		var p: Vector3 = at[0]
		var v: Vector3 = at[1]
		# the ground under it matters only low down (looking it up costs a little)
		var floor_y := _ground_y(p) if p.y < last_ground + 300.0 else -1e4
		var gray := rng.randf_range(0.025, 0.045)
		_put(buf, p + _rand_dir(rng) * 1.2, v * 0.12 + _rand_dir(rng) * 2.0, rng.randf_range(5.0, 7.0),
			rng.randf_range(16.0, 26.0), rng.randf_range(6.5, 9.0), 1.2, 2.5, Kind.SMOKE,
			Color(gray, gray, gray, 0.8), te, rng.randf(), rng.randf_range(-0.3, 0.3), floor_y)
		_put(buf, p + _rand_dir(rng) * 0.8, v * 0.05 + _rand_dir(rng) * 1.5, rng.randf_range(3.0, 4.5),
			rng.randf_range(5.5, 8.0), rng.randf_range(0.35, 0.6), 2.0, 1.5, Kind.FIRE, Color(1, 1, 1, 1), te,
			rng.randf(), rng.randf_range(-1.0, 1.0), floor_y)
		te += clampf(PUFF_SPACING / maxf(v.length(), 1.0), 0.02, 0.1)
	if last.y - last_ground < 40.0:                   # a wreck on the ground
		var base := Vector3(last.x, last_ground + 2.0, last.z)
		var tw := t_end
		while tw < t_end + WRECK_TIME:
			var fade := 1.0 - (tw - t_end) / WRECK_TIME
			var gray := rng.randf_range(0.035, 0.065)
			_put(buf, base + Vector3(rng.randf_range(-4, 4), 0, rng.randf_range(-4, 4)),
				Vector3(rng.randf_range(-1.5, 1.5), rng.randf_range(9.0, 13.0), rng.randf_range(-1.5, 1.5)),
				rng.randf_range(8.0, 12.0), rng.randf_range(40.0, 60.0), rng.randf_range(11.0, 15.0), 0.1, 0.0,
				Kind.SMOKE, Color(gray, gray, gray, 0.75 * fade), tw, rng.randf(), rng.randf_range(-0.2, 0.2),
				last_ground)
			if tw < t_end + 15.0:
				_put(buf, base + Vector3(rng.randf_range(-3, 3), 0, rng.randf_range(-3, 3)),
					Vector3(0, rng.randf_range(3.0, 5.0), 0), rng.randf_range(4.0, 6.0), rng.randf_range(7.0, 10.0),
					rng.randf_range(0.5, 0.9), 0.5, 1.0, Kind.FIRE, Color(1, 1, 1, 1), tw + 0.1, rng.randf(),
					rng.randf_range(-1.0, 1.0), last_ground)
			tw += 0.25
	# already in time order: the fall's puffs, then the wreck's (a window of them is cut out by time)
	_finish(s, buf)

func _finish(s: Dictionary, buf: PackedFloat32Array) -> void:
	var n := buf.size() / STRIDE
	var births := PackedFloat32Array()
	births.resize(n)
	for k in n:
		births[k] = buf[k * STRIDE + 16]
	s["data"] = buf
	s["births"] = births
