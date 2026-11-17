extends Node
## Manages a 24-hour day/night cycle for the visualizer.
##
## Interpolates sun light, sky colors, ambient light, and fog across
## predefined keyframes. Supports three modes:
##   MANUAL     — user controls time via slider
##   AUTO_CYCLE — time advances automatically (full day in ~12 minutes)
##   SIM_LINKED — time derived from SUMO simulation seconds
##
## Add as a child of the scene root. Requires references to
## DirectionalLight3D and WorldEnvironment nodes.

signal time_changed(hour: float)
signal night_mode_changed(is_night: bool)
## Fires at DUSK_START_HOUR (4:00 PM — start of golden hour) going into
## evening, and again at MORNING_HOUR (6:00 AM) when day fully returns. The
## signal name says "dusk" for continuity but the trigger is actually golden-
## hour-start: that's when the sun begins dimming and early-risers start
## flipping lights on in real life. The flag stays true through the entire
## evening/night so consumers can light a subset of windows / car headlights
## earlier than full dark, mimicking real-world behaviour (early adopters
## turn lights on before sundown).
signal dusk_mode_changed(is_dusk: bool)

# ── Mode ────────────────────────────────────────────────────────────────────
enum Mode { MANUAL, AUTO_CYCLE, SIM_LINKED }

var mode: Mode = Mode.MANUAL    # Start stable — user must opt in to auto-cycle
var time_of_day: float = 12.0   # 0.0–24.0 (hours) — start at true noon for max brightness
var cycle_speed: float = 120.0  # Real seconds per sim-hour (full day in ~48 min)
                                # Slower than before so CLEAR noon is visible for a while
                                # before the sun drops, even if the user switches to AUTO.

# ── Dusk / night thresholds ─────────────────────────────────────────────────
## Note: the signal is named dusk_mode_changed for historical reasons, but the
## trigger is actually "start of golden hour" — i.e. the moment the sun starts
## dimming and the sky begins to warm. That's when early-risers realistically
## start flipping lights on in the real world, well before full dusk.
const DUSK_START_HOUR: float = 16.0   # 4:00 PM — golden hour begins (sun energy starts dropping)
const NIGHT_START_HOUR: float = 18.0  # 6:00 PM — full dark (all lights should be on)
const MORNING_HOUR: float = 6.0       # 6:00 AM — day returns, lights go off

# ── Night / dusk state ──────────────────────────────────────────────────────
var _is_night: bool = false
var _is_dusk: bool = false

# ── Node references (set by parent script) ──────────────────────────────────
var sun: DirectionalLight3D
var world_env: WorldEnvironment
# Shadowless moonlight and city skyglow: at night the roads, roofs and ground
# stay readable from the air instead of dropping to black between the lamps.
var moon: DirectionalLight3D
const MOON_ENERGY: float = 0.42
var _sky_material: Material
var _environment: Environment

# ── Sun azimuth (preserved from scene, only pitch changes) ──────────────────
var _sun_base_transform: Transform3D


# ── Keyframes ───────────────────────────────────────────────────────────────
# Each keyframe: [hour, sun_energy, sun_color, sun_pitch_deg,
#                  ambient_energy, ambient_color,
#                  sky_top, sky_horizon, ground_bottom, ground_horizon,
#                  fog_density]

