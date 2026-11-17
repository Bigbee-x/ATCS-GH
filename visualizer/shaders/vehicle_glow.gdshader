shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, fog_disabled, shadows_disabled;

// Additive lamp halos and the pool a vehicle's lights throw on the road.
// UV.y in 0..1 is a round lamp halo with a hot core; UV.y in 2..3 is the
// tapering ground pool, 2 at the bumper and 3 at its far end. The vertex
// colour is the light colour and its alpha the strength. `boost` brightens one
// vehicle's rear set while it brakes.
instance uniform float boost = 1.0;
varying vec4 tint;

void vertex() {
	tint = COLOR;
}

void fragment() {
	float shape;
	if (UV.y > 1.5) {
		float along = UV.y - 2.0;
		float across = 1.0 - pow(abs(UV.x * 2.0 - 1.0), 2.0);
		shape = smoothstep(0.0, 0.06, along) * pow(1.0 - along, 1.7) * across;
	} else {
		vec2 c = UV * 2.0 - 1.0;
		float r = dot(c, c);
		shape = pow(max(1.0 - r, 0.0), 3.0) + pow(max(1.0 - r * 10.0, 0.0), 2.0) * 1.6;
	}
	ALBEDO = tint.rgb * tint.a * shape * boost;
}
