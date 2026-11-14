extends Node3D
## Smooth anatomical forms, a distance-driven gait and two-bone leg placement.
## Origin is at the soles. Forward is local +Z; all animation stays local.
const FABRIC = preload("res://shaders/pedestrian_fabric.gdshader")
static var _fabric_cache: Dictionary = {}
const G = preload("res://scripts/PropGeometry.gd")
const SHIRTS = [Color("a76b45"), Color("466c70"), Color("a79a73"), Color("795469"), Color("ded3b9"), Color("3e576c"), Color("547452")]
const SKINS = [Color("583827"), Color("754c34"), Color("8b6042"), Color("432d23"), Color("a37753")]
const TROUSERS = [Color("303a43"), Color("534c40"), Color("252d30"), Color("6c6554")]
var phase: float = 0.0
var stride_blend: float = 0.0
var age: float = 0.0
var character_scale: float = 1.0
var _hips: Array[MeshInstance3D] = []
var _shins: Array[MeshInstance3D] = []
var _knees: Array[MeshInstance3D] = []
var _shoes: Array[Node3D] = []
var _arms: Array[MeshInstance3D] = []
var _forearms: Array[MeshInstance3D] = []
var _hands: Array[MeshInstance3D] = []
var _upper: Node3D
var _head: Node3D
var _bag: Node3D
var _bag_side: float = 0.0
var _variation: float = 0.0

