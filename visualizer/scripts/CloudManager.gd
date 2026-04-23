extends Node3D
## Drifting cumulus clouds high above the scene.
##
## Each cloud is a small cluster of sphere-mesh "puffs" sharing one mesh
## and one material (cheap, GPU-instanced). The whole swarm drifts in one
## direction at a gentle pace and wraps around when it leaves the visible
## box so the sky never empties out.
##
## Color is driven by two signals:
##   TimeOfDayManager.time_changed → base cloud color (white → orange →
##       dark navy through dawn → day → dusk → night)
##   WeatherManager.weather_changed → tint multiplier + how many clouds
##       are visible (Clear = sparse white, Overcast = full dense gray,
##       Harmattan = dusty beige, Rain = full dark gray)
##
## The two are multiplied together, so a rainy dusk correctly yields
## dark-orange brooding clouds rather than one flavor winning outright.

# ── Layout ──────────────────────────────────────────────────────────────────
const CLOUD_COUNT: int = 24
const CLOUD_HEIGHT_MIN: float = 26.0
const CLOUD_HEIGHT_MAX: float = 42.0
const CLOUD_SPREAD: float = 140.0      # XZ wrap box half-extent
const PUFFS_PER_CLOUD_MIN: int = 3
const PUFFS_PER_CLOUD_MAX: int = 5
const PUFF_RADIUS_MIN: float = 2.4
const PUFF_RADIUS_MAX: float = 4.8

# ── Drift ───────────────────────────────────────────────────────────────────
const DRIFT_SPEED: float = 0.9          # world units/sec
var _drift_dir: Vector3 = Vector3(1.0, 0.0, 0.35).normalized()

# ── State ───────────────────────────────────────────────────────────────────
var _clouds: Array[Node3D] = []         # one Node3D per cloud (wraps its puffs)
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _sphere_mesh: SphereMesh
var _material: StandardMaterial3D

# Color state — TOD and weather combine multiplicatively
var _tod_color: Color = Color(1.0, 1.0, 1.0)
var _weather_tint: Color = Color(1.0, 1.0, 1.0)
var _visible_count: int = CLOUD_COUNT

# ── External refs (wired by Main.gd) ────────────────────────────────────────
var tod: Node                  # TimeOfDayManager
var weather_manager: Node      # WeatherManager


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_rng.seed = 0x61_74_63_73   # deterministic placement across runs

	# Low-poly sphere shared across every puff — cheap instancing
	_sphere_mesh = SphereMesh.new()
	_sphere_mesh.radius = 1.0
	_sphere_mesh.height = 2.0
	_sphere_mesh.radial_segments = 8
	_sphere_mesh.rings = 4

	# Unshaded so clouds stay readable regardless of sun angle.
	# TOD drives the albedo directly, so no lighting compensation needed.
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.albedo_color = Color(1.0, 1.0, 1.0)

	_build_clouds()
	# Signal wiring + initial color are deferred to initialize(), which
	# Main.gd calls after assigning `tod` and `weather_manager`. Children's
	# _ready() runs before the parent's, so those refs aren't populated yet
	# at this point.


func initialize() -> void:
	## Called by Main.gd AFTER `tod` and `weather_manager` are assigned.
	## Connects to their signals and applies the first-frame color so the
	## sky doesn't briefly show stale white clouds at launch.
	if tod and tod.has_signal("time_changed"):
		if not tod.time_changed.is_connected(_on_time_changed):
			tod.time_changed.connect(_on_time_changed)
	if weather_manager and weather_manager.has_signal("weather_changed"):
		if not weather_manager.weather_changed.is_connected(_on_weather_changed):
			weather_manager.weather_changed.connect(_on_weather_changed)

	# Seed initial state so launch frame is already correct
	if tod and "time_of_day" in tod:
		_on_time_changed(float(tod.time_of_day))
	if weather_manager and weather_manager.has_method("get_weather"):
		_on_weather_changed(int(weather_manager.get_weather()))


# ═════════════════════════════════════════════════════════════════════════════
# CONSTRUCTION
# ═════════════════════════════════════════════════════════════════════════════

func _build_clouds() -> void:
	for i in range(CLOUD_COUNT):
		var cloud := _make_cloud()
		cloud.position = Vector3(
			_rng.randf_range(-CLOUD_SPREAD, CLOUD_SPREAD),
			_rng.randf_range(CLOUD_HEIGHT_MIN, CLOUD_HEIGHT_MAX),
			_rng.randf_range(-CLOUD_SPREAD, CLOUD_SPREAD)
		)
		cloud.rotation.y = _rng.randf_range(0.0, TAU)
		add_child(cloud)
		_clouds.append(cloud)


