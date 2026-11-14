extends Node3D
## Procedural folding quadcopter in the compact consumer style, modelled at flight
## scale. Nose is -Z. The front arms fold from high shoulders and the rear arms swing
## down from under the tail, so the rear rotors run lower than the front ones.
## Static parts are baked by material; rotors and the three-axis gimbal stay articulated.
const G = preload("res://scripts/PropGeometry.gd")
# Front-left, front-right, rear-left, rear-right; diagonal pairs share a spin direction.
const MOTOR_POINTS: Array[Vector3] = [Vector3(-0.322, 0.030, -0.262), Vector3(0.322, 0.030, -0.262), Vector3(-0.300, -0.040, 0.268), Vector3(0.300, -0.040, 0.268)]
const PROP_RADIUS: float = 0.19
const FOOT_Y: float = -0.112
var rotors: Array[Node3D] = []
var _blur_discs: Array[MeshInstance3D] = []
var _gimbal_roll: Node3D
var _gimbal_pitch: Node3D
var _gimbal_yaw: Node3D
var _blade_material: StandardMaterial3D
var _tail_material: StandardMaterial3D
var _beacon_material: StandardMaterial3D
var _parts: Node3D
var _slate: Material
var _titanium: Material
var _graphite: Material
var _rubber: Material
var _metal: Material
var _accent: Material
var _glass: Material
var _gloss: Material

func _ready() -> void:
	_slate = G.solid(Color("3b4348"), 0.28, 0.36)        # fuselage shell
	_titanium = G.solid(Color("9aa4aa"), 0.45, 0.32)     # battery and trim
	_graphite = G.solid(Color("23292d"), 0.3, 0.42)      # arms, belly, gimbal
	_rubber = G.solid(Color("111619"), 0.05, 0.75)
	_metal = G.solid(Color("8d989e"), 0.85, 0.22)
	_accent = G.solid(Color("f5a524"), 0.25, 0.35)       # amber trim, as on TSH-1
	_glass = G.solid(Color("10303d"), 0.8, 0.06)
	_gloss = G.solid(Color("0b0e10"), 0.6, 0.1)          # vision sensor surrounds
	_parts = Node3D.new()
	add_child(_parts)
	_build_shell()
	_build_arms()
	_build_feet()
	_build_sensors()
	_build_gimbal()
	_bake_static_parts()
	set_rotor_activity(0.0)

func _build_shell() -> void:
	# Squarer superellipse sections give a chamfered fuselage: narrow nose, broad
	# shoulders where the front arms fold, and a blunt tail for the rear sensors.
	_shell(_parts, [Vector4(-0.266, 0.006, 0.004, 0.002), Vector4(-0.248, 0.044, 0.028, 0.004),
		Vector4(-0.210, 0.078, 0.045, 0.008), Vector4(-0.140, 0.102, 0.056, 0.010),
		Vector4(-0.040, 0.110, 0.060, 0.011), Vector4(0.080, 0.108, 0.058, 0.010),
		Vector4(0.180, 0.096, 0.050, 0.006), Vector4(0.238, 0.072, 0.040, 0.004),
		Vector4(0.256, 0.050, 0.026, 0.004), Vector4(0.262, 0.030, 0.012, 0.004)], _slate, "Fuselage", 0.5)
	# Darker belly pan, a few millimetres proud of the shell.
	_shell(_parts, [Vector4(-0.215, 0.040, 0.010, -0.030), Vector4(-0.150, 0.088, 0.016, -0.040),
		Vector4(0.150, 0.086, 0.016, -0.040), Vector4(0.230, 0.050, 0.010, -0.028)], _graphite, "BellyPan", 0.5)
	# Top-loading smart battery, raised over the rear deck.
	_shell(_parts, [Vector4(-0.030, 0.062, 0.004, 0.066), Vector4(-0.012, 0.084, 0.014, 0.064),
		Vector4(0.150, 0.086, 0.015, 0.062), Vector4(0.212, 0.074, 0.012, 0.054),
		Vector4(0.232, 0.052, 0.004, 0.046)], _titanium, "SmartBattery", 0.45)
	for i in range(5):
		var z: float = 0.168 + i * 0.010
		var y: float = 0.0775 - (z - 0.150) / 0.062 * 0.011
		G.segment(_parts, Vector3(-0.045, y, z), Vector3(0.045, y, z), 0.0022, _rubber, "BatteryGrip")
	for i in range(4):
		G.ellipsoid(_parts, Vector3((i - 1.5) * 0.011, 0.0585, 0.2225), Vector3(0.006, 0.003, 0.004), _led(Color("67ac91"), 0.9), "BatteryGauge")
	G.ellipsoid(_parts, Vector3(0.037, 0.0575, 0.2215), Vector3(0.010, 0.004, 0.010), _accent, "PowerButton")
	var label := G.label(self, "ATCS", Vector3(0, 0.0785, 0.060), 0.084, 0.021, Color("4a5358"), "AirframeMark")
	label.rotation.x = -PI * 0.5
	label.shaded = false
	var serial := G.label(self, "SURVEY 01", Vector3(0, 0.0782, 0.100), 0.066, 0.010, Color("5d686e"), "AirframeSerial")
	serial.rotation.x = -PI * 0.5
	serial.shaded = false
	G.segment(_parts, Vector3(-0.058, 0.0535, -0.205), Vector3(0.058, 0.0535, -0.205), 0.0022, _accent, "NoseStripe")

