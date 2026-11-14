extends RefCounted
## Shared mesh primitives for people and street furniture; no per-frame CSG rebuilds.
const Materials = preload("res://scripts/StreetscapeMaterials.gd")
static var _meshes: Dictionary = {}

static func solid(color: Color, metal: float = 0.0, rough: float = 0.65) -> StandardMaterial3D:
	return Materials.solid(color, metal, rough)

static func instance(parent: Node3D, mesh: Mesh, at: Vector3, material: Material, node_name: String = "Detail") -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.position = at
	node.material_override = material
	node.name = node_name
	parent.add_child(node)
	return node

static func box(parent: Node3D, at: Vector3, size: Vector3, material: Material, node_name: String = "Panel") -> MeshInstance3D:
	if not _meshes.has("box"):
		_meshes["box"] = BoxMesh.new()
	var node := instance(parent, _meshes["box"], at, material, node_name)
	node.scale = size
	return node

static func ellipsoid(parent: Node3D, at: Vector3, size: Vector3, material: Material, node_name: String = "Form") -> MeshInstance3D:
	if not _meshes.has("sphere"):
		var mesh := SphereMesh.new()
		mesh.radius = 0.5
		mesh.height = 1.0
		mesh.radial_segments = 20
		mesh.rings = 12
		_meshes["sphere"] = mesh
	var node := instance(parent, _meshes["sphere"], at, material, node_name)
	node.scale = size
	return node

static func segment(parent: Node3D, a: Vector3, b: Vector3, radius: float, material: Material, node_name: String = "Tube", taper: float = 1.0) -> MeshInstance3D:
	var key := "cylinder:%.3f" % taper
	if not _meshes.has(key):
		var mesh := CylinderMesh.new()
		mesh.top_radius = taper
		mesh.bottom_radius = 1.0
		mesh.height = 1.0
		mesh.radial_segments = 20
		mesh.rings = 1
		_meshes[key] = mesh
	var node := instance(parent, _meshes[key], Vector3.ZERO, material, node_name)
	pose_segment(node, a, b, radius)
	return node

static func pose_segment(node: Node3D, a: Vector3, b: Vector3, radius: float) -> void:
	var direction := b - a
	if direction.length_squared() < 0.0000001:
		return
	node.transform = Transform3D(Basis(Quaternion(Vector3.UP, direction.normalized())) * Basis.from_scale(Vector3(radius, direction.length(), radius)), (a + b) * 0.5)

static func rounded_box(parent: Node3D, at: Vector3, size: Vector3, radius: float, material: Material, node_name: String = "Housing") -> MeshInstance3D:
	var key := "rounded:%s:%.4f" % [size, radius]
	if not _meshes.has(key):
		var outline: Array[Vector2] = []
		var r: float = minf(radius, minf(size.x, size.y) * 0.49)
		for corner in range(4):
			var angle: float = corner * PI * 0.5
			var center := Vector2(1 if corner in [0, 3] else -1, 1 if corner in [0, 1] else -1) * (Vector2(size.x, size.y) * 0.5 - Vector2.ONE * r)
			for step in range(5):
				var theta: float = angle + step * PI / 8.0
				outline.append(center + Vector2(cos(theta), sin(theta)) * r)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in range(outline.size()):
			var a := Vector3(outline[i].x, outline[i].y, size.z * 0.5)
			var b := Vector3(outline[(i + 1) % outline.size()].x, outline[(i + 1) % outline.size()].y, size.z * 0.5)
			var back := Vector3(0, 0, -size.z)
			triangle(st, Vector3(0, 0, size.z * 0.5), a, b)
			triangle(st, Vector3(0, 0, -size.z * 0.5), b + back, a + back)
			triangle(st, a, a + back, b)
			triangle(st, b, a + back, b + back)
		_meshes[key] = st.commit()
	return instance(parent, _meshes[key], at, material, node_name)

static func triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for p: Vector3 in [a, c, b]:
		st.set_normal(normal)
		st.set_uv(Vector2(p.x, p.y))
		st.add_vertex(p)

static func label(parent: Node3D, text: String, at: Vector3, width: float, height: float, color: Color, node_name: String = "Lettering") -> Label3D:
	var font := ThemeDB.fallback_font
	var measured: float = 1.0
	var lines := text.split("\n")
	for line in lines:
		measured = maxf(measured, font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 64).x)
	var node := Label3D.new()
	node.text = text
	node.font_size = 64
	node.pixel_size = minf(width / measured, height / (font.get_height(64) * lines.size()))
	node.position = at
	node.modulate = color
	node.outline_size = 0
	node.shaded = true
	node.double_sided = false
	node.visibility_range_end = 160.0
	node.name = node_name
	parent.add_child(node)
	return node

static func loft(parent: Node3D, rings: Array[Vector4], material: Material, node_name: String) -> MeshInstance3D:
	# Anatomical/clothing cross-sections: y, half-width, half-depth, depth offset.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const SEGMENTS := 24
	for row in range(rings.size() - 1):
		var a: Vector4 = rings[row]
		var b: Vector4 = rings[row + 1]
		for i in range(SEGMENTS):
			var u: float = i * TAU / SEGMENTS
			var v: float = (i + 1) * TAU / SEGMENTS
			var p := Vector3(cos(u) * a.y, a.x, sin(u) * a.z + a.w)
			var q := Vector3(cos(v) * a.y, a.x, sin(v) * a.z + a.w)
			var r := Vector3(cos(u) * b.y, b.x, sin(u) * b.z + b.w)
			var t := Vector3(cos(v) * b.y, b.x, sin(v) * b.z + b.w)
			for point: Vector3 in [p, q, r, q, t, r]:
				st.set_uv(Vector2(atan2(point.z - a.w, point.x) / TAU, point.y))
				st.add_vertex(point)
	st.index()
	st.generate_normals()
	return instance(parent, st.commit(), Vector3.ZERO, material, node_name)
