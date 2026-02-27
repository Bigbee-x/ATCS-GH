extends Control
## Rolling line chart for real-time traffic metrics.
##
## Uses Control._draw() with draw_polyline() for efficient rendering.
## Supports multiple color-coded data series (one per approach).
##
## Usage:
##   var chart = MetricsChart.new()
##   chart.chart_title = "Queue Depth"
##   chart.max_value = 50.0
##   add_child(chart)
##   chart.add_point("north", 12.0)
##   chart.add_point("south", 8.0)

# ── Configuration ────────────────────────────────────────────────────────────
## Title shown above the chart
@export var chart_title: String = "Metric"

## Maximum expected value for Y-axis scaling
@export var max_value: float = 50.0

## Number of data points to display (scrolling window)
const MAX_HISTORY: int = 200

# ── Series colors (approach → color) ─────────────────────────────────────────
const SERIES_COLORS: Dictionary = {
	"north": Color(0.35, 0.55, 1.0),    # Blue
	"south": Color(1.0, 0.35, 0.35),    # Red
	"east":  Color(0.35, 1.0, 0.45),    # Green
	"west":  Color(1.0, 0.9, 0.25),     # Yellow
}

# ── Style ────────────────────────────────────────────────────────────────────
const BG_COLOR      := Color(0.04, 0.04, 0.07, 0.85)
const GRID_COLOR    := Color(0.2, 0.2, 0.25, 0.4)
const LABEL_COLOR   := Color(0.6, 0.6, 0.65)
const TITLE_COLOR   := Color(0.8, 0.8, 0.85)
const LINE_WIDTH    := 1.5
const GRID_ROWS     := 4  ## Number of horizontal grid lines

# ── Internal data ────────────────────────────────────────────────────────────
## { "north": PackedFloat32Array, "south": ..., "east": ..., "west": ... }
var _data: Dictionary = {}

## Cached font for labels
var _font: Font
var _font_size: int = 10


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Initialize empty data arrays for all approaches
	for approach in SERIES_COLORS:
		_data[approach] = PackedFloat32Array()

	# Cache the default theme font
	_font = ThemeDB.fallback_font
	_font_size = 10

	# Mouse should pass through to 3D viewport
	mouse_filter = Control.MOUSE_FILTER_IGNORE


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func add_point(approach: String, value: float) -> void:
	## Append a data point for the given approach. Triggers redraw.
	if not _data.has(approach):
		return

	_data[approach].append(value)

	# Trim to scrolling window size
	if _data[approach].size() > MAX_HISTORY:
		_data[approach] = _data[approach].slice(1)

	queue_redraw()


func clear_data() -> void:
	## Clear all series data (for simulation restart).
	for approach in _data:
		_data[approach] = PackedFloat32Array()
	queue_redraw()


# ═════════════════════════════════════════════════════════════════════════════
# DRAWING
# ═════════════════════════════════════════════════════════════════════════════

func _draw() -> void:
	var sz: Vector2 = get_size()
	if sz.x < 10 or sz.y < 10:
		return

	var chart_top: float = 16.0      ## Space for title
	var chart_bottom: float = 14.0   ## Space for legend
	var chart_left: float = 28.0     ## Space for Y-axis labels
	var chart_right: float = 4.0

	var chart_w: float = sz.x - chart_left - chart_right
	var chart_h: float = sz.y - chart_top - chart_bottom

	# ── Background ────────────────────────────────────────────────────────
	draw_rect(Rect2(Vector2.ZERO, sz), BG_COLOR)

	# ── Title ─────────────────────────────────────────────────────────────
	if _font:
		draw_string(_font, Vector2(chart_left, 12), chart_title, HORIZONTAL_ALIGNMENT_LEFT, chart_w, _font_size, TITLE_COLOR)

	# ── Grid lines + Y-axis labels ───────────────────────────────────────
	for i in range(GRID_ROWS + 1):
		var frac: float = float(i) / float(GRID_ROWS)
		var y_pos: float = chart_top + frac * chart_h
		# Horizontal grid line
		draw_line(Vector2(chart_left, y_pos), Vector2(sz.x - chart_right, y_pos), GRID_COLOR, 1.0)

		# Y-axis label (values go top=max, bottom=0)
		if _font:
			var val: float = max_value * (1.0 - frac)
			var label_text: String = "%d" % int(val) if val == int(val) else "%.0f" % val
			draw_string(_font, Vector2(2, y_pos + 4), label_text, HORIZONTAL_ALIGNMENT_LEFT, 24, _font_size - 1, LABEL_COLOR)

	# ── Data lines ────────────────────────────────────────────────────────
	for approach in _data:
		var arr: PackedFloat32Array = _data[approach]
		if arr.size() < 2:
			continue

		var points := PackedVector2Array()
		var count: int = arr.size()

		for j in range(count):
			var x: float = chart_left + (float(j) / float(MAX_HISTORY)) * chart_w
			var normalized: float = clampf(arr[j] / max_value, 0.0, 1.0)
			var y: float = chart_top + (1.0 - normalized) * chart_h
			points.append(Vector2(x, y))

		var color: Color = SERIES_COLORS.get(approach, Color.WHITE)
		draw_polyline(points, color, LINE_WIDTH, true)

	# ── Legend bar at bottom ──────────────────────────────────────────────
	var legend_y: float = sz.y - 3.0
	var legend_x: float = chart_left
	var spacing: float = chart_w / float(SERIES_COLORS.size())

	for approach in SERIES_COLORS:
		var color: Color = SERIES_COLORS[approach]
		# Color swatch (small square)
		draw_rect(Rect2(Vector2(legend_x, legend_y - 7), Vector2(8, 8)), color)
		# Label
		if _font:
			var short_name: String = approach.substr(0, 1).to_upper()
			draw_string(_font, Vector2(legend_x + 10, legend_y), short_name, HORIZONTAL_ALIGNMENT_LEFT, 20, _font_size - 1, LABEL_COLOR)
		legend_x += spacing