func configure(seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	phase = rng.randf() * TAU
	_variation = rng.randf() * TAU
	character_scale = rng.randf_range(0.94, 1.10)
	scale = Vector3.ONE * character_scale
	var shirt := _fabric(SHIRTS[rng.randi_range(0, SHIRTS.size() - 1)], seed_value % 4 == 2)
	var skin := G.solid(SKINS[rng.randi_range(0, SKINS.size() - 1)], 0, 0.68)
	var pants := _fabric(TROUSERS[rng.randi_range(0, TROUSERS.size() - 1)], false)
	var shoe := G.solid(Color("252522"), 0, 0.85)
	var hair := G.solid(Color("201c19"), 0, 0.88)
	_upper = Node3D.new()
	_upper.name = "UpperBody"
	add_child(_upper)
	# Continuous tailored surfaces replace intersecting oval torso pieces.
	G.loft(_upper, [Vector4(0.385, 0.04, 0.035, 0), Vector4(0.41, 0.072, 0.049, 0), Vector4(0.47, 0.072, 0.05, 0)], pants, "TrousersWaist")
	G.loft(_upper, [Vector4(0.466, 0.073, 0.051, 0), Vector4(0.49, 0.075, 0.052, 0.002), Vector4(0.55, 0.076, 0.05, 0), Vector4(0.60, 0.087, 0.055, 0), Vector4(0.64, 0.10, 0.052, 0), Vector4(0.66, 0.084, 0.045, 0), Vector4(0.684, 0.033, 0.031, 0)], shirt, "Shirt")
	for side in [-1.0, 1.0]:
		G.ellipsoid(_upper, Vector3(side * 0.101, 0.641, 0), Vector3(0.06, 0.062, 0.065), shirt, "SleeveShoulder")
	G.segment(_upper, Vector3(0, 0.68, 0), Vector3(0, 0.738, 0), 0.031, skin, "Neck")
	_head = Node3D.new()
	_head.position = Vector3(0, 0.784, 0)
	_head.name = "HeadPivot"
	_upper.add_child(_head)
	G.loft(_head, [Vector4(-0.067, 0.018, 0.019, 0.015), Vector4(-0.054, 0.032, 0.027, 0.015), Vector4(-0.034, 0.045, 0.038, 0.008), Vector4(-0.005, 0.052, 0.045, 0), Vector4(0.029, 0.052, 0.046, -0.002), Vector4(0.052, 0.04, 0.037, -0.004), Vector4(0.066, 0.02, 0.019, -0.004), Vector4(0.071, 0.001, 0.001, -0.004)], skin, "Head")
	G.ellipsoid(_head, Vector3(0, -0.004, 0.047), Vector3(0.016, 0.029, 0.021), skin, "Nose")
	for side in [-1.0, 1.0]:
		G.ellipsoid(_head, Vector3(side * 0.051, -0.008, -0.002), Vector3(0.015, 0.03, 0.022), skin, "Ear")
		G.ellipsoid(_head, Vector3(side * 0.023, 0.011, 0.041), Vector3(0.013, 0.0045, 0.006), hair, "Eye")
		G.ellipsoid(_head, Vector3(side * 0.023, 0.019, 0.042), Vector3(0.018, 0.003, 0.004), hair, "Brow")
	G.ellipsoid(_head, Vector3(0, -0.035, 0.046), Vector3(0.026, 0.004, 0.005), G.solid(skin.albedo_color.darkened(0.3)), "Mouth")
	G.loft(_head, [Vector4(0.026, 0.053, 0.047, -0.003), Vector4(0.043, 0.047, 0.043, -0.004), Vector4(0.061, 0.032, 0.03, -0.004), Vector4(0.073, 0.001, 0.001, -0.004)], hair, "Hair")
	if seed_value % 3 == 0:
		G.ellipsoid(_head, Vector3(0, 0.012, -0.064), Vector3(0.077, 0.089, 0.065), hair, "HairBun")
	if seed_value % 4 == 0:
		var cap := G.solid(Color("8d694b"))
		G.ellipsoid(_head, Vector3(0, 0.057, 0), Vector3(0.123, 0.048, 0.13), cap, "Cap")
		G.ellipsoid(_head, Vector3(0, 0.043, 0.059), Vector3(0.113, 0.012, 0.095), cap, "CapBrim")
	# Flat folded collar pieces, with subtle seams and small buttons.
	var collar_mesh := SurfaceTool.new()
	collar_mesh.begin(Mesh.PRIMITIVE_TRIANGLES)
	for side in [-1.0, 1.0]:
		G.triangle(collar_mesh, Vector3(side * 0.008, 0.676, 0.031), Vector3(side * 0.038, 0.672, 0.039), Vector3(side * 0.023, 0.645, 0.05))
	G.instance(_upper, collar_mesh.commit(), Vector3.ZERO, shirt, "Collar")
	for y in [0.63, 0.59, 0.55]:
		G.ellipsoid(_upper, Vector3(0, y, 0.06), Vector3.ONE * 0.006, G.solid(Color("c2b8a3")))
	for side in [-1.0, 1.0]:
		_hips.append(G.segment(self, Vector3.ZERO, Vector3.UP, 0.042, pants, "Thigh", 0.78))
		_shins.append(G.segment(self, Vector3.ZERO, Vector3.UP, 0.031, skin if seed_value % 5 == 0 else pants, "Shin", 0.72))
		_knees.append(G.ellipsoid(self, Vector3.ZERO, Vector3(0.063, 0.066, 0.067), skin if seed_value % 5 == 0 else pants, "Knee"))
		var foot := Node3D.new()
		foot.name = "Foot"
		add_child(foot)
		G.ellipsoid(foot, Vector3(0, -0.017, 0.025), Vector3(0.067, 0.048, 0.125), shoe, "Shoe")
		G.ellipsoid(foot, Vector3(0, -0.034, 0.025), Vector3(0.068, 0.013, 0.126), G.solid(Color("aaa28e")), "Sole")
		_shoes.append(foot)
		_arms.append(G.segment(self, Vector3.ZERO, Vector3.UP, 0.031, shirt, "Sleeve", 0.8))
		_forearms.append(G.segment(self, Vector3.ZERO, Vector3.UP, 0.023, skin, "Forearm", 0.73))
		_hands.append(G.ellipsoid(self, Vector3.ZERO, Vector3(0.037, 0.058, 0.027), skin, "Hand"))
	if seed_value % 3 == 1:
		_bag_side = 1.0
		_bag = Node3D.new()
		_bag.name = "ShoulderBag"
		_upper.add_child(_bag)
		G.rounded_box(_bag, Vector3(0.112, 0.45, -0.015), Vector3(0.085, 0.13, 0.09), 0.02, G.solid(Color("635044")))
		G.segment(_bag, Vector3(0.11, 0.49, 0.03), Vector3(0.10, 0.665, -0.01), 0.007, shoe, "Strap")
	animate(0.0, 0.0, 1.0)

func animate(distance: float, speed: float, delta: float) -> void:
	age += delta
	stride_blend = move_toward(stride_blend, clampf(speed / 0.30, 0.0, 1.0), delta * 5.0)
	# Distance, rather than time, advances the stance: feet do not skate at slow speeds.
	phase = fposmod(phase + distance / (0.45 * character_scale) * TAU, TAU)
	var bob: float = sin(phase * 2.0) * 0.004 * stride_blend
	var breath: float = sin(age * 1.7 + _variation) * 0.0015 * (1.0 - stride_blend)
	var ankles: Array[Vector3] = []
	var pelvis_y: float = 0.452 + bob
	for i in range(2):
		var t: float = fposmod(phase / TAU + i * 0.5, 1.0)
		var z: float = lerpf(0.14, -0.14, t / 0.62) if t < 0.62 else lerpf(-0.14, 0.14, smoothstep(0.0, 1.0, (t - 0.62) / 0.38))
		var lift: float = 0.0 if t < 0.62 else sin((t - 0.62) / 0.38 * PI) * 0.067
		var ankle := Vector3(-0.055 if i == 0 else 0.055, 0.042 + lift * stride_blend, z * stride_blend)
		ankles.append(ankle)
		pelvis_y = minf(pelvis_y, ankle.y + sqrt(0.418 * 0.418 - ankle.z * ankle.z))
	bob = pelvis_y - 0.432
	_upper.position.y = bob + breath
	_upper.rotation.y = sin(phase) * 0.045 * stride_blend
	_upper.rotation.z = sin(phase) * 0.025 * stride_blend
	_head.rotation.y = sin(age * 0.52 + _variation) * 0.13 * (1.0 - stride_blend * 0.65)
	_head.rotation.x = -0.025 + sin(age * 0.7 + _variation) * 0.025
	for i in range(2):
		var side: float = -1.0 if i == 0 else 1.0
		var t: float = fposmod(phase / TAU + i * 0.5, 1.0)
		var hip := Vector3(side * 0.05, pelvis_y, 0)
		var ankle: Vector3 = ankles[i]
		var direction := ankle - hip
		var bend := Vector3(0, direction.z, -direction.y).normalized()
		var knee := (hip + ankle) * 0.5 + bend * sqrt(maxf(0.21 * 0.21 - direction.length_squared() * 0.25, 0.0001))
		G.pose_segment(_hips[i], hip, knee, 0.042)
		G.pose_segment(_shins[i], knee, ankle, 0.031)
		_knees[i].position = knee
		_shoes[i].position = ankle
		_shoes[i].rotation.x = (-0.16 * sin((t - 0.62) / 0.38 * TAU) if t > 0.62 else 0.0) * stride_blend
		var arm_swing: float = -ankle.z * 0.42
		if _bag_side == side:
			arm_swing *= 0.35
		var shoulder := Vector3(side * 0.101, 0.645 + bob, 0)
		var elbow := Vector3(side * 0.125, 0.515 + bob, arm_swing)
		var hand := Vector3(side * 0.12, 0.405 + bob, arm_swing * 1.5 + 0.026)
		G.pose_segment(_arms[i], shoulder, elbow, 0.031)
		G.pose_segment(_forearms[i], elbow, hand, 0.023)
		_hands[i].position = hand

static func _fabric(color: Color, striped: bool) -> ShaderMaterial:
	var key := color.to_html() + str(striped)
	if not _fabric_cache.has(key):
		var material := ShaderMaterial.new()
		material.shader = FABRIC
		material.set_shader_parameter("cloth_color", color)
		material.set_shader_parameter("striped", striped)
		_fabric_cache[key] = material
	return _fabric_cache[key]
