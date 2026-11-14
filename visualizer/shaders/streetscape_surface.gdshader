shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// World-space materials: the grain stays the same size on a shop and a tower.
uniform sampler2D grain : repeat_enable, filter_linear_mipmap;
uniform sampler2D albedo_map : source_color, repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D height_map : repeat_enable, filter_linear_mipmap_anisotropic;
uniform sampler2D roughness_map : repeat_enable, filter_linear_mipmap_anisotropic;
uniform bool photographed = false;
uniform float tile_size = 2.0;
uniform vec4 tint : source_color = vec4(0.65, 0.58, 0.46, 1.0);
// plaster, asphalt, concrete, ground, sheet metal, paving, bark
uniform int surface_kind = 0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

float noise_at(vec2 p) {
	return texture(grain, p / 12.0).r;
}

void fragment() {
	vec3 n = abs(normalize(world_normal));
	vec2 p = world_pos.xz;
	if (n.y < 0.55) {
		p = n.x > n.z ? world_pos.zy : world_pos.xy;
	}
	float macro = noise_at(p * 0.3);
	float medium = noise_at(p * 3.0);
	float fine = noise_at(p * 18.0);
	vec3 color = tint.rgb * (0.78 + macro * 0.25 + medium * 0.16);
	float relief = fine * 0.002;
	float rough = 0.88;
	float metal = 0.0;
	vec3 photographed_color = vec3(1.0);
	float photographed_height = 0.5;
	if (photographed) {
		vec2 uv = p / tile_size;
		photographed_color = texture(albedo_map, uv).rgb;
		photographed_height = texture(height_map, uv).r;
		rough = clamp(texture(roughness_map, uv).r, 0.55, 1.0);
		// Normalize the grey scan so each facade keeps its chosen paint color.
		float value = dot(photographed_color, vec3(0.2126, 0.7152, 0.0722));
		color *= clamp(value / (surface_kind == 1 ? 0.145 : 0.072), 0.3, 1.8);
		relief = (photographed_height - 0.5) * 0.0015;
	}
	if (surface_kind == 0) {
		// Mottled render, rising damp and irregular areas of exposed plaster.
		float stains = smoothstep(0.53, 0.76, noise_at(p * vec2(2.8, 0.28)));
		float base_dirt = exp(-max(world_pos.y, 0.0) * 2.5);
		color *= 1.0 - stains * 0.19 - base_dirt * 0.26;
		color = mix(color, vec3(0.32, 0.29, 0.24), smoothstep(0.73, 0.84, medium) * 0.28);
	} else if (surface_kind == 1) {
		// Photographed aggregate and cracks, with broad faded repair patches.
		float repairs = smoothstep(0.40, 0.65, noise_at(p * 0.24));
		color *= 0.92 + repairs * 0.16;
		relief = (photographed_height - 0.5) * 0.003;
		rough = max(rough, 0.82);
	} else if (surface_kind == 2 || surface_kind == 5) {
		vec2 cells = p / (surface_kind == 5 ? vec2(0.42, 0.24) : vec2(1.1, 0.8));
		cells.x += mod(floor(cells.y), 2.0) * 0.5;
		vec2 edge = min(fract(cells), 1.0 - fract(cells));
		float seam = 1.0 - smoothstep(0.008, 0.025, min(edge.x, edge.y));
		color *= 1.0 - seam * 0.28;
		relief += fine * 0.003 - seam * 0.008;
	} else if (surface_kind == 3) {
		// Dry laterite and irregular grass, rather than a uniform green carpet.
		float vegetation = smoothstep(0.45, 0.8, noise_at(p * 0.32));
		vec3 soil = photographed_color * vec3(0.7, 0.66, 0.58);
		color = mix(soil, soil * vec3(0.55, 0.75, 0.36), vegetation * 0.55);
		color *= 0.9 + macro * 0.2;
		relief = (photographed_height - 0.5) * 0.045;
	} else if (surface_kind == 4) {
		float ribs = sin((world_pos.x + world_pos.z) * 72.0);
		float fade = 1.0 - smoothstep(0.8, 3.0, fwidth((world_pos.x + world_pos.z) * 72.0));
		float rust = smoothstep(0.58, 0.75, medium);
		color = mix(color, vec3(0.24, 0.105, 0.045), rust * 0.33);
		color *= 0.91 + ribs * fade * 0.065;
		relief = ribs * fade * 0.007;
		rough = 0.52 + rust * 0.3;
		metal = 0.35;
	} else if (surface_kind == 6) {
		float bark = noise_at(p * vec2(18.0, 1.6));
		color *= 0.6 + bark * 0.65;
		relief = bark * 0.025;
	}
	// Water gathers on upward-facing paved surfaces, leaving irregular dry islands.
	float pavement = (surface_kind == 1 || surface_kind == 2 || surface_kind == 5) ? 1.0 : 0.0;
	float pooling = pavement * smoothstep(0.85, 0.99, world_normal.y);
	float hollows = noise_at(p * 0.46) * 0.7 + noise_at(p * 1.4) * 0.3;
	float puddle = smoothstep(0.60 - wetness * 0.25, 0.68 - wetness * 0.25, hollows) * pooling * wetness;
	vec2 rain_cell = floor(p * 2.4);
	float seed = fract(sin(dot(rain_cell, vec2(127.1, 311.7))) * 43758.5453);
	vec2 center = vec2(seed, fract(seed * 13.37)) * 0.6 + 0.2;
	float age = fract(TIME * 0.85 + seed);
	float radius = length(fract(p * 2.4) - center);
	float ring = sin((radius - age * 0.65) * 68.0) * exp(-abs(radius - age * 0.65) * 28.0) * (1.0 - age);
	relief = mix(relief, ring * 0.0015 * rain_intensity, puddle);
	// Surface-gradient bump mapping works on generated meshes without tangents.
	vec3 dx = dFdx(VERTEX);
	vec3 dy = dFdy(VERTEX);
	vec3 r1 = cross(dy, NORMAL);
	vec3 r2 = cross(NORMAL, dx);
	float determinant = dot(dx, r1);
	vec3 gradient = sign(determinant) * (dFdx(relief) * r1 + dFdy(relief) * r2);
	NORMAL = normalize(max(abs(determinant), 0.000001) * NORMAL - gradient);
	float wet = wetness * (surface_kind == 1 ? 0.85 : 0.35);
	ALBEDO = color * (1.0 - wet * 0.3);
	ROUGHNESS = mix(mix(rough, 0.35, wet), 0.085, puddle);
	METALLIC = metal;
	SPECULAR = mix(0.2, 0.60, puddle);
	CLEARCOAT = puddle * 0.65;
	CLEARCOAT_ROUGHNESS = 0.10;
}
