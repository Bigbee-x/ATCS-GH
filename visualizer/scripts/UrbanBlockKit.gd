extends RefCounted
## Compound groups, commercial yards and the covered market, after Accra's
## roofscape: several buildings around a swept earth yard, a zinc lean-to, the
## polytank on its stand, washing on a line and cars nosed in where they fit.
## Geometry is still batched through the shared streetscape, with real envelopes.
const M = preload("res://scripts/StreetscapeMaterials.gd")
var kit: Node3D
var life: RefCounted

func _init(streetscape: Node3D, street_life: RefCounted = null) -> void:
	kit = streetscape
	life = street_life

func market(at: Vector3, facing: Vector3, w: float, d: float) -> void:
	var frame: Transform3D = kit._frame(at,facing)
	var yaw: float = atan2(facing.x,facing.z)
	kit._record_use("market",at,facing,w,d,1)
	kit._building_count += 1
	kit._box(frame,Vector3(0,0.025,0),Vector3(w,0.05,d),M.surface(9,Color("9c6c4e")))
	var steel := M.solid(Color("6b7169"),0.6)
	# Three covered trading aisles under rusting zinc, with real stalls, clear
	# cross passages and slim columns. The open ground between the sheds fills
	# with umbrella traders, produce heaps and head porters.
	for row in range(3):
		var z: float = -d*0.32+row*d*0.28
		kit._hip_roof(frame*Transform3D(Basis.IDENTITY,Vector3(0,0,z)),w-3,8,3.5,1.25,true)
		for bay in range(int((w-5)/6)):
			var x: float = -w/2+4+bay*6
			for side in [-1.0,1.0]:
				kit._beam(frame,Vector3(x,0,z+side*3.5),Vector3(x,3.5,z+side*3.5),0.11,steel)
			if bay%5 == 2: continue
			kit.market_stall(frame*Vector3(x,0,z),facing,4.4,2.2)
			kit._box(frame,Vector3(x,0.45,z-2),Vector3(2.8,0.9,1.3),M.surface(6,Color("8f6d54") if row%2 else Color("70867b")))
			if life != null and bay%2 == 0:
				life.person(frame*Vector3(x+1.2,0,z+1.9),yaw+PI,false,1 if bay%4 == 0 else 0)
		if life == null or row == 2: continue
		for spot in range(int(w/7)):
			var x: float = -w/2+5+spot*7
			var lane_z: float = z+d*0.14
			if spot%3 == 0:
				life.ground_heap(frame*Vector3(x,0,lane_z),yaw)
			else:
				life.vendor(frame*Vector3(x,0,lane_z),yaw+(PI if spot%2 else 0.0))
	if life != null:
		# The market spills out along its road edge.
		for spot in range(int(w/6)):
			var x: float = -w/2+4+spot*6
			if spot%4 == 3:
				life.handcart(frame*Vector3(x,0,d*0.5-2.2),yaw+PI*0.5)
			else:
				life.vendor(frame*Vector3(x,0,d*0.5-2.4),yaw)
	kit._sign(frame,"AKWAABA MARKET\nProduce  •  Fabrics  •  Provisions",Vector3(0,4.2,d*0.47),minf(w*0.5,14),1.3,Color("1c7a45"))
	for x in [-minf(w*0.25,7),minf(w*0.25,7)]:
		kit._beam(frame,Vector3(x,0,d*0.47),Vector3(x,4.2,d*0.47),0.16,steel)

