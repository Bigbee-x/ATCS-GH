extends RefCounted
## Compact, connected town around the three metric traffic junctions.
const G = preload("res://scripts/PropGeometry.gd")
const M = preload("res://scripts/StreetscapeMaterials.gd")
const Airport = preload("res://scripts/AirportLayout.gd")
const Net = preload("res://scripts/CorridorGeometry.gd")
const TOWN := Rect2(-184,-160,368,1000)
# Side lanes that were never surfaced: graded red laterite, rutted by taxis.
const LATERITE_LANES: Array[float] = [510.0, 750.0]
# Not all of Accra is red earth. These two districts are fully paved and kept
# clean, in the manner of Airport City or Cantonments: the business quarter
# between J0 and J1, and the mall, bank and office frontage north of J1.
const PAVED: Array[Rect2] = [Rect2(-108,14,216,272), Rect2(-184,314,368,124)]

static func paved_at(x: float, z: float) -> bool:
	for zone in PAVED:
		if zone.has_point(Vector2(x,z)): return true
	return false
var parcels: Array[Rect2] = []
var counts: Dictionary = {}
var footway_surfaces: Array[Rect2] = []
var env: Node3D
var kit: Node3D
var life: RefCounted
var blocks: RefCounted

static func sections() -> Array:
	return [
		{"name":"Commercial courts", "bounds":Rect2(-184,0,368,300), "z":150.0},
		{"name":"Civic and shopping", "bounds":Rect2(-184,300,368,300), "z":450.0},
		{"name":"Northern neighbourhood", "bounds":Rect2(-184,600,368,240), "z":720.0},
		{"name":"Market neighbourhood", "bounds":Rect2(-184,-160,368,160), "z":-80.0}]

static func streets() -> Array:
	var result: Array = []
	for side in [-1.0,1.0]:
		# Continuous back street, with short links to the main road.
		result.append({"a":Vector3(side*112,0,-145),"b":Vector3(side*112,0,825)})
		for z in [-145.0,90.0,210.0,390.0,510.0,750.0,825.0]:
			var end: float = 112.0 if side > 0 and z in [90.0,210.0] else 178.0
			result.append({"a":Vector3(side*7.9,0,z),"b":Vector3(side*end,0,z)})
	return result

static func street_plot(street: Dictionary) -> Rect2:
	var a: Vector3 = street.a
	var b: Vector3 = street.b
	return Rect2(minf(a.x,b.x)-5,minf(a.z,b.z)-5,absf(b.x-a.x)+10,absf(b.z-a.z)+10)

static func reserve_streets(environment: Node3D) -> void:
	for street in streets():
		var r := street_plot(street)
		environment._add_exclusion_zone(r.position.x,r.position.y,r.end.x,r.end.y)

func build(environment: Node3D) -> void:
	env = environment
	kit = env._streetscape
	life = env._street_life
	blocks = preload("res://scripts/UrbanBlockKit.gd").new(kit, life)
	_urban_ground()
	_commercial_quarter()
	# A few named destinations, rather than copies in every block.
	# The mall sits clear of the deeper trading apron on the J1 cross street.
	_retail(Vector3(-145,0,348),Vector3.RIGHT,42,27,"mall","CIRCLE GALLERIA")
	_retail(Vector3(-145,0,550),Vector3.RIGHT,36,23,"supermarket","NEIGHBOURHOOD MARKET")
	var bank := Vector3(145,0,420)
	if _claim(bank,Vector3.BACK,24,19,"bank"):
		kit.office(bank,4,24,19)
		_label("UNITY BANK",bank+Vector3(0,4,9.65),17)
		_parking(bank+Vector3(0,0,21),27,10,true)
	_parking(Vector3(-145,0,379),42,14,true)
	_civic_quarter()
	_northern_quarter()
	_market_quarter()
	for street in streets(): _street(street)
	_street_mouths()
	_landscape()
	_outskirts()
	_road_ends()
	print("[CompactTown] ",parcels.size()," infill premises in ",TOWN,"; uses=",counts)

