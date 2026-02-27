extends Node
## Procedural audio manager for the ATCS-GH traffic visualizer.
##
## Three sound layers, all generated in real-time (no audio files):
##
##   1. AMBIENT TRAFFIC — Low-frequency rumble (110 Hz + harmonics + noise).
##      Volume scales with total queued vehicle count.
##
##   2. EMERGENCY SIREN — Frequency-sweep wah-wah siren (600-1200 Hz).
##      Plays only when an emergency vehicle is active.
##
##   3. PHASE CHANGE BEEP — Short 150ms tone at 660 Hz.
##      Fires each time the traffic light phase changes.
##
## All audio uses AudioStreamGenerator at 22050 Hz mix rate for
## low CPU overhead while maintaining acceptable quality.

# ── Constants ────────────────────────────────────────────────────────────────
const MIX_RATE: float = 22050.0
const BUFFER_LENGTH: float = 0.1   ## Seconds of audio buffer

# ── Audio players ────────────────────────────────────────────────────────────
var _ambient_player: AudioStreamPlayer
var _siren_player: AudioStreamPlayer
var _beep_player: AudioStreamPlayer

# ── Generator playbacks ──────────────────────────────────────────────────────
var _ambient_playback: AudioStreamGeneratorPlayback
var _siren_playback: AudioStreamGeneratorPlayback
var _beep_playback: AudioStreamGeneratorPlayback

# ── Synthesis state ──────────────────────────────────────────────────────────
## Ambient
var _ambient_phase: float = 0.0
var _ambient_volume: float = 0.15   ## 0.0 - 0.6, scales with vehicle count

## Siren
var _siren_active: bool = false
var _siren_phase: float = 0.0
var _siren_sweep_phase: float = 0.0  ## Controls the frequency sweep oscillation

## Beep
var _beep_remaining: float = 0.0    ## Seconds left of beep tone
var _beep_phase: float = 0.0
const BEEP_DURATION: float = 0.15   ## 150ms
const BEEP_FREQ: float = 660.0      ## Hz (E5 note)
const BEEP_VOLUME: float = 0.25

## Phase tracking (to detect changes)
var _last_phase: int = -1


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_setup_player("ambient")
	_setup_player("siren")
	_setup_player("beep")


func _process(delta: float) -> void:
	# Always fill ambient buffer
	if _ambient_playback:
		_fill_ambient()

	# Siren only when active
	if _siren_active and _siren_playback:
		_fill_siren()
	elif _siren_playback:
		# Push silence to keep buffer alive
		_fill_silence(_siren_playback)

	# Beep countdown
	if _beep_remaining > 0.0:
		if _beep_playback:
			_fill_beep()
		_beep_remaining -= delta
	elif _beep_playback:
		_fill_silence(_beep_playback)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func update_audio(data: Dictionary) -> void:
	## Called every state_update from Main.gd.

	# --- Scale ambient volume with total queued vehicles ---
	var total_q: int = 0
	var queues: Dictionary = data.get("queues", {})
	for approach in queues:
		total_q += int(queues[approach])
	# Range: quiet (0.08) at 0 vehicles -> loud (0.5) at 100+
	_ambient_volume = clampf(0.08 + float(total_q) * 0.004, 0.08, 0.5)

	# --- Siren on/off ---
	var emergency: Dictionary = data.get("emergency", {})
	_siren_active = emergency.get("active", false)

	# --- Detect phase change -> trigger beep ---
	var phase: int = data.get("phase", -1)
	if phase != _last_phase and _last_phase >= 0:
		_beep_remaining = BEEP_DURATION
		_beep_phase = 0.0
	_last_phase = phase


func reset_audio() -> void:
	## Called on simulation restart.
	_siren_active = false
	_last_phase = -1
	_beep_remaining = 0.0
	_ambient_volume = 0.15


# ═════════════════════════════════════════════════════════════════════════════
# SETUP
# ═════════════════════════════════════════════════════════════════════════════

