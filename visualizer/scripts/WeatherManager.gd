extends Node
## Weather system layered on top of TimeOfDayManager.
##
## Supports four modes:
##   CLEAR     — default, no modifiers
##   OVERCAST  — grey sky, dim sun, light haze
##   HARMATTAN — Accra's Dec–Feb dry-season dust (warm yellow-brown haze)
##   RAIN      — dark sky, heavy fog, GPU-particle rain falling over the scene
##
## Each frame:
##   1. Asks TimeOfDayManager to re-apply its base values (sun/sky/fog)
##   2. Lerps internal modifier state toward the selected weather preset
##   3. Layers those modifiers onto the environment/sun nodes
##   4. Repositions / fades the rain particle emitter to follow the camera
##
## Wire via Main.gd:
##   weather_manager.tod = tod_manager
##   weather_manager.sun = $DirectionalLight3D
##   weather_manager.world_env = $WorldEnvironment
##   weather_manager.camera_follow = $IsometricCamera

signal weather_changed(weather_idx: int)

# ── Weather modes ───────────────────────────────────────────────────────────
enum Weather { CLEAR, OVERCAST, HARMATTAN, RAIN }
const WEATHER_NAMES: Array = ["Clear", "Overcast", "Harmattan", "Rain"]

var weather: Weather = Weather.CLEAR

# ── External node refs (wired by Main.gd) ───────────────────────────────────
var tod: Node                      # TimeOfDayManager
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var camera_follow: Camera3D        # rain emitter tracks this

# ── Cached env refs ─────────────────────────────────────────────────────────
var _environment: Environment
var _sky_material: ProceduralSkyMaterial

# ── Modifier state (lerps smoothly between weather presets) ─────────────────
# All fields default to CLEAR (identity) so startup causes no visual change.
class WeatherMods:
	var sun_energy_mul: float = 1.0
	var ambient_energy_mul: float = 1.0
	var sky_top_tint: Color = Color(0, 0, 0)
	var sky_horizon_tint: Color = Color(0, 0, 0)
	var sky_tint_strength: float = 0.0
	var fog_density_add: float = 0.0
	var fog_color_tint: Color = Color(0, 0, 0)
	var fog_tint_strength: float = 0.0
	var rain_intensity: float = 0.0   # 0.0 = off, 1.0 = full downpour


var _current_mods: WeatherMods = WeatherMods.new()
var _target_mods: WeatherMods = WeatherMods.new()

const MOD_LERP_SPEED: float = 0.8   # ~1.25 sec to finish a weather change

# ── Rain particle system ────────────────────────────────────────────────────
var _rain_particles: GPUParticles3D
const RAIN_BOX_HALF_XZ: float = 60.0       # covers visible area
const RAIN_BOX_HEIGHT:  float = 25.0       # above camera
const RAIN_PARTICLE_COUNT: int = 3500
const RAIN_LIFETIME: float = 1.6

# ── Lightning + thunder ─────────────────────────────────────────────────────
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _lightning_timer: float = 8.0          # sec until next strike
var _flash_remaining: float = 0.0          # sec of active flash
var _flash_peak: float = 0.0               # peak ambient boost for this flash
var _pending_thunder_delay: float = -1.0   # sec until thunder plays (<0 = none pending)
var _thunder_volume_db: float = -4.0
var _thunder_player: AudioStreamPlayer
var _thunder_stream: AudioStreamWAV

const LIGHTNING_MIN_INTERVAL: float = 7.0
const LIGHTNING_MAX_INTERVAL: float = 22.0
const LIGHTNING_FLASH_DURATION: float = 0.28
const LIGHTNING_PEAK_ENERGY: float = 2.6


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Process AFTER TimeOfDayManager so our modifiers land on fresh base values.
	process_priority = 10
	_rng.randomize()
	_lightning_timer = _rng.randf_range(6.0, 14.0)
	_build_rain_particles()
	_build_thunder()


func _process(delta: float) -> void:
	if sun == null or world_env == null:
		return

	# 1. Lerp current mods toward target mods (smooth weather transitions)
	_lerp_mods_toward_target(delta)

	# 2. Reset the environment to TimeOfDayManager's baseline for THIS frame
	if tod and tod.has_method("force_reapply"):
		tod.force_reapply()

	# 3. Cache env/sky refs on first run
	if _environment == null:
		_environment = world_env.environment
	if _sky_material == null and _environment and _environment.sky:
		_sky_material = _environment.sky.sky_material as ProceduralSkyMaterial

	# 4. Apply the weather layer
	_apply_weather_layer()

	# 5. Rain emitter follows the camera; fade particles in/out with intensity
	_update_rain(delta)

	# 6. Lightning + thunder — only during heavy rain
	_process_lightning(delta)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func set_weather(w: int) -> void:
	## Request a new weather mode (smoothly transitioned).
	if w < 0 or w >= WEATHER_NAMES.size():
		return
	weather = w as Weather
	_target_mods = _preset_for(weather)
	weather_changed.emit(int(weather))


