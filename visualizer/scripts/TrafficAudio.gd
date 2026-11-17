extends Node3D
## Sparse street sound for the TrafIQ visualizer.
##
## There is deliberately NO continuous engine or traffic-roar layer. Two attempts
## at synthesised engine loops were both heard as a fake drone that starts with
## the sim and never stops, so nothing here plays constantly by day. What is
## left is occasional and quiet:
##
##   • HORNS — short taps and double taps from vehicles near the listener,
##     more often in a jam, with long gaps between them.
##   • CRICKETS at night and a few BIRDS by day, both low and fading with
##     height, rain and (for crickets) the town.
##   • LISTENER — an AudioListener3D near what the camera is looking at, so
##     horns are heard from the overview as well as from the street.
##
## Press M to mute or unmute all sim sound. The WAV files are synthesised by
## scripts/build_soundscape.py and read from assets/audio at startup.
## Created as a child by VehicleManager in both scenes.

const AUDIO_DIR := "res://assets/audio/"
const HORN_POOL_SIZE: int = 3
const HORN_CHECK_INTERVAL: float = 0.5
const BED_INTERVAL: float = 0.5
const EAR_REACH: float = 60.0

var _vm: Node3D
var _tod: Node
var _weather: Node
var _ear: AudioListener3D
var _streams: Dictionary = {}
var _missing: Array[String] = []
var _horn_players: Array[AudioStreamPlayer3D] = []
var _beds: Dictionary = {}               # name -> AudioStreamPlayer
var _bed_targets: Dictionary = {}        # name -> target volume_db
var _bed_t: float = 0.0
var _horn_t: float = 0.0
var _horn_cooldown: float = 6.0          # nothing sounds in the first seconds
var _ear_position := Vector3.ZERO


func _ready() -> void:
	_vm = get_parent() as Node3D
	var scene: Node = _vm.get_parent() if _vm else null
	if scene:
		_tod = scene.get_node_or_null("TimeOfDayManager")
		_weather = scene.get_node_or_null("WeatherManager")
	for loop_name in ["night_crickets", "day_birds"]:
		_streams[loop_name] = _load(loop_name, true)
	for shot_name in ["horn_car_tap", "horn_car_double", "horn_taxi_pips", "horn_trotro_double"]:
		_streams[shot_name] = _load(shot_name, false)
	_ensure_limiter()

	_ear = AudioListener3D.new()
	_ear.name = "StreetListener"
	add_child(_ear)
	_ear.make_current()

	for i in range(HORN_POOL_SIZE):
		var horn := AudioStreamPlayer3D.new()
		horn.name = "Horn_%d" % i
		horn.unit_size = 17.0
		horn.max_distance = 280.0
		# Distance dulls a horn before it silences it.
		horn.attenuation_filter_cutoff_hz = 3800.0
		horn.attenuation_filter_db = -18.0
		horn.bus = "Master"
		add_child(horn)
		_horn_players.append(horn)
	for bed_name in ["night_crickets", "day_birds"]:
		var bed := AudioStreamPlayer.new()
		bed.name = bed_name.to_pascal_case()
		bed.stream = _streams[bed_name]
		bed.volume_db = -70.0
		bed.bus = "Master"
		add_child(bed)
		_beds[bed_name] = bed
		_bed_targets[bed_name] = -70.0

	if _missing.is_empty():
		print("[TrafficAudio] Ready — horns, night crickets, day birds; no engine loops. M mutes.")
	else:
		push_warning("[TrafficAudio] Missing sound files %s; run scripts/build_soundscape.py" % str(_missing))


func _load(sound: String, loop: bool) -> AudioStreamWAV:
	## Read the WAV straight from disk. The folder is not imported by Godot.
	var path: String = AUDIO_DIR + sound + ".wav"
	if not FileAccess.file_exists(path):
		_missing.append(sound)
		return null
	var wav: AudioStreamWAV = AudioStreamWAV.load_from_file(ProjectSettings.globalize_path(path))
	if wav == null:
		_missing.append(sound)
		return null
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav.data.size() / (4 if wav.stereo else 2)
	return wav


func _ensure_limiter() -> void:
	## Hold the sum of everything under full scale on the master bus.
	if not ClassDB.class_exists("AudioEffectHardLimiter"):
		return
	for i in range(AudioServer.get_bus_effect_count(0)):
		if AudioServer.get_bus_effect(0, i).is_class("AudioEffectHardLimiter"):
			return
	var limiter: AudioEffect = ClassDB.instantiate("AudioEffectHardLimiter")
	limiter.set("ceiling_db", -1.0)
	AudioServer.add_bus_effect(0, limiter)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_M:
		var muted: bool = not AudioServer.is_bus_mute(0)
		AudioServer.set_bus_mute(0, muted)
		print("[TrafficAudio] Sound ", "muted" if muted else "on")