func court(at: Vector3, facing: Vector3, w: float, d: float, floors: int, residential: bool, clean: bool = false) -> void:
	var frame: Transform3D = kit._frame(at,facing)
	if clean:
		_clean_court(frame,at,facing,w,d,floors,residential)
		return
	# Asymmetric wings enclose a usable shared yard. These are separate
	# envelopes, not one tiny house in the middle of a large identical square.
	var rear := Vector3(0,0,-d*0.28)
	if w>34 and posmod(int(at.x+at.z),3) != 0:
		kit.building(frame*(rear+Vector3(-w*0.22,0,0)),facing,w*0.54,d*0.40,floors,not residential)
		kit.building(frame*(rear+Vector3(w*0.28,0,d*0.015)),facing,w*0.39,d*0.37,maxi(1,floors-1),not residential)
	else:
		kit.building(frame*rear,facing,w-1.8,d*0.40,floors,not residential)
	kit.building(frame*Vector3(-w*0.31,0,d*0.18),facing,w*0.31,d*0.39,maxi(1,floors-1),not residential)
	if posmod(int(at.x*3+at.z),7) == 0 and not residential:
		kit.uncompleted(frame*Vector3(w*0.32,0,d*0.27),facing,w*0.28,d*0.23,2)
	else:
		kit.building(frame*Vector3(w*0.32,0,d*0.27),facing,w*0.28,d*0.23,1,not residential)
	# A zinc lean-to on timber posts belongs to the yard: the outdoor kitchen of
	# a compound, the store or welding bay of a business.
	var zinc := M.surface(4,Color("a3a8a6") if posmod(int(at.z),2) == 0 else Color("8a5b3e"))
	var shed := frame*Transform3D(Basis(Vector3.FORWARD,0.1),Vector3(w*0.33,2.6,d*0.03))
	kit._box(shed,Vector3.ZERO,Vector3(w*0.26,0.06,d*0.20),zinc)
	for x in [w*0.21,w*0.45]:
		for z in [d*0.03-d*0.09,d*0.03+d*0.09]:
			kit._beam(frame,Vector3(x,0,z),Vector3(x,2.6,z),0.1,M.surface(6,Color("6a5638")))
	if residential:
		_wall(frame,Vector3(0,0,-d/2),w,0)
		for side in [-1.0,1.0]:
			_wall(frame,Vector3(side*w/2,0,0),d,PI/2)
			_wall(frame,Vector3(side*(w/4+1.3),0,d/2),w/2-2.6,0)
		_washing(frame,Vector3(-w*0.05,0,d*0.36),minf(w*0.3,6.0))
		kit.banana(frame*Vector3(-w*0.42,0,d*0.4))
		if life != null:
			life.person(frame*Vector3(w*0.3,0,d*0.03),atan2(facing.x,facing.z)+2.2,true)
	kit.tree(frame*Vector3(w*0.10,0,d*0.43),posmod(int(at.x),5) == 0,7,10,1.3)
	kit.tank_stand(frame*Vector3(-w*0.44,0,-d*0.02),3.4)
	_yard_stock(frame,w,d,residential)
	if w >= 25 and d >= 24:
		_yard_cars(frame,w,d)

func _clean_court(frame: Transform3D, at: Vector3, facing: Vector3, w: float, d: float, floors: int, residential: bool) -> void:
	# The kept districts: the same wings around a block-paved forecourt with
	# marked bays, planters and palms. No lean-to, drums or washing line here.
	var rear := Vector3(0,0,-d*0.28)
	if w>34 and posmod(int(at.x+at.z),3) != 0:
		kit.building(frame*(rear+Vector3(-w*0.22,0,0)),facing,w*0.54,d*0.40,floors,not residential)
		kit.building(frame*(rear+Vector3(w*0.28,0,d*0.015)),facing,w*0.39,d*0.37,maxi(1,floors-1),not residential)
	else:
		kit.building(frame*rear,facing,w-1.8,d*0.40,floors,not residential)
	kit.building(frame*Vector3(-w*0.31,0,d*0.18),facing,w*0.31,d*0.39,maxi(1,floors-1),not residential)
	kit.building(frame*Vector3(w*0.32,0,d*0.27),facing,w*0.28,d*0.23,1,not residential)
	var kerb := M.surface(2,Color("9a9a8e"))
	for x in [-w*0.08,w*0.12]:
		kit._box(frame,Vector3(x,0.22,d*0.44),Vector3(2.6,0.44,1.1),kerb)
		kit.shrub(frame*Vector3(x-0.6,0.3,d*0.44),0.8)
		kit.shrub(frame*Vector3(x+0.6,0.3,d*0.44),0.8,posmod(int(at.z),2) == 0)
	kit.tree(frame*Vector3(w*0.02,0,d*0.3),true,7,10,1.2)
	if w >= 25 and d >= 24:
		var available: float = w*0.28
		for i in range(maxi(1,int(available/2.8))):
			var x: float = -available/2+(i+0.5)*2.8
			kit._box(frame,Vector3(x-1.4,0.03,1.0),Vector3(0.1,0.012,5.0),M.solid(Color("e6e2d2")))
			if i%3 == 1: continue
			var car := preload("res://scripts/VehicleActor.gd").new()
			car.configure("car",i+int(absf(frame.origin.x+frame.origin.z)))
			car.transform = frame*Transform3D(Basis.IDENTITY,Vector3(x,0.04,1.0))
			car.set_metric_dimensions(Vector3(1.8,1.5,4.5))
			kit.add_child(car)

