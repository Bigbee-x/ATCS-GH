shader_type spatial;
render_mode diffuse_burley;
uniform vec4 signal_color : source_color = vec4(1.0, 0.12, 0.04, 1.0);
uniform float active : hint_range(0.0, 1.0) = 0.0;
uniform bool arrow = false;
void fragment() {
	vec2 p = UV - 0.5;
	float circle = 1.0 - step(0.485, length(p));
	vec2 cell = fract(UV * 17.0) - 0.5;
	float led = 1.0 - smoothstep(0.26, 0.38, length(cell));
	float symbol = 1.0;
	if (arrow) {
		// Local -X is left when viewed from the approaching driver's side (+Z).
		float shaft = step(-0.08, p.x) * step(p.x, 0.30) * step(abs(p.y), 0.065);
		float tip = step(-0.31, p.x) * step(p.x, -0.015) * step(abs(p.y), (p.x + 0.31) * 0.9);
		symbol = max(shaft, tip);
	}
	ALBEDO = mix(vec3(0.012, 0.018, 0.016), signal_color.rgb * 0.12, led * symbol);
	EMISSION = signal_color.rgb * active * symbol * (0.22 + led * 2.0);
	ROUGHNESS = 0.24;
	SPECULAR = 0.55;
	ALPHA = circle;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
