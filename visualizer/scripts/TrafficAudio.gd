extends Node3D
## Realistic road-traffic soundscape for the ATCS-GH visualizer.
##
## Three layers, all procedurally generated at startup (no audio asset files —
## same pattern as DroneController's prop-buzz and AudioManager's layers):
##
##   • ENGINE POOL — a pool of positional AudioStreamPlayer3D emitters assigned
##     to the vehicles nearest the current camera. Two engine voices: a petrol
##     car hum and a rougher, lower diesel (trotro/truck). Pitch and volume
##     track each vehicle's SUMO-reported speed (idle chug when queued, rising
##     note as they pull away). Doppler-tracked, so drone flybys bend pitch.
##
##   • HORNS — stochastic one-shot horns fired from stopped vehicles when a
##     junction is congested (the Accra soundtrack). Two voices: a dual-tone
##     car horn and a blarier trotro klaxon. Globally rate-limited.
##
##   • WASH — a non-positional distant-traffic bed (filtered noise) whose
##     volume follows how many vehicles are MOVING near the camera. Complements
##     AudioManager's queue-driven idle rumble rather than duplicating it.
##
## Created as a child by VehicleManager (no scene wiring needed — works in both
## the single-junction and corridor scenes). Reads vehicle poses/speeds via
## VehicleManager.audio_snapshot().

const MIX_RATE: int = 22050

# ── Engine pool tuning ───────────────────────────────────────────────────────
const ENGINE_POOL_SIZE: int = 10
const ENGINE_MAX_DIST: float = 45.0     # emitters only for vehicles this close
const ENGINE_KEEP_DIST: float = 54.0    # hysteresis: keep assignment till here
const RETUNE_INTERVAL: float = 0.25     # seconds between assignment passes
const MAX_SPEED: float = 19.44          # SUMO car maxSpeed (m/s) for normalising

# ── Horn tuning ──────────────────────────────────────────────────────────────
const HORN_POOL_SIZE: int = 3
const HORN_CHECK_INTERVAL: float = 0.5
const HORN_COOLDOWN: float = 2.5        # min seconds between any two horns
const HORN_MIN_JAM: int = 4             # stopped vehicles needed before honking

# ── State ────────────────────────────────────────────────────────────────────
var _vm: Node3D                          # VehicleManager (parent)
var _engine_players: Array = []          # AudioStreamPlayer3D pool
var _assignments: Dictionary = {}        # vid -> player index
var _engine_speeds: Dictionary = {}      # vid -> smoothed speed (for pitch)
var _horn_players: Array = []
var _wash_player: AudioStreamPlayer
var _retune_t: float = 0.0
var _horn_t: float = 0.0
var _horn_cooldown: float = 0.0
var _wash_target_db: float = -60.0

var _petrol_loop: AudioStreamWAV
var _diesel_loop: AudioStreamWAV
var _horn_car: AudioStreamWAV
var _horn_klaxon: AudioStreamWAV


func _ready() -> void:
	_vm = get_parent() as Node3D

	_petrol_loop = _gen_engine_loop(90.0, 0.18, 30.0, 0.10)
	_diesel_loop = _gen_engine_loop(55.0, 0.30, 12.0, 0.16)
	_horn_car = _gen_horn([400.0, 505.0], 0.7)
	_horn_klaxon = _gen_horn([310.0, 415.0, 466.0], 0.9)

	for i in range(ENGINE_POOL_SIZE):
		var p := AudioStreamPlayer3D.new()
		p.name = "Engine_%d" % i
		p.max_distance = ENGINE_MAX_DIST + 10.0
		p.unit_size = 6.0
		p.volume_db = -60.0
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
		p.bus = "Master"
		add_child(p)
		_engine_players.append(p)

	for i in range(HORN_POOL_SIZE):
		var h := AudioStreamPlayer3D.new()
		h.name = "Horn_%d" % i
		h.max_distance = 80.0
		h.unit_size = 9.0
		h.volume_db = -4.0
		h.bus = "Master"
		add_child(h)
		_horn_players.append(h)

	_wash_player = AudioStreamPlayer.new()
	_wash_player.name = "TrafficWash"
	var wash := _gen_wash_loop()
	_wash_player.stream = wash
	_wash_player.volume_db = -60.0
	_wash_player.bus = "Master"
	add_child(_wash_player)
	_wash_player.play()

	print("[TrafficAudio] Ready — %d engine emitters, %d horns, wash bed" % [
		ENGINE_POOL_SIZE, HORN_POOL_SIZE])