const KEYFRAMES: Array = [
	# Dawn
	[6.0,  0.4, Color(1.0, 0.7, 0.4),   15.0,
	 0.3,  Color(0.45, 0.35, 0.30),
	 Color(0.25, 0.25, 0.50), Color(0.85, 0.55, 0.30),
	 Color(0.15, 0.15, 0.12), Color(0.50, 0.40, 0.30),
	 0.002],
	# Bright morning — clear daylight already in by 9:30
	[9.5,  1.30, Color(1.0, 0.95, 0.86),   50.0,
	 0.72,  Color(0.50, 0.45, 0.40),
	 Color(0.33, 0.54, 0.84), Color(0.76, 0.80, 0.84),
	 Color(0.18, 0.22, 0.15), Color(0.55, 0.62, 0.55),
	 0.0],
	# Peak hot daylight — START of the flat plateau (11:00)
	[11.0, 1.55, Color(1.0, 0.98, 0.93),   70.0,
	 0.82,  Color(0.52, 0.47, 0.42),
	 Color(0.29, 0.50, 0.88), Color(0.74, 0.80, 0.86),
	 Color(0.20, 0.25, 0.16), Color(0.55, 0.62, 0.55),
	 0.0],
	# Peak hot daylight — END of the flat plateau (3:50 PM)
	# Values intentionally identical to the 11:00 keyframe except for the sun
	# pitch (which legitimately drops as the sun moves across the sky). The
	# interpolator produces a flat peak between these two times.
	[15.833, 1.55, Color(1.0, 0.98, 0.93),   65.0,
	 0.82,  Color(0.52, 0.47, 0.42),
	 Color(0.29, 0.50, 0.88), Color(0.74, 0.80, 0.86),
	 Color(0.20, 0.25, 0.16), Color(0.55, 0.62, 0.55),
	 0.0],
	# Golden hour begins — slight dimming starts at 4:00 PM
	[16.0, 1.30, Color(1.0, 0.92, 0.80),   55.0,
	 0.66, Color(0.50, 0.43, 0.37),
	 Color(0.38, 0.58, 0.88), Color(0.75, 0.70, 0.65),
	 Color(0.20, 0.22, 0.14), Color(0.55, 0.55, 0.45),
	 0.0],
	# Dusk
	[17.0, 0.8, Color(1.0, 0.55, 0.25),  25.0,
	 0.4,  Color(0.40, 0.30, 0.25),
	 Color(0.55, 0.30, 0.45), Color(0.90, 0.50, 0.25),
	 Color(0.15, 0.12, 0.10), Color(0.50, 0.35, 0.25),
	 0.002],
	# Night
	[20.0, 0.0, Color(0.2, 0.2, 0.4),    10.0,
	 0.62, Color(0.32, 0.36, 0.52),
	 Color(0.05, 0.06, 0.16), Color(0.22, 0.18, 0.20),
	 Color(0.05, 0.05, 0.05), Color(0.10, 0.09, 0.10),
	 0.004],
	# Midnight
	[2.0,  0.0, Color(0.15, 0.15, 0.3),  -10.0,
	 0.52, Color(0.28, 0.32, 0.50),
	 Color(0.03, 0.04, 0.12), Color(0.17, 0.14, 0.17),
	 Color(0.03, 0.03, 0.03), Color(0.08, 0.07, 0.08),
	 0.005],
]


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Apply initial state
	_apply_time(time_of_day)


func _process(delta: float) -> void:
	if mode == Mode.AUTO_CYCLE and cycle_speed > 0.0:
		time_of_day += delta / cycle_speed
		if time_of_day >= 24.0:
			time_of_day -= 24.0
		_apply_time(time_of_day)
		time_changed.emit(time_of_day)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func set_time(hour: float) -> void:
	## Set the time of day (0.0–24.0).
	time_of_day = fmod(hour, 24.0)
	if time_of_day < 0.0:
		time_of_day += 24.0
	_apply_time(time_of_day)
	time_changed.emit(time_of_day)


func set_mode(new_mode: Mode) -> void:
	mode = new_mode


func update_from_sim_time(sim_seconds: float) -> void:
	## Map SUMO simulation seconds to time-of-day.
	## 7200s sim window maps to 6:00 AM – 8:00 PM (14 hours).
	if mode != Mode.SIM_LINKED:
		return
	var progress: float = clampf(sim_seconds / 7200.0, 0.0, 1.0)
	time_of_day = 6.0 + progress * 14.0  # 6 AM to 8 PM
	_apply_time(time_of_day)
	time_changed.emit(time_of_day)


func is_night() -> bool:
	return _is_night


func is_dusk() -> bool:
	## True whenever the "some lights starting to come on" window applies
	## (16:30 through 6:00 AM — i.e. dusk + full night). Full night consumers
	## should also check is_night() to distinguish partial vs. full brightness.
	return _is_dusk


func force_reapply() -> void:
	## Re-apply the current time-of-day values to sun/sky/ambient/fog.
	## Used by WeatherManager each frame so it can layer its modifiers on
	## top of a freshly-written base (otherwise weather tints would drift
	## in manual mode where _apply_time() isn't called every frame).
	_apply_time(time_of_day)


# ═════════════════════════════════════════════════════════════════════════════
# INTERPOLATION ENGINE
# ═════════════════════════════════════════════════════════════════════════════

