extends SceneTree
## Integration and transition checks. Rendering is verified with preview_streetscape.gd.
const Layout = preload("res://scripts/AirportLayout.gd")
const WeatherSystem = preload("res://scripts/WeatherManager.gd")
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	_transition_checks()
	for corridor in [false, true]:
		var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
		scene.get_node("WebSocketClient").auto_connect = false
		root.add_child(scene)
		current_scene = scene
		scene.set_process(false)
		scene.get_node("WebSocketClient").set_process(false)
		await process_frame
		var weather: Node = scene.get_node("WeatherManager")
		var clock: Node = scene.get_node("TimeOfDayManager")
		var clouds: Node = scene.get_node("CloudManager")
		_check(weather._sky_material is ShaderMaterial, "Continuous sky missing")
		_check(weather._sky_material == clock._sky_material and weather._sky_material == clouds._material, "Clock and weather use different skies")
		clock.set_time(13.0)
		weather.set_weather(3)
		for i in range(200):
			weather._lerp_mods_toward_target(0.2)
			weather._update_surface_water(0.2)
		weather._process(0.016)
		clouds._process(0.016)
		_check(weather._rain_particles.emitting, "Rain did not start")
		_check(weather.surface_wetness > 0.95, "Pavement does not accumulate rainwater")
		_check(weather._rain_collision.visible, "Roof collision is inactive during rain")
		_check(weather._rain_particles.lifetime * 19.0 >= weather.camera_follow.global_position.y + weather.RAIN_BOX_HEIGHT, "Rain dies above street level")
		_check(float(clouds._material.get_shader_parameter("cloud_cover")) > 0.95, "Storm clouds not applied")
		if corridor:
			_airport_checks(scene, weather, clock)
		weather.set_weather(2)
		for i in range(200):
			weather._lerp_mods_toward_target(0.2)
		weather._process(0.016)
		clouds._process(0.016)
		_check(not weather._rain_particles.emitting, "Rain does not stop for Harmattan")
		_check(not weather._rain_collision.visible, "Dry weather still captures a rain heightfield")
		_check(float(clouds._material.get_shader_parameter("dust")) > 0.95, "Harmattan haze not applied")
		_check(weather.get_wind().x < 0, "Harmattan wind does not change direction")
		var wet_after: float = weather.surface_wetness
		weather._update_surface_water(1.0)
		_check(weather.surface_wetness > wet_after * 0.98, "Roads dry instantly when weather changes")
		weather._update_surface_water(600.0)
		_check(weather.surface_wetness < 0.05, "Roads never dry after rain")
		print("AIRPORT/WEATHER validated ", "corridor" if corridor else "single")
		scene.queue_free()
		await process_frame
	print("Airport/weather validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)

func _transition_checks() -> void:
	var fine = WeatherSystem.new()
	var coarse = WeatherSystem.new()
	fine.set_weather(3)
	coarse.set_weather(3)
	for i in range(100):
		fine._lerp_mods_toward_target(0.05)
	for i in range(10):
		coarse._lerp_mods_toward_target(0.5)
	_check(is_equal_approx(fine._current_mods.rain_intensity, coarse._current_mods.rain_intensity), "Weather transition depends on frame rate")
	_check(fine._current_mods.wind.is_equal_approx(coarse._current_mods.wind), "Wind transition depends on frame rate")
	fine.set_weather(-1)
	_check(fine.get_weather() == 3, "Invalid preset changes the weather")
	fine.free()
	coarse.free()

func _airport_checks(scene: Node3D, weather: Node, clock: Node) -> void:
	var airport: Node3D = scene.get_node("EnvironmentBuilder/Airport")
	_check(airport.aircraft.size() == 2, "Both passenger stands need aircraft")
	for obstacle: Rect2 in airport.obstacles:
		_check(not obstacle.intersects(Layout.RUNWAY.grow(1.0)), "Airport structure obstructs the runway strip")
		_check(not obstacle.intersects(Layout.TAXIWAY), "Airport structure obstructs the parallel taxiway")
	var aircraft_plots: Array[Rect2] = []
	for aircraft: Node3D in airport.aircraft:
		var plot := Rect2(aircraft.position.x - 6.2, aircraft.position.z - 5.4, 12.4, 10.8)
		_check(Layout.APRON.encloses(plot), "Airliner extends outside the apron")
		for other in aircraft_plots:
			_check(not plot.intersects(other), "Parked aircraft overlap")
		aircraft_plots.append(plot)
		var mesh: ArrayMesh = aircraft.get_node("AirlinerGeometry").mesh
		_check(mesh.get_surface_count() < 10, "Airliner draw calls are not batched")
		var extent := Vector3.ZERO
		for surface in range(mesh.get_surface_count()):
			var arrays: Array = mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			for index in indices:
				extent = extent.max(vertices[index].abs())
		_check(extent.x > 5.2 and extent.y > 3.4, "Batching dropped the visible wings or vertical tail")
	var kit: Node3D = scene.get_node("EnvironmentBuilder/DetailedStreetscape")
	for use: Dictionary in kit.land_uses:
		var size := Vector2(use.width, use.depth)
		if absf(use.facing.x) > 0.5:
			size = Vector2(size.y, size.x)
		var plot := Rect2(Vector2(use.center.x, use.center.z) - size * 0.5, size)
		_check(not plot.intersects(Layout.SITE), "City building intrudes into airport grounds")
		_check(not plot.intersects(Layout.ACCESS), "City building blocks airport access")
	weather.set_weather(0)
	weather._lerp_mods_toward_target(100.0)
	clock.set_time(13.0)
	airport._process(0.016)
	_check(not airport._lit, "Airport floodlights remain on in clear daylight")
	clock.set_time(21.0)
	airport._process(0.016)
	_check(airport._lit and airport._lamps[0].light_energy > 0, "Airport does not light at night")
	clock.set_time(13.0)
	weather.set_weather(3)
	weather._lerp_mods_toward_target(100.0)
	airport._process(0.016)
	_check(airport._lit, "Airport lights do not respond to storm visibility")
