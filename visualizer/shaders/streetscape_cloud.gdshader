shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D cloud_noise : repeat_enable, filter_linear_mipmap;
uniform vec4 cloud_color : source_color = vec4(1.0);

void fragment() {
	vec2 uv = UV * 2.5;
	float broad = texture(cloud_noise, uv * 0.18).r;
	float detail = texture(cloud_noise, uv * 0.8).r;
	float shape = broad * 0.85 + detail * 0.15;
	float edge = 1.0 - smoothstep(0.24, 0.5, length((UV - 0.5) * vec2(1.0, 1.2)));
	ALPHA = smoothstep(0.28, 0.59, shape) * edge * 0.88;
	ALBEDO = cloud_color.rgb * mix(0.7, 1.0, smoothstep(0.3, 0.7, shape));
}
