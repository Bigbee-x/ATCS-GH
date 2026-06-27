extends Node3D
## Big roadside advertising billboards for the corridor township.
##
## A curated set of brand-themed panels (recognizable Ghanaian companies +
## Valiborn Technologies) standing in the road frontage, facing the corridor,
## that light up brightly at night. Each sign is posts + a dark frame + an
## emissive ad face + Label3D headline/tagline. By day the faces are flat-lit;
## at night their emission ramps up and the scene's glow/bloom makes them pop.
##
## Self-wires to the sibling TimeOfDayManager (same pattern as
## EnvironmentBuilder) so day/night just works — purely cosmetic, no gameplay.
##
## PLACEMENT NOTE: the world coords in BILLBOARDS assume the corridor layout in
## CorridorBuilder.gd — road along Z at x∈[-3,3]; junctions J0=0, J1=30, J2=60;
## flanking districts centred at x=±38. Signs sit in the open frontage at
## x≈±12 (clear of both the road furniture and the district buildings) and face
## the road. If that layout moves, nudge this table to match.
##
## Each sign's local FRONT (ad face + readable text) is local +Z, so a sign on
## the +X side faces the road with yaw = -PI/2, and one on the -X side uses
## yaw = +PI/2.

# ── Emission energy for the ad faces (driven by day/night) ──────────────────
const DAY_EMISSION:   float = 0.0    # flat-lit printed panel
const DUSK_EMISSION:  float = 1.4    # warming up
const NIGHT_EMISSION: float = 3.6    # bright glow

# ── Shared structural colours ───────────────────────────────────────────────
const POST_COLOR:  Color = Color(0.20, 0.20, 0.23)
const FRAME_COLOR: Color = Color(0.09, 0.09, 0.11)

var _is_night: bool = false
var _is_dusk: bool  = false

var _mat_post: StandardMaterial3D
var _mat_frame: StandardMaterial3D
var _panel_mats: Array[StandardMaterial3D] = []   # one per ad face, ramped at night

# ── The curated line-up ─────────────────────────────────────────────────────
# pos/yaw place + aim the sign; w/h = panel size; post = how high it sits;
# bg = panel colour, fg = text colour; name = headline, tag = small tagline.
const YAW_FACE_WEST:  float = -PI / 2.0   # +X-side sign facing the road (-X)
const YAW_FACE_EAST:  float =  PI / 2.0   # -X-side sign facing the road (+X)

