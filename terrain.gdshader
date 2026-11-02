shader_type spatial;

// field: R = terrain height, G = water depth, B = rock, A = original height
uniform sampler2D field : filter_linear, repeat_disable;
uniform float size = 96.0;
uniform vec3 sand : source_color = vec3(0.93, 0.80, 0.58);
uniform vec3 grass : source_color = vec3(0.47, 0.58, 0.34);
uniform vec3 rock_col : source_color = vec3(0.55, 0.50, 0.45);

varying vec4 f;

vec4 at(vec2 uv) { return textureLod(field, uv, 0.0); }

void vertex() {
	vec2 uv = (VERTEX.xz + size * 0.5) / size;
	f = at(uv);
	VERTEX.y = f.r;
	float e = 1.0 / size;
	float hl = at(uv - vec2(e, 0.0)).r;
	float hr = at(uv + vec2(e, 0.0)).r;
	float hd = at(uv - vec2(0.0, e)).r;
	float hu = at(uv + vec2(0.0, e)).r;
	NORMAL = normalize(vec3(hl - hr, 2.0, hd - hu));
}

void fragment() {
	vec3 col = mix(sand, grass, smoothstep(2.6, 3.4, f.r));
	col = mix(col, rock_col, smoothstep(0.4, 0.6, f.b));
	col = mix(col, sand * 0.8, smoothstep(0.15, 0.6, f.a - f.r)); // freshly dug sand
	col = mix(col, sand * 0.62, smoothstep(0.0, 0.06, f.g));      // wet sand
	ALBEDO = col;
	ROUGHNESS = 0.95;
}