func _commercial_quarter() -> void:
	# Section 1, J0–J1: deeper perimeter premises and shared courts. The
	# airport side keeps its existing airfield reservation and access street.
	for spec in [[-149,52,54,49,2],[-150,124,46,48,2],[-148,180,44,48,3],[-151,253,53,47,2],
		[-71,109,24,58,3],[-71,181,31,58,3],[-70,247,48,60,3],
		[72,111,25,58,2],[73,169,66,57,3],[72,249,47,58,2]]:
		_court(Vector3(spec[0],0,spec[1]),Vector3.RIGHT if spec[0]<0 else Vector3.LEFT,spec[2],spec[3],spec[4],false)
	_ribbon(23,279,37,3101,false)
	_ribbon(23,279,91,3102,false)
	_pack(22,278,3103,"commercial")

func _civic_quarter() -> void:
	# Section 2, J1–J2: a civic green, mall courts and office frontages around
	# the school and clinic. Taller buildings mark destinations, not every plot.
	_tower(Vector3(-79,0,350),22,20,7,false)
	_tower(Vector3(83,0,351),20,21,8,true)
	_tower(Vector3(146,0,565),34,26,6,false)
	_park(Vector3(147,0,476),48,52)
	for spec in [[-149,449,100,48,2],[-72,543,43,56,3],[73,550,38,58,2],
		[74,405,18,57,2],[-73,405,18,57,3],[-148,583,17,47,2]]:
		_court(Vector3(spec[0],0,spec[1]),Vector3.RIGHT if spec[0]<0 else Vector3.LEFT,spec[2],spec[3],spec[4],false)
	_ribbon(326,577,38,4201,false)
	_ribbon(326,577,92,4202,false)
	_pack(321,579,4203,"civic")

func _tower(at: Vector3, width: float, depth: float, floors: int, apartment: bool) -> void:
	if not _claim(at,Vector3.BACK,width,depth,"apartment" if apartment else "office"): return
	if apartment: kit.apartment(at,Vector3.BACK,floors,width,depth)
	else: kit.office(at,floors,width,depth)

func _northern_quarter() -> void:
	# Section 3, beyond J2: family courts and apartments behind the high
	# street, with a separate workshop/warehouse cluster on the western side.
	for spec in [[150,657,62,47,2],[149,716,43,49,2],[151,785,48,47,2],
		[-150,655,58,48,2],[-149,715,43,48,1],[82,715,44,41,2],[78,788,46,54,2]]:
		_court(Vector3(spec[0],0,spec[1]),Vector3.RIGHT if spec[0]<0 else Vector3.LEFT,spec[2],spec[3],spec[4],true)
	_tower(Vector3(-82,0,649),22,20,7,true)
	var warehouse := Vector3(-150,0,786)
	if _claim(warehouse,Vector3.BACK,42,28,"warehouse"):
		kit.warehouse(warehouse,42,6,28)
		_parking(warehouse+Vector3(0,0,23),42,12)
	_court(Vector3(-73,0,787),Vector3.RIGHT,44,58,2,false)
	_ribbon(625,817,38,5301,true)
	_ribbon(625,817,92,5302,true)
	_pack(623,817,5303,"residential")

func _market_quarter() -> void:
	# Section 4, south of J0: covered trading halls, smaller shop units and
	# a low residential neighbourhood around the existing ambient street loop.
	var market := Vector3(-150,0,-87)
	if _claim(market,Vector3.RIGHT,88,47,"market"):
		blocks.market(market,Vector3.RIGHT,88,47)
	for spec in [[150,-116,33,48,2],[149,-73,40,47,2],[148,-35,25,48,2],[91,-111,38,19,2]]:
		_court(Vector3(spec[0],0,spec[1]),Vector3.LEFT,spec[2],spec[3],spec[4],true)
	_court(Vector3(-79,0,-42),Vector3.RIGHT,29,43,2,false)
	_ribbon(-135,-22,35,6401,false)
	_ribbon(-135,-22,91,6402,false)
	_pack(-136,-22,6403,"market")

func _park(at: Vector3, width: float, depth: float) -> void:
	if not _claim(at,Vector3.BACK,width,depth,"park"): return
	var f: Transform3D = kit._frame(at)
	kit._box(f,Vector3(0,0.025,0),Vector3(width,0.04,depth),M.surface(7,Color("6f8a4a")))
	for x in [-width*0.35,width*0.35]:
		kit._box(f,Vector3(x,0.06,0),Vector3(2.5,0.05,depth),M.surface(9,Color("a37556")))
	for z in [-depth*0.32,depth*0.32]:
		kit._box(f,Vector3(0,0.06,z),Vector3(width,0.05,2.5),M.surface(9,Color("a37556")))
	for p in [Vector3(-10,0,-8),Vector3(8,0,11),Vector3(12,0,-12),Vector3(-12,0,14)]:
		kit.tree(at+p,false,10,14,1.7)
		kit._box(f,p+Vector3(2,0.45,1),Vector3(2.2,0.12,0.55),M.surface(6,Color("8b7254")))