func _build_arms() -> void:
	_blade_material = StandardMaterial3D.new()
	_blade_material.albedo_color = Color("1f262b")
	_blade_material.metallic = 0.2
	_blade_material.roughness = 0.38
	_blade_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var blade_mesh: ArrayMesh = _propeller_blade()
	var blur := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded;
void fragment() {
 vec2 p = UV * 2.0 - 1.0;
 float r = length(p);
 float ring = smoothstep(0.16,0.32,r) * (1.0-smoothstep(0.92,1.0,r));
 float arc = 0.65 + 0.35 * sin(atan(p.y,p.x)*2.0 + TIME*28.0);
 ALBEDO = vec3(0.34,0.40,0.43);
 ALPHA = ring * arc * 0.085;
}"""
	blur.shader = shader
	for i in range(MOTOR_POINTS.size()):
		var motor: Vector3 = MOTOR_POINTS[i]
		var side: float = signf(motor.x)
		var front: bool = motor.z < 0.0
		var root_at := Vector3(side * 0.100, 0.018, -0.122) if front else Vector3(side * 0.066, -0.044, 0.150)
		var elbow := root_at.lerp(motor, 0.5) + (Vector3(0, 0.006, -0.012) if front else Vector3(0, -0.014, 0.010))
		# Flattened, aerofoil-like arm, deepest at its folding hinge.
		_arm(_parts, [root_at, elbow, motor], [0.026, 0.019, 0.018], [0.017, 0.011, 0.012], _graphite)
		if front:
			# Front arms swing forward about a vertical hinge on the shoulder.
			_cylinder(_parts, root_at + Vector3(0, 0.004, 0), 0.021, 0.032, _graphite, "ArmHinge")
			_cylinder(_parts, root_at + Vector3(0, 0.021, 0), 0.014, 0.004, _metal, "HingeCap")
			var tip: Vector3 = motor - (motor - elbow).normalized() * 0.030
			G.segment(_parts, root_at + Vector3(0, 0.0175, 0), elbow + Vector3(0, 0.0115, 0), 0.0028, _accent, "ArmStripe")
			G.segment(_parts, elbow + Vector3(0, 0.0115, 0), tip + Vector3(0, 0.0125, 0), 0.0028, _accent, "ArmStripe")
		else:
			# Rear arms fold down and back about a horizontal hinge under the tail.
			G.segment(_parts, root_at + Vector3(-0.017, 0, 0), root_at + Vector3(0.017, 0, 0), 0.015, _graphite, "RearHinge")
			G.segment(_parts, root_at + Vector3(side * 0.017, 0, 0), root_at + Vector3(side * 0.020, 0, 0), 0.009, _metal, "HingePin")
		# Cable runs inside the underside of the arm to the motor.
		G.segment(_parts, root_at + Vector3(0, -0.015, 0), elbow + Vector3(0, -0.010, 0), 0.0028, _rubber, "MotorCable")
		G.segment(_parts, elbow + Vector3(0, -0.010, 0), motor + Vector3(0, -0.011, 0), 0.0028, _rubber, "MotorCable")
		# Low-profile brushless motor; the front pair wears amber crowns.
		_cylinder(_parts, motor, 0.030, 0.022, _graphite, "MotorMount")
		_cylinder(_parts, motor + Vector3(0, 0.015, 0), 0.025, 0.018, _metal, "BrushlessStator")
		_cylinder(_parts, motor + Vector3(0, 0.029, 0), 0.028, 0.018, _graphite, "MotorBell")
		for rib in range(10):
			var theta: float = rib * TAU / 10.0
			var at := motor + Vector3(cos(theta) * 0.028, 0.022, sin(theta) * 0.028)
			G.segment(_parts, at, at + Vector3(0, 0.013, 0), 0.0014, _rubber, "MotorCoolingSlot")
		_cylinder(_parts, motor + Vector3(0, 0.0395, 0), 0.020, 0.004, _accent if front else _metal, "MotorCrown")
		# Folding two-blade propeller on a quick-release hub.
		var prop := Node3D.new()
		prop.name = "Rotor%d" % i
		prop.position = motor + Vector3(0, 0.046, 0)
		add_child(prop)
		rotors.append(prop)
		for blade in range(2):
			var mesh := G.instance(prop, blade_mesh, Vector3.ZERO, _blade_material, "FoldingBlade")
			mesh.rotation.y = PI * blade
		_cylinder(prop, Vector3(0, 0.004, 0), 0.016, 0.012, _graphite, "QuickReleaseHub")
		_cylinder(prop, Vector3(0, 0.011, 0), 0.006, 0.004, _metal, "HubFastener")
		for x in [-0.020, 0.020]:
			_cylinder(prop, Vector3(x, 0.006, 0), 0.0042, 0.010, _metal, "BladePivot")
		if i in [0, 3]:
			_cylinder(prop, Vector3(0, 0.0105, 0), 0.0165, 0.0015, _titanium, "PropDirectionMark")
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE * PROP_RADIUS * 2.0
		var disc := G.instance(prop, quad, Vector3(0, 0.004, 0), blur, "RotorBlur")
		disc.rotation.x = -PI * 0.5
		disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_blur_discs.append(disc)
		prop.rotation.y = 0.35 + i * 0.8
		# Slim lenses under each motor: red port, green starboard, white at the rear.
		var color := Color("e9eef0")
		if front:
			color = Color("d14d3f") if side < 0 else Color("57bda1")
		G.ellipsoid(_parts, motor + Vector3(0, -0.013, -0.014 if front else 0.014), Vector3(0.016, 0.006, 0.022), _led(color, 1.9), "NavigationLens")

func _build_feet() -> void:
	# Short feet under the motors keep the gimbal clear of the ground; the
	# front pair carries the antenna strips.
	for motor in MOTOR_POINTS:
		var front: bool = motor.z < 0.0
		var top: Vector3 = motor + Vector3(0, -0.011, 0)
		var foot := Vector3(motor.x, FOOT_Y, motor.z)
		_arm(_parts, [top, top.lerp(foot, 0.6), foot + Vector3(0, 0.006, 0)], [0.011, 0.009, 0.008], [0.016, 0.012, 0.010], _graphite)
		G.ellipsoid(_parts, foot, Vector3(0.022, 0.012, 0.030), _rubber, "FootPad")
		if front:
			G.segment(_parts, top.lerp(foot, 0.25) + Vector3(0, 0, -0.0125), top.lerp(foot, 0.8) + Vector3(0, 0, -0.0105), 0.0032, _titanium, "AntennaStrip")

func _build_sensors() -> void:
	# Forward stereo vision pair in glossy surrounds at the nose.
	for x in [-0.034, 0.034]:
		G.ellipsoid(_parts, Vector3(x, 0.014, -0.238), Vector3(0.040, 0.028, 0.026), _gloss, "ForwardVisionSurround")
		G.segment(_parts, Vector3(x, 0.014, -0.249), Vector3(x, 0.014, -0.253), 0.0105, _metal, "SensorBezel")
		G.segment(_parts, Vector3(x, 0.014, -0.252), Vector3(x, 0.014, -0.2545), 0.0082, _glass, "StereoLens")
		G.ellipsoid(_parts, Vector3(x - 0.003, 0.017, -0.2552), Vector3(0.0035, 0.0035, 0.001), G.solid(Color("88b6c7"), 0.3, 0.12), "OpticalReflection")
	# Side vision on the flanks and a rear stereo pair in the blunt tail.
	for side in [-1.0, 1.0]:
		G.ellipsoid(_parts, Vector3(side * 0.106, 0.016, -0.075), Vector3(0.008, 0.020, 0.030), _gloss, "SideVision")
		G.segment(_parts, Vector3(side * 0.020, 0.006, 0.256), Vector3(side * 0.020, 0.006, 0.2635), 0.0065, _glass, "RearVision")
		for i in range(5):
			var z: float = 0.095 + i * 0.013
			G.segment(_parts, Vector3(side * 0.106, -0.006, z), Vector3(side * 0.108, 0.018, z + 0.006), 0.0024, _rubber, "CoolingVent")
	# Belly: downward optical-flow pair, range sensor and landing light.
	for x in [-0.030, 0.030]:
		_cylinder(_parts, Vector3(x, -0.057, 0.040), 0.013, 0.006, _gloss, "DownwardSensor")
		_cylinder(_parts, Vector3(x, -0.061, 0.040), 0.008, 0.002, _glass, "DownwardOptic")
	_cylinder(_parts, Vector3(0, -0.058, 0.095), 0.010, 0.005, _led(Color("fff6e6"), 0.6), "LandingLight")
	# Rear status light and a top anti-collision strobe, both animated in flight.
	_tail_material = _led(Color("e8bc72"), 2.0)
	G.ellipsoid(self, Vector3(0, 0.024, 0.258), Vector3(0.030, 0.007, 0.008), _tail_material, "RearStatusLED")
	_beacon_material = _led(Color("ffffff"), 0.3)
	G.ellipsoid(self, Vector3(0, 0.0715, -0.048), Vector3(0.012, 0.005, 0.012), _beacon_material, "TopStrobe")

func _build_gimbal() -> void:
	# Damped plate under the nose carrying a single-sided three-axis gimbal:
	# yaw motor on top, roll motor behind the camera, pitch motor on its left.
	var mount := G.rounded_box(_parts, Vector3(0, -0.050, -0.178), Vector3(0.074, 0.050, 0.010), 0.010, _graphite, "GimbalMount")
	mount.rotation.x = -PI * 0.5
	for x in [-0.026, 0.026]:
		for z in [-0.196, -0.160]:
			G.ellipsoid(_parts, Vector3(x, -0.056, z), Vector3(0.012, 0.014, 0.012), _rubber, "GimbalDamper")
	_gimbal_yaw = Node3D.new()
	_gimbal_yaw.name = "GimbalYaw"
	_gimbal_yaw.position = Vector3(0, -0.058, -0.200)
	add_child(_gimbal_yaw)
	_cylinder(_gimbal_yaw, Vector3.ZERO, 0.015, 0.012, _graphite, "YawMotor")
	G.segment(_gimbal_yaw, Vector3(0, -0.005, 0), Vector3(0, -0.024, 0.029), 0.0055, _graphite, "YawArm")
	_gimbal_roll = Node3D.new()
	_gimbal_roll.name = "GimbalRoll"
	_gimbal_roll.position = Vector3(0, -0.024, -0.012)   # on the camera's optical axis
	_gimbal_yaw.add_child(_gimbal_roll)
	G.segment(_gimbal_roll, Vector3(0, 0, 0.034), Vector3(0, 0, 0.048), 0.013, _graphite, "RollMotor")
	G.segment(_gimbal_roll, Vector3(0, 0, 0.041), Vector3(-0.052, 0, 0.041), 0.006, _graphite, "RollArm")
	G.segment(_gimbal_roll, Vector3(-0.052, 0, 0.041), Vector3(-0.052, 0, 0.0), 0.006, _graphite, "RollArm")
	G.segment(_gimbal_roll, Vector3(-0.058, 0, 0), Vector3(-0.044, 0, 0), 0.0135, _metal, "PitchMotor")
	G.segment(_gimbal_roll, Vector3(-0.044, 0, 0), Vector3(-0.038, 0, 0), 0.006, _metal, "PitchShaft")
	_gimbal_pitch = Node3D.new()
	_gimbal_pitch.name = "GimbalPitch"
	_gimbal_roll.add_child(_gimbal_pitch)
	G.rounded_box(_gimbal_pitch, Vector3.ZERO, Vector3(0.076, 0.048, 0.056), 0.016, _graphite, "CameraHousing")
	G.rounded_box(_gimbal_pitch, Vector3(0, 0, -0.029), Vector3(0.068, 0.042, 0.004), 0.014, _gloss, "CameraFace")
	G.segment(_gimbal_pitch, Vector3(0, 0, -0.030), Vector3(0, 0, -0.042), 0.0225, _rubber, "LensBarrel")
	G.segment(_gimbal_pitch, Vector3(0, 0, -0.040), Vector3(0, 0, -0.044), 0.021, _accent, "LensRing")
	G.segment(_gimbal_pitch, Vector3(0, 0, -0.044), Vector3(0, 0, -0.046), 0.018, _glass, "CoatedLens")
	G.segment(_gimbal_pitch, Vector3(0, 0, -0.046), Vector3(0, 0, -0.047), 0.0075, G.solid(Color("06151e"), 0.2, 0.12), "LensAperture")
	G.ellipsoid(_gimbal_pitch, Vector3(-0.006, 0.007, -0.048), Vector3(0.007, 0.0035, 0.001), G.solid(Color("72a5be"), 0.4, 0.1), "LensReflection")
	G.segment(_gimbal_pitch, Vector3(0.026, 0.013, -0.030), Vector3(0.026, 0.013, -0.033), 0.0042, _glass, "RangeSensor")
	var mark := G.label(_gimbal_pitch, "4K", Vector3(0.025, -0.014, -0.0315), 0.011, 0.007, Color("5d6a72"), "CameraMark")
	mark.rotation.y = PI

func animate_flight(spin: float, pitch: float, body_pitch: float, bank: float, heading_error: float, time: float) -> void:
	for i in range(rotors.size()):
		rotors[i].rotation.y = spin * (1.0 if i in [0, 3] else -1.0) + i * 0.8
	_gimbal_yaw.rotation.y = clampf(heading_error, -0.6, 0.6)
	_gimbal_roll.rotation.z = -bank
	_gimbal_pitch.rotation.x = clampf(pitch - body_pitch, -1.48, 0.65)
	_tail_material.emission_energy_multiplier = 2.8 if fmod(time, 1.2) < 0.12 else 0.35
	# Double flash on the top strobe, offset from the tail light.
	var phase: float = fmod(time + 0.5, 1.6)
	_beacon_material.emission_energy_multiplier = 4.0 if phase < 0.05 or (phase > 0.14 and phase < 0.19) else 0.2
	set_rotor_activity(1.0)

func set_rotor_activity(amount: float) -> void:
	_blade_material.albedo_color.a = lerpf(1.0, 0.58, clampf(amount, 0.0, 1.0))
	for disc in _blur_discs:
		disc.visible = amount > 0.05

func _cylinder(parent: Node3D, at: Vector3, radius: float, height: float, material: Material, node_name: String) -> MeshInstance3D:
	return G.segment(parent, at - Vector3.UP * height * 0.5, at + Vector3.UP * height * 0.5, radius, material, node_name)

func _led(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	material.roughness = 0.25
	return material

func _shell(parent: Node3D, rings: Array[Vector4], material: Material, node_name: String, exponent: float = 0.68) -> void:
	# Each ring is (z, half-width, half-height, centre y). Lower exponents give
	# squarer, more chamfered sections.
	var rows: Array = []
	for ring in rings:
		var row: Array[Vector3] = []
		for i in range(32):
			var angle: float = i * TAU / 32.0
			var x: float = signf(cos(angle)) * pow(absf(cos(angle)), exponent) * ring.y
			var y: float = signf(sin(angle)) * pow(absf(sin(angle)), exponent) * ring.z + ring.w
			row.append(Vector3(x, y, ring.x))
		rows.append(row)
	G.instance(parent, _surface_from_rings(rows), Vector3.ZERO, material, node_name)

func _arm(parent: Node3D, points: Array[Vector3], widths: Array[float], heights: Array[float], material: Material) -> void:
	var rows: Array = []
	for row in range(points.size()):
		var direction: Vector3 = points[mini(row + 1, points.size() - 1)] - points[maxi(row - 1, 0)]
		var along := direction.normalized()
		var side := along.cross(Vector3.UP).normalized()
		if side.length_squared() < 0.01:
			side = Vector3.RIGHT
		var up := side.cross(along).normalized()
		var ring: Array[Vector3] = []
		for i in range(16):
			var angle: float = i * TAU / 16.0
			ring.append(points[row] + side * cos(angle) * widths[row] + up * sin(angle) * heights[row])
		rows.append(ring)
	G.instance(parent, _surface_from_rings(rows), Vector3.ZERO, material, "TaperedArm")

func _propeller_blade() -> ArrayMesh:
	# Sections are (radius, chord, sweep, pitch angle): a slim, swept-back tip.
	var rows: Array = []
	var sections: Array[Vector4] = [Vector4(0.014, 0.013, 0, 0.24), Vector4(0.040, 0.030, 0.001, 0.20),
		Vector4(0.090, 0.029, 0.007, 0.15), Vector4(0.145, 0.022, 0.016, 0.10),
		Vector4(0.175, 0.013, 0.023, 0.06), Vector4(0.190, 0.002, 0.026, 0.03)]
	for section in sections:
		var row: Array[Vector3] = []
		for i in range(12):
			var angle: float = i * TAU / 12.0
			var chord: float = cos(angle) * section.y * 0.5
			var thickness: float = sin(angle) * section.y * 0.055
			row.append(Vector3(section.x, sin(section.w) * chord + thickness, section.z + cos(section.w) * chord))
		rows.append(row)
	return _surface_from_rings(rows)

func _surface_from_rings(rows: Array) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Establish outward winding from each cross-section centre, regardless of axis.
	for row in range(rows.size() - 1):
		var center := Vector3.ZERO
		for v: Vector3 in rows[row]:
			center += v / rows[row].size()
		for i in range(rows[row].size()):
			var next: int = (i + 1) % rows[row].size()
			_outward_triangle(st, rows[row][i], rows[row][next], rows[row + 1][i], center)
			_outward_triangle(st, rows[row][next], rows[row + 1][next], rows[row + 1][i], center)
	for end in [0, rows.size() - 1]:
		var center := Vector3.ZERO
		var inside := Vector3.ZERO
		for v: Vector3 in rows[end]:
			center += v / rows[end].size()
		for v: Vector3 in rows[1 if end == 0 else rows.size() - 2]:
			inside += v / rows[end].size()
		for i in range(rows[end].size()):
			_outward_triangle(st, center, rows[end][i], rows[end][(i + 1) % rows[end].size()], inside)
	st.index()
	st.generate_normals()
	return st.commit()

func _outward_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, inside: Vector3) -> void:
	if (b - a).cross(c - a).dot((a + b + c) / 3.0 - inside) < 0:
		G.triangle(st, a, c, b)
	else:
		G.triangle(st, a, b, c)

func _bake_static_parts() -> void:
	var groups: Dictionary = {}
	for node in _parts.get_children():
		if not node is MeshInstance3D:
			continue
		var material: Material = node.material_override
		if not groups.has(material):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[material] = st
		groups[material].append_from(node.mesh, 0, node.transform)
	var mesh := ArrayMesh.new()
	for material in groups:
		groups[material].set_material(material)
		groups[material].commit(mesh)
	var instance := MeshInstance3D.new()
	instance.name = "AirframeBody"
	instance.mesh = mesh
	add_child(instance)
	_parts.free()