func _apply_time(hour: float) -> void:
	## Interpolate all environment parameters for the given hour.
	if sun == null or world_env == null:
		return
	if _environment == null:
		_environment = world_env.environment
	if _sky_material == null and _environment and _environment.sky:
		_sky_material = _environment.sky.sky_material

	# Find the two keyframes to interpolate between
	var kf_a: Array = KEYFRAMES[KEYFRAMES.size() - 1]  # wrap-around default
	var kf_b: Array = KEYFRAMES[0]
	var t: float = 0.0

	for i in range(KEYFRAMES.size()):
		var curr: Array = KEYFRAMES[i]
		var next_idx: int = (i + 1) % KEYFRAMES.size()
		var next: Array = KEYFRAMES[next_idx]
		var h_curr: float = curr[0]
		var h_next: float = next[0]

		# Handle wrap-around (e.g., 20:00 → 2:00)
		if h_next <= h_curr:
			h_next += 24.0
		var h_test: float = hour
		if h_test < h_curr and h_curr > 12.0:
			h_test += 24.0

		if h_test >= h_curr and h_test < h_next:
			kf_a = curr
			kf_b = next
			t = (h_test - h_curr) / (h_next - h_curr)
			break

	# Smoothstep for natural transitions
	t = t * t * (3.0 - 2.0 * t)

	# ── Apply sun ──────────────────────────────────────────────────────
	var sun_energy: float = lerpf(kf_a[1], kf_b[1], t)
	var sun_color: Color = kf_a[2].lerp(kf_b[2], t)
	var sun_pitch: float = lerpf(kf_a[3], kf_b[3], t)

	sun.light_energy = sun_energy * 0.9
	sun.light_angular_distance = 0.7
	sun.light_color = sun_color
	sun.visible = sun_energy > 0.01

	# Rotate sun pitch while keeping yaw/roll constant.
	# "pitch" in the keyframes = elevation above horizon (90 = zenith, 0 = horizon,
	# negative = below horizon). DirectionalLight3D shines along its local -Z axis;
	# rotating by R_x(θ) sends (0,0,-1) → (0, sin θ, -cos θ), so to get light rays
	# pointing θ° below horizontal (sun at elevation θ) we set rotation.x = -θ.
	# Previous formula `-(90 - pitch)` was inverted: at noon (pitch=70) it rendered
	# the sun at 20° elevation (long shadows, dim scene) and at midnight (pitch=-10)
	# it rendered the sun still above the horizon.
	if _sun_base_transform == Transform3D():
		_sun_base_transform = sun.transform
	sun.rotation_degrees.x = -sun_pitch

	# ── Apply moonlight ────────────────────────────────────────────────
	if moon == null:
		moon = DirectionalLight3D.new()
		moon.name = "MoonLight"
		moon.light_color = Color(0.62, 0.72, 1.0)
		moon.shadow_enabled = false
		moon.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		moon.rotation_degrees = Vector3(-58.0, 140.0, 0.0)
		sun.get_parent().add_child.call_deferred(moon)
	var night_amount: float = maxf(smoothstep(17.4, 19.2, hour), 1.0 - smoothstep(5.4, 6.6, hour))
	moon.light_energy = MOON_ENERGY * night_amount
	moon.visible = night_amount > 0.01

	# ── Apply ambient ──────────────────────────────────────────────────
	if _environment:
		_environment.ambient_light_energy = lerpf(kf_a[4], kf_b[4], t) * 0.85
		_environment.ambient_light_color = kf_a[5].lerp(kf_b[5], t)

	# ── Apply sky ──────────────────────────────────────────────────────
	if _sky_material:
		_set_sky_color("sky_top_color", kf_a[6].lerp(kf_b[6], t))
		_set_sky_color("sky_horizon_color", kf_a[7].lerp(kf_b[7], t))
		_set_sky_color("ground_bottom_color", kf_a[8].lerp(kf_b[8], t))
		_set_sky_color("ground_horizon_color", kf_a[9].lerp(kf_b[9], t))

	# ── Apply fog ──────────────────────────────────────────────────────
	if _environment:
		var fog_density: float = lerpf(kf_a[10], kf_b[10], t)
		fog_density = maxf(fog_density, 0.0012) * 0.12  # Metre-scale city visibility.
		_environment.fog_enabled = fog_density > 0.00005
		if _environment.fog_enabled:
			_environment.fog_density = fog_density
			_environment.fog_light_color = kf_a[7].lerp(kf_b[7], t)
			_environment.fog_sky_affect = 0.18

	# ── Night mode detection ───────────────────────────────────────────
	var now_night: bool = (hour >= NIGHT_START_HOUR or hour < MORNING_HOUR)
	if now_night != _is_night:
		_is_night = now_night
		night_mode_changed.emit(_is_night)

	# ── Dusk mode detection (superset of night) ────────────────────────
	# True from 4:30 PM through 6:00 AM so a subset of windows / car
	# headlights can come on before full dark and stay on through the night.
	var now_dusk: bool = (hour >= DUSK_START_HOUR or hour < MORNING_HOUR)
	if now_dusk != _is_dusk:
		_is_dusk = now_dusk
		dusk_mode_changed.emit(_is_dusk)


func _set_sky_color(key: String, color: Color) -> void:
	if _sky_material is ShaderMaterial:
		_sky_material.set_shader_parameter(key, color)
	elif _sky_material:
		_sky_material.set(key, color)