var BILLBOARDS: Array = [
	# ── Valiborn Technology — flagship, tall, on the J0–J1 approach (clear of
	#    the cross-streets at the junctions). Long name → smaller head_ps. ──
	{
		"pos": Vector3(13.0, 0, 18.0), "yaw": YAW_FACE_WEST,
		"w": 13.0, "h": 6.0, "post": 7.0, "head_ps": 0.020,
		"bg": Color(0.05, 0.07, 0.15), "fg": Color(0.30, 0.92, 1.00),
		"name": "Valiborn Technology", "tag": "Relax, it works.",
	},
	# ── MTN — the yellow is unmistakable ──
	{
		"pos": Vector3(12.0, 0, 46.0), "yaw": YAW_FACE_WEST,
		"w": 9.0, "h": 4.5, "post": 6.0,
		"bg": Color(1.00, 0.80, 0.00), "fg": Color(0.05, 0.05, 0.05),
		"name": "MTN", "tag": "everywhere you go",
	},
	# ── Telecel (the former Vodafone red) ──
	{
		"pos": Vector3(-12.0, 0, 40.0), "yaw": YAW_FACE_EAST,
		"w": 9.0, "h": 4.5, "post": 6.0,
		"bg": Color(0.86, 0.05, 0.10), "fg": Color(1.00, 1.00, 1.00),
		"name": "TELECEL", "tag": "the future is here",
	},
	# ── GCB Bank ──
	{
		"pos": Vector3(12.0, 0, 70.0), "yaw": YAW_FACE_WEST,
		"w": 8.5, "h": 4.5, "post": 6.0,
		"bg": Color(0.06, 0.18, 0.45), "fg": Color(1.00, 0.82, 0.25),
		"name": "GCB BANK", "tag": "your bank for life",
	},
	# ── Voltic water ──
	{
		"pos": Vector3(-12.0, 0, 52.0), "yaw": YAW_FACE_EAST,
		"w": 8.0, "h": 4.0, "post": 5.5,
		"bg": Color(0.10, 0.45, 0.80), "fg": Color(1.00, 1.00, 1.00),
		"name": "VOLTIC", "tag": "pure natural water",
	},
	# ── Guinness — iconic in Ghana ──
	{
		"pos": Vector3(12.0, 0, 82.0), "yaw": YAW_FACE_WEST,
		"w": 9.0, "h": 4.5, "post": 6.0,
		"bg": Color(0.08, 0.07, 0.05), "fg": Color(1.00, 0.80, 0.30),
		"name": "GUINNESS", "tag": "Black shines",
	},
	# ── Fan Milk / Fan Ice ──
	{
		"pos": Vector3(-12.0, 0, -18.0), "yaw": YAW_FACE_EAST,
		"w": 8.5, "h": 4.5, "post": 5.5,
		"bg": Color(0.12, 0.55, 0.88), "fg": Color(1.00, 1.00, 1.00),
		"name": "FAN ICE", "tag": "stay cool, Ghana",
	},
	# ── GOIL — at the hospital-block filling station (−X side, faces the road) ──
	{
		"pos": Vector3(-12.0, 0, 8.0), "yaw": YAW_FACE_EAST,
		"w": 8.5, "h": 4.5, "post": 6.0,
		"bg": Color(0.95, 0.45, 0.05), "fg": Color(1.00, 1.00, 1.00),
		"name": "GOIL", "tag": "go with GOIL",
	},
	# ── MELCOM — the big-box retailer ──
	{
		"pos": Vector3(-13.0, 0, -38.0), "yaw": YAW_FACE_EAST,
		"w": 9.0, "h": 4.5, "post": 6.0,
		"bg": Color(0.78, 0.10, 0.10), "fg": Color(1.00, 0.85, 0.10),
		"name": "MELCOM", "tag": "you shop, we care",
	},
]


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_build_materials()
	for spec in BILLBOARDS:
		_build_one(spec)
	_wire_day_night()
	print("[BillboardBuilder] Built %d billboards" % BILLBOARDS.size())


func _build_materials() -> void:
	_mat_post = StandardMaterial3D.new()
	_mat_post.albedo_color = POST_COLOR
	_mat_post.metallic = 0.4
	_mat_post.roughness = 0.5

	_mat_frame = StandardMaterial3D.new()
	_mat_frame.albedo_color = FRAME_COLOR
	_mat_frame.metallic = 0.3
	_mat_frame.roughness = 0.6


# ═════════════════════════════════════════════════════════════════════════════
# CONSTRUCTION
# ═════════════════════════════════════════════════════════════════════════════