func _process(delta: float) -> void:
	if _vm == null or not _vm.has_method("audio_snapshot"):
		return
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null:
		return
	var cam_pos: Vector3 = cam.global_position

	_retune_t -= delta
	if _retune_t <= 0.0:
		_retune_t = RETUNE_INTERVAL
		_retune_engines(cam_pos)

	_update_engines(delta)

	_horn_cooldown = maxf(_horn_cooldown - delta, 0.0)
	_horn_t -= delta
	if _horn_t <= 0.0:
		_horn_t = HORN_CHECK_INTERVAL
		_maybe_honk(cam_pos)

	# Smooth the wash volume toward its target
	_wash_player.volume_db = lerpf(_wash_player.volume_db, _wash_target_db, delta * 2.0)


# ═════════════════════════════════════════════════════════════════════════════
# ENGINE POOL
# ═════════════════════════════════════════════════════════════════════════════

func _retune_engines(cam_pos: Vector3) -> void:
	## Reassign pool emitters to the nearest vehicles (with hysteresis so a
	## borderline car doesn't flap on/off), and refresh the wash target from
	## how much traffic is MOVING nearby.
	var cands: Array = _vm.audio_snapshot(cam_pos, ENGINE_KEEP_DIST)
	# cands: [{vid, node, speed, type, dist}] sorted by dist (nearest first)

	var moving_near: int = 0
	for c in cands:
		if c["speed"] > 1.0:
			moving_near += 1
	# Wash: -46 dB when empty → about -14 dB with 18+ movers
	_wash_target_db = clampf(-46.0 + float(moving_near) * 1.8, -46.0, -14.0)

	# Drop assignments whose vehicle vanished or drifted out of keep-range
	var cand_by_vid: Dictionary = {}
	for c in cands:
		cand_by_vid[c["vid"]] = c
	var stale: Array = []
	for vid in _assignments:
		if not cand_by_vid.has(vid):
			stale.append(vid)
	for vid in stale:
		var idx: int = _assignments[vid]
		(_engine_players[idx] as AudioStreamPlayer3D).stop()
		_assignments.erase(vid)
		_engine_speeds.erase(vid)

	# Assign free players to the nearest unassigned vehicles (within MAX_DIST)
	var used: Dictionary = {}
	for vid in _assignments:
		used[_assignments[vid]] = true
	for c in cands:
		if _assignments.size() >= ENGINE_POOL_SIZE:
			break
		if c["dist"] > ENGINE_MAX_DIST or _assignments.has(c["vid"]):
			continue
		for i in range(ENGINE_POOL_SIZE):
			if used.has(i):
				continue
			var p: AudioStreamPlayer3D = _engine_players[i]
			p.stream = _diesel_loop if str(c["type"]) == "trotro" else _petrol_loop
			p.play(randf() * 0.5)   # random loop offset so engines don't phase-lock
			_assignments[c["vid"]] = i
			_engine_speeds[c["vid"]] = c["speed"]
			used[i] = true
			break

	# Refresh node refs + reported speeds for every assigned vehicle
	for vid in _assignments:
		if cand_by_vid.has(vid):
			var c: Dictionary = cand_by_vid[vid]
			_engine_speeds[vid] = lerpf(float(_engine_speeds.get(vid, 0.0)),
					float(c["speed"]), 0.6)
			var p2: AudioStreamPlayer3D = _engine_players[_assignments[vid]]
			p2.set_meta("node", c["node"])


func _update_engines(delta: float) -> void:
	## Per-frame: follow each assigned vehicle and glide pitch/volume with its
	## smoothed speed. Idle = low chug; full speed = higher, louder note.
	for vid in _assignments:
		var p: AudioStreamPlayer3D = _engine_players[_assignments[vid]]
		var node: Node3D = p.get_meta("node", null)
		if node == null or not is_instance_valid(node):
			continue
		p.global_position = node.global_position
		var s: float = clampf(float(_engine_speeds.get(vid, 0.0)) / MAX_SPEED, 0.0, 1.0)
		var target_pitch: float = 0.75 + s * 0.55
		var target_db: float = -16.0 + s * 10.0
		p.pitch_scale = lerpf(p.pitch_scale, target_pitch, delta * 3.0)
		p.volume_db = lerpf(p.volume_db, target_db, delta * 3.0)


# ═════════════════════════════════════════════════════════════════════════════
# HORNS
# ═════════════════════════════════════════════════════════════════════════════