func _pack(start: float, end: float, seed_value: int, district: String) -> void:
	# Irregular small tenancies occupy the gaps between the authored anchors.
	# Larger plots go first, then shallow annexes: no fixed rows or square lots.
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for pass_index in range(2):
		for attempt in range(1100):
			var at := Vector3(rng.randf_range(-174,174),0,rng.randf_range(start,end))
			var w: float = rng.randf_range(14,27) if pass_index == 0 else rng.randf_range(8,14)
			var d: float = rng.randf_range(12,25) if pass_index == 0 else rng.randf_range(8,13)
			var home: bool = district == "residential" or (district == "market" and absf(at.x)>120)
			var facing := Vector3(signf(at.x) if absf(at.x)<112 else -signf(at.x),0,0)
			if not _claim(at,facing,w,d,"house" if home else "shop"): continue
			var pick: float = rng.randf()
			if paved_at(at.x,at.z): pick = minf(pick,0.8)  # no shells or vacant plots in the kept districts
			if home and minf(w,d) >= 13.0 and pick < 0.62:
				# A walled family compound, the commonest house form in the city.
				kit.compound(at,minf(w,d)-1.0,rng.randi_range(1,2),facing)
			elif pick > 0.9:
				kit.uncompleted(at,facing,w,d,rng.randi_range(1,3))
			elif pick > 0.84:
				kit.walled_plot(at,facing,w,d)
			else:
				kit.building(at,facing,w,d,rng.randi_range(1,3),not home)
				if home and pick > 0.7: kit.banana(at+Vector3(facing.z,0,facing.x)*(w*0.5+1.2))

func _court(at: Vector3, facing: Vector3, width: float, depth: float, floors: int, home: bool) -> bool:
	if not _claim(at,facing,width,depth,"house" if home else "shop"): return false
	blocks.court(at,facing,width,depth,floors,home,paved_at(at.x,at.z))
	return true