func _process(delta: float) -> void:
	if _vm == null or not _vm.has_method("audio_snapshot"):
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	_ear_position = _place_ear(cam)

	_horn_cooldown = maxf(_horn_cooldown - delta, 0.0)
	_horn_t -= delta
	if _horn_t <= 0.0:
		_horn_t = HORN_CHECK_INTERVAL
		_maybe_honk(_ear_position)

	_bed_t -= delta
	if _bed_t <= 0.0:
		_bed_t = BED_INTERVAL
		_set_bed_targets(_ear_position)
	for bed_name in _beds:
		var bed: AudioStreamPlayer = _beds[bed_name]
		bed.volume_db = lerpf(bed.volume_db, _bed_targets[bed_name], 1.0 - exp(-delta * 1.5))
		# A silent layer is stopped, not left running at a low level.
		var wanted: bool = _bed_targets[bed_name] > -55.0 and bed.stream != null
		if wanted and not bed.playing:
			bed.play()
		elif not wanted and bed.playing and bed.volume_db < -58.0:
			bed.stop()


func _place_ear(cam: Camera3D) -> Vector3:
	## The listener rides between the camera and the ground it is looking at.
	var origin: Vector3 = cam.global_position
	var forward: Vector3 = -cam.global_basis.z
	var target: Vector3 = origin
	if forward.y < -0.05:
		target = origin + forward * (origin.y / -forward.y)
	var ear: Vector3 = target + (origin - target).limit_length(EAR_REACH)
	ear.y = maxf(ear.y, 1.6)
	_ear.global_transform = Transform3D(cam.global_basis.orthonormalized(), ear)
	return ear


func _maybe_honk(ear: Vector3) -> void:
	## A horn now and then: taxis touting, trotros pulling out, a stuck queue.
	if _horn_cooldown > 0.0:
		return
	var cands: Array = _vm.audio_snapshot(ear, 170.0)
	if cands.is_empty():
		return
	var stopped: int = 0
	for c in cands:
		if c["speed"] < 0.5:
			stopped += 1
	var chance: float = clampf(0.02 + cands.size() * 0.002 + stopped * 0.004, 0.0, 0.18)
	if randf() > chance:
		return
	var victim: Dictionary = cands[randi() % cands.size()]
	var roll: float = randf()
	var sound: String
	if str(victim["type"]) == "trotro":
		sound = "horn_trotro_double"
	elif roll < 0.55:
		sound = "horn_car_tap"
	elif roll < 0.85:
		sound = "horn_car_double"
	else:
		sound = "horn_taxi_pips"
	if _streams[sound] == null:
		return
	for player in _horn_players:
		if player.playing:
			continue
		player.stream = _streams[sound]
		var node: Node3D = victim["node"]
		if node != null and is_instance_valid(node):
			player.global_position = node.global_position
		player.pitch_scale = randf_range(0.93, 1.09)
		player.volume_db = randf_range(-13.0, -8.0)
		player.play()
		_horn_cooldown = randf_range(2.5, 7.0)
		return


func _set_bed_targets(ear: Vector3) -> void:
	var hour: float = float(_tod.get("time_of_day")) if is_instance_valid(_tod) else 12.0
	var day: float = smoothstep(5.3, 7.0, hour) * (1.0 - smoothstep(18.5, 20.0, hour))
	var dawn: float = smoothstep(5.0, 6.0, hour) * (1.0 - smoothstep(8.0, 10.0, hour))
	var rain: float = 0.0
	if is_instance_valid(_weather):
		rain = float(_weather.get("_current_mods").rain_intensity)
	var near_ground: float = 1.0 - smoothstep(25.0, 130.0, ear.y)
	var town: float = _town_amount(ear)
	_bed_targets["night_crickets"] = _level((1.0 - day) * (1.0 - smoothstep(60.0, 260.0, ear.y)) * (1.0 - town * 0.5) * (1.0 - rain), -26.0)
	_bed_targets["day_birds"] = _level(day * (0.3 + 0.7 * dawn) * near_ground * (1.0 - town * 0.4) * (1.0 - rain), -27.0)


func _level(amount: float, full_db: float) -> float:
	return full_db + linear_to_db(clampf(amount, 0.001, 1.0))


func _town_amount(ear: Vector3) -> float:
	## 1 inside the built-up area, falling away over the first hundred metres of bush.
	if _vm.get("corridor_mode"):
		var town: Rect2 = preload("res://scripts/CityDistrictBuilder.gd").TOWN
		var dx: float = maxf(maxf(town.position.x - ear.x, ear.x - town.end.x), 0.0)
		var dz: float = maxf(maxf(town.position.y - ear.z, ear.z - town.end.y), 0.0)
		return 1.0 - smoothstep(0.0, 120.0, Vector2(dx, dz).length())
	return 1.0 - smoothstep(90.0, 260.0, Vector2(ear.x, ear.z).length())
