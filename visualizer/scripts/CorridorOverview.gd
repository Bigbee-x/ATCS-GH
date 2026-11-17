extends Control
## Static route orientation, never an indication of live signal state or traffic.
const ACCENT := Color("f59a50")
const TEXT := Color("eeeeee")
const MUTED := Color("a4a4a4")

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)

func _draw() -> void:
	var bounds := size
	var font := get_theme_default_font()
	for x in range(0, int(bounds.x), 32):
		for y in range(10, int(bounds.y)-10, 32):
			draw_circle(Vector2(x,y), 0.8, Color("333333"))
	var points: Array[Vector2] = [bounds*Vector2(0.19,0.70), bounds*Vector2(0.50,0.44), bounds*Vector2(0.81,0.18)]
	var direction := (points[2]-points[0]).normalized()
	var cross := Vector2(-direction.y, direction.x)
	for p in points:
		_road(p-cross*65, p+cross*65, 15)
	var start := points[0]-direction*60
	var end := points[2]+direction*60
	_road(start, end, 30)
	for i in range(3):
		var p := points[i]
		for sign_value in [-1.0,1.0]:
			for stripe in range(4):
				var at: Vector2 = p+direction*sign_value*(23.0+stripe*3.0)
				draw_line(at-cross*10,at+cross*10,Color("777777"),1.4,true)
		draw_circle(p, 15, Color("38312c"))
		draw_arc(p, 15, 0, TAU, 48, ACCENT, 1.5, true)
		draw_circle(p, 5, ACCENT)
		var label_at := p+Vector2(-16,39)
		draw_string(font,label_at,"J%d" % i,HORIZONTAL_ALIGNMENT_LEFT,-1,13,ACCENT)
		draw_string(font,label_at+Vector2(0,19),["Achimota","Asylum Down","Nima"][i],HORIZONTAL_ALIGNMENT_LEFT,-1,13,TEXT)
	for i in range(2):
		var middle := (points[i]+points[i+1])*0.5-cross*27
		draw_string(font,middle-Vector2(18,0),"300 m",HORIZONTAL_ALIGNMENT_LEFT,-1,10,MUTED)

func _road(a: Vector2,b: Vector2,width: float) -> void:
	draw_line(a,b,Color("555555"),width+2,true)
	draw_line(a,b,Color("282828"),width,true)
	var direction := (b-a).normalized()
	var length := a.distance_to(b)
	for d in range(6, int(length)-8, 14):
		draw_line(a+direction*d,a+direction*(d+6),Color("777777"),1,true)