func _maybe_honk(cam_pos: Vector3) -> void:
	## Occasionally fire a horn from a stopped vehicle when traffic is jammed
	## nearby — probability scales with how many vehicles are sitting still.
	if _horn_cooldown > 0.0:
		return
	var cands: Array = _vm.audio_snapshot(cam_pos, 60.0)
	var stopped: Array = []
	for c in cands:
		if c["speed"] < 0.5:
			stopped.append(c)
	if stopped.size() < HORN_MIN_JAM:
		return
	var p_honk: float = clampf(0.02 + float(stopped.size()) * 0.004, 0.0, 0.15)
	if randf() > p_honk:
		return

	var victim: Dictionary = stopped[randi() % stopped.size()]
	for h in _horn_players:
		var player := h as AudioStreamPlayer3D
		if player.playing:
			continue
		player.stream = _horn_klaxon if str(victim["type"]) == "trotro" else _horn_car
		var node: Node3D = victim["node"]
		if node != null and is_instance_valid(node):
			player.global_position = node.global_position
		player.pitch_scale = randf_range(0.9, 1.15)
		player.play()
		_horn_cooldown = HORN_COOLDOWN
		return


# ═════════════════════════════════════════════════════════════════════════════
# PROCEDURAL SOUND GENERATION (startup, 16-bit PCM — DroneController pattern)
# ═════════════════════════════════════════════════════════════════════════════

func _gen_engine_loop(f0: float, chug_depth: float, chug_hz: float,
		noise_amp: float) -> AudioStreamWAV:
	## Looping engine voice: harmonic stack on f0, amplitude "chug" (slow AM),
	## and low-passed noise for the mechanical wash. 1-second seamless loop —
	## all partials are integer Hz, chug_hz divides evenly.
	var n: int = MIX_RATE
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var lp: float = 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = int(f0) * 7919
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var chug: float = 1.0 - chug_depth * (0.5 + 0.5 * sin(TAU * chug_hz * t))
		var s: float = sin(TAU * f0 * t) * 0.30
		s += sin(TAU * f0 * 2.0 * t) * 0.18
		s += sin(TAU * f0 * 3.0 * t) * 0.10
		s += sin(TAU * f0 * 4.5 * t) * 0.05
		s *= chug
		var white: float = rng.randf() * 2.0 - 1.0
		lp = lp * 0.85 + white * 0.15
		s += lp * noise_amp
		var s16: int = int(clampf(s, -1.0, 1.0) * 30000.0)
		bytes[i * 2] = s16 & 0xFF
		bytes[i * 2 + 1] = (s16 >> 8) & 0xFF
	return _wav(bytes, true)


func _gen_horn(freqs: Array, dur: float) -> AudioStreamWAV:
	## One-shot horn: stacked tones with square-ish harmonics, fast attack,
	## held body, quick release.
	var n: int = int(MIX_RATE * dur)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var env: float = 1.0
		if t < 0.02:
			env = t / 0.02                          # attack
		elif t > dur - 0.12:
			env = maxf((dur - t) / 0.12, 0.0)       # release
		var s: float = 0.0
		for f in freqs:
			var ff: float = float(f)
			s += sin(TAU * ff * t) * 0.28
			s += sin(TAU * ff * 2.0 * t) * 0.10     # square-ish bite
			s += sin(TAU * ff * 3.0 * t) * 0.05
		var s16: int = int(clampf(s * env, -1.0, 1.0) * 30000.0)
		bytes[i * 2] = s16 & 0xFF
		bytes[i * 2 + 1] = (s16 >> 8) & 0xFF
	return _wav(bytes, false)


func _gen_wash_loop() -> AudioStreamWAV:
	## Distant-traffic bed: heavily low-passed noise with a slow undulation —
	## the generic city "shhh" that moving traffic makes. 2-second loop.
	var n: int = MIX_RATE * 2
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var lp1: float = 0.0
	var lp2: float = 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x7EAFF1C
	for i in range(n):
		var t: float = float(i) / MIX_RATE
		var white: float = rng.randf() * 2.0 - 1.0
		lp1 = lp1 * 0.92 + white * 0.08
		lp2 = lp2 * 0.97 + lp1 * 0.03
		var undulate: float = 0.75 + 0.25 * sin(TAU * 0.5 * t)
		var s: float = (lp1 * 0.35 + lp2 * 0.65) * undulate
		var s16: int = int(clampf(s, -1.0, 1.0) * 30000.0)
		bytes[i * 2] = s16 & 0xFF
		bytes[i * 2 + 1] = (s16 >> 8) & 0xFF
	return _wav(bytes, true)


func _wav(bytes: PackedByteArray, loop: bool) -> AudioStreamWAV:
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = bytes.size() / 2
	return wav
