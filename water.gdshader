shader_type spatial;
render_mode blend_mix, cull_back;

uniform sampler2D field : filter_linear, repeat_disable;
uniform float size = 96.0;
uniform vec3 shallow : source_color = vec3(0.36, 0.80, 0.76);
uniform vec3 deep : source_color = vec3(0.06, 0.42, 0.50);

varying float depth;

vec2 at(vec2 uv) { return textureLod(field, uv, 0.0).rg; }
float surf(vec2 uv) { vec2 v = at(uv); return v.x + v.y; }

void vertex() {
	vec2 uv = (VERTEX.xz + size * 0.5) / size;
	vec2 v = at(uv);
	depth = v.y;
	VERTEX.y = v.y > 0.02 ? v.x + v.y : v.x - 0.1;
	float e = 1.0 / size;
	NORMAL = normalize(vec3(surf(uv - vec2(e, 0.0)) - surf(uv + vec2(e, 0.0)), 2.0,
			surf(uv - vec2(0.0, e)) - surf(uv + vec2(0.0, e))));
}

void fragment() {
	vec2 p = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xz;
	float rip = sin(p.x * 1.7 + TIME * 1.3) + sin(p.y * 2.1 - TIME * 1.1);
	NORMAL = normalize(NORMAL + VIEW_MATRIX[0].xyz * rip * 0.04);
	vec3 col = mix(shallow, deep, smoothstep(0.1, 2.2, depth));
	col = mix(vec3(0.95), col, smoothstep(0.04, 0.2, depth)); // shore foam
	ALBEDO = col;
	ALPHA = mix(0.55, 0.92, smoothstep(0.05, 1.5, depth)) * smoothstep(0.0, 0.05, depth);
	ROUGHNESS = 0.08;
	SPECULAR = 0.6;
}