func _ribbon(start: float, end: float, x: float, seed_value: int, homes: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	for side in [-1.0,1.0]:
		var cursor: float = start+rng.randf_range(0,4)
		while cursor < end-12:
			var width: float = rng.randf_range(13,25)
			var depth: float = rng.randf_range(15,24)
			if cursor+width > end: break
			var at := Vector3(side*(x+rng.randf_range(-1,1)),0,cursor+width/2)
			var face := Vector3(side if x>70 else -side,0,0)
			var placed := _court(at,face,width,depth,rng.randi_range(1,3),homes)
			cursor += width+rng.randf_range(1.6,3.5) if placed else 3.0

func _claim(at: Vector3, facing: Vector3, width: float, depth: float, kind: String) -> bool:
	var plot: Rect2 = env._building_plot(at,facing,width,depth,1.8).grow(0.5)
	if not TOWN.encloses(plot) or _reserved(plot,kind=="house") or not env._plot_available(plot): return false
	parcels.append(plot)
	env._occupied_plots.append(plot)
	counts[kind] = counts.get(kind,0)+1
	return true

func _reserved(plot: Rect2, house: bool = false, roadside: bool = false) -> bool:
	if plot.intersects(Airport.SITE.grow(3)) or plot.intersects(Airport.ACCESS): return true
	# Buildings stay behind the trading apron in front of the roadside shops.
	# Only `roadside` scenery (boards, riders, shade trees) may stand on it.
	var margin: float = 12.1 if house else (3.7 if roadside else 8.9)
	if plot.intersects(Rect2(-6.4,-1500,12.8,3600).grow(margin)): return true
	for z in [0,300,600]:
		if plot.intersects(Rect2(-1500,z-6.4,3000,12.8).grow(margin)): return true
	return false

func _retail(at: Vector3, facing: Vector3, width: float, depth: float, kind: String, title: String) -> void:
	if not _claim(at,facing,width,depth,kind): return
	kit.commercial(at,facing,width,depth,kind,title)

func _label(title: String, at: Vector3, width: float) -> Label3D:
	var label := G.label(env,title,at,width,0.8,Color("f1e3c4"))
	label.visibility_range_end = 180
	return label

func _street(spec: Dictionary) -> void:
	var a: Vector3 = spec.a
	var b: Vector3 = spec.b
	var d := (b-a).normalized()
	var n := Vector3(-d.z,0,d.x)
	var unsurfaced: bool = absf(d.x) > 0.9 and a.z in LATERITE_LANES
	# Clip surfacing at every junction. Nothing local may run across the live
	# arterial or across another local street mouth.
	var half: float = 2.6 if unsurfaced else 3.0
	var bed := Rect2(minf(a.x,b.x)-half,minf(a.z,b.z)-half,absf(b.x-a.x)+half*2,absf(b.z-a.z)+half*2)
	if unsurfaced:
		_surface_pieces(bed,_arterials(),M.surface(9,Color("8f573c")),0.03,0.03)
		# Two wheel ruts worn darker and smoother than the crown of the lane.
		for rut in [-1.0,1.0]:
			_surface_pieces(Rect2(bed.position.x,a.z+rut*0.95-0.24,bed.size.x,0.48),_arterials(),M.surface(9,Color("81503a")),0.047,0.004)
	else:
		_surface_pieces(bed,_arterials(),M.surface(1,Color("5d5b53")),0.045,0.07)
		# No kerbed footways on an ordinary back street: a worn earth shoulder each
		# side, where people actually walk. Inside the paved districts the same
		# strip is a kerbed block-paved footway. Both keep clear of the main road
		# and of other street mouths.
		for side in [-1.0,1.0]:
			var center: Vector3 = (a+b)*0.5+n*side*4.2
			var size := Vector2(2.4,a.distance_to(b)) if absf(d.z)>0.9 else Vector2(a.distance_to(b),2.4)
			var strip := Rect2(Vector2(center.x,center.z)-size/2,size)
			var cuts: Array[Rect2] = _arterials(1.5)
			for other in streets():
				if other == spec: continue
				cuts.append(street_plot(other).grow(-1.8))
			var earth_cuts: Array[Rect2] = cuts.duplicate()
			earth_cuts.append_array(PAVED)
			footway_surfaces.append_array(_surface_pieces(strip,earth_cuts,M.surface(9,Color("946548")),0.02,0.03))
			for zone in PAVED:
				var kept := strip.intersection(zone)
				if kept.has_area():
					footway_surfaces.append_array(_surface_pieces(kept,cuts,M.surface(5,Color("b5afa2")),0.075,0.15))
	# Paved crossovers continue over the arterial footway at each street mouth.
	if absf(d.x)>0.9:
		kit._box(kit._frame(Vector3(signf(a.x)*7.15,0,a.z)),Vector3(0,0.16,0),Vector3(1.5,0.02,6),M.surface(2,Color("a79f8d")))
	else:
		for j in range(3):
			var widths := preload("res://scripts/CorridorGeometry.gd").widths(j)
			var width: float = widths.y if a.x < 0 else widths.z
			for side in [-1.0,1.0]:
				kit._box(kit._frame(Vector3(a.x,0,j*300+side*(width/2+0.75))),Vector3(0,0.16,0),Vector3(6,0.02,1.5),M.surface(2,Color("a79f8d")))
	# Shade along the back streets: neem and mango, with the odd coconut palm.
	if absf(d.z) > 0.9:
		for i in range(int(a.distance_to(b)/27)):
			var at := a+d*(14+i*27)
			if _reserved(Rect2(at.x-1,at.z-1,2,2)): continue
			kit.tree(at+n*5.4,i%4 == 0,6,8,1.5)

func _street_mouths() -> void:
	# Where a side street meets the main road: the thicket of direction boards,
	# okada riders waiting for fares and a few hawkers working the junction.
	var index: int = 0
	for spec in streets():
		var a: Vector3 = spec.a
		var b: Vector3 = spec.b
		if absf(b.x-a.x) < 1.0: continue
		var side: float = signf(a.x)
		var corner := Vector3(side*13.2,0,a.z)
		index += 1
		if not _reserved(Rect2(corner.x-2,corner.z+4.5,4,4),false,true):
			life.sign_cluster(corner+Vector3(0,0,6.4),0.0 if index%2 == 0 else PI,3+index%3)
		var rank := corner+Vector3(0,0,-6.6)
		if index%2 == 0 and not _reserved(Rect2(rank.x-2,rank.z-2,4,4),false,true):
			for i in range(3):
				life.okada(rank+Vector3(side*i*0.2,0,-i*1.0),PI*0.5*side+0.3,i != 1)
		elif not _reserved(Rect2(rank.x-2,rank.z-2,4,4),false,true):
			life.vendor(rank,-PI*0.5*side)
			life.person(rank+Vector3(side*1.6,0,-1.4),PI*0.5*side,false,1)

func _outskirts() -> void:
	# The town does not stop at a line: bush, scattered trees and the roofs of
	# outlying compounds thin out with distance. Background batches, no shadows.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7741
	var taken: Array[Rect2] = []
	kit._building_backdrop = true
	# Outlying settlements gather in clusters near the town edge and the roads.
	for cluster in range(26):
		var heart := Vector3(rng.randf_range(-430,430),0,rng.randf_range(-400,1080))
		var reach: float = _town_distance(heart)
		if reach < 30.0 or reach > 260.0 or _reserved(Rect2(heart.x-30,heart.z-30,60,60)): continue
		for attempt in range(rng.randi_range(6,13)):
			var at := heart+Vector3(rng.randf_range(-48,48),0,rng.randf_range(-48,48))
			var plot := Rect2(at.x-8,at.z-8,16,16)
			if _town_distance(at) < 8.0 or _reserved(plot.grow(6)): continue
			var clash: bool = false
			for other in taken:
				if other.intersects(plot): clash = true
			if clash: continue
			taken.append(plot)
			kit._background_building(at,rng.randi_range(0,3)*PI*0.5)
			if rng.randf() < 0.6: kit.tree(at+Vector3(7,0,rng.randf_range(-5,5)),rng.randf() < 0.3,5,7,1.5)
			if rng.randf() < 0.3: kit.banana(at+Vector3(-6.5,0,rng.randf_range(-4,4)))
	for attempt in range(1700):
		var at := Vector3(rng.randf_range(-560,560),0,rng.randf_range(-520,1200))
		var away: float = _town_distance(at)
		var spot := Rect2(at.x-3,at.z-3,6,6)
		if away < 4.0 or _reserved(spot.grow(4)): continue
		if rng.randf() > 0.25+0.75*exp(-away/210.0): continue
		var clash: bool = false
		for other in taken:
			if other.intersects(spot): clash = true
		if clash: continue
		if rng.randf() < 0.5:
			kit.tree(at,rng.randf() < 0.12,5,7,rng.randf_range(1.2,2.0))
		else:
			for i in range(3):
				kit.shrub(at+Vector3(rng.randf_range(-2.5,2.5),0,rng.randf_range(-2.5,2.5)),rng.randf_range(1.4,2.6))
	kit._building_backdrop = false

func _road_ends() -> void:
	# Each drawn road ends inside a belt of forest, as the Nsawam road meets
	# Achimota Forest: big trees flank the last stretch, their crowns close over
	# the carriageway, and the wood carries on beyond the end. Traffic appears
	# from under the canopy instead of from the end of a road in open bush.
	var rng := RandomNumberGenerator.new()
	rng.seed = 9917
	var ends: Array = [[Vector3(0,0,Net.VIEW.position.y),Vector3.FORWARD,6.4],[Vector3(0,0,Net.VIEW.end.y),Vector3.BACK,6.4]]
	for j in range(3):
		var widths := Net.widths(j)
		ends.append([Vector3(Net.VIEW.position.x,0,j*300.0),Vector3.LEFT,widths.y*0.5])
		ends.append([Vector3(Net.VIEW.end.x,0,j*300.0),Vector3.RIGHT,widths.z*0.5])
	for spec in ends:
		var end: Vector3 = spec[0]
		var out: Vector3 = spec[1]
		var across := Vector3(-out.z,0,out.x)
		var clear: float = float(spec[2])+5.2
		for attempt in range(150):
			var along: float = rng.randf_range(-85.0,95.0)
			var lateral: float = rng.randf_range(-78.0,78.0)
			# Inside the end, trees keep off the road, footway and drain strip.
			if along < 3.0 and absf(lateral) < clear: continue
			# The belt thins toward its outer edges instead of ending in a line.
			var thin: float = maxf(absf(lateral)/78.0,maxf(-along/85.0,along/95.0))
			if rng.randf() < thin*thin*0.85: continue
			var at := end+out*along+across*lateral
			if _town_distance(at) < 12.0 or Airport.SITE.grow(6).has_point(Vector2(at.x,at.z)): continue
			# Trees beside the road cast shadows; the depth of the wood does not.
			kit._building_backdrop = absf(lateral) > 26.0 or along > 12.0
			kit.tree(at,rng.randf() < 0.08,6,8,rng.randf_range(1.9,2.7))
		kit._building_backdrop = false
		# Crowns meeting over the carriageway hide where the asphalt stops.
		for i in range(46):
			var along: float = rng.randf_range(-52.0,10.0)
			var at := end+out*along+across*rng.randf_range(-clear,clear)+Vector3(0,rng.randf_range(8.5,13.0)+maxf(-along-30.0,0.0)*0.12,0)
			var basis := Basis.from_euler(Vector3(rng.randf_range(-0.5,0.5),rng.randf_range(0,TAU),rng.randf_range(-0.5,0.5))).scaled(Vector3.ONE*rng.randf_range(4.2,6.4))
			var light: float = rng.randf_range(0.12,0.6)
			kit._batch(kit._leaf_mesh,M.foliage(),Transform3D(basis,at),Color(light,light,maxf(light,0.1)))

func _town_distance(at: Vector3) -> float:
	var dx: float = maxf(maxf(TOWN.position.x-at.x,at.x-TOWN.end.x),0.0)
	var dz: float = maxf(maxf(TOWN.position.y-at.z,at.z-TOWN.end.y),0.0)
	return Vector2(dx,dz).length()

func _arterials(margin: float = 0.0) -> Array[Rect2]:
	var roads: Array[Rect2] = [Rect2(-6.4,-1500,12.8,3600).grow(margin)]
	for j in range(3):
		var widths := preload("res://scripts/CorridorGeometry.gd").widths(j)
		roads.append(Rect2(-1500,j*300-widths.y/2,1500,widths.y).grow(margin))
		roads.append(Rect2(0,j*300-widths.z/2,1500,widths.z).grow(margin))
	return roads

func _surface_pieces(area: Rect2, cuts: Array[Rect2], material: Material, y: float, height: float) -> Array[Rect2]:
	var pieces: Array[Rect2] = [area]
	for cut in cuts:
		var remainder: Array[Rect2] = []
		for piece in pieces:
			var hit := piece.intersection(cut)
			if not hit.has_area():
				remainder.append(piece)
				continue
			for part in [Rect2(piece.position,Vector2(piece.size.x,hit.position.y-piece.position.y)),
				Rect2(Vector2(piece.position.x,hit.end.y),Vector2(piece.size.x,piece.end.y-hit.end.y)),
				Rect2(Vector2(piece.position.x,hit.position.y),Vector2(hit.position.x-piece.position.x,hit.size.y)),
				Rect2(Vector2(hit.end.x,hit.position.y),Vector2(piece.end.x-hit.end.x,hit.size.y))]:
				if part.has_area(): remainder.append(part)
		pieces = remainder
	for piece in pieces:
		var at := piece.get_center()
		kit._box(kit._frame(Vector3(at.x,0,at.y)),Vector3(0,y,0),Vector3(piece.size.x,height,piece.size.y),material)
	return pieces

func _urban_ground() -> void:
	# The ground plane itself wears to bare laterite under the town (surface
	# kind 10). Here: the paler, swept trading apron along every arterial in
	# town, and the red-earth shoulder that follows each road out into the bush.
	var cuts: Array[Rect2] = _arterials(1.55)
	cuts.append(Airport.SITE)
	cuts.append(Airport.ACCESS)
	var shoulder := M.surface(9,Color("8f6046"))
	for side in [-1.0,1.0]:
		_apron(Rect2(7.9 if side > 0 else -15.3,-150,7.4,980),cuts,0.016)
		# A band of red blocks along the back of the footway through the paved town.
		for zone in PAVED:
			_surface_pieces(Rect2(7.9 if side > 0 else -8.6,zone.position.y,0.7,zone.size.y),cuts,M.surface(5,Color("a8644c")),0.02,0.03)
		for run in [Vector2(Net.VIEW.position.y,-150),Vector2(830,Net.VIEW.end.y)]:
			_shoulder(Rect2(7.9 if side > 0 else -12.4,run.x,4.5,run.y-run.x),cuts,shoulder)
	for j in range(3):
		var widths := preload("res://scripts/CorridorGeometry.gd").widths(j)
		for arm in [[Net.VIEW.position.x,-7.9,widths.y],[7.9,Net.VIEW.end.x,widths.z]]:
			for end in [-1.0,1.0]:
				var edge: float = j*300+end*(float(arm[2])/2+1.5)
				var town_from: float = maxf(arm[0],-180.0)
				var town_to: float = minf(arm[1],180.0)
				_apron(Rect2(town_from,edge if end > 0 else edge-7.4,town_to-town_from,7.4),cuts,0.017)
				for run in [Vector2(arm[0],town_from),Vector2(town_to,arm[1])]:
					if run.y-run.x < 1.0: continue
					_shoulder(Rect2(run.x,edge if end > 0 else edge-4.5,run.y-run.x,4.5),cuts,shoulder)

func _apron(strip: Rect2, cuts: Array[Rect2], y: float) -> void:
	# Swept earth in most of town; interlocking blocks in the paved districts.
	var earth_cuts: Array[Rect2] = cuts.duplicate()
	earth_cuts.append_array(PAVED)
	_surface_pieces(strip,earth_cuts,M.surface(9,Color("9c6c4e")),y,0.016)
	for zone in PAVED:
		var kept := strip.intersection(zone)
		if kept.has_area(): _surface_pieces(kept,cuts,M.surface(5,Color("b5afa2")),y,0.016)

func _shoulder(strip: Rect2, cuts: Array[Rect2], material: Material) -> void:
	# Laid in 120 m lengths: a single kilometre-long box is culled and lit as one
	# object, and a plate thinner than 2 cm picks up shadow acne at a distance.
	var along_z: bool = strip.size.y > strip.size.x
	var length: float = strip.size.y if along_z else strip.size.x
	var count: int = maxi(1,ceili(length/120.0))
	for i in range(count):
		var from: float = length*i/count
		var piece := Rect2(strip.position.x,strip.position.y+from,strip.size.x,length/count) if along_z else Rect2(strip.position.x+from,strip.position.y,length/count,strip.size.y)
		_surface_pieces(piece,cuts,material,0.014,0.02)

func _landscape() -> void:
	# Shade the remaining courts, rather than leaving isolated buildings in
	# a field. Availability checks keep trunks out of entrances and streets.
	var rng := RandomNumberGenerator.new()
	rng.seed = 6162
	for attempt in range(1200):
		var at := Vector3(rng.randf_range(-210,210),0,rng.randf_range(-173,852))
		var plot := Rect2(at.x-3.4,at.z-3.4,6.8,6.8)
		if _reserved(plot,false,true) or not env._plot_available(plot): continue
		env._occupied_plots.append(plot)
		var frame: Transform3D = kit._frame(at)
		kit.tree(at,attempt%9 == 0,8,12,rng.randf_range(1.25,1.85))
		if attempt%4 == 0:
			kit._box(frame,Vector3(0,0.48,1.65),Vector3(1.8,0.12,0.5),M.surface(6,Color("827257")))
			for leg in [-0.65,0.65]:
				kit._box(frame,Vector3(leg,0.22,1.65),Vector3(0.1,0.44,0.4),M.solid(Color("414a42"),0.6))

func _parking(at: Vector3, width: float, depth: float, paved: bool = false) -> void:
	# Marked asphalt only at the mall and the bank. Everywhere else cars stand
	# on a compacted yard, nosed in wherever there is room.
	var plot := Rect2(at.x-width/2,at.z-depth/2,width,depth)
	if _reserved(plot) or not env._plot_available(plot): return
	env._occupied_plots.append(plot)
	kit._box(kit._frame(at),Vector3(0,0.02,0),Vector3(width,0.08,depth),M.surface(1,Color("51564e")) if paved else M.surface(9,Color("946548")))
	for i in range(int(width/2.8)):
		var x: float = -width/2+(i+0.5)*2.8
		if paved: kit._box(kit._frame(at),Vector3(x-1.3,0.07,-depth/2+2.8),Vector3(0.08,0.012,5.2),M.solid(Color("ddd6bc")))
		if i%3 == 0 or (not paved and i%2 == 0): continue
		var car := preload("res://scripts/VehicleActor.gd").new()
		car.configure("car",i+int(absf(at.z)))
		car.set_metric_dimensions(Vector3(1.8,1.5,4.5))
		car.position = at+Vector3(x,0.08,-depth/2+2.8)
		if not paved: car.rotation.y = sin(float(i)*3.7+at.z)*0.22
		kit.add_child(car)
