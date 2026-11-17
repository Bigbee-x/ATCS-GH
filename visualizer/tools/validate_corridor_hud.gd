extends SceneTree
## UI contract checks with explicit fixture data; no traffic server is started.
const HUD = preload("res://scripts/CorridorHUD.gd")
class ClockedHUD extends "res://scripts/CorridorHUD.gd":
	func _now_ms() -> int: return 20000

var failures := 0
var commands: Array = []
func _initialize() -> void: call_deferred("run")
func check(ok: bool,message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func run() -> void:
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280,720)
	var hud := ClockedHUD.new()
	root.add_child(hud)
	await process_frame
	await process_frame
	check(not hud._drawer.visible,"Inspector must start closed")
	check(hud._lbl_completed.text == "—" and hud._btn_mode_toggle.disabled,"No invented metrics or offline commands")
	var packet := fixture(100.0)
	hud.set_connection_status(true)
	hud.update_display(packet)
	check(hud._lbl_completed.text == "28" and hud._lbl_avg_wait.text == "2.6s","Top metrics disagree with packet")
	check(hud._cards.J1.details.text.contains("10 queued"),"J1 summary counts wrong")
	hud.update_display(packet)
	check(hud._history.J0.size() == 1,"Duplicate timestamp inflated history")
	hud.toggle_page("Traffic")
	hud.select_junction("J2")
	check(hud._detail_name.text == "Nima / Tesano","Junction selection wrong")
	check(hud._approaches.north.queue.text == "3","Selected junction queue wrong")
	check(hud._detail_signal.text.contains("N red"),"Actual signal states absent")
	hud.override_requested.connect(func(jid: String,arm: String): commands.append([jid,arm]))
	hud._request_override("north")
	check(commands == [["J2","north"]],"Override sent to wrong junction")
	var modes: Array = []
	hud.mode_switch_requested.connect(func(mode: String): modes.append(mode))
	hud._request_mode()
	check(modes == ["baseline"] and hud._lbl_mode.text == "Adaptive AI","Request falsely acknowledged before server")
	check(hud._btn_mode_toggle.disabled,"Repeated pending mode change enabled")
	hud.update_control_mode("baseline")
	check(hud._lbl_mode.text == "Fixed timer" and hud._pending_mode.is_empty(),"Server acknowledgement ignored")
	hud.set_connection_status(false)
	hud._request_override("east")
	check(commands.size() == 1 and hud._override_buttons[0].disabled,"Disconnected controls sent an action")
	check(hud._lbl_completed.text == "28" and hud._lbl_connection.text == "Reconnecting","Disconnect erased snapshot or claimed Live")
	hud.set_connection_status(true)
	hud._last_packet_ms = hud._now_ms()-16000
	hud._refresh_connection()
	check(hud._lbl_connection.text == "Data delayed" and hud._btn_mode_toggle.disabled,"Stale data still commands traffic")
	packet.junctions.J2.queues.erase("north")
	packet.junctions.J2.erase("avg_wait")
	hud.update_display(packet)
	check(hud._approaches.north.queue.text == "—" and hud._history.J2[-1].wait == null,"Missing samples invented zeroes")
	check(hud._cards.J2.details.text.contains("— queued"),"Partial queue presented as full total")
	var changed: Array = []
	hud.pedestrian_toggled.connect(func(enabled: bool): changed.append(enabled))
	hud._ped_toggle.button_pressed = false
	check(changed == [false],"Pedestrian visibility control disconnected")
	var times: Array = []
	hud.time_of_day_changed.connect(func(hour: float): times.append(hour))
	hud.update_time_display(18.5)
	check(times.is_empty() and hud._lbl_tod_time.text == "18:30","Scene clock update emitted a user command")
	hud._slider_tod.value = 13.5
	check(times == [13.5],"Time slider disconnected")
	var weather: Array = []
	hud.weather_changed.connect(func(index: int): weather.append(index))
	hud._weather_choice.item_selected.emit(3)
	check(weather == [3],"Weather control disconnected")
	hud.update_display(fixture(5.0))
	check(hud._history.J0.size() == 1 and hud._history.J0[0].time == 5.0,"Restart retains prior history")
	hud.show_completion({"total_arrived":77})
	check(hud._lbl_completed.text == "77" and hud._btn_mode_toggle.disabled,"Completion permits active commands")
	hud.reset_display()
	check(hud._history.J0.is_empty() and hud._lbl_avg_wait.text == "—","Reset invents or retains metrics")
	for dimensions in [Vector2i(1280,720),Vector2i(960,600),Vector2i(800,600)]:
		root.size = dimensions
		for page in ["Traffic","Scene","Controls"]:
			if not hud._page.is_empty(): hud.toggle_page(hud._page)
			hud.toggle_page(page)
			await process_frame
			await process_frame
			check(hud._top.get_global_rect().end.x <= dimensions.x,"Header overflows screen")
			check(hud._dock.get_global_rect().end.x <= dimensions.x,"Dock overflows screen")
			check(hud._drawer.get_global_rect().end.y <= dimensions.y-90,"Inspector overlaps dock")
			check(hud._drawer.get_global_rect().end.x <= dimensions.x,"Inspector overflows screen")
	check(hud.dismiss_panel() and not hud._drawer.visible,"Panel dismissal failed")
	print("Corridor HUD validation: ",failures," failures")
	hud.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)

func fixture(time: float) -> Dictionary:
	var junctions := {}
	for i in range(3):
		junctions["J%d" % i] = {"phase_name":"NS_THROUGH","phase_timer":17,"ai_decision":"HOLD","avg_wait":2.5+i,
			"queues":{"north":i+1,"east":2,"south":4,"west":2},"wait_times":{"north":2.0,"east":3.0,"south":4.0,"west":5.0},
			"signals":{"north":{"main":"red"}},"control":{"reason":"minimum_green","sample_time":time},
			"crossing_green":{"north":false,"east":true,"south":false,"west":true}}
	return {"mode":"corridor","control_mode":"ai","sim_time":time,"vehicles_completed":28,"corridor_avg_wait":2.6,"junctions":junctions}
