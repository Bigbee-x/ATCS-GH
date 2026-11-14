extends Node
## Apply signals at the vehicle playback time, including pedestrian clearance.
var intersection: Node3D
var vehicles: Node3D
var history: Array[Dictionary] = []
var displayed: Dictionary = {}

func feed(data: Dictionary) -> void:
	if not data.has("phase") and not data.has("junctions"):
		return
	var t: float = float(data.get("sim_time", 0))
	if not history.is_empty() and t < float(history.back().sim_time):
		history.clear()
	if not history.is_empty() and t == float(history.back().sim_time):
		history.pop_back()
	history.append(data)
	while history.size() > 32:
		history.pop_front()

func _process(_delta: float) -> void:
	if history.is_empty(): return
	var t: float = vehicles._clock.render_t
	var chosen: Dictionary = history[0]
	for packet in history:
		var effective: float = float(packet.get("signal_time", packet.sim_time))
		if packet.has("junctions"):
			effective = float(packet.junctions.get("J0", {}).get("signal_time", effective))
		if effective > t: break
		chosen = packet
	if displayed != chosen:
		displayed = chosen
		intersection.update_lights(chosen)

func reset() -> void:
	history.clear()
	displayed.clear()
