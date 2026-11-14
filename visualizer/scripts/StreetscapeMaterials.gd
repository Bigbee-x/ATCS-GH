extends RefCounted
## Shared photographed surfaces with deterministic weathering. Entirely offline.

const SURFACE = preload("res://shaders/streetscape_surface.gdshader")
const FOLIAGE = preload("res://shaders/streetscape_foliage.gdshader")
const PLASTER = [preload("res://assets/streetscape/plastered_wall_05_diff_1k.jpg"),
	preload("res://assets/streetscape/plastered_wall_05_disp_1k.jpg"),
	preload("res://assets/streetscape/plastered_wall_05_rough_1k.jpg")]
const ASPHALT = [preload("res://assets/streetscape/asphalt_02_diff_1k.jpg"),
	preload("res://assets/streetscape/asphalt_02_disp_1k.jpg"),
	preload("res://assets/streetscape/asphalt_02_rough_1k.jpg")]
const GROUND = [preload("res://assets/streetscape/dry_ground_rocks_diff_1k.jpg"),
	preload("res://assets/streetscape/dry_ground_rocks_disp_1k.jpg"),
	preload("res://assets/streetscape/dry_ground_rocks_rough_1k.jpg")]
static var _cache: Dictionary = {}
static var _grain: NoiseTexture2D
static var _wetness: float = 0.0
static var _rain: float = 0.0
static var _wind := Vector3(1.6, 0, 0.5)

static func surface(kind: int, color: Color) -> ShaderMaterial:
	var key := "%d:%s" % [kind, color.to_html()]
	if _cache.has(key):
		return _cache[key]
	if _grain == null:
		var noise := FastNoiseLite.new()
		noise.seed = 42071
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.frequency = 0.035
		noise.fractal_octaves = 5
		_grain = NoiseTexture2D.new()
		_grain.width = 512
		_grain.height = 512
		_grain.seamless = true
		_grain.generate_mipmaps = true
		_grain.noise = noise
	var material := ShaderMaterial.new()
	material.shader = SURFACE
	material.set_shader_parameter("grain", _grain)
	material.set_shader_parameter("wetness", _wetness)
	material.set_shader_parameter("rain_intensity", _rain)
	material.set_shader_parameter("surface_kind", kind)
	material.set_shader_parameter("tint", color)
	if kind in [0, 1, 2, 3, 5, 8]:
		var maps: Array = ASPHALT if kind == 1 else (GROUND if kind in [3, 8] else PLASTER)
		material.set_shader_parameter("photographed", true)
		material.set_shader_parameter("albedo_map", maps[0])
		material.set_shader_parameter("height_map", maps[1])
		material.set_shader_parameter("roughness_map", maps[2])
		material.set_shader_parameter("tile_size", 3.0 if kind == 1 else (4.0 if kind in [3, 8] else 2.0))
	_cache[key] = material
	return material

static func foliage() -> ShaderMaterial:
	if not _cache.has("leaves"):
		var material := ShaderMaterial.new()
		material.shader = FOLIAGE
		material.set_shader_parameter("wind", _wind)
		_cache["leaves"] = material
	return _cache["leaves"]

static func solid(color: Color, metallic: float = 0.0, roughness: float = 0.75) -> StandardMaterial3D:
	var key := "solid:%s:%.2f:%.2f" % [color.to_html(), metallic, roughness]
	if not _cache.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.metallic = metallic
		material.roughness = roughness
		_cache[key] = material
	return _cache[key]

static func set_wetness(amount: float, rain: float = 0.0) -> void:
	_wetness = clampf(amount, 0.0, 1.0)
	_rain = clampf(rain, 0.0, 1.0)
	for material in _cache.values():
		if material is ShaderMaterial and material.shader == SURFACE:
			material.set_shader_parameter("wetness", _wetness)
			material.set_shader_parameter("rain_intensity", _rain)

static func set_wind(wind: Vector3) -> void:
	_wind = wind
	if _cache.has("leaves"):
		_cache["leaves"].set_shader_parameter("wind", wind)
