shader_type sky;

uniform vec4 sky_top_color : source_color = vec4(0.25, 0.48, 0.72, 1.0);
uniform vec4 sky_horizon_color : source_color = vec4(0.72, 0.80, 0.85, 1.0);
uniform vec4 ground_bottom_color : source_color = vec4(0.20, 0.22, 0.20, 1.0);
uniform vec4 ground_horizon_color : source_color = vec4(0.72, 0.80, 0.85, 1.0);
uniform sampler2D cloud_noise : repeat_enable, filter_linear_mipmap;
uniform vec2 cloud_offset = vec2(0.0);
uniform float cloud_cover = 0.30;
uniform float storm = 0.0;
uniform float dust = 0.0;
uniform vec3 sun_direction = vec3(0.3, 0.8, 0.4);
uniform vec4 sun_color : source_color = vec4(1.0);
uniform float daylight = 1.0;

float cloud_field(vec2 p) {
	return texture(cloud_noise, p).r * 0.57
		+ texture(cloud_noise, p * 2.17 + vec2(0.17, 0.31)).r * 0.29
		+ texture(cloud_noise, p * 5.1).r * 0.14;
}

void sky() {
	float elevation = max(EYEDIR.y, 0.0);
	vec3 base = mix(sky_horizon_color.rgb, sky_top_color.rgb, pow(elevation, 0.42));
	if (EYEDIR.y < 0.0) {
		base = mix(sky_horizon_color.rgb, ground_bottom_color.rgb, smoothstep(0.0, 0.65, -EYEDIR.y));
	}
	float sun_dot = max(dot(EYEDIR, normalize(sun_direction)), 0.0);
	base += sun_color.rgb * pow(sun_dot, mix(32.0, 6.0, dust)) * daylight * 0.12;
	if (!AT_CUBEMAP_PASS && EYEDIR.y > 0.0) {
		vec2 p = EYEDIR.xz / (elevation + 0.23) * 0.22 + cloud_offset;
		float field = cloud_field(p);
		float threshold = mix(0.65, 0.26, cloud_cover);
		float bank = smoothstep(threshold, threshold + 0.14, field);
		bank = max(bank, smoothstep(0.70, 1.0, cloud_cover) * 0.94);
		float detail = cloud_field(p + vec2(0.014, 0.009));
		float rim = clamp((field - detail) * 5.0 + 0.62, 0.2, 1.0);
		vec3 lit_cloud = mix(vec3(0.032, 0.044, 0.069), vec3(0.94, 0.95, 0.94), daylight);
		lit_cloud *= mix(0.72, 1.06, rim);
		lit_cloud = mix(lit_cloud, mix(vec3(0.025, 0.035, 0.05), vec3(0.17, 0.20, 0.25) * (0.7 + rim * 0.5), daylight), storm);
		lit_cloud = mix(lit_cloud, sky_horizon_color.rgb, (1.0 - smoothstep(0.0, 0.22, elevation)) * 0.75);
		base = mix(base, lit_cloud, bank * (1.0 - dust * 0.60) * smoothstep(0.0, 0.055, elevation));
		float disc = smoothstep(0.99994, 0.99998, sun_dot);
		base += sun_color.rgb * disc * daylight * (1.0 - bank) * (1.0 - dust * 0.9) * 2.0;
	}
	COLOR = base;
}