func _setup_player(layer_name: String) -> void:
	## Create an AudioStreamPlayer with AudioStreamGenerator.
	var player := AudioStreamPlayer.new()
	player.name = "Audio_%s" % layer_name
	player.bus = "Master"

	var stream := AudioStreamGenerator.new()
	stream.mix_rate = MIX_RATE
	stream.buffer_length = BUFFER_LENGTH
	player.stream = stream
	add_child(player)

	# Volume adjustments per layer
	match layer_name:
		"ambient":
			player.volume_db = -6.0
			_ambient_player = player
		"siren":
			player.volume_db = -3.0
			_siren_player = player
		"beep":
			player.volume_db = -2.0
			_beep_player = player

	player.play()

	# Get the playback interface (must call after play())
	var pb = player.get_stream_playback()
	match layer_name:
		"ambient":
			_ambient_playback = pb
		"siren":
			_siren_playback = pb
		"beep":
			_beep_playback = pb


# ═════════════════════════════════════════════════════════════════════════════
# BUFFER FILLING — AMBIENT
# ═════════════════════════════════════════════════════════════════════════════

func _fill_ambient() -> void:
	## Low rumble: 110 Hz fundamental + 220 Hz harmonic + subtle noise.
	var frames: int = _ambient_playback.get_frames_available()
	if frames <= 0:
		return

	var inc_base: float = 110.0 / MIX_RATE
	var vol: float = _ambient_volume

	for i in range(frames):
		_ambient_phase += inc_base
		if _ambient_phase > 1.0:
			_ambient_phase -= 1.0

		# Fundamental + 2nd harmonic + noise
		var sample: float = sin(_ambient_phase * TAU) * vol * 0.4
		sample += sin(_ambient_phase * 2.0 * TAU) * vol * 0.15
		sample += randf_range(-1.0, 1.0) * vol * 0.08
		_ambient_playback.push_frame(Vector2(sample, sample))


# ═════════════════════════════════════════════════════════════════════════════
# BUFFER FILLING — SIREN
# ═════════════════════════════════════════════════════════════════════════════

func _fill_siren() -> void:
	## Wah-wah siren: frequency sweeps between 600 and 1200 Hz.
	var frames: int = _siren_playback.get_frames_available()
	if frames <= 0:
		return

	var sweep_rate: float = 2.5  ## Oscillations per second for the sweep

	for i in range(frames):
		# Sweep phase controls the frequency modulation
		_siren_sweep_phase += sweep_rate / MIX_RATE
		if _siren_sweep_phase > 1.0:
			_siren_sweep_phase -= 1.0

		# Current frequency: 600-1200 Hz sinusoidal sweep
		var freq: float = 900.0 + 300.0 * sin(_siren_sweep_phase * TAU)

		# Advance the tone phase
		_siren_phase += freq / MIX_RATE
		if _siren_phase > 1.0:
			_siren_phase -= 1.0

		var sample: float = sin(_siren_phase * TAU) * 0.3
		_siren_playback.push_frame(Vector2(sample, sample))


# ═════════════════════════════════════════════════════════════════════════════
# BUFFER FILLING — BEEP
# ═════════════════════════════════════════════════════════════════════════════

func _fill_beep() -> void:
	## Short tone with quick attack/decay envelope.
	var frames: int = _beep_playback.get_frames_available()
	if frames <= 0:
		return

	var inc: float = BEEP_FREQ / MIX_RATE

	for i in range(frames):
		_beep_phase += inc
		if _beep_phase > 1.0:
			_beep_phase -= 1.0

		# Envelope: quick fade-out over the beep duration
		var env: float = clampf(_beep_remaining / BEEP_DURATION, 0.0, 1.0)
		var sample: float = sin(_beep_phase * TAU) * BEEP_VOLUME * env
		_beep_playback.push_frame(Vector2(sample, sample))


# ═════════════════════════════════════════════════════════════════════════════
# UTILITY
# ═════════════════════════════════════════════════════════════════════════════

func _fill_silence(playback: AudioStreamGeneratorPlayback) -> void:
	## Push silence frames to keep the generator buffer from underrun.
	var frames: int = playback.get_frames_available()
	for i in range(frames):
		playback.push_frame(Vector2.ZERO)