func _make_cloud() -> Node3D:
	## Build one cloud: a clump of 3–5 offset sphere puffs.
	var root := Node3D.new()
	root.name = "Cloud"
	var puff_count: int = _rng.randi_range(PUFFS_PER_CLOUD_MIN, PUFFS_PER_CLOUD_MAX)
	for i in range(puff_count):
		var puff := MeshInstance3D.new()
		puff.mesh = _sphere_mesh
		puff.material_override = _material
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var r: float = _rng.randf_range(PUFF_RADIUS_MIN, PUFF_RADIUS_MAX)
		# Slightly squash vertically so clouds look flatter than spheres
		puff.scale = Vector3(r, r * 0.55, r)
		puff.position = Vector3(
			_rng.randf_range(-3.8, 3.8),
			_rng.randf_range(-0.6, 0.6),
			_rng.randf_range(-3.0, 3.0)
		)
		root.add_child(puff)
	return root


# ═════════════════════════════════════════════════════════════════════════════
# PROCESS — drift + wrap
# ═════════════════════════════════════════════════════════════════════════════

func _process(delta: float) -> void:
	if _clouds.is_empty():
		return
	var step: Vector3 = _drift_dir * DRIFT_SPEED * delta
	for cloud in _clouds:
		cloud.position += step
		# Wrap so clouds re-enter on the opposite side
		if cloud.position.x > CLOUD_SPREAD:
			cloud.position.x -= CLOUD_SPREAD * 2.0
		elif cloud.position.x < -CLOUD_SPREAD:
			cloud.position.x += CLOUD_SPREAD * 2.0
		if cloud.position.z > CLOUD_SPREAD:
			cloud.position.z -= CLOUD_SPREAD * 2.0
		elif cloud.position.z < -CLOUD_SPREAD:
			cloud.position.z += CLOUD_SPREAD * 2.0


# ═════════════════════════════════════════════════════════════════════════════
# COLOR — TOD × WEATHER
# ═════════════════════════════════════════════════════════════════════════════

func _on_time_changed(hour: float) -> void:
	## Pick a base cloud color based on hour-of-day.
	## Returns bright white at midday, warm tones at dawn/dusk, dark navy
	## at night (still slightly visible so the sky isn't pitch-black empty).
	var c: Color
	if hour >= 6.0 and hour < 7.5:
		# Dawn — orange fading into white
		var t: float = (hour - 6.0) / 1.5
		c = Color(0.75, 0.55, 0.45).lerp(Color(1.0, 0.96, 0.92), t)
	elif hour >= 7.5 and hour < 16.5:
		# Day — bright white
		c = Color(1.0, 1.0, 1.0)
	elif hour >= 16.5 and hour < 19.0:
		# Dusk — white shading into deep orange/pink
		var t: float = (hour - 16.5) / 2.5
		c = Color(1.0, 0.95, 0.88).lerp(Color(0.85, 0.45, 0.40), t)
	elif hour >= 19.0 and hour < 20.5:
		# Twilight — pink fading to navy
		var t: float = (hour - 19.0) / 1.5
		c = Color(0.65, 0.35, 0.40).lerp(Color(0.20, 0.22, 0.32), t)
	else:
		# Night (20:30 through 06:00) — faint moonlit navy
		c = Color(0.20, 0.22, 0.32)
	_tod_color = c
	_update_material()


func _on_weather_changed(weather_idx: int) -> void:
	## Weather sets a tint multiplier and how many of the clouds are visible.
	##   0 Clear     — sparse, white (tint identity)
	##   1 Overcast  — all clouds, cool gray
	##   2 Harmattan — most clouds, dusty warm beige
	##   3 Rain      — all clouds, dark gray
	match weather_idx:
		0:
			_visible_count = int(CLOUD_COUNT * 0.35)
			_weather_tint = Color(1.0, 1.0, 1.0)
		1:
			_visible_count = CLOUD_COUNT
			_weather_tint = Color(0.70, 0.72, 0.76)
		2:
			_visible_count = int(CLOUD_COUNT * 0.75)
			_weather_tint = Color(0.82, 0.74, 0.58)
		3:
			_visible_count = CLOUD_COUNT
			_weather_tint = Color(0.42, 0.44, 0.50)
		_:
			_visible_count = int(CLOUD_COUNT * 0.35)
			_weather_tint = Color(1.0, 1.0, 1.0)

	# Toggle per-cloud visibility based on the current visible_count
	for i in range(_clouds.size()):
		_clouds[i].visible = i < _visible_count
	_update_material()


func _update_material() -> void:
	## Combine TOD base color × weather tint into the shared material.
	## Shared material means one assignment affects every puff — cheap.
	if _material == null:
		return
	_material.albedo_color = Color(
		_tod_color.r * _weather_tint.r,
		_tod_color.g * _weather_tint.g,
		_tod_color.b * _weather_tint.b
	)
