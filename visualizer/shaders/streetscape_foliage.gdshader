shader_type spatial;
render_mode cull_disabled, diffuse_burley;

uniform vec3 wind = vec3(1.6, 0.0, 0.5);
varying float leaf_light;
varying float bloom;
varying float bloom_hue;
void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float breeze = sin(TIME * 1.3 + world.x * 0.7 + world.z * 0.6);
	VERTEX.xz += wind.xz * breeze * 0.014 * UV.y;
	leaf_light = COLOR.r;
	// Instance blue of zero marks blossom: flamboyant red when green is high,
	// bougainvillea magenta when it is low. Leaves always carry blue above 0.05.
	bloom = 1.0 - step(0.02, COLOR.b);
	bloom_hue = COLOR.g;
}
void fragment() {
	float vein = 1.0 - smoothstep(0.0, 0.035, abs(UV.x - 0.5));
	// Deep mango and neem greens; the bright end stays a sunlit tropical green.
	vec3 leaf = mix(vec3(0.030, 0.082, 0.020), vec3(0.150, 0.270, 0.055), leaf_light);
	leaf += vein * vec3(0.025, 0.028, 0.005);
	vec3 petal = mix(vec3(0.60, 0.035, 0.22), vec3(0.78, 0.115, 0.02), step(0.5, bloom_hue));
	petal *= 0.55 + leaf_light * 1.6;
	ALBEDO = mix(leaf, petal, bloom);
	ROUGHNESS = 0.86;
	SPECULAR = 0.18;
	BACKLIGHT = mix(vec3(0.12, 0.17, 0.035), vec3(0.20, 0.05, 0.04), bloom);
}
