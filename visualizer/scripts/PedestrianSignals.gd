extends Node
## Live pedestrian heads for one junction (ITE hand / walking person). WALK while
## SUMO has the crossing green; a flashing hand while walkers who started on WALK
## are still on the crossing (scripts/crossing_safety.py holds the conflicting
## traffic for them); a steady hand otherwise. Packets without crossing states
## fall back to the crossing columns of PHASE_SIGNALS in ai/traffic_env.py.
const Signals = preload("res://scripts/SignalHardware.gd")
const ARMS: Array[String] = ["north", "east", "south", "west"]   # SUMO crossings c0..c3
var junction: String = "J0"
var heads: Dictionary = {"north": [], "east": [], "south": [], "west": []}
var modes: Dictionary = {"north": "stop", "east": "stop", "south": "stop", "west": "stop"}
var _blink: float = 0.0

static func phase_walk(phase: int) -> Dictionary:
	# N/S vehicle phases walk the east and west crossings, E/W phases the north
	# and south ones; yellows walk none.
	var ns: bool = phase in [0, 1, 6]
	var ew: bool = phase in [3, 4, 7]
	return {"north": ew, "east": ns, "south": ew, "west": ns}

func add(arm: String, head: Dictionary) -> void:
	heads[arm].append(head)

func update(state: Dictionary, pedestrians: Array) -> void:
	var walk: Dictionary = state.get("crossing_green", phase_walk(int(state.get("phase", 0))))
	var occupied: Dictionary = {}
	var prefix := ":%s_c" % junction
	for ped in pedestrians:
		var edge := String(ped.get("edge", ""))
		if edge.begins_with(prefix):
			occupied[ARMS[clampi(int(edge.get_slice("_c", 1)), 0, 3)]] = true
	for arm in ARMS:
		var mode: String = "walk" if bool(walk.get(arm, false)) else ("flash" if occupied.has(arm) else "stop")
		modes[arm] = mode
		for head in heads[arm]:
			Signals.set_aspect(head["person"], mode == "walk")
			Signals.set_aspect(head["hand"], mode == "stop" or (mode == "flash" and _blink < 0.5))

func _process(delta: float) -> void:
	_blink = fmod(_blink + delta, 1.0)
	var lit: bool = _blink < 0.5
	for arm in ARMS:
		if modes[arm] != "flash":
			continue
		for head in heads[arm]:
			if head["hand"]["on"] != lit:
				Signals.set_aspect(head["hand"], lit)
