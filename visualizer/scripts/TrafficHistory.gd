extends Control
## Actual simulation-time history; missing samples are gaps, never invented zeroes.
var samples: Array = []
var field := "wait"
var caption := "Current mean wait · seconds"
var line_color := Color("eeeeee")
const T = preload("res://scripts/TrafIQTheme.gd")
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
func set_samples(values: Array) -> void:
	samples = values
	queue_redraw()
func _draw() -> void:
	var font := get_theme_default_font()
	draw_string(font,Vector2(0,15),caption,HORIZONTAL_ALIGNMENT_LEFT,size.x,12,T.TEXT)
	var area := Rect2(32,30,maxf(size.x-38,1),maxf(size.y-54,1))
	var maximum := 4.0
	for sample in samples:
		if sample.get(field) != null: maximum = maxf(maximum,float(sample[field]))
	maximum = ceilf(maximum/4.0)*4.0
	for i in range(5):
		var y: float = area.position.y+area.size.y*float(i)/4.0
		draw_line(Vector2(area.position.x,y),Vector2(area.end.x,y),Color("343434"),1)
		draw_string(font,Vector2(0,y+4),"%.0f" % (maximum*(1.0-float(i)/4)),HORIZONTAL_ALIGNMENT_LEFT,29,10,T.MUTED)
	if samples.is_empty():
		draw_string(font,area.position+Vector2(8,area.size.y*0.5),"Waiting for measured data",HORIZONTAL_ALIGNMENT_LEFT,area.size.x-8,11,T.MUTED)
		return
	var first: float = samples[0].time
	var last: float = samples[-1].time
	var previous := Vector2.ZERO
	var have_previous := false
	for sample in samples:
		if sample.get(field) == null:
			have_previous = false
			continue
		var at := Vector2(area.position.x+(float(sample.time)-first)/maxf(last-first,1)*area.size.x,area.end.y-float(sample[field])/maximum*area.size.y)
		if have_previous: draw_line(previous,at,line_color,1.6,true)
		else: draw_circle(at,2,line_color)
		previous = at
		have_previous = true
	draw_string(font,Vector2(area.position.x,size.y-3),_time(first),HORIZONTAL_ALIGNMENT_LEFT,70,10,T.MUTED)
	draw_string(font,Vector2(area.end.x-68,size.y-3),_time(last),HORIZONTAL_ALIGNMENT_RIGHT,68,10,T.MUTED)
func _time(seconds: float) -> String:
	return "%02d:%02d" % [int(seconds)/60,int(seconds)%60]