func get_weather() -> int:
	return int(weather)


func get_weather_name() -> String:
	return WEATHER_NAMES[int(weather)]


# ═════════════════════════════════════════════════════════════════════════════
# PRESETS
# ═════════════════════════════════════════════════════════════════════════════

func _preset_for(w: Weather) -> WeatherMods:
	var m := WeatherMods.new()
	match w:
		Weather.CLEAR:
			pass   # identity — no modifiers
		Weather.OVERCAST:
			m.sun_energy_mul = 0.40
			m.ambient_energy_mul = 0.90
			m.sky_top_tint = Color(0.58, 0.60, 0.66)
			m.sky_horizon_tint = Color(0.72, 0.74, 0.78)
			m.sky_tint_strength = 0.55
			m.fog_density_add = 0.002
			m.fog_color_tint = Color(0.65, 0.68, 0.72)
			m.fog_tint_strength = 0.55
			m.rain_intensity = 0.0
		Weather.HARMATTAN:
			# Accra dry-season dust haze — warm yellow-brown, low visibility.
			m.sun_energy_mul = 0.60
			m.ambient_energy_mul = 0.85
			m.sky_top_tint = Color(0.72, 0.65, 0.48)
			m.sky_horizon_tint = Color(0.82, 0.72, 0.52)
			m.sky_tint_strength = 0.65
			m.fog_density_add = 0.006
			m.fog_color_tint = Color(0.78, 0.68, 0.50)
			m.fog_tint_strength = 0.65
			m.rain_intensity = 0.0
		Weather.RAIN:
			m.sun_energy_mul = 0.28
			m.ambient_energy_mul = 0.65
			m.sky_top_tint = Color(0.32, 0.36, 0.42)
			m.sky_horizon_tint = Color(0.48, 0.52, 0.56)
			m.sky_tint_strength = 0.65
			m.fog_density_add = 0.004
			m.fog_color_tint = Color(0.50, 0.54, 0.60)
			m.fog_tint_strength = 0.60
			m.rain_intensity = 1.0
	return m


# ═════════════════════════════════════════════════════════════════════════════
# MOD INTERPOLATION + APPLY
# ═════════════════════════════════════════════════════════════════════════════

func _lerp_mods_toward_target(delta: float) -> void:
	var t: float = clampf(delta * MOD_LERP_SPEED * 4.0, 0.0, 1.0)
	_current_mods.sun_energy_mul      = lerpf(_current_mods.sun_energy_mul,      _target_mods.sun_energy_mul,      t)
	_current_mods.ambient_energy_mul  = lerpf(_current_mods.ambient_energy_mul,  _target_mods.ambient_energy_mul,  t)
	_current_mods.sky_top_tint        = _current_mods.sky_top_tint.lerp(_target_mods.sky_top_tint, t)
	_current_mods.sky_horizon_tint    = _current_mods.sky_horizon_tint.lerp(_target_mods.sky_horizon_tint, t)
	_current_mods.sky_tint_strength   = lerpf(_current_mods.sky_tint_strength,   _target_mods.sky_tint_strength,   t)
	_current_mods.fog_density_add     = lerpf(_current_mods.fog_density_add,     _target_mods.fog_density_add,     t)
	_current_mods.fog_color_tint      = _current_mods.fog_color_tint.lerp(_target_mods.fog_color_tint, t)
	_current_mods.fog_tint_strength   = lerpf(_current_mods.fog_tint_strength,   _target_mods.fog_tint_strength,   t)
	_current_mods.rain_intensity      = lerpf(_current_mods.rain_intensity,      _target_mods.rain_intensity,      t)


const FOG_DENSITY_MAX: float = 0.010   # hard ceiling so we never wall off the scene


