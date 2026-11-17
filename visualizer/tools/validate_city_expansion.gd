extends SceneTree
var failures := 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void: call_deferred("run")
func run() -> void:
	var scene: Node3D = load("res://scenes/CorridorMain.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	await process_frame
	var env: Node3D = scene.get_node("EnvironmentBuilder")
	var town = preload("res://scripts/CityDistrictBuilder.gd")
	var plots: Array = env.get_meta("city_parcels")
	check(plots.size() >= 140 and plots.size() < 250,"Compact town infill coverage changed unexpectedly")
	for kind in ["mall","supermarket","bank","house","office","shop","apartment","park","market","warehouse"]:
		check(env.get_meta("city_mix").get(kind,0) > 0,"Missing compact-town destination: "+kind)
	check(env._streetscape._building_count > 450 and env._streetscape._building_count < 800,"Town should be populated without recreating the sprawling grid")
	for section: Dictionary in town.sections():
		var local_plots: int = 0
		for plot: Rect2 in plots:
			if section.bounds.has_point(plot.get_center()): local_plots += 1
		check(local_plots >= 8,"Missing planned infill in "+section.name)
	var airport: Node3D = env.get_node("Airport")
	check(airport.aircraft.size() == 2,"Compact airport must retain both detailed passenger stands")
	var layout = preload("res://scripts/AirportLayout.gd")
	check(layout.SITE.size.x < 160 and layout.SITE.size.y < 250,"Airport should fit beside the compact town")
	check(airport.scale.is_equal_approx(Vector3.ONE*layout.SCALE),"Airport size must match its reserved site")
	for footprint in airport.obstacles:
		check(not footprint.intersects(layout.RUNWAY),"Airport structure obstructs runway")
	for plot in plots:
		check(town.TOWN.encloses(plot),"Infill must stay inside the compact town boundary")
		for street in town.streets():
			check(not plot.intersects(town.street_plot(street)),"Town building obstructs its local street")
		check(not plot.intersects(layout.SITE),"City plot occupies airfield")
		check(not plot.intersects(Rect2(-6.4,-1500,12.8,3600)),"City plot blocks arterial")
		for z in [0,300,600]: check(not plot.intersects(Rect2(-1500,z-6.4,3000,12.8)),"City plot blocks cross street")
	for footway: Rect2 in env.get_meta("city_footways"):
		check(not footway.intersects(Rect2(-6.4,-1500,12.8,3600)),"Local footway obstructs main carriageway")
		for j in range(3):
			var widths := preload("res://scripts/CorridorGeometry.gd").widths(j)
			check(not footway.intersects(Rect2(-1500,j*300-widths.y/2,1500,widths.y)),"Local footway crosses live west approach")
			check(not footway.intersects(Rect2(0,j*300-widths.z/2,1500,widths.z)),"Local footway crosses live east approach")
	scene.get_node("TimeOfDayManager").set_time(21)
	airport._process(1)
	check(airport._lit,"Airport lighting must turn on at night")
	scene.get_node("TimeOfDayManager").set_time(13)
	airport._process(1)
	check(not airport._lit,"Airport lighting must respond to daylight")
	print("Compact town validation: ",failures," failures")
	scene.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
