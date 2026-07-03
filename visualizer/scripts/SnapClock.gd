extends RefCounted
## Adaptive playback clock for sim-time-stamped snapshot interpolation.
## (No class_name — consumers `preload` this script, which works headless
## without the editor's global-class cache.)
##
## The visualizer server broadcasts entity positions once per SUMO second,
## stamped with the authoritative `sim_time`. Rendering entities AT the newest
## packet (or easing toward it) causes the classic once-per-second stutter; the
## April-2026 attempt to fix that with client-arrival-time interpolation was
## reverted (see 165df1c) because arrival times are bursty — segments froze or
## oscillated.
##
## This clock does what networked games do instead (snapshot interpolation):
##   • `feed(t)` once per packet records the newest sim_time and EMA-estimates
##     the production rate (sim-seconds per wall-second — handles --speed N).
##   • `advance(delta)` each frame moves `render_t` forward at the production
##     rate, gently corrected (±15 %) to hold `render_t` TARGET_DELAY sim-secs
##     behind the newest packet — an adaptive jitter buffer.
##   • Consumers interpolate their entities between the two snapshots that
##     straddle `render_t`. Always between KNOWN snapshots, never extrapolating,
##     so neither of the April failure modes can occur.
##
## The ~1.5 s render delay is invisible in practice: signals apply instantly
## while traffic responds a beat later, which reads as driver reaction time.
## Sim restarts (sim_time jumping backwards) hard-resync the clock.

const TARGET_DELAY: float = 1.5      # sim-seconds to stay behind the newest packet
const RESYNC_AHEAD: float = 6.0      # buffer depth beyond which we hard-resync
const RATE_EMA: float = 0.1          # production-rate smoothing factor

var latest_t: float = -1.0           # newest sim_time seen
var render_t: float = -1.0           # playback position (what consumers sample at)

var _prod_rate: float = 1.0          # EMA sim-seconds per wall-second
var _last_wall: float = -1.0
var _last_t: float = -1.0


func is_active() -> bool:
	return render_t >= 0.0


func restarted(t: float) -> bool:
	## True when packet time `t` implies the sim restarted (time went backwards).
	## Callers should clear their snapshot buffers when this returns true.
	return t >= 0.0 and latest_t >= 0.0 and t < latest_t - 1.0


func feed(t: float) -> void:
	## Call once per packet that carries a sim_time (t < 0 = no stamp, ignored).
	if t < 0.0:
		return
	var now: float = Time.get_ticks_msec() / 1000.0

	if restarted(t):
		latest_t = t
		render_t = t - TARGET_DELAY
		_prod_rate = 1.0
		_last_wall = -1.0
		_last_t = -1.0

	if _last_wall >= 0.0 and t > _last_t:
		var dw: float = now - _last_wall
		if dw > 0.001:
			var r: float = (t - _last_t) / dw
			if r < 20.0:                    # ignore absurd spikes (hitches)
				_prod_rate = lerpf(_prod_rate, r, RATE_EMA)
	if t > _last_t:
		_last_wall = now
		_last_t = t

	latest_t = maxf(latest_t, t)
	if render_t < 0.0:
		render_t = t - TARGET_DELAY


func advance(delta: float) -> void:
	## Call once per frame. Advances render_t; self-corrects toward the target
	## buffer depth; hard-resyncs when hopelessly out of range.
	if latest_t < 0.0 or render_t < 0.0:
		return
	var depth: float = latest_t - render_t
	if depth > RESYNC_AHEAD or depth < -0.5:
		render_t = latest_t - TARGET_DELAY
		return
	var corr: float = clampf(1.0 + (depth - TARGET_DELAY) * 0.1, 0.85, 1.15)
	render_t += delta * _prod_rate * corr
