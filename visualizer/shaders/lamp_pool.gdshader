shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back, fog_disabled, shadows_disabled;

// Warm pool of street-lamp light laid on the road. Real spot lights do the work
// close to the camera; these quads take over as the lights fade with distance,
// so the lit corridor still reads from the drone.
uniform float level = 0.0;
uniform vec3 glow : source_color = vec3(1.0, 0.84, 0.60);
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 c = UV * 2.0 - 1.0;
	float pool = pow(max(1.0 - dot(c, c), 0.0), 2.0);
	float far = smoothstep(140.0, 330.0, distance(CAMERA_POSITION_WORLD, world_pos));
	ALBEDO = glow * pool * level * mix(0.05, 0.16, far);
}