func _build_one(spec: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Billboard_%s" % String(spec["name"]).replace(" ", "_")
	root.position = spec["pos"]
	root.rotation.y = spec["yaw"]
	add_child(root)

	var w: float = spec["w"]
	var h: float = spec["h"]
	var post_h: float = spec["post"]
	var cy: float = post_h + h / 2.0   # panel vertical centre

	# ── Two support posts (front = +Z, so posts sit a touch behind the face) ──
	var gap: float = w * 0.32
	for sx in [-1.0, 1.0]:
		var post := CSGCylinder3D.new()
		post.radius = 0.22
		post.height = cy
		post.sides = 10
		post.position = Vector3(sx * gap, cy / 2.0, -0.12)
		post.material = _mat_post
		root.add_child(post)

	# ── Dark backboard / frame ──
	var frame := CSGBox3D.new()
	frame.size = Vector3(w + 0.5, h + 0.5, 0.30)
	frame.position = Vector3(0, cy, -0.05)
	frame.material = _mat_frame
	root.add_child(frame)

	# ── Emissive ad face (brand colour), on the front (+Z) ──
	var face_mat := StandardMaterial3D.new()
	face_mat.albedo_color = spec["bg"]
	face_mat.roughness = 0.4
	face_mat.metallic = 0.0
	face_mat.emission_enabled = true
	face_mat.emission = spec["bg"]
	face_mat.emission_energy_multiplier = _current_emission()
	_panel_mats.append(face_mat)

	var face := CSGBox3D.new()
	face.size = Vector3(w, h, 0.12)
	face.position = Vector3(0, cy, 0.12)
	face.material = face_mat
	root.add_child(face)

	# ── Headline + tagline (Label3D faces +Z by default → toward the road) ──
	var headline := Label3D.new()
	headline.text = String(spec["name"])
	headline.font_size = 64
	headline.pixel_size = spec.get("head_ps", h * 0.0060)   # per-sign override for long names
	headline.modulate = spec["fg"]
	headline.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	headline.outline_size = 10
	headline.outline_modulate = Color(0, 0, 0, 0.55)
	headline.position = Vector3(0, cy + h * 0.13, 0.20)
	headline.name = "Headline"
	root.add_child(headline)

	var tag := Label3D.new()
	tag.text = String(spec["tag"])
	tag.font_size = 40
	tag.pixel_size = h * 0.0030
	tag.modulate = spec["fg"]
	tag.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	tag.outline_size = 6
	tag.outline_modulate = Color(0, 0, 0, 0.45)
	tag.position = Vector3(0, cy - h * 0.24, 0.20)
	tag.name = "Tagline"
	root.add_child(tag)

	# ── Floodlight gantry across the top (cosmetic) ──
	var bar := CSGBox3D.new()
	bar.size = Vector3(w * 0.9, 0.10, 0.10)
	bar.position = Vector3(0, cy + h / 2.0 + 0.55, 0.55)
	bar.material = _mat_frame
	root.add_child(bar)
	for i in range(3):
		var fx: float = -w * 0.30 + i * (w * 0.30)
		var flood := CSGBox3D.new()
		flood.size = Vector3(0.50, 0.22, 0.30)
		flood.position = Vector3(fx, cy + h / 2.0 + 0.52, 0.58)
		flood.rotation.x = deg_to_rad(35.0)   # tilt down toward the panel
		flood.material = _mat_frame
		root.add_child(flood)


# ═════════════════════════════════════════════════════════════════════════════
# DAY / NIGHT (self-wired, mirrors EnvironmentBuilder)
# ═════════════════════════════════════════════════════════════════════════════

func _wire_day_night() -> void:
	var tod: Node = get_parent().get_node_or_null("TimeOfDayManager")
	if tod == null:
		return   # no day/night manager — leave panels in the day state
	if tod.has_signal("night_mode_changed"):
		tod.night_mode_changed.connect(_on_night_mode_changed)
	if tod.has_signal("dusk_mode_changed"):
		tod.dusk_mode_changed.connect(_on_dusk_mode_changed)
	if tod.has_method("is_night"):
		_is_night = tod.is_night()
	if tod.has_method("is_dusk"):
		_is_dusk = tod.is_dusk()
	_apply_glow()


func _on_night_mode_changed(is_night: bool) -> void:
	_is_night = is_night
	_apply_glow()


func _on_dusk_mode_changed(is_dusk: bool) -> void:
	_is_dusk = is_dusk
	_apply_glow()


func _current_emission() -> float:
	if _is_night:
		return NIGHT_EMISSION
	if _is_dusk:
		return DUSK_EMISSION
	return DAY_EMISSION


func _apply_glow() -> void:
	var e: float = _current_emission()
	for m in _panel_mats:
		m.emission_energy_multiplier = e
