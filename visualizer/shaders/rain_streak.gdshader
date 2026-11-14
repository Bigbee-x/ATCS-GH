shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec3 fall_direction = vec3(0.10, -1.0, 0.02);
uniform float intensity = 0.0;
varying vec3 rain_world;
void vertex() {
	// Face the camera while retaining the projected wind slant.
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 along = normalize(fall_direction);
	vec3 across = normalize(cross(along, INV_VIEW_MATRIX[2].xyz));
	rain_world = center + across * VERTEX.x - along * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(rain_world, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(VERTEX, 1.0);
}
void fragment() {
	if (rain_world.y < 0.16) { discard; }
	float taper = sin(UV.y * 3.14159) * (1.0 - abs(UV.x * 2.0 - 1.0));
	ALBEDO = vec3(0.70, 0.78, 0.84);
	ALPHA = taper * intensity * 0.43;
}
