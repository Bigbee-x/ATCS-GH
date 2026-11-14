shader_type spatial;
render_mode diffuse_burley;
// ITE pedestrian module: raised hand (Portland orange) or walking person (lunar
// white), drawn as an LED pictogram so it reads like the vehicle lenses.
uniform vec4 signal_color : source_color = vec4(1.0, 0.54, 0.12, 1.0);
uniform float active : hint_range(0.0, 1.0) = 0.0;
uniform bool person = false;

float seg(vec2 p, vec2 a, vec2 b, float r) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - r;
}

float rbox(vec2 p, vec2 c, vec2 h, float r) {
	vec2 d = abs(p - c) - h + vec2(r);
	return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

void fragment() {
	vec2 p = vec2(UV.x - 0.5, 0.5 - UV.y);
	float d;
	if (person) {
		d = length(p - vec2(0.03, 0.30)) - 0.06;
		d = min(d, seg(p, vec2(0.02, 0.20), vec2(-0.01, -0.03), 0.05));
		d = min(d, seg(p, vec2(-0.01, -0.03), vec2(-0.14, -0.32), 0.042));
		d = min(d, seg(p, vec2(-0.01, -0.03), vec2(0.10, -0.17), 0.042));
		d = min(d, seg(p, vec2(0.10, -0.17), vec2(0.07, -0.33), 0.038));
		d = min(d, seg(p, vec2(0.01, 0.15), vec2(0.15, 0.04), 0.034));
		d = min(d, seg(p, vec2(0.01, 0.15), vec2(-0.13, 0.05), 0.034));
	} else {
		d = rbox(p, vec2(0.0, -0.10), vec2(0.15, 0.14), 0.06);
		d = min(d, seg(p, vec2(-0.105, -0.02), vec2(-0.105, 0.20), 0.036));
		d = min(d, seg(p, vec2(-0.035, -0.02), vec2(-0.035, 0.27), 0.036));
		d = min(d, seg(p, vec2(0.035, -0.02), vec2(0.035, 0.26), 0.036));
		d = min(d, seg(p, vec2(0.105, -0.02), vec2(0.105, 0.20), 0.036));
		d = min(d, seg(p, vec2(0.13, -0.12), vec2(0.25, 0.01), 0.038));
	}
	float symbol = 1.0 - smoothstep(-0.008, 0.008, d);
	vec2 cell = fract(UV * 24.0) - 0.5;
	float led = 1.0 - smoothstep(0.24, 0.40, length(cell));
	ALBEDO = mix(vec3(0.012, 0.016, 0.016), signal_color.rgb * 0.10, symbol * led);
	EMISSION = signal_color.rgb * active * symbol * (0.25 + led * 2.0);
	ROUGHNESS = 0.24;
	SPECULAR = 0.5;
}