func _wall(frame: Transform3D, at: Vector3, width: float, yaw: float) -> void:
	var f := frame*Transform3D(Basis(Vector3.UP,yaw),at)
	kit._box(f,Vector3(0,0.9,0),Vector3(width,1.8,0.2),M.surface(0,Color("d9c9a3")),true)
	kit._box(f,Vector3(0,1.84,0),Vector3(width+0.08,0.10,0.3),M.surface(0,Color("f0e9d8")))

func _washing(frame: Transform3D, at: Vector3, span: float) -> void:
	var post := M.surface(6,Color("6a5638"))
	for x in [-span*0.5,span*0.5]:
		kit._beam(frame,at+Vector3(x,0,0),at+Vector3(x,1.9,0),0.07,post)
	kit._detail = true
	kit._box(frame,at+Vector3(0,1.85,0),Vector3(span,0.015,0.015),M.solid(Color("d8d2c0")))
	for i in range(int(span/0.6)):
		var drop: float = 0.5+fposmod(i*0.37,0.5)
		kit._box(frame,at+Vector3(-span*0.5+0.4+i*0.6,1.85-drop*0.5,0),Vector3(0.46,drop,0.02),M.solid(kit.CLOTH[i%kit.CLOTH.size()],0.0,0.9))
	kit._detail = false

func _yard_stock(frame: Transform3D, w: float, d: float, residential: bool) -> void:
	# Under the lean-to: cooking pots and a charcoal stove at home; drums,
	# crates and gas bottles behind a business.
	kit._detail = true
	var at := Vector3(w*0.3,0,d*0.03)
	if residential:
		kit._drum(frame,at,0.5,0.32,M.solid(Color("c3c5c0"),0.7,0.35))
		kit._drum(frame,at+Vector3(0.7,0,0.2),0.36,0.42,M.solid(Color("2b2b28"),0.3,0.8))
		kit._drum(frame,at+Vector3(-0.8,0,-0.3),0.55,0.36,M.solid(Color("1c63a8"),0.0,0.45))
	else:
		for i in range(4):
			kit._drum(frame,at+Vector3(i*0.66-1.0,0,0),0.58,0.88,M.solid([Color("2f5f93"),Color("8d3b2f"),Color("2e7352"),Color("55585a")][i],0.4,0.6))
		for i in range(6):
			kit._box(frame,at+Vector3((i%2)*0.5-0.2,0.15+(i/2)*0.3,1.0),Vector3(0.44,0.28,0.34),M.solid([Color("c62f25"),Color("f2c318")][i%2],0.0,0.6))
	kit._detail = false

func _yard_cars(frame: Transform3D, w: float, d: float) -> void:
	# No painted bays in a yard: two or three cars left at slight angles.
	var available: float = w*0.28
	var bays: int = maxi(1,int(available/2.8))
	for i in range(bays):
		if i%3 == 1: continue
		var x: float = -available/2+(i+0.5)*2.8
		var car := preload("res://scripts/VehicleActor.gd").new()
		car.configure("car",i+int(absf(frame.origin.x+frame.origin.z)))
		# Place first: assigning a transform would discard the metre-scale sizing.
		car.transform = frame*Transform3D(Basis(Vector3.UP,sin(float(i)*2.3+frame.origin.z)*0.2),Vector3(x,0.06,1.0))
		car.set_metric_dimensions(Vector3(1.8,1.5,4.5))
		kit.add_child(car)
