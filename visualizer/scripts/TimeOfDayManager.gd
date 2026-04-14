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

# ── Mode ────────────────────────────────────────────────────────────────────
enum Mode { MANUAL, AUTO_CYCLE, SIM_LINKED }

var mode: Mode = Mode.AUTO_CYCLE
var time_of_day: float = 10.0   # 0.0–24.0 (hours)
var cycle_speed: float = 30.0   # Real seconds per sim-hour (full day in 12 min)

# ── Night state ─────────────────────────────────────────────────────────────
var _is_night: bool = false

# ── Node references (set by parent script) ──────────────────────────────────
var sun: DirectionalLight3D
var world_env: WorldEnvironment
var _sky_material: ProceduralSkyMaterial
var _environment: Environment

# ── Sun azimuth (preserved from scene, only pitch changes) ──────────────────
var _sun_base_transform: Transform3D
var _sun_yaw: float = 0.0


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
	# Morning (default — matches original scene)
	[10.0, 1.3, Color(1.0, 0.96, 0.9),   45.0,
	 0.6,  Color(0.35, 0.35, 0.40),
	 Color(0.35, 0.55, 0.85), Color(0.65, 0.75, 0.88),
	 Color(0.18, 0.22, 0.15), Color(0.55, 0.62, 0.55),
	 0.0],
	# Noon
	[14.0, 1.5, Color(1.0, 1.0, 0.98),   70.0,
	 0.7,  Color(0.40, 0.40, 0.45),
	 Color(0.30, 0.50, 0.90), Color(0.60, 0.72, 0.92),
	 Color(0.20, 0.25, 0.16), Color(0.55, 0.62, 0.55),
	 0.0],
	# Dusk
	[17.0, 0.8, Color(1.0, 0.55, 0.25),  25.0,
	 0.4,  Color(0.40, 0.30, 0.25),
	 Color(0.55, 0.30, 0.45), Color(0.90, 0.50, 0.25),
	 Color(0.15, 0.12, 0.10), Color(0.50, 0.35, 0.25),
	 0.002],
	# Night
	[20.0, 0.0, Color(0.2, 0.2, 0.4),    10.0,
	 0.15, Color(0.12, 0.12, 0.18),
	 Color(0.05, 0.05, 0.15), Color(0.10, 0.10, 0.18),
	 Color(0.05, 0.05, 0.05), Color(0.08, 0.08, 0.10),
	 0.004],
	# Midnight
	[2.0,  0.0, Color(0.15, 0.15, 0.3),  -10.0,
	 0.10, Color(0.08, 0.08, 0.12),
	 Color(0.03, 0.03, 0.10), Color(0.06, 0.06, 0.12),
	 Color(0.03, 0.03, 0.03), Color(0.05, 0.05, 0.07),
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
		_sky_material = _environment.sky.sky_material as ProceduralSkyMaterial

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

	sun.light_energy = sun_energy
	sun.light_color = sun_color
	sun.visible = sun_energy > 0.01

	# Rotate sun pitch while keeping yaw constant
	if _sun_base_transform == Transform3D():
		_sun_base_transform = sun.transform
	# Reconstruct rotation: keep original yaw/roll, change pitch (X rotation)
	sun.rotation_degrees.x = -(90.0 - sun_pitch)  # Map pitch angle to Godot rotation

	# ── Apply ambient ──────────────────────────────────────────────────
	if _environment:
		_environment.ambient_light_energy = lerpf(kf_a[4], kf_b[4], t)
		_environment.ambient_light_color = kf_a[5].lerp(kf_b[5], t)

	# ── Apply sky ──────────────────────────────────────────────────────
	if _sky_material:
		_sky_material.sky_top_color = kf_a[6].lerp(kf_b[6], t)
		_sky_material.sky_horizon_color = kf_a[7].lerp(kf_b[7], t)
		_sky_material.ground_bottom_color = kf_a[8].lerp(kf_b[8], t)
		_sky_material.ground_horizon_color = kf_a[9].lerp(kf_b[9], t)

	# ── Apply fog ──────────────────────────────────────────────────────
	if _environment:
		var fog_density: float = lerpf(kf_a[10], kf_b[10], t)
		_environment.fog_enabled = fog_density > 0.0005
		if _environment.fog_enabled:
			_environment.fog_density = fog_density
			_environment.fog_light_color = kf_a[5].lerp(kf_b[5], t)  # Tint fog with ambient

	# ── Night mode detection ───────────────────────────────────────────
	var now_night: bool = (hour >= 19.0 or hour < 6.0)
	if now_night != _is_night:
		_is_night = now_night
		night_mode_changed.emit(_is_night)
