extends Node3D
## Draw exact lane ribbons, SUMO junction polygons and corner walking areas.
const Net = preload("res://scripts/CorridorGeometry.gd")
const Surfaces = preload("res://scripts/StreetscapeMaterials.gd")
const G = preload("res://scripts/PropGeometry.gd")
const Transit = preload("res://scripts/TransitLayout.gd")
var corridor_mode: bool = true
var _surfaces: Dictionary = {}
var _boxes: Dictionary = {}

func build() -> void:
	for key in ["road", "walk", "paint", "kerb"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_surfaces[key] = st
	for j in Net.data(corridor_mode).junctions.values(): _polygon(j.shape, 0.05, "road")
	for e in Net.data(corridor_mode).edges:
		if e.kind == "internal": continue
		for lane in e.lanes:
			if e.kind == "walkingarea":
				_polygon(lane.shape, 0.065, "walk")
			elif e.kind == "crossing":
				_crossing(lane)
			elif e.kind == "road":
				# Only the window of each approach around town is drawn; see Net.VIEW.
				var shape: Array = Net.clip_shape(lane.shape, corridor_mode)
				if shape.size() < 2:
					continue
				var full: Dictionary = lane
				lane = lane.duplicate()
				lane.shape = shape
				if lane.pedestrian:
					_footway(lane)
				else:
					_ribbon(lane.shape, lane.width, 0.05, "road")
					_lane_marks(lane, e)
					lane = full
					if e.target.begins_with("J"):
						var end := Net.point(lane.shape[-1], 0.058)
						var t := (end-Net.point(lane.shape[-2], 0.058)).normalized()
						# The bar ends at SUMO's lane endpoint, before the crossing.
						_box(end-t*0.15, Vector3(lane.width,0.012,0.30), atan2(t.x,t.z), "paint")
	var materials := {"road": Surfaces.surface(0,Color("444b4b")), "walk": Surfaces.surface(2,Color("a59d88")), "paint": G.solid(Color("e9e5d4")), "kerb": G.solid(Color("a7aaa0"))}
	for key in _surfaces:
		var st: SurfaceTool = _surfaces[key]
		var mesh: ArrayMesh = st.commit()
		if mesh.get_surface_count() > 0:
			var mi := MeshInstance3D.new()
			mi.name = key.capitalize()+"Surface"
			mi.mesh = mesh
			mi.material_override = materials[key]
			add_child(mi)
			if key in ["road", "walk"]:
				mi.create_trimesh_collision()

	for key in _boxes:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var cube := BoxMesh.new()
		cube.size = Vector3.ONE
		mm.mesh = cube
		mm.instance_count = _boxes[key].size()
		for i in range(mm.instance_count): mm.set_instance_transform(i, _boxes[key][i])
		var mi := MultiMeshInstance3D.new()
		mi.name = key.capitalize()+"Details"
		mi.multimesh = mm
		mi.material_override = materials[key]
		add_child(mi)

func _footway(lane: Dictionary) -> void:
	for k in range(1, lane.shape.size()):
		var a := Net.point(lane.shape[k-1], 0.10)
		var b := Net.point(lane.shape[k], 0.10)
		var t := (b-a).normalized()
		var distance: float = a.distance_to(b)
		var cuts: Array[float] = [0.0, distance]
		var driveways: Array[Vector2] = []
		if absf(t.z) > 0.99:
			for station in Transit.stations(corridor_mode):
				if not station.get("parking",false) or signf(a.x) != float(station.side): continue
				for offset in [-18.0, 18.0]:
					var at: float = (float(station.z)+offset-a.z)/t.z
					if at-6.0 <= 0 or at+6.0 >= distance: continue
					cuts.append_array([at-6.0, at+6.0])
					driveways.append(Vector2(at-6.0, at+6.0))
		cuts.sort()
		for i in range(1, cuts.size()):
			var mid: float = (cuts[i-1]+cuts[i])*0.5
			var lowered: bool = false
			for driveway in driveways:
				if mid > driveway.x and mid < driveway.y: lowered = true
			var start := a+t*cuts[i-1]
			var end := a+t*cuts[i]
			_ribbon([[start.x,start.z],[end.x,end.z]], lane.width, 0.065 if lowered else 0.15, "walk")
			if not lowered:
				var inward := Vector3(t.z, 0, -t.x)*float(lane.width)*0.5
				_box((start+end)*0.5+inward, Vector3(0.12,0.10,end.distance_to(start)), atan2(t.x,t.z), "kerb")

func _polygon(shape: Array, height: float, key: String) -> void:
	var polygon := PackedVector2Array()
	for p in shape: polygon.append(Vector2(p[0],p[1]))
	var indices := Geometry2D.triangulate_polygon(polygon)
	var st: SurfaceTool = _surfaces[key]
	for index in indices:
		var p := polygon[index]
		st.set_normal(Vector3.UP)
		st.set_uv(p*0.2)
		st.add_vertex(Vector3(p.x,height,p.y))

func _ribbon(shape: Array, width: float, height: float, key: String) -> void:
	for i in range(1,shape.size()):
		var a := Vector2(shape[i-1][0],shape[i-1][1])
		var b := Vector2(shape[i][0],shape[i][1])
		var t := (b-a).normalized()
		var n := Vector2(-t.y,t.x)*width*0.5
		_polygon([[a.x+n.x,a.y+n.y],[b.x+n.x,b.y+n.y],[b.x-n.x,b.y-n.y],[a.x-n.x,a.y-n.y]],height,key)

func _box(at: Vector3, size: Vector3, yaw: float, key: String) -> void:
	if not _boxes.has(key): _boxes[key] = []
	_boxes[key].append(Transform3D(Basis(Vector3.UP,yaw).scaled_local(size),at))

func _crossing(lane: Dictionary) -> void:
	var a := Net.point(lane.shape[0],0.058)
	var b := Net.point(lane.shape[-1],0.058)
	var t := (b-a).normalized()
	var distance := a.distance_to(b)
	var n: int = int(distance/0.8)
	for i in range(n):
		_box(a+t*((distance-n*0.8)*0.5+i*0.8+0.2),Vector3(lane.width-0.2,0.012,0.4),atan2(t.x,t.z),"paint")

func _lane_marks(lane: Dictionary, e: Dictionary) -> void:
	var a := Net.point(lane.shape[0],0.058)
	var b := Net.point(lane.shape[-1],0.058)
	var t := (b-a).normalized()
	var n := Vector3(t.z,0,-t.x)*float(lane.width)*0.5
	var distance := a.distance_to(b)
	var center_line: bool = lane.id == e.lanes[-1].id
	if center_line:
		_box((a+b)*0.5+n,Vector3(0.10,0.01,distance),atan2(t.x,t.z),"paint")
	else:
		for i in range(int(distance/6.0)):
			_box(a+t*(i*6.0+1.5)+n,Vector3(0.12,0.01,3.0),atan2(t.x,t.z),"paint")
