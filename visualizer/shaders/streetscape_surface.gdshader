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
// plaster, asphalt, concrete, ground, sheet metal, paving, bark, turf, laterite,
// unjointed urban hardstand, natural hinterland, sandcrete blockwork
uniform int surface_kind = 0;
uniform float wetness : hint_range(0.0, 1.0) = 0.0;
uniform float rain_intensity : hint_range(0.0, 1.0) = 0.0;
// Kind 10 only: built-up area (min x, min z, max x, max z) whose ground is trodden
// bare. A zero-size rectangle leaves the whole plane as open savanna.
uniform vec4 town_rect = vec4(0.0);
// Kind 10 only: up to two fully paved, clean districts inside the town, in the
// same (min x, min z, max x, max z) form. Zero size disables each.
uniform vec4 paved_a = vec4(0.0);
uniform vec4 paved_b = vec4(0.0);
varying vec3 world_pos;
varying vec3 world_normal;
// Batched streetscape parts share one material per surface kind and carry
// their paint as an sRGB instance colour. Other meshes leave COLOR white.
varying vec3 paint;
// Instance alpha below one marks a well-kept building: less splash-back and rust.
varying float dirt;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	paint = mix(pow((COLOR.rgb + 0.055) / 1.055, vec3(2.4)), COLOR.rgb / 12.92, lessThan(COLOR.rgb, vec3(0.04045)));
	dirt = COLOR.a;
}

float paved_zone(vec2 p, vec4 r) {
	float depth = min(min(p.x - r.x, r.z - p.x), min(p.y - r.y, r.w - p.y));
	float ragged = (fract(sin(dot(floor(p * 0.35), vec2(12.9898, 78.233))) * 43758.5453) - 0.5) * 2.4;
	return smoothstep(-1.5, 1.5, depth + ragged) * step(0.5, r.z - r.x);
}

float noise_at(vec2 p) {
	return texture(grain, p / 12.0).r;
}

// Non-periodic world noise for large areas: no repeated 4 m photograph or
// high-frequency bump pattern should become a checkerboard from the drone.
float ground_hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float ground_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(ground_hash(i), ground_hash(i+vec2(1,0)), f.x),
		mix(ground_hash(i+vec2(0,1)), ground_hash(i+vec2(1,1)), f.x), f.y);
}