func _apply_weather_layer() -> void:
	var m := _current_mods

	# ── Day-brightness guard ──────────────────────────────────────────
	# Weather tints scale with how bright the base scene is. At night TOD
	# already renders dark / fogged — piling weather on top at full strength
	# produces an opaque wall of color. We lerp strengths between 35 % (deep
	# night) and 100 % (midday) using the current sun energy as a proxy.
	var brightness: float = clampf(sun.light_energy / 1.3, 0.0, 1.0)
	var tint_scale: float = lerpf(0.35, 1.0, brightness)
	var fog_scale:  float = lerpf(0.45, 1.0, brightness)

	# Sun — multiplicative on top of TOD energy
	sun.light_energy = sun.light_energy * m.sun_energy_mul

	# Ambient — multiplicative
	if _environment:
		_environment.ambient_light_energy = _environment.ambient_light_energy * m.ambient_energy_mul

	# Sky — tint toward weather color by strength (scaled by brightness)
	if _sky_material and m.sky_tint_strength > 0.001:
		var sky_strength: float = m.sky_tint_strength * tint_scale
		_sky_material.sky_top_color = _sky_material.sky_top_color.lerp(
			m.sky_top_tint, sky_strength)
		_sky_material.sky_horizon_color = _sky_material.sky_horizon_color.lerp(
			m.sky_horizon_tint, sky_strength)

	# Fog — add density (capped), tint color (scaled)
	if _environment:
		var density_add: float = m.fog_density_add * fog_scale
		var new_density: float = minf(_environment.fog_density + density_add, FOG_DENSITY_MAX)
		if new_density > 0.0005:
			_environment.fog_enabled = true
			_environment.fog_density = new_density
			if m.fog_tint_strength > 0.001:
				var fog_strength: float = m.fog_tint_strength * tint_scale
				_environment.fog_light_color = _environment.fog_light_color.lerp(
					m.fog_color_tint, fog_strength)


# ═════════════════════════════════════════════════════════════════════════════
# RAIN PARTICLES
# ═════════════════════════════════════════════════════════════════════════════

func _build_rain_particles() -> void:
	_rain_particles = GPUParticles3D.new()
	_rain_particles.name = "RainParticles"
	_rain_particles.amount = RAIN_PARTICLE_COUNT
	_rain_particles.lifetime = RAIN_LIFETIME
	_rain_particles.explosiveness = 0.0
	_rain_particles.visibility_aabb = AABB(
		Vector3(-RAIN_BOX_HALF_XZ, -RAIN_BOX_HEIGHT, -RAIN_BOX_HALF_XZ),
		Vector3(RAIN_BOX_HALF_XZ * 2, RAIN_BOX_HEIGHT + 10.0, RAIN_BOX_HALF_XZ * 2)
	)
	_rain_particles.emitting = false   # hidden until RAIN selected
	_rain_particles.preprocess = 0.5   # start mid-flight so scene isn't empty

	# Process material — defines how each particle behaves
	var proc := ParticleProcessMaterial.new()
	proc.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	proc.emission_box_extents = Vector3(RAIN_BOX_HALF_XZ, 0.1, RAIN_BOX_HALF_XZ)
	proc.direction = Vector3(0.05, -1.0, 0.0)   # slight wind angle
	proc.spread = 2.0
	proc.initial_velocity_min = 14.0
	proc.initial_velocity_max = 17.0
	proc.gravity = Vector3.ZERO
	proc.scale_min = 1.0
	proc.scale_max = 1.0
	# Subtle color variation for depth — bluish white
	proc.color = Color(0.75, 0.82, 0.95, 0.55)
	_rain_particles.process_material = proc

	# Draw mesh — thin vertical streak, stretched in velocity direction
	var streak := QuadMesh.new()
	streak.size = Vector2(0.015, 0.55)
	var streak_mat := StandardMaterial3D.new()
	streak_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	streak_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	streak_mat.albedo_color = Color(0.80, 0.88, 1.00, 0.55)
	streak_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	streak_mat.billboard_keep_scale = true
	streak_mat.disable_receive_shadows = true
	streak.material = streak_mat
	_rain_particles.draw_pass_1 = streak

	# Emitter sits at the scene root; _update_rain() moves it each frame so
	# it hovers above whatever the camera is looking at.
	_rain_particles.position = Vector3(0, RAIN_BOX_HEIGHT, 0)
	add_child(_rain_particles)


func _update_rain(_delta: float) -> void:
	if _rain_particles == null:
		return
	var intensity: float = _current_mods.rain_intensity
	var should_emit: bool = intensity > 0.02
	if _rain_particles.emitting != should_emit:
		_rain_particles.emitting = should_emit

	# Scale particle count by intensity (cheap — material property only)
	var proc := _rain_particles.process_material as ParticleProcessMaterial
	if proc:
		var col: Color = proc.color
		col.a = 0.55 * intensity
		proc.color = col

	# Follow the camera in XZ so rain fills the visible frustum
	if camera_follow and should_emit:
		var cp: Vector3 = camera_follow.global_position
		_rain_particles.global_position = Vector3(cp.x, RAIN_BOX_HEIGHT, cp.z)


# ═════════════════════════════════════════════════════════════════════════════
# LIGHTNING + THUNDER
# ═════════════════════════════════════════════════════════════════════════════

