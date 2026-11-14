shader_type spatial;
render_mode cull_disabled, diffuse_burley;

uniform vec3 wind = vec3(1.6, 0.0, 0.5);
varying float leaf_light;
void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float breeze = sin(TIME * 1.3 + world.x * 0.7 + world.z * 0.6);
	VERTEX.xz += wind.xz * breeze * 0.014 * UV.y;
	leaf_light = COLOR.r;
}
void fragment() {
	float vein = 1.0 - smoothstep(0.0, 0.035, abs(UV.x - 0.5));
	ALBEDO = mix(vec3(0.055, 0.115, 0.025), vec3(0.17, 0.27, 0.065), leaf_light);
	ALBEDO += vein * vec3(0.025, 0.028, 0.005);
	ROUGHNESS = 0.86;
	SPECULAR = 0.18;
	BACKLIGHT = vec3(0.12, 0.17, 0.035);
}
