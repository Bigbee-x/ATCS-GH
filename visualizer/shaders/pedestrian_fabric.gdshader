shader_type spatial;
uniform vec4 cloth_color : source_color = vec4(0.3, 0.4, 0.35, 1.0);
uniform bool striped = false;
void fragment() {
	vec2 weave_uv = UV * vec2(180.0, 380.0);
	float fade = 1.0 - smoothstep(0.4, 1.4, max(fwidth(weave_uv.x), fwidth(weave_uv.y)));
	float weave = sin(weave_uv.x * 6.283) * sin(weave_uv.y * 6.283) * fade;
	float band = striped ? smoothstep(0.03, 0.08, fract(UV.y * 27.0)) * (1.0 - smoothstep(0.20, 0.25, fract(UV.y * 27.0))) : 0.0;
	ALBEDO = cloth_color.rgb * (0.97 + weave * 0.035 - band * 0.2);
	ROUGHNESS = 0.94;
	SPECULAR = 0.16;
}