func _process_lightning(delta: float) -> void:
	# Only schedule strikes during heavy rain
	var rain_strong: bool = _current_mods.rain_intensity > 0.6

	if rain_strong:
		_lightning_timer -= delta
		if _lightning_timer <= 0.0:
			_trigger_lightning()
			_lightning_timer = _rng.randf_range(LIGHTNING_MIN_INTERVAL, LIGHTNING_MAX_INTERVAL)
	else:
		# Reset so a fresh rain run doesn't insta-flash
		if _lightning_timer < 4.0:
			_lightning_timer = _rng.randf_range(6.0, 12.0)

	# ── Active flash: sharp rise then exponential decay ───────────────
	if _flash_remaining > 0.0:
		var progress: float = 1.0 - (_flash_remaining / LIGHTNING_FLASH_DURATION)
		var shape: float
		if progress < 0.15:
			shape = progress / 0.15
		else:
			shape = exp(-(progress - 0.15) * 6.5)
		var boost: float = _flash_peak * shape
		if _environment:
			_environment.ambient_light_energy += boost
		# Wash the sky briefly white — strongest at flash peak
		if _sky_material:
			var w: float = clampf(shape * 0.55, 0.0, 0.55)
			_sky_material.sky_top_color = _sky_material.sky_top_color.lerp(Color.WHITE, w)
			_sky_material.sky_horizon_color = _sky_material.sky_horizon_color.lerp(Color.WHITE, w)
		_flash_remaining -= delta

	# ── Delayed thunder ───────────────────────────────────────────────
	if _pending_thunder_delay > 0.0:
		_pending_thunder_delay -= delta
		if _pending_thunder_delay <= 0.0:
			_play_thunder()
			_pending_thunder_delay = -1.0


func _trigger_lightning() -> void:
	_flash_remaining = LIGHTNING_FLASH_DURATION
	_flash_peak = LIGHTNING_PEAK_ENERGY * _rng.randf_range(0.65, 1.0)
	# Sound lag simulates distance — 0.6 sec = ~200m, 2.5 sec = ~800m
	_pending_thunder_delay = _rng.randf_range(0.6, 2.5)
	# Louder when closer (shorter delay)
	var proximity: float = 1.0 - (_pending_thunder_delay - 0.6) / 1.9
	_thunder_volume_db = lerpf(-14.0, -2.0, clampf(proximity, 0.0, 1.0))


func _play_thunder() -> void:
	if _thunder_player == null or _thunder_stream == null:
		return
	_thunder_player.volume_db = _thunder_volume_db
	# Tiny pitch randomization for variety
	_thunder_player.pitch_scale = _rng.randf_range(0.82, 1.05)
	_thunder_player.play()


func _build_thunder() -> void:
	## Build a procedural thunder rumble — no asset files required.
	_thunder_stream = _generate_thunder_sample(2.2, 22050)
	_thunder_player = AudioStreamPlayer.new()
	_thunder_player.name = "ThunderPlayer"
	_thunder_player.stream = _thunder_stream
	_thunder_player.volume_db = -6.0
	_thunder_player.bus = "Master"
	add_child(_thunder_player)


func _generate_thunder_sample(duration_sec: float, sample_rate: int) -> AudioStreamWAV:
	## Brown-noise rumble with attack/decay envelope. 16-bit mono PCM.
	var num_samples: int = int(sample_rate * duration_sec)
	var bytes := PackedByteArray()
	bytes.resize(num_samples * 2)

	var rumble: float = 0.0     # brown-noise integrator
	var lp: float = 0.0         # extra low-pass for deeper feel

	for i in range(num_samples):
		var t: float = float(i) / sample_rate
		# Envelope: fast attack, exponential decay, secondary rolling bump
		var env: float
		if t < 0.04:
			env = t / 0.04
		else:
			env = exp(-(t - 0.04) * 1.4)
			# Secondary "rolling" bump around 0.7 sec
			env += 0.35 * exp(-pow((t - 0.75) / 0.35, 2.0))
		env = clampf(env, 0.0, 1.0)

		# Brown noise step (integrated white noise, leaky)
		rumble = rumble * 0.985 + (_rng.randf() * 2.0 - 1.0) * 0.14
		rumble = clampf(rumble, -1.0, 1.0)

		# Extra one-pole low-pass for more bass-heavy thunder feel
		lp = lp * 0.82 + rumble * 0.18

		var sample: float = lp * env * 0.85
		var s16: int = int(clampf(sample, -1.0, 1.0) * 32767.0)
		# Little-endian 16-bit
		bytes[i * 2] = s16 & 0xFF
		bytes[i * 2 + 1] = (s16 >> 8) & 0xFF

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = bytes
	return wav