void fragment() {
	vec3 base_tint = tint.rgb * paint;
	vec3 n = abs(normalize(world_normal));
	vec2 p = world_pos.xz;
	if (n.y < 0.55) {
		p = n.x > n.z ? world_pos.zy : world_pos.xy;
	}
	float macro = noise_at(p * 0.3);
	float medium = noise_at(p * 3.0);
	float fine = noise_at(p * 18.0);
	vec3 color = base_tint * (0.78 + macro * 0.25 + medium * 0.16);
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
	if (surface_kind == 0 && n.y < 0.55) {
		// Painted sandcrete wall. The grey scan only modulates the paint a little;
		// sun-faded patches, dark rain streaks and the red laterite splash-back at
		// the foot of the wall do the weathering. Upward faces keep the older look
		// below, which the carriageway surface also relies on.
		color = base_tint * (0.88 + macro * 0.14 + medium * 0.08);
		float value = dot(photographed_color, vec3(0.2126, 0.7152, 0.0722));
		color *= photographed ? mix(1.0, clamp(value / 0.072, 0.5, 1.5), 0.30) : 1.0;
		float faded = smoothstep(0.50, 0.82, noise_at(p * 0.13 + 7.0));
		color = mix(color, color * 1.06 + 0.035, faded * 0.5);
		float streaks = smoothstep(0.56, 0.80, noise_at(p * vec2(3.1, 0.20)));
		color *= 1.0 - streaks * 0.16;
		float splash = exp(-max(world_pos.y - 0.08, 0.0) * 1.9) * (0.42 + medium * 0.75);
		color = mix(color, vec3(0.25, 0.105, 0.045) * (0.8 + fine * 0.4), clamp(splash, 0.0, 0.62) * dirt);
	} else if (surface_kind == 0) {
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
		// Accra groundcover, green by the user's choice (17 Nov): rainy-season grass
		// over laterite, olive where it dries in broad swathes, red earth worn through
		// only in small patches. Albedos are true linear values (grass reflects about
		// 10% green). The soil photograph only shows near the camera; from the air
		// its tiling would read as a dotted grid.
		float near3 = 1.0 - smoothstep(0.02, 0.30, length(fwidth(p)));
		float cover = smoothstep(0.22, 0.40, noise_at(p * 0.32) * 0.62 + medium * 0.20
			+ ground_noise(p * 0.035) * 0.34 - 0.08);
		vec3 soil = mix(vec3(0.235, 0.105, 0.052), photographed_color * vec3(0.78, 0.60, 0.68), near3);
		soil *= mix(1.0, 0.74, smoothstep(0.55, 0.85, ground_noise(p * 0.09 + 31.0)));
		soil = mix(soil, vec3(0.30, 0.17, 0.10), smoothstep(0.50, 0.80, ground_noise(p * 0.045 + 61.0)) * 0.5);
		float detail = clamp(dot(photographed_color, vec3(0.3333)) / 0.19, 0.4, 1.8);
		float dryness = smoothstep(0.38, 0.80, noise_at(p * 0.085 + vec2(17.0, 3.0)));
		vec3 grass = mix(vec3(0.046, 0.102, 0.026), vec3(0.112, 0.118, 0.042), dryness);
		grass *= mix(1.0, detail, 0.32 * near3) * (0.84 + medium * 0.22) * (0.9 + fine * 0.2);
		color = mix(soil, grass, cover);
		color *= 0.9 + macro * 0.2;
		relief = (photographed_height - 0.5) * 0.045 * near3;
	} else if (surface_kind == 4) {
		float ribs = sin((world_pos.x + world_pos.z) * 72.0);
		float fade = 1.0 - smoothstep(0.8, 3.0, fwidth((world_pos.x + world_pos.z) * 72.0));
		float rust = smoothstep(0.58, 0.75, medium) * mix(0.3, 1.0, dirt);
		color = mix(color, vec3(0.24, 0.105, 0.045), rust * 0.33);
		color *= 0.91 + ribs * fade * 0.065;
		relief = ribs * fade * 0.007;
		rough = 0.72 + rust * 0.2;
		// Painted/corroded sheet roofs have a mostly dielectric top surface.
		metal = 0.08;
	} else if (surface_kind == 6) {
		float bark = noise_at(p * vec2(18.0, 1.6));
		color *= 0.6 + bark * 0.65;
		relief = bark * 0.025;
	} else if (surface_kind == 7) {
		// Mown turf: the stripe colour with fine blade grain and faint clumping.
		color = base_tint * (0.86 + medium * 0.12 + fine * 0.14);
		relief = fine * 0.008;
		rough = 0.93;
	} else if (surface_kind == 8) {
		// Bare laterite: tracks, yards and tilled plots in the same earth as kind 3.
		float near8 = 1.0 - smoothstep(0.02, 0.30, length(fwidth(p)));
		color = mix(vec3(0.235, 0.105, 0.052), photographed_color * vec3(0.78, 0.60, 0.68), near8) * base_tint;
		color *= 0.86 + macro * 0.2 + ground_noise(p * 0.11) * 0.10;
		relief = (photographed_height - 0.5) * 0.045 * near8;
	} else if (surface_kind == 9) {
		// Compacted yard, shoulder or worn hardstand: no joints, broad wear, darker
		// damp hollows and a fine grit that only shows close to the camera.
		float wear = ground_noise(p * 0.12) * 0.6 + ground_noise(p * 0.43 + 11.0) * 0.4;
		color = base_tint * (0.72 + wear * 0.36);
		float hollows9 = smoothstep(0.58, 0.86, ground_noise(p * 0.055 + 5.0));
		color *= 1.0 - hollows9 * 0.22;
		color = mix(color, color * vec3(1.10, 1.06, 1.0) + 0.02, smoothstep(0.5, 0.8, ground_noise(p * 0.03 + 19.0)) * 0.45);
		// Loose stones and grit, visible only underfoot.
		float near9 = 1.0 - smoothstep(0.004, 0.05, length(fwidth(p)));
		float stone = step(0.975, ground_hash(floor(p * 11.0))) * near9;
		color = mix(color, color * 1.45 + 0.03, stone);
		float close_detail = 1.0 - smoothstep(0.05, 0.6, length(fwidth(p)));
		color *= 1.0 + (fine - 0.5) * 0.22 * close_detail;
		relief = (fine - 0.5) * 0.004 * close_detail;
		rough = 0.93;
	} else if (surface_kind == 10) {
		// Coastal-savanna hinterland after the rains, green by the user's choice
		// (17 Nov): grass that dries to olive in broad swathes, bare laterite only
		// where the cover has worn through. `tint` is the grass colour.
		float patches = ground_noise(p * 0.018) * 0.65 + ground_noise(p * 0.061 + 23.0) * 0.35;
		vec3 grass10 = mix(base_tint * 0.83, base_tint * vec3(0.72, 0.96, 0.55), smoothstep(0.35, 0.70, patches));
		float dry10 = smoothstep(0.50, 0.80, ground_noise(p * 0.011 + 57.0) * 0.7 + ground_noise(p * 0.047 + 8.0) * 0.3);
		grass10 = mix(grass10, grass10 * vec3(1.55, 1.0, 1.35), dry10 * 0.75);
		float bare = ground_noise(p * 0.013 + 71.0) * 0.55 + ground_noise(p * 0.052 + 3.0) * 0.30
			+ ground_noise(p * 0.19 + 9.0) * 0.15;
		bare = smoothstep(0.62, 0.76, bare);
		vec3 earth10 = vec3(0.225, 0.100, 0.050) * (0.80 + ground_noise(p * 0.21) * 0.32);
		color = mix(grass10, earth10, bare * 0.7);
		// Inside the town the open ground is trodden: still mostly grass, worn to
		// swept laterite in broad patches. The edge frays into the bush along a noisy
		// line, not the rectangle of the plan.
		float depth10 = min(min(p.x - town_rect.x, town_rect.z - p.x), min(p.y - town_rect.y, town_rect.w - p.y));
		float fray = (ground_noise(p * 0.028) - 0.5) * 80.0 + (ground_noise(p * 0.10 + 40.0) - 0.5) * 26.0;
		float urban = smoothstep(-34.0, 10.0, depth10 + fray) * step(0.5, town_rect.z - town_rect.x);
		vec3 yard = vec3(0.245, 0.115, 0.060) * (0.70 + ground_noise(p * 0.16) * 0.30 + ground_noise(p * 0.9) * 0.14);
		// Paler swept patches, darker damp ground and weeds where nobody walks.
		yard = mix(yard, vec3(0.30, 0.170, 0.100), smoothstep(0.45, 0.80, ground_noise(p * 0.045 + 61.0)) * 0.55);
		yard *= 1.0 - smoothstep(0.60, 0.85, ground_noise(p * 0.07 + 5.0)) * 0.22;
		float weeds = smoothstep(0.60, 0.80, ground_noise(p * 0.085 + 15.0) * 0.7 + ground_noise(p * 0.33) * 0.3) * 0.7;
		yard = mix(yard, grass10 * 0.85, weeds);
		float worn10 = smoothstep(0.52, 0.68, ground_noise(p * 0.05 + 47.0) * 0.6 + ground_noise(p * 0.21 + 13.0) * 0.4);
		color = mix(color, mix(grass10 * vec3(1.06, 0.97, 0.94), yard, worn10), urban);
		// Paved, swept districts: interlocking concrete blocks, joints showing
		// only underfoot, with a little dust drifting in from the earth around.
		float paved = max(paved_zone(p, paved_a), paved_zone(p, paved_b));
		vec3 blocks = vec3(0.34, 0.32, 0.275) * (0.88 + ground_noise(p * 0.07) * 0.14);
		vec2 cell10 = p / vec2(0.22, 0.11);
		cell10.x += mod(floor(cell10.y), 2.0) * 0.5;
		vec2 edge10 = min(fract(cell10), 1.0 - fract(cell10));
		float joint10 = (1.0 - smoothstep(0.02, 0.08, min(edge10.x * 2.0, edge10.y)))
			* (1.0 - smoothstep(0.02, 0.22, length(fwidth(p))));
		blocks *= 1.0 - joint10 * 0.24;
		blocks = mix(blocks, yard, smoothstep(0.66, 0.92, ground_noise(p * 0.06 + 33.0)) * 0.22);
		color = mix(color, blocks, paved);
		color *= 0.92 + ground_noise(p * 0.31) * 0.12;
		relief = 0.0;
		rough = 1.0;
	} else if (surface_kind == 11) {
		// Bare sandcrete blockwork, 460 x 230 mm in running bond with recessed
		// mortar joints; each block keeps its own slightly different grey.
		vec2 cells11 = p / vec2(0.46, 0.23);
		cells11.x += mod(floor(cells11.y), 2.0) * 0.5;
		vec2 edge11 = min(fract(cells11), 1.0 - fract(cells11));
		float joint = 1.0 - smoothstep(0.02, 0.07, min(edge11.x * 2.0, edge11.y));
		float joint_fade = 1.0 - smoothstep(0.25, 1.4, length(fwidth(cells11)));
		color = base_tint * (0.80 + ground_hash(floor(cells11)) * 0.22 + medium * 0.10);
		color *= 1.0 - joint * joint_fade * 0.30;
		float splash11 = exp(-max(world_pos.y - 0.08, 0.0) * 1.9) * (0.4 + medium * 0.7);
		color = mix(color, vec3(0.30, 0.115, 0.045), clamp(splash11, 0.0, 0.55) * step(n.y, 0.55));
		relief = fine * 0.003 - joint * joint_fade * 0.010;
		rough = 0.96;
	}
	// Water gathers on upward-facing paved surfaces, leaving irregular dry islands.
	float pavement = (surface_kind == 1 || surface_kind == 2 || surface_kind == 5 || surface_kind == 9) ? 1.0 : 0.0;
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
