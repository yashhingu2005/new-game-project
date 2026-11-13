extends Node2D

const State = preload("res://simulation/mission_state.gd")
const Grid = preload("res://simulation/power_grid.gd")
const Tuning = preload("res://simulation/tuning.gd")
const PlacementRules = preload("res://simulation/placement_rules.gd")
const DataSources = preload("res://data/sources.gd")
const Story = preload("res://simulation/story_system.gd")
const BadgeSystem = preload("res://simulation/badge_system.gd")
const Hazards = preload("res://simulation/hazards.gd")
const RoverSystem = preload("res://simulation/rover_system.gd")
const SECONDS_PER_HOUR := 4.0

const PANEL := Color("091522")
const PANEL_EDGE := Color("2b7187")
const TEXT := Color("d6e8f0")
const MUTED := Color("7795a5")
const CYAN := Color("58d6ec")
const GREEN := Color("8de6a7")
const RED := Color("ff6b62")
const GOLD := Color("ffc857")

class ForecastChart extends Control:
	var points: Array[Dictionary] = []
	var capacity: float = 1.0
	var reserve: float = 0.2
	var reserve_hour: Variant = null
	var zero_hour: Variant = null

	func _draw() -> void:
		var rect := Rect2(Vector2.ZERO, size)
		draw_rect(rect, Color("0b1520"), true)
		draw_rect(rect, Color("496173"), false, 1.0)
		var area := Rect2(Vector2(38, 12), Vector2(maxf(20.0, size.x - 52.0), maxf(20.0, size.y - 34.0)))
		for fraction in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]:
			var y := area.position.y + area.size.y * (1.0 - float(fraction))
			draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), Color(0.25, 0.38, 0.47, 0.38), 1.0)
		var reserve_y := area.position.y + area.size.y * (1.0 - reserve)
		draw_line(Vector2(area.position.x, reserve_y), Vector2(area.end.x, reserve_y), RED, 2.0)
		draw_string(ThemeDB.fallback_font, Vector2(3, reserve_y + 4), "Reserve", HORIZONTAL_ALIGNMENT_LEFT, 34, 10, RED)
		if points.size() > 1:
			var line := PackedVector2Array()
			for i in points.size():
				var charge := clampf(float(points[i].get("charge", 0.0)) / maxf(capacity, 0.001), 0.0, 1.0)
				line.append(Vector2(area.position.x + area.size.x * float(i) / float(points.size() - 1), area.position.y + area.size.y * (1.0 - charge)))
			draw_polyline(line, Color("69d9ff"), 3.0, true)
			var r_index := _first_below(reserve)
			if r_index >= 0: _draw_marker(area, r_index, Color("ff9f43"), "R")
			var zero_index := _first_below(0.001)
			if zero_index >= 0: _draw_marker(area, zero_index, RED, "0")
		draw_string(ThemeDB.fallback_font, Vector2(area.position.x, size.y - 4), "Dusk", HORIZONTAL_ALIGNMENT_LEFT, 50, 11, TEXT)
		draw_string(ThemeDB.fallback_font, Vector2(area.end.x - 48, size.y - 4), "Dawn", HORIZONTAL_ALIGNMENT_LEFT, 50, 11, TEXT)

	func _first_below(fraction: float) -> int:
		for i in points.size():
			if float(points[i].get("charge", 0.0)) / maxf(capacity, 0.001) <= fraction: return i
		return -1

	func _draw_marker(area: Rect2, index: int, color: Color, label: String) -> void:
		var x := area.position.x + area.size.x * float(index) / maxf(1.0, float(points.size() - 1))
		draw_line(Vector2(x, area.position.y), Vector2(x, area.end.y), color, 1.5)
		draw_string(ThemeDB.fallback_font, Vector2(x + 3, area.position.y + 12), label, HORIZONTAL_ALIGNMENT_LEFT, 18, 11, color)

var world: Node2D
var state: State
var tuning: Dictionary
var rng := RandomNumberGenerator.new()
var ui_layer: CanvasLayer
var ui_root: Control
var ui_scale: float = 1.0
var inspector_text: Label
var inspector_title: Label
var preview_text: Label
var preview_panel: PanelContainer
var preview_confirm: Button
var modal: PanelContainer
var modal_title: Label
var modal_text: Label
var modal_chart: ForecastChart
var modal_confirm: Button
var modal_cancel: Button
var story_options_box: VBoxContainer
var story_dilemma_open := false
var queued_critical_event: Dictionary = {}
var debrief_toast: PanelContainer
var debrief_toast_text: Label
var debrief_toast_time: float = 0.0
var evening_notice_sol := -1
var planning_screen := false
var is_paused := false
var rover_following := false
var rover_dispatch_mode := false
var selected_rover_inspector := false
var rover_sprite: Sprite2D
var rover_world_label: Label
var rover_travel_tween: Tween
var rover_charge_request: float = 0.0
var rover_dispatch_button: Button
var rover_recover_button: Button
var rover_charge_button: Button
var pole_switch_button: Button
var pole_reset_button: Button
var speed := 1.0
var time_accumulator := 0.0
var show_grid := false
var active_build_type := ""
var move_mode := false
var moving_building_id := ""
var moving_destination := Vector2i(-1, -1)
var preview_tile := Vector2i(-1, -1)
var preview_locked := false
var preview_valid := false
var preview_reason := ""
var selected_pole_id := -1
var selected_building_id := ""
var pending_action: Dictionary = {}
var pending_kind := ""
var sol_changes: Array[Dictionary] = []
var last_generation := 0.0
var last_demand := 0.0
var power_stat: Dictionary
var air_stat: Dictionary
var food_stat: Dictionary
var dose_stat: Dictionary
var hud_clock: Label
var hud_hint: Label
var build_buttons: Dictionary = {}
var move_button: Button
var grid_button: Button
var follow_button: Button
var speed_label: Label
var _hover_pole_id := -1
var data_panel: PanelContainer
var real_mars_mode := false
var data_mode_button: Button
var live_data_status: Label
var donki_request: HTTPRequest
var top_panel: PanelContainer
var build_panel: PanelContainer
var inspector_panel: PanelContainer
var command_panel: PanelContainer
var command_grid: GridContainer
var build_drawer_button: Button
var quick_pole_button: Button
var inspector_toggle_button: Button
var compact_layout := false
var inspector_open := false
var _layout_initialized := false
var clean_button: Button
var toggle_work_button: Button

func _ready() -> void:
	z_index = 180
	call_deferred("_setup_from_parent")

func _setup_from_parent() -> void:
	if state != null: return
	var parent := get_parent()
	if parent is Node2D and parent.has_method("_grid_to_iso") and parent.get("camera") != null:
		setup(parent)

func setup(world_node: Node2D) -> void:
	world = world_node
	tuning = Tuning.preset("game")
	state = State.create_default(tuning)
	rng.seed = 88421
	_tag_existing_sprites()
	_sync_rover_visual()
	_build_interface()
	_refresh_all()
	refresh_forecast()

func _process(delta: float) -> void:
	_camera_keys(delta)
	if state == null: return
	if world != null and world.has_method("set_time_of_day"):
		world.call("set_time_of_day", float(state.hour) + time_accumulator / SECONDS_PER_HOUR)
	if debrief_toast_time > 0.0:
		debrief_toast_time = maxf(0.0, debrief_toast_time - delta)
		if debrief_toast != null:
			debrief_toast.modulate.a = clampf(debrief_toast_time / 0.8, 0.0, 1.0)
		if debrief_toast_time <= 0.0 and debrief_toast != null:
			debrief_toast.visible = false
	_update_preview()
	_hover_pole_id = _pole_at_tile(_mouse_tile())
	queue_redraw()
	if is_paused or speed <= 0.0:
		return
	time_accumulator += delta * speed
	while time_accumulator >= SECONDS_PER_HOUR:
		time_accumulator -= SECONDS_PER_HOUR
		_simulation_hour()
		if is_paused:
			break

func _draw() -> void:
	if state == null or world == null:
		return
	var hover_id := selected_pole_id if selected_pole_id > 0 else _hover_pole_id
	if hover_id > 0:
		var pole := _pole_by_id(hover_id)
		if not pole.is_empty(): _draw_pole_radius(pole, Color(0.35, 0.78, 1.0, 0.16), Color(0.45, 0.86, 1.0, 0.85))
	if show_grid:
		_draw_grid()
	_draw_poles()
	_draw_building_status()
	if active_build_type != "" or moving_building_id != "":
		if preview_tile.x >= 0:
			var center := world.call("_grid_to_iso", preview_tile.x, preview_tile.y) as Vector2
			var color := GREEN if preview_valid else RED
			var diamond := PackedVector2Array([center + Vector2(0, -18), center + Vector2(34, 0), center + Vector2(0, 18), center + Vector2(-34, 0)])
			draw_colored_polygon(diamond, Color(color.r, color.g, color.b, 0.27))
			draw_polyline(PackedVector2Array([diamond[0], diamond[1], diamond[2], diamond[3], diamond[0]]), color, 2.5, true)
	if moving_building_id != "" and moving_destination.x >= 0:
		var origin := _building_tile(moving_building_id)
		var a: Vector2 = world.call("_grid_to_iso", origin.x, origin.y)
		var b: Vector2 = world.call("_grid_to_iso", moving_destination.x, moving_destination.y)
		draw_line(a, b, Color(1.0, 0.82, 0.35, 0.8), 2.0, true)

func _draw_pole_radius(pole: Dictionary, fill: Color, edge: Color) -> void:
	var radius := float(pole.get("radius", 5.0))
	var tile: Vector2i = pole.get("tile", Vector2i.ZERO)
	var points := PackedVector2Array()
	for i in 49:
		var angle := TAU * float(i) / 48.0
		var gx := float(tile.x) + cos(angle) * radius
		var gy := float(tile.y) + sin(angle) * radius
		points.append(world.call("_grid_to_iso", gx, gy))
	if points.size() >= 3:
		var closed := points.duplicate()
		closed.append(points[0])
		draw_colored_polygon(points, fill)
		draw_polyline(closed, edge, 2.0, true)

func _building_near_mouse() -> Dictionary:
	var mouse: Vector2 = world.camera.get_global_mouse_position()
	var best: Dictionary = {}
	var best_distance := 80.0   # world pixels, about 60% of a tile width
	var candidates: Array[Dictionary] = []
	for building: Dictionary in state.buildings:
		candidates.append(building)
	for panel: Dictionary in state.solar_arrays:
		candidates.append({"id": "solar_array:%d" % int(panel.get("id", 0)), "tile": panel.get("tile", Vector2i.ZERO), "fixed": false, "size_factor": 1.5})
	for battery: Dictionary in state.batteries:
		candidates.append({"id": "battery:%d" % int(battery.get("id", 0)), "tile": battery.get("tile", Vector2i.ZERO), "fixed": false, "size_factor": 1.5})
	for item: Dictionary in candidates:
		var tile: Vector2i = item.get("tile", Vector2i(-1, -1))
		var centre: Vector2 = world.call("_grid_to_iso", tile.x, tile.y) + Vector2(0, -26)
		var d := mouse.distance_to(centre)
		if d < best_distance:
			best_distance = d
			best = item
	return best
	
func _draw_grid() -> void:
	var grid: Dictionary = Grid.compute_grid(state, tuning)
	var poles: Array = state.poles
	var energized: Array = grid["energized_poles"]
	var now := float(Time.get_ticks_msec()) / 1000.0
	for i in poles.size():
		var a: Dictionary = poles[i]
		for j in range(i + 1, poles.size()):
			var b: Dictionary = poles[j]
			var at: Vector2i = a.get("tile", Vector2i.ZERO)
			var bt: Vector2i = b.get("tile", Vector2i.ZERO)
			if Vector2(at).distance_to(Vector2(bt)) > minf(float(a.get("radius", 0)), float(b.get("radius", 0))): continue
			var linked := energized.has(int(a["id"])) and energized.has(int(b["id"]))
			var color := Color(0.3, 0.88, 1.0, 0.7) if linked else Color(0.56, 0.62, 0.68, 0.38)
			var p1: Vector2 = world.call("_grid_to_iso", at.x, at.y)
			var p2: Vector2 = world.call("_grid_to_iso", bt.x, bt.y)
			draw_line(p1, p2, color, 2.0 if linked else 1.0, true)
			if linked:
				var flow := fposmod(now * 0.42, 1.0)
				draw_circle(p1.lerp(p2, flow), 4.0, Color("d7fbff"))
	for pole: Dictionary in poles:
		var id := int(pole["id"])
		var tile: Vector2i = pole.get("tile", Vector2i.ZERO)
		var pos: Vector2 = world.call("_grid_to_iso", tile.x, tile.y)
		var color := Color("62e6ff") if energized.has(id) else Color("89949e")
		if bool(pole.get("tripped", false)):
			color = RED if int(now * 3.0) % 2 == 0 else Color("8a4545")
		elif not bool(pole.get("on", true)):
			color = Color("89949e")
		draw_circle(pos, 8.0, Color(0.06, 0.1, 0.15, 0.9))
		draw_arc(pos, 8.0, 0.0, TAU, 20, color, 3.0, true)
		draw_string(ThemeDB.fallback_font, pos + Vector2(11, 4), str(id), HORIZONTAL_ALIGNMENT_LEFT, 14, 11, TEXT)

func _draw_poles() -> void:
	for pole: Dictionary in state.poles:
		var tile: Vector2i = pole.get("tile", Vector2i.ZERO)
		var pos: Vector2 = world.call("_grid_to_iso", tile.x, tile.y)
		var is_on := bool(pole.get("on", true)) and not bool(pole.get("tripped", false))
		var tint := Color("73e5ff") if is_on else Color("88939e")
		draw_circle(pos + Vector2(0, -2), 10.0, Color(tint.r, tint.g, tint.b, 0.22))
		draw_rect(Rect2(pos + Vector2(-4, -20), Vector2(8, 20)), Color("10202b"))
		draw_rect(Rect2(pos + Vector2(-2, -20), Vector2(4, 20)), tint)
		draw_line(pos + Vector2(-7, -16), pos + Vector2(7, -16), tint, 3.0, true)
		draw_circle(pos + Vector2(0, -22), 4.0, tint)
		draw_string(ThemeDB.fallback_font, pos + Vector2(10, -18), "P%d" % int(pole.get("id", 0)), HORIZONTAL_ALIGNMENT_LEFT, 28, 10, TEXT)

func _draw_building_status() -> void:
	var grid: Dictionary = Grid.compute_grid(state, tuning)
	var assignments: Dictionary = grid["assignments"]
	for building: Dictionary in state.buildings:
		var id := str(building.get("id", ""))
		var tile: Vector2i = building.get("tile", Vector2i.ZERO)
		var pos: Vector2 = world.call("_grid_to_iso", tile.x, tile.y) + Vector2(0, 58)
		var status := "ON"
		var color := GREEN
		if bool(building.get("faulted", false)) or bool(building.get("low_power_fault", false)):
			status = "!"; color = RED
		elif not bool(assignments.get(id) != null):
			status = "OFF"; color = Color("c2cad0")
			for pole: Dictionary in state.poles:
				var pole_tile: Vector2i = pole.get("tile", Vector2i.ZERO)
				if bool(pole.get("tripped", false)) and Grid._distance(pole_tile, tile) <= float(pole.get("radius", 0.0)):
					status = "TRIP"; color = RED; break
		elif not bool(building.get("work_enabled", true)):
			status = "CUT"; color = GOLD
		draw_string(ThemeDB.fallback_font, pos, status, HORIZONTAL_ALIGNMENT_CENTER, 40, 10, color)
	for panel: Dictionary in state.solar_arrays:
		var tile: Vector2i = panel.get("tile", Vector2i.ZERO)
		var status := "GEN" if state.sol >= int(panel.get("offline_until_sol", 0)) else "MOVE"
		draw_string(ThemeDB.fallback_font, world.call("_grid_to_iso", tile.x, tile.y) + Vector2(0, 58), status, HORIZONTAL_ALIGNMENT_CENTER, 42, 10, GREEN if status == "GEN" else GOLD)
	for battery: Dictionary in state.batteries:
		var tile: Vector2i = battery.get("tile", Vector2i.ZERO)
		var status := "BAT" if state.sol >= int(battery.get("offline_until_sol", 0)) else "MOVE"
		draw_string(ThemeDB.fallback_font, world.call("_grid_to_iso", tile.x, tile.y) + Vector2(0, 58), status, HORIZONTAL_ALIGNMENT_CENTER, 42, 10, Color("75caff") if status == "BAT" else GOLD)

func _build_interface() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)
	# Canvas-item stretching can also inherit the OS display scale. Keep the
	# fixed-size HUD controls in their intended design size on HiDPI displays.
	ui_scale = maxf(1.0, DisplayServer.screen_get_scale())
	ui_root = Control.new()
	ui_root.anchor_left = 0.0
	ui_root.anchor_top = 0.0
	ui_root.anchor_right = 0.0
	ui_root.anchor_bottom = 0.0
	ui_root.position = Vector2.ZERO
	ui_root.scale = Vector2.ONE / ui_scale
	ui_root.mouse_filter = Control.MOUSE_FILTER_PASS
	ui_layer.add_child(ui_root)
	get_viewport().size_changed.connect(_resize_ui_root)
	_resize_ui_root()
	_build_top_bar()
	_build_menu()
	_build_inspector()
	_build_command_bar()
	_build_preview()
	_build_modal()
	_build_debrief()
	_build_data_screen()
	_layout_interface()

func _resize_ui_root() -> void:
	if ui_root == null:
		return
	ui_scale = maxf(1.0, DisplayServer.screen_get_scale())
	ui_root.scale = Vector2.ONE / ui_scale
	# The root uses scaled logical coordinates so anchored panels still reach
	# the physical viewport edges after its inverse HiDPI transform.
	ui_root.size = get_viewport().get_visible_rect().size * ui_scale
	_layout_interface()

func _layout_interface() -> void:
	if ui_root == null or top_panel == null or command_panel == null:
		return
	var w := ui_root.size.x
	var h := ui_root.size.y
	# Choose the layout using the rendered viewport size, not the scaled
	# Control coordinates. On HiDPI displays those values can differ greatly.
	var rendered_size := Vector2(DisplayServer.window_get_size())
	compact_layout = rendered_size.x < 1120.0 or rendered_size.y < 720.0
	var top_height := 96.0 if compact_layout else 66.0
	var command_height := 82.0 if compact_layout else 56.0
	top_panel.offset_left = 14.0
	top_panel.offset_right = -14.0
	top_panel.offset_top = 12.0
	top_panel.offset_bottom = 12.0 + top_height
	if debrief_toast != null:
		debrief_toast.offset_top = top_height + 18.0
		debrief_toast.offset_bottom = top_height + 154.0
	var metric_grid := top_panel.get_child(0) as GridContainer
	if metric_grid != null:
		metric_grid.columns = 3 if compact_layout else 5
	command_panel.offset_left = 14.0
	command_panel.offset_right = -14.0
	command_panel.offset_top = -command_height - 12.0
	command_panel.offset_bottom = -12.0
	command_grid.columns = 4 if compact_layout else 8
	if not _layout_initialized:
		_layout_initialized = true
		build_drawer_button.button_pressed = not compact_layout
		build_panel.visible = not compact_layout
	var side_width := clampf(w * 0.205, 282.0, 326.0)
	var side_top := top_height + 26.0
	var side_bottom := command_height + 26.0
	var available_height := maxf(210.0, h - side_top - side_bottom)
	build_panel.position = Vector2(14.0, side_top)
	build_panel.custom_minimum_size = Vector2(minf(302.0, maxf(248.0, w * 0.29)), minf(360.0, available_height))
	build_panel.size = build_panel.custom_minimum_size
	var build_box := build_panel.get_child(0) as VBoxContainer
	var build_scroll := build_box.get_child(2) as ScrollContainer
	build_scroll.custom_minimum_size.y = maxf(96.0, build_panel.size.y - 142.0)
	build_panel.position = Vector2(14.0, side_top)
	build_panel.visible = build_drawer_button.button_pressed
	inspector_panel.position = Vector2(w - side_width - 14.0, side_top)
	inspector_panel.custom_minimum_size = Vector2(side_width, available_height)
	inspector_panel.size = inspector_panel.custom_minimum_size
	inspector_text.custom_minimum_size.y = 90.0 if compact_layout else 180.0
	if compact_layout:
		inspector_panel.position.x = 14.0
		inspector_panel.visible = inspector_open
	else:
		inspector_panel.visible = inspector_open
	var preview_width := clampf(w * 0.58, 460.0, 780.0)
	preview_panel.offset_left = -preview_width * 0.5
	preview_panel.offset_right = preview_width * 0.5
	preview_panel.offset_top = -command_height - 104.0
	preview_panel.offset_bottom = -command_height - 18.0
	var modal_width := minf(760.0, maxf(320.0, w - 36.0))
	var modal_height := minf(620.0, maxf(260.0, h - top_height - command_height - 40.0))
	if planning_screen:
		var dock_width := minf(460.0, maxf(320.0, w * 0.34))
		modal_width = dock_width
		modal.anchor_left = 0.0
		modal.anchor_right = 0.0
		modal.anchor_top = 0.0
		modal.anchor_bottom = 0.0
		modal.offset_left = w - dock_width - 18.0
		modal.offset_right = w - 18.0
		modal.offset_top = top_height + 22.0
		modal.offset_bottom = minf(h - command_height - 18.0, top_height + 500.0)
		modal.mouse_filter = Control.MOUSE_FILTER_PASS
	else:
		modal.anchor_left = 0.5
		modal.anchor_right = 0.5
		modal.anchor_top = 0.5
		modal.anchor_bottom = 0.5
		modal.offset_left = -modal_width * 0.5
		modal.offset_right = modal_width * 0.5
		modal.offset_top = -modal_height * 0.5
		modal.offset_bottom = modal_height * 0.5
	modal_chart.custom_minimum_size = Vector2(maxf(280.0, modal_width - 44.0), clampf(modal_height * 0.38, 145.0, 235.0))
	if data_panel != null:
		var data_width := minf(820.0, maxf(320.0, w - 36.0))
		var data_height := minf(700.0, maxf(300.0, h - 36.0))
		data_panel.offset_left = -data_width * 0.5
		data_panel.offset_right = data_width * 0.5
		data_panel.offset_top = -data_height * 0.5
		data_panel.offset_bottom = data_height * 0.5

func _panel(parent: Control, title: String, panel_position: Vector2, minimum: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = panel_position
	panel.custom_minimum_size = minimum
	panel.add_theme_stylebox_override("panel", _style(PANEL, PANEL_EDGE))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 7)
	panel.add_child(box)
	if title != "":
		var label := Label.new()
		label.text = "▰  " + title.to_upper()
		label.add_theme_font_size_override("font_size", 15)
		label.add_theme_color_override("font_color", CYAN)
		box.add_child(label)
	parent.add_child(panel)
	return panel

func _style(fill: Color, edge: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(fill.r, fill.g, fill.b, 0.88)
	s.border_color = edge
	s.set_border_width_all(2)
	s.border_width_bottom = 4
	s.set_corner_radius_all(10)
	s.shadow_color = Color(0, 0, 0, 0.45)
	s.shadow_size = 8
	s.shadow_offset = Vector2(0, 3)
	s.content_margin_left = 12; s.content_margin_right = 12
	s.content_margin_top = 10; s.content_margin_bottom = 10
	return s

func _stat_bar(tint: Color) -> Dictionary:
	var box := VBoxContainer.new()
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", TEXT)
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(130, 14)
	var fill := StyleBoxFlat.new(); fill.bg_color = tint; fill.set_corner_radius_all(7)
	var back := StyleBoxFlat.new(); back.bg_color = Color("0d1d2b"); back.set_corner_radius_all(7)
	bar.add_theme_stylebox_override("fill", fill)
	bar.add_theme_stylebox_override("background", back)
	box.add_child(title)
	box.add_child(bar)
	return {"root": box, "title": title, "bar": bar}
	
	
func _build_top_bar() -> void:
	top_panel = PanelContainer.new()
	top_panel.anchor_right = 1.0
	top_panel.offset_left = 14
	top_panel.offset_top = 12
	top_panel.offset_right = -14
	top_panel.offset_bottom = 94
	top_panel.add_theme_stylebox_override("panel", _style(PANEL, PANEL_EDGE))
	var row := GridContainer.new()   # this is "the grid"
	row.columns = 5
	row.add_theme_constant_override("h_separation", 18)
	row.add_theme_constant_override("v_separation", 3)
	top_panel.add_child(row)

	power_stat = _stat_bar(CYAN)
	air_stat = _stat_bar(GREEN)
	food_stat = _stat_bar(GOLD)
	dose_stat = _stat_bar(GREEN)
	power_stat.title.tooltip_text = "Battery charge. Use is what the outpost draws per hour; solar is what the panels make."
	air_stat.title.tooltip_text = "Air is the breathable oxygen supply."
	food_stat.title.tooltip_text = "Food is the crew's food supply."
	dose_stat.title.tooltip_text = "Radiation dose in millisieverts (mSv). The warning line is a game placeholder."

	hud_clock = _label("SOL 1 · MORNING", 14, GOLD)
	hud_clock.add_theme_color_override("font_color", CYAN)
	hud_clock.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

	for item: Control in [power_stat.root, air_stat.root, food_stat.root, dose_stat.root, hud_clock]:
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(item)   # <- "add each root to the grid"
	ui_root.add_child(top_panel)

func _build_menu() -> void:
	build_panel = _panel(ui_root, "Build modules", Vector2(14, 104), Vector2(292, 360))
	var box: VBoxContainer = build_panel.get_child(0)
	var helper := _label("Choose a kit, then click a green tile.", 12, TEXT)
	helper.tooltip_text = "Green means the tile is clear and connected to the power grid."
	box.add_child(helper)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 215)
	var choice_list := VBoxContainer.new()
	choice_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	choice_list.add_theme_constant_override("separation", 7)
	scroll.add_child(choice_list)
	box.add_child(scroll)
	var choices := [
		{"id": "solar_array", "title": "Solar Array", "description": "Makes power in sunlight.", "cost": "10 materials · 1 Earth part · 3 crew-hours", "tip": "Dust makes a solar array weaker."},
		{"id": "battery", "title": "Battery", "description": "Saves power for nighttime.", "cost": "12 materials · 2 Earth parts · 4 crew-hours", "tip": "The reserve is the protected last 20% of battery power."},
		{"id": "power_pole", "title": "Power Pole", "description": "Carries power to nearby buildings.", "cost": "8 materials · 1 Earth part · 2 crew-hours · 1 power", "tip": "Poles must connect to the grid. A breaker trips if a pole carries too much."},
		{"id": "weather_station", "title": "Weather Station", "description": "Warns you about storms and solar events.", "cost": "16 materials · 1 Earth part · 5 crew-hours", "tip": "It needs power to send an early warning. If switched off, you may only get a late message from Earth."},
	]
	for choice: Dictionary in choices:
		var button := Button.new()
		button.text = "%s · %s\n%s" % [choice["title"], choice["description"], choice["cost"]]
		button.tooltip_text = str(choice["tip"]) + "\n" + str(choice["cost"])
		button.custom_minimum_size = Vector2(0, 64)
		button.pressed.connect(func() -> void: _select_build_type(str(choice["id"])))
		choice_list.add_child(button)
		build_buttons[choice["id"]] = button
	hud_hint = _label("G GRID  ·  ESC CANCEL", 11, MUTED)
	hud_hint.tooltip_text = "WASD pans the camera. The wheel zooms. Middle mouse drags. Home returns to the base."
	box.add_child(hud_hint)

func _build_command_bar() -> void:
	command_panel = PanelContainer.new()
	command_panel.anchor_left = 0.0
	command_panel.anchor_right = 1.0
	command_panel.anchor_top = 1.0
	command_panel.anchor_bottom = 1.0
	command_panel.offset_left = 14
	command_panel.offset_right = -14
	command_panel.offset_top = -76
	command_panel.offset_bottom = -12
	command_panel.add_theme_stylebox_override("panel", _style(PANEL, PANEL_EDGE))
	command_grid = GridContainer.new()
	command_grid.columns = 7
	command_grid.add_theme_constant_override("h_separation", 8)
	command_grid.add_theme_constant_override("v_separation", 6)
	command_panel.add_child(command_grid)
	build_drawer_button = _button("BUILD", "Open or close the construction drawer. Build costs appear before placement.")
	build_drawer_button.toggle_mode = true
	build_drawer_button.pressed.connect(func() -> void: build_panel.visible = build_drawer_button.button_pressed; _layout_interface())
	command_grid.add_child(build_drawer_button)
	quick_pole_button = _button("POLE", "Place a connected Power Pole. Cost: 8 materials, 1 Earth part, 2 crew-hours and 1 power.")
	quick_pole_button.pressed.connect(func() -> void: _select_build_type("power_pole"))
	command_grid.add_child(quick_pole_button)
	grid_button = _button("GRID · G", "Show or hide the power lines and pole states.")
	grid_button.toggle_mode = true
	grid_button.pressed.connect(func() -> void: show_grid = grid_button.button_pressed; _refresh_all())
	command_grid.add_child(grid_button)
	move_button = _button("MOVE", "Move a non-fixed building. The preview shows cost and downtime before confirming.")
	move_button.pressed.connect(_start_move_mode)
	command_grid.add_child(move_button)
	follow_button = _button("ROVER CAM", "Keep the camera centered on Nomad-1.")
	follow_button.toggle_mode = true
	follow_button.pressed.connect(_toggle_follow)
	command_grid.add_child(follow_button)
	inspector_toggle_button = _button("INSPECT", "Show stores and details for the selected pole or building.")
	inspector_toggle_button.toggle_mode = true
	inspector_toggle_button.pressed.connect(func() -> void: inspector_open = inspector_toggle_button.button_pressed; _layout_interface())
	command_grid.add_child(inspector_toggle_button)
	var data_button := _button("DATA", "Open Data & Sources and the Real Mars mode toggle.")
	data_button.pressed.connect(func() -> void: data_panel.visible = true)
	command_grid.add_child(data_button)
	clean_button = _button("CLEAN PANELS", "Wipe the dust off every solar panel. Costs 1 crew-hour.")
	clean_button.pressed.connect(func() -> void:
		var r: Dictionary = Grid.apply_action(state, Grid.action("clean_panels", null, tuning))
		if bool(r["ok"]):
			state = r["state"]
			sol_changes.append_array(r["changes"])
		else:
			hud_hint.text = "Can't clean: %s" % r["reason"]
		_refresh_all()
		refresh_forecast())
	command_grid.add_child(clean_button)
	var speed_box := HBoxContainer.new()
	speed_box.add_theme_constant_override("separation", 4)
	for item in [{"title": "1×", "value": 1.0}, {"title": "2×", "value": 2.0}, {"title": "4×", "value": 4.0}, {"title": "Ⅱ", "value": 0.0}]:
		var speed_button := _button(str(item["title"]), "Simulation speed. Each game hour takes 4 seconds at 1×, 2 seconds at 2×, or 1 second at 4×. Pause stops the clock.")
		speed_button.pressed.connect(func() -> void: speed = float(item["value"]); is_paused = speed <= 0.0; _refresh_all())
		speed_box.add_child(speed_button)
	command_grid.add_child(speed_box)
	ui_root.add_child(command_panel)

func _build_inspector() -> void:
	inspector_panel = PanelContainer.new()
	inspector_panel.add_theme_stylebox_override("panel", _style(PANEL, PANEL_EDGE))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	inspector_panel.add_child(box)
	inspector_title = _label("SYSTEM INSPECTOR", 15, CYAN)
	box.add_child(inspector_title)
	inspector_text = _label("", 13, TEXT)
	inspector_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inspector_text.custom_minimum_size = Vector2(290, 180)
	inspector_text.tooltip_text = "Select a pole or building to see its details. Water, materials, and Earth parts stay in this drawer."
	box.add_child(inspector_text)
	var actions := HFlowContainer.new()
	pole_switch_button = _button("Switch pole", "Turn a pole on or off. The next screen shows what will stop before you confirm.")
	pole_switch_button.pressed.connect(_request_inspector_switch)
	actions.add_child(pole_switch_button)
	pole_reset_button = _button("Reset breaker", "A tripped breaker needs crew time and one material to reset.")
	pole_reset_button.pressed.connect(_request_reset_breaker)
	actions.add_child(pole_reset_button)
	toggle_work_button = _button("Toggle work", "Turn this building's work on or off for 0.25 crew-hours. Heaters still run at night. Life support can't be switched off.")
	toggle_work_button.pressed.connect(_request_toggle_work)
	actions.add_child(toggle_work_button)
	rover_dispatch_button = _button("DISPATCH", "Choose a sample site in range. The cost and Nomad-1 battery use appear before launch.")
	rover_dispatch_button.pressed.connect(_start_rover_dispatch)
	actions.add_child(rover_dispatch_button)
	rover_recover_button = _button("RECOVER", "Pull a stuck Nomad-1 out of soft sand. Cost appears before confirming.")
	rover_recover_button.pressed.connect(_request_rover_recovery)
	actions.add_child(rover_recover_button)
	rover_charge_button = _button("CHARGE FROM GRID", "Charge Nomad-1 from an energized power pole. The preview shows the grid power used.")
	rover_charge_button.pressed.connect(_request_rover_charge)
	actions.add_child(rover_charge_button)
	box.add_child(actions)
	inspector_panel.visible = false
	ui_root.add_child(inspector_panel)

func _request_toggle_work() -> void:
	if selected_building_id == "": return
	var result: Dictionary = Grid.apply_action(state, Grid.action("toggle_work", selected_building_id, tuning))
	if bool(result["ok"]):
		state = result["state"]
		sol_changes.append_array(result["changes"])
	else:
		hud_hint.text = "Can't toggle: %s" % result["reason"]
	_refresh_all()
	refresh_forecast()   # the night forecast chart updates immediately

func _building_by_id(id: String) -> Dictionary:
	for building: Dictionary in state.buildings:
		if str(building.get("id", "")) == id: return building
	return {}
	
func _build_data_screen() -> void:
	data_panel = PanelContainer.new()
	data_panel.anchor_left = 0.5
	data_panel.anchor_right = 0.5
	data_panel.anchor_top = 0.5
	data_panel.anchor_bottom = 0.5
	data_panel.offset_left = -380
	data_panel.offset_right = 380
	data_panel.offset_top = -300
	data_panel.offset_bottom = 300
	data_panel.add_theme_stylebox_override("panel", _style(Color("0b1722"), Color("75a6bb")))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	data_panel.add_child(box)
	var title := _label("Data & Sources", 22, GOLD)
	box.add_child(title)
	var intro := _label("Archived facts are labeled. Game-mode rates are exaggerated for play. No data is called live unless a NASA request succeeds.", 13, TEXT)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(intro)
	data_mode_button = _button("Real Mars mode: Off", "Use the real preset rates where a sourced value is available; all other values stay marked UNVERIFIED.")
	data_mode_button.pressed.connect(_toggle_real_mars_mode)
	box.add_child(data_mode_button)
	var live_button := _button("Fetch last 7 Earth days from NASA DONKI", "Optional internet request. A NASA_API_KEY environment variable is used when present; otherwise DEMO_KEY is used.")
	live_button.pressed.connect(_request_live_donki)
	box.add_child(live_button)
	live_data_status = _label("Archive is loaded. Live data has not been requested.", 12, Color("bed0dd"))
	live_data_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(live_data_status)
	donki_request = HTTPRequest.new()
	donki_request.timeout = 15.0
	donki_request.request_completed.connect(_on_donki_request_completed)
	ui_root.add_child(donki_request)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for record: Dictionary in DataSources.RECORDS:
		var row := RichTextLabel.new()
		row.bbcode_enabled = true
		row.fit_content = true
		row.scroll_active = false
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var source := "[b]%s[/b]" % str(record["name"])
		if str(record["url"]).begins_with("https://"):
			source = "[url=%s]%s[/url]" % [str(record["url"]), str(record["name"])]
		row.text = "[b]%s[/b] · %s · %s\n%s\n%s" % [source, record["label"], record["status"], record["drives"], record["fact"]]
		row.meta_clicked.connect(func(meta: Variant) -> void: OS.shell_open(str(meta)))
		list.add_child(row)
	scroll.add_child(list)
	box.add_child(scroll)
	var close := _button("Close", "Return to the outpost.")
	close.pressed.connect(func() -> void: data_panel.visible = false)
	box.add_child(close)
	data_panel.visible = false
	ui_root.add_child(data_panel)

func _toggle_real_mars_mode() -> void:
	real_mars_mode = not real_mars_mode
	tuning = Tuning.preset("real" if real_mars_mode else "game")
	for battery: Dictionary in state.batteries:
		var previous_capacity := maxf(0.001, float(battery.get("capacity", 1.0)))
		var charge_fraction := float(battery.get("charge", 0.0)) / previous_capacity
		var next_capacity := float(tuning["battery_capacity"])
		battery["capacity"] = next_capacity
		battery["charge"] = next_capacity * clampf(charge_fraction, 0.0, 1.0)
	var pole_tiers: Dictionary = tuning["pole_tiers"]
	for pole: Dictionary in state.poles:
		var tier := int(pole.get("tier", 1))
		var pole_spec: Dictionary = pole_tiers.get(tier, pole_tiers[1])
		pole["radius"] = pole_spec["radius"]
		pole["capacity"] = pole_spec["capacity"]
		pole["standby"] = pole_spec["standby"]
	data_mode_button.text = "Real Mars mode: %s" % ("On" if real_mars_mode else "Off")
	_refresh_all()
	refresh_forecast()

func _request_live_donki() -> void:
	var end_date := Time.get_date_dict_from_system()
	var start_date := Time.get_date_dict_from_unix_time(int(Time.get_unix_time_from_system()) - 7 * 86400)
	var end_text := "%04d-%02d-%02d" % [end_date["year"], end_date["month"], end_date["day"]]
	var start_text := "%04d-%02d-%02d" % [start_date["year"], start_date["month"], start_date["day"]]
	var request_error := donki_request.request(DataSources.donki_flare_url(start_text, end_text, DataSources.live_api_key()))
	if request_error != OK:
		live_data_status.text = "Live request could not start. The archived events remain available."
	else:
		live_data_status.text = "Asking NASA DONKI for recent solar flares… Archived events stay available if the request fails."

func _on_donki_request_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		live_data_status.text = "Live data was unavailable (HTTP %d). Using the clearly labeled archive." % response_code
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not parsed is Array:
		live_data_status.text = "NASA returned an unexpected response. Using the archive instead."
		return
	live_data_status.text = "Live NASA DONKI request succeeded: %d recent solar flare record(s). These are solar events, not automatic Mars impacts." % parsed.size()

func _build_preview() -> void:
	preview_panel = PanelContainer.new()
	preview_panel.anchor_left = 0.5
	preview_panel.anchor_right = 0.5
	preview_panel.anchor_top = 1.0
	preview_panel.anchor_bottom = 1.0
	preview_panel.offset_left = -270
	preview_panel.offset_right = 270
	preview_panel.offset_top = -114
	preview_panel.offset_bottom = -18
	preview_panel.add_theme_stylebox_override("panel", _style(PANEL, PANEL_EDGE))
	var row := HBoxContainer.new()
	preview_panel.add_child(row)
	preview_text = _label("Choose a tile.", 13, TEXT)
	preview_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preview_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(preview_text)
	preview_confirm = _button("Confirm", "Spend the shown costs and place or move the building.")
	preview_confirm.pressed.connect(_confirm_preview)
	row.add_child(preview_confirm)
	var cancel := _button("Cancel", "Cancel this placement or move. No resources are spent.")
	cancel.pressed.connect(_cancel_mode)
	row.add_child(cancel)
	preview_panel.visible = false
	ui_root.add_child(preview_panel)

func _build_modal() -> void:
	modal = PanelContainer.new()
	modal.anchor_left = 0.5
	modal.anchor_right = 0.5
	modal.anchor_top = 0.5
	modal.anchor_bottom = 0.5
	modal.offset_left = -330
	modal.offset_right = 330
	modal.offset_top = -270
	modal.offset_bottom = 270
	modal.add_theme_stylebox_override("panel", _style(Color("0b1722"), Color("75a6bb")))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	modal.add_child(box)
	modal_title = _label("Plan for night", 23, GOLD)
	box.add_child(modal_title)
	modal_text = _label("", 14, TEXT)
	modal_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(modal_text)
	story_options_box = VBoxContainer.new()
	story_options_box.add_theme_constant_override("separation", 7)
	story_options_box.visible = false
	box.add_child(story_options_box)
	modal_chart = ForecastChart.new()
	modal_chart.custom_minimum_size = Vector2(600, 210)
	box.add_child(modal_chart)
	var buttons := HBoxContainer.new()
	modal_confirm = _button("Start night", "Close planning and continue the simulation into the night.")
	modal_confirm.pressed.connect(_start_night)
	buttons.add_child(modal_confirm)
	modal_cancel = _button("Cancel", "Close this confirmation without changing the grid.")
	modal_cancel.pressed.connect(_close_modal)
	buttons.add_child(modal_cancel)
	box.add_child(buttons)
	modal.visible = false
	ui_root.add_child(modal)

func _build_debrief() -> void:
	debrief_toast = PanelContainer.new()
	debrief_toast.anchor_left = 1.0
	debrief_toast.anchor_right = 1.0
	debrief_toast.anchor_top = 0.0
	debrief_toast.anchor_bottom = 0.0
	debrief_toast.offset_left = -420.0
	debrief_toast.offset_right = -18.0
	debrief_toast.offset_top = 84.0
	debrief_toast.offset_bottom = 220.0
	debrief_toast.add_theme_stylebox_override("panel", _style(PANEL, PANEL_EDGE))
	debrief_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debrief_toast_text = _label("Sol report", 12, TEXT)
	debrief_toast_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	debrief_toast_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	debrief_toast.add_child(debrief_toast_text)
	debrief_toast.visible = false
	ui_root.add_child(debrief_toast)

func _button(caption: String, tip: String) -> Button:
	var button := Button.new()
	button.text = caption
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_ALL
	button.add_theme_font_size_override("font_size", 13)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", Color("f1fbff"))
	button.add_theme_color_override("font_pressed_color", CYAN)
	button.add_theme_color_override("font_disabled_color", MUTED)
	button.add_theme_stylebox_override("normal", _button_style(Color("0d1d2b"), PANEL_EDGE))
	button.add_theme_stylebox_override("hover", _button_style(Color("132d3c"), CYAN))
	button.add_theme_stylebox_override("pressed", _button_style(Color("183b4c"), CYAN))
	button.add_theme_stylebox_override("focus", _button_style(Color("0d1d2b"), GOLD))
	button.add_theme_stylebox_override("disabled", _button_style(Color("0b1722"), Color("29424f")))
	return button

func _button_style(fill: Color, edge: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = edge
	style.set_border_width_all(1)
	style.set_corner_radius_all(0)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style

func _tag_existing_sprites() -> void:
	var known := {
		"ares_command_habitat": "habitat", "demeter_greenhouse": "greenhouse",
		"aquifer_water_recycler": "water_recycler", "sagan_sample_lab": "laboratory",
		"storm_shelter": "storm_shelter", "deep_space_comms": "antenna",
		"vulcan_rover_garage": "workshop", "helios_solar_farm": "solar_array:1",
	}
	for node in world.get_children():
		if not node is Sprite2D: continue
		var id := str(known.get(str(node.name), ""))
		if id != "":
			node.set_meta("building_id", id)
			node.set_meta("grid_offset_y", -26.0)
			if id.begins_with("solar_array:"):
				for panel: Dictionary in state.solar_arrays:
					if "solar_array:%d" % int(panel.get("id", 0)) == id: node.set_meta("grid_tile", panel["tile"])
			else:
				for building: Dictionary in state.buildings:
					if str(building.get("id", "")) == id: node.set_meta("grid_tile", building["tile"])
	for item in [{"id": "airlock", "tile": Vector2i(33, 32), "offset": Vector2(0, -22)},
		{"id": "battery:1", "tile": Vector2i(28, 34), "offset": Vector2(0, -22)},
		{"id": "oxygen_generator", "tile": Vector2i(37, 32), "offset": Vector2(0, -22)},
		{"id": "hydroponics", "tile": Vector2i(35, 29), "offset": Vector2(0, -22)}]:
		var target: Vector2 = world.call("_grid_to_iso", item["tile"].x, item["tile"].y) + item["offset"]
		var closest: Sprite2D
		var closest_distance := 8.0
		for node in world.get_children():
			if node is Sprite2D and not node.has_meta("building_id"):
				var distance: float = node.position.distance_to(target)
				if distance < closest_distance:
					closest = node
					closest_distance = distance
		if closest != null:
			closest.set_meta("building_id", item["id"])
			closest.set_meta("grid_tile", item["tile"])
			closest.set_meta("grid_offset_y", -22.0)

func _camera_keys(delta: float) -> void:
	if world == null: return
	var camera: Camera2D = world.get("camera")
	if camera == null: return
	if rover_following:
		var rover := world.find_child("Nomad-1 Rover", true, false) as Sprite2D
		if rover != null: camera.position = rover.position
		return
	var motion := Vector2.ZERO
	if Input.is_key_pressed(KEY_A): motion.x -= 1.0
	if Input.is_key_pressed(KEY_D): motion.x += 1.0
	if Input.is_key_pressed(KEY_W): motion.y -= 1.0
	if Input.is_key_pressed(KEY_S): motion.y += 1.0
	if motion != Vector2.ZERO: camera.position += motion.normalized() * 700.0 * delta / camera.zoom.x

func _label(caption: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.tooltip_text = caption
	return label

func _select_build_type(kind: String) -> void:
	active_build_type = kind
	move_mode = false
	moving_building_id = ""
	build_drawer_button.button_pressed = true
	build_panel.visible = true
	_layout_interface()
	preview_panel.visible = true
	preview_text.text = "Move the pointer to choose a tile. Costs: %s" % _build_cost_text(kind)
	_update_preview()

func _start_move_mode() -> void:
	active_build_type = ""
	move_mode = true
	moving_building_id = ""
	moving_destination = Vector2i(-1, -1)
	preview_panel.visible = true
	preview_text.text = "Click a non-fixed building, then choose its new tile."
	preview_confirm.disabled = true

func _toggle_follow() -> void:
	rover_following = not rover_following
	follow_button.button_pressed = rover_following
	follow_button.text = "ROVER CAM · ON" if rover_following else "ROVER CAM"

func _start_rover_dispatch() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty() or bool(rover.get("stuck", false)) or str(rover.get("status", "ready")) in ["dispatched", "traveling"]:
		return
	active_build_type = ""
	move_mode = false
	moving_building_id = ""
	rover_dispatch_mode = true
	preview_locked = false
	preview_panel.visible = true
	preview_confirm.disabled = true
	preview_text.text = "Click a sample site in range. The crew, grid and rover-battery costs appear before launch."
	_update_preview()

func _request_rover_recovery() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty() or not bool(rover.get("stuck", false)): return
	var cost: Dictionary = tuning["action_costs"]["rover_recover"]
	var recovery_tile := _nearest_rover_recovery_tile(rover)
	modal_title.text = "Recover Nomad-1?"
	modal_text.text = "Pull the rover out of soft sand and tow it to the nearest pole at (%d, %d). Cost: %s." % [recovery_tile.x, recovery_tile.y, _cost_text(cost)]
	modal_text.tooltip_text = "Crew time is the hours the astronauts spend on this job. Grid power comes from the outpost battery."
	modal_chart.visible = false
	modal_confirm.visible = true
	modal_confirm.text = "Recover rover"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(_confirm_rover_recovery, CONNECT_ONE_SHOT)
	modal_cancel.visible = true
	modal.visible = true

func _confirm_rover_recovery() -> void:
	var result: Dictionary = Grid.apply_action(state, RoverSystem.recovery_action("Nomad-1", tuning))
	if bool(result.get("ok", false)):
		state = result["state"]
		var rover := _rover_by_id("Nomad-1")
		if not rover.is_empty(): rover["tile"] = _nearest_rover_recovery_tile(rover)
		sol_changes.append_array(result["changes"])
		_sync_rover_visual()
	_refresh_all()
	_return_to_planning_or_close()

func _nearest_rover_recovery_tile(rover: Dictionary) -> Vector2i:
	var from_tile: Vector2i = rover.get("tile", Vector2i.ZERO)
	if state.poles.is_empty(): return from_tile
	var grid: Dictionary = Grid.compute_grid(state, tuning)
	var energized: Array = grid.get("energized_poles", [])
	var best_tile: Vector2i = state.poles[0].get("tile", from_tile)
	var best_distance := INF
	for pole: Dictionary in state.poles:
		if not energized.is_empty() and not energized.has(int(pole.get("id", -1))): continue
		var tile: Vector2i = pole.get("tile", from_tile)
		var distance := Vector2(from_tile).distance_to(Vector2(tile))
		if distance < best_distance:
			best_distance = distance
			best_tile = tile
	return best_tile

func _request_rover_charge() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty(): return
	var next: State = State.from_data(state.to_data())
	var amount := maxf(0.0, float(rover.get("capacity", 0.0)) - float(rover.get("charge", 0.0)))
	var quote: Dictionary = RoverSystem.charge_from_grid(next, "Nomad-1", amount, tuning)
	if not bool(quote.get("ok", false)):
		hud_hint.text = "Can't charge Nomad-1: %s" % str(quote.get("reason", "grid unavailable"))
		return
	rover_charge_request = amount
	modal_title.text = "Charge Nomad-1 from the grid?"
	modal_text.text = "Nomad-1 gains %.0f charge. The outpost supplies %.0f shared power now." % [float(quote["power_used"]), float(quote["battery_used"])]
	modal_chart.visible = false
	modal_confirm.visible = true
	modal_confirm.text = "Charge rover"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(_confirm_rover_charge, CONNECT_ONE_SHOT)
	modal_cancel.visible = true
	modal.visible = true

func _confirm_rover_charge() -> void:
	var next: State = State.from_data(state.to_data())
	var result: Dictionary = RoverSystem.charge_from_grid(next, "Nomad-1", rover_charge_request, tuning)
	if bool(result.get("ok", false)):
		state = next
		sol_changes.append({"cause": "rover_charge", "detail": "Charged Nomad-1 from the shared grid"})
		_update_rover_label()
	_refresh_all()
	refresh_forecast()
	_return_to_planning_or_close()

func _rover_grid_connected(rover: Dictionary) -> bool:
	var grid: Dictionary = Grid.compute_grid(state, tuning)
	var tile: Vector2i = rover.get("tile", Vector2i.ZERO)
	for pole: Dictionary in state.poles:
		if grid["energized_poles"].has(int(pole.get("id", -1))) and Grid._distance(tile, pole.get("tile", Vector2i.ZERO)) <= float(pole.get("radius", 0.0)):
			return true
	return false

func _select_building_or_pole(tile: Vector2i) -> void:
	if _rover_near_mouse():
		selected_rover_inspector = true
		selected_pole_id = -1
		selected_building_id = ""
		inspector_open = true
		if inspector_toggle_button != null: inspector_toggle_button.button_pressed = true
		_layout_interface()
		_refresh_all()
		return
	selected_rover_inspector = false
	var pole_id := _pole_at_tile(tile)
	if pole_id > 0:
		selected_pole_id = pole_id
		selected_building_id = ""
		inspector_open = true
		if inspector_toggle_button != null: inspector_toggle_button.button_pressed = true
		_layout_interface()
		_refresh_all()
		return
	var building := _building_by_id(str(_building_near_mouse().get("id", "")))
	if not building.is_empty():
		selected_rover_inspector = false
		selected_building_id = str(building.get("id", ""))
		selected_pole_id = -1
		inspector_open = true
		if inspector_toggle_button != null: inspector_toggle_button.button_pressed = true
		_layout_interface()
		_refresh_all()

func _rover_near_mouse() -> bool:
	if rover_sprite == null or world == null or world.camera == null:
		return false
	return world.camera.get_global_mouse_position().distance_to(rover_sprite.position) <= 52.0

func _rover_by_id(rover_id: String) -> Dictionary:
	if state == null: return {}
	for rover: Dictionary in state.rovers:
		if str(rover.get("id", "")) == rover_id: return rover
	return {}

func _sync_rover_visual() -> void:
	if world == null or state == null: return
	rover_sprite = world.find_child("Nomad-1 Rover", true, false) as Sprite2D
	if rover_sprite == null: return
	rover_world_label = null
	for child in world.get_children():
		if child is Label and str(child.text).begins_with("NOMAD-1"):
			rover_world_label = child as Label
			break
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty(): return
	var tile: Vector2i = rover.get("tile", Vector2i.ZERO)
	var tile_pos: Vector2 = world.call("_grid_to_iso", tile.x, tile.y)
	_set_rover_visual_position(tile_pos + Vector2(0, -10))
	_update_rover_label()

func _update_rover_label() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty() or rover_world_label == null: return
	var charge := float(rover.get("charge", 0.0))
	var capacity := maxf(0.1, float(rover.get("capacity", 1.0)))
	rover_world_label.text = "NOMAD-1 (%.0f%%)" % (charge / capacity * 100.0)
	if selected_rover_inspector:
		_refresh_inspector()

func _building_at_tile(tile: Vector2i) -> Dictionary:
	for building: Dictionary in state.buildings:
		if building.get("tile", Vector2i(-1, -1)) == tile: return building
	for panel: Dictionary in state.solar_arrays:
		if panel.get("tile", Vector2i(-1, -1)) == tile:
			return {"id": "solar_array:%d" % int(panel.get("id", 0)), "tile": tile, "fixed": false, "size_factor": 1.5}
	for battery: Dictionary in state.batteries:
		if battery.get("tile", Vector2i(-1, -1)) == tile:
			return {"id": "battery:%d" % int(battery.get("id", 0)), "tile": tile, "fixed": false, "size_factor": 1.5}
	return {}

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_HOME:
			rover_following = false
			var camera: Camera2D = world.get("camera")
			camera.position = world.call("_grid_to_iso", 32, 32)
			camera.zoom = Vector2(0.6, 0.6)
			get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_F:
			_toggle_follow(); get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_ESCAPE and (active_build_type != "" or rover_dispatch_mode or moving_building_id != "" or preview_panel.visible):
			_cancel_mode(); get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_G:
			show_grid = not show_grid; _refresh_all(); get_viewport().set_input_as_handled(); return
		if event.keycode == KEY_ENTER and planning_screen:
			_start_night(); get_viewport().set_input_as_handled(); return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if event.double_click and not move_mode and not rover_dispatch_mode and active_build_type == "":
			var camera: Camera2D = world.get("camera")
			rover_following = false
			camera.position = camera.get_global_mouse_position()
			get_viewport().set_input_as_handled()
			return
		var tile := _mouse_tile()
		if rover_dispatch_mode:
			preview_tile = tile
			preview_locked = true
			_update_preview()
			get_viewport().set_input_as_handled()
			return
		if active_build_type != "":
			preview_tile = tile
			preview_locked = true
			_update_preview()
			get_viewport().set_input_as_handled()
			return
		if move_mode and moving_building_id == "":
			var building := _building_near_mouse()
			if not building.is_empty() and not bool(building.get("fixed", false)):
				moving_building_id = str(building.get("id", ""))
				preview_locked = false
				_update_preview()
			else:
				preview_text.text = "Choose a movable building. Habitat and airlock stay fixed."
			get_viewport().set_input_as_handled()
			return
		if move_mode and moving_building_id != "":
			if tile == _building_tile(moving_building_id):
				moving_building_id = ""
				preview_locked = false
			else:
				preview_tile = tile
				preview_locked = true
				_update_preview()
			get_viewport().set_input_as_handled()
			return
		if preview_panel.visible:
			return
		if show_grid and _pole_at_tile(tile) > 0:
			_request_switch_pole(_pole_at_tile(tile))
			get_viewport().set_input_as_handled()
			return
		_select_building_or_pole(tile)

func _mouse_tile() -> Vector2i:
	var pos: Vector2 = world.camera.get_global_mouse_position()
	return Vector2i(roundi(pos.x / 128.0 + pos.y / 64.0), roundi(pos.y / 64.0 - pos.x / 128.0))

func _update_preview() -> void:
	if active_build_type == "" and not move_mode and not rover_dispatch_mode:
		return
	if not preview_locked:
		preview_tile = _mouse_tile()      # was: preview_tile = _mouse_tile())
	if rover_dispatch_mode:
		_update_rover_preview()
		return
	if move_mode and moving_building_id == "":
		preview_valid = false
		preview_confirm.disabled = true
		preview_text.text = "Click a non-fixed building to move it."
		return
	var kind := active_build_type if not move_mode else "building"
	var terrain: String = world.call("_terrain_type", preview_tile.x, preview_tile.y)
	var validation: Dictionary = PlacementRules.validate(state, preview_tile, kind, terrain, true, tuning)
	preview_valid = bool(validation["valid"])
	preview_reason = str(validation["reason"])
	preview_confirm.disabled = not preview_valid
	if not move_mode:
		preview_text.text = "%s at (%d, %d) · %s\n%s" % [_nice_name(kind), preview_tile.x, preview_tile.y, "Ready" if preview_valid else preview_reason, _build_cost_text(kind)]
	else:
		moving_destination = preview_tile
		var action_data := Grid.move_building_action(state, moving_building_id, preview_tile, tuning)
		var connections := _move_connection_summary(action_data)
		preview_text.text = "Move %s to (%d, %d) · %s\nCost: %s · Offline %d Sols\n%s" % [moving_building_id, preview_tile.x, preview_tile.y, "Ready" if preview_valid else preview_reason, _cost_text(action_data["cost"]), int(action_data["downtime"]), connections]
	preview_text.tooltip_text = preview_reason
	_refresh_inspector()

func _update_rover_preview() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty():
		preview_valid = false
		preview_confirm.disabled = true
		preview_text.text = "Nomad-1 is not available."
		return
	var terrain: String = str(world.call("_terrain_type", preview_tile.x, preview_tile.y))
	var quote: Dictionary = RoverSystem.dispatch_preview(rover, preview_tile, terrain, tuning)
	var action_data: Dictionary = RoverSystem.dispatch_action("Nomad-1", preview_tile, tuning)
	var rover_can_travel := bool(quote.get("valid", false))
	var can_pay := _story_action_affordable(action_data)
	preview_valid = rover_can_travel and can_pay
	preview_reason = str(quote.get("reason", "cannot travel there")) if not rover_can_travel else "not enough crew time or shared battery" if not can_pay else str(quote.get("reason", "ready"))
	preview_confirm.disabled = not preview_valid
	var rover_cost := float(quote.get("rover_charge", 0.0))
	var return_risk := "\nRETURN RISK: charge may be too low to return." if bool(quote.get("may_get_stuck", false)) else ""
	preview_text.text = "NOMAD-1 to (%d, %d) · %s\nCrew + grid: %s\nRover battery: −%.0f · Sample: %s%s" % [preview_tile.x, preview_tile.y, "Ready" if preview_valid else preview_reason, _cost_text(action_data["cost"]), rover_cost, str(quote.get("sample", "—")), return_risk]
	preview_text.tooltip_text = preview_reason

func _confirm_preview() -> void:
	if not preview_valid: return
	if rover_dispatch_mode:
		_execute_rover_dispatch()
		return
	var action_data: Dictionary
	if moving_building_id != "":
		action_data = Grid.move_building_action(state, moving_building_id, preview_tile, tuning)
		pending_kind = "move"
	else:
		match active_build_type:
			"solar_array": action_data = Grid.place_solar_array_action(preview_tile, tuning)
			"battery": action_data = Grid.place_battery_action(preview_tile, tuning)
			"power_pole": action_data = Grid.place_pole_action(preview_tile, 1, 0, tuning)
			"weather_station": action_data = Grid.place_weather_station_action(preview_tile, tuning)
			_: return
		pending_kind = "placement"
	pending_action = action_data
	_execute_pending_action()

func _execute_rover_dispatch() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty(): return
	var destination := preview_tile
	var terrain: String = str(world.call("_terrain_type", destination.x, destination.y))
	var quote: Dictionary = RoverSystem.dispatch_preview(rover, destination, terrain, tuning)
	if not bool(quote.get("valid", false)):
		preview_text.text = "Can't dispatch: %s" % str(quote.get("reason", "choose another tile"))
		return
	var action_data: Dictionary = RoverSystem.dispatch_action("Nomad-1", destination, tuning)
	var result: Dictionary = Grid.apply_action(state, action_data)
	if not bool(result.get("ok", false)):
		preview_text.text = "Can't dispatch: %s" % str(result.get("reason", "not enough supplies"))
		return
	state = result["state"]
	var travel_rover := _rover_by_id("Nomad-1")
	travel_rover["charge"] = maxf(0.0, float(travel_rover.get("charge", 0.0)) - float(quote["rover_charge"]))
	travel_rover["status"] = "traveling"
	travel_rover["mission_target"] = destination
	travel_rover["return_risk"] = bool(quote.get("may_get_stuck", false))
	sol_changes.append_array(result["changes"])
	_cancel_mode()
	_refresh_all()
	refresh_forecast()
	if rover_sprite == null: _sync_rover_visual()
	if rover_sprite == null:
		_complete_rover_trip()
		return
	var from_position := rover_sprite.position
	var tile_position: Vector2 = world.call("_grid_to_iso", destination.x, destination.y)
	var to_position := tile_position + Vector2(0, -10)
	var distance := float(quote.get("distance", 1.0))
	rover_travel_tween = create_tween()
	rover_travel_tween.tween_method(Callable(self, "_set_rover_visual_position"), from_position, to_position, maxf(0.35, distance * 0.08))
	rover_travel_tween.finished.connect(_complete_rover_trip, CONNECT_ONE_SHOT)
	_update_rover_label()

func _complete_rover_trip() -> void:
	var rover := _rover_by_id("Nomad-1")
	if rover.is_empty(): return
	var destination: Vector2i = rover.get("mission_target", rover.get("tile", Vector2i.ZERO))
	rover["tile"] = destination
	rover.erase("mission_target")
	rover["status"] = "ready"
	var terrain: String = str(world.call("_terrain_type", destination.x, destination.y))
	var sample_result: Dictionary = RoverSystem.collect_sample(state, "Nomad-1", terrain)
	if bool(sample_result.get("ok", false)):
		var sample: Dictionary = sample_result["sample"]
		sol_changes.append({"cause": "rover_sample", "detail": "Nomad-1 collected %s at (%d, %d)" % [str(sample.get("type", "a sample")), destination.x, destination.y]})
		hud_hint.text = "Sample collected: %s" % str(sample.get("type", "sample"))
	else:
		_show_toast("Nomad-1 returned without a sample: %s" % str(sample_result.get("reason", "no sample found")))
	var stranded := bool(rover.get("return_risk", false))
	rover.erase("return_risk")
	if stranded:
		rover["stuck"] = true
		rover["status"] = "stuck"
		_show_toast("Nomad-1 collected its sample but needs a tow. Select it and choose RECOVER.")
	_sync_rover_visual()
	_refresh_all()

func _set_rover_visual_position(world_position: Vector2) -> void:
	if rover_sprite == null: return
	rover_sprite.position = world_position
	rover_sprite.z_index = 300 + roundi(world_position.y + 10.0) + 2
	if rover_world_label != null:
		rover_world_label.position = world_position + Vector2(-160, 28)
		rover_world_label.z_index = 300 + roundi(world_position.y + 10.0) + 3

func _execute_pending_action() -> void:
	var result: Dictionary = Grid.apply_action(state, pending_action)
	if not bool(result["ok"]):
		preview_text.text = "Could not do that: %s" % result["reason"]
		return
	state = result["state"]
	sol_changes.append_array(result["changes"])
	if pending_kind == "placement": _add_placed_visual(pending_action)
	if pending_kind == "move": _move_building_visual(str(pending_action["target_id"]), pending_action["tile"])
	_cancel_mode()
	_refresh_all()
	refresh_forecast()
	pending_action.clear()

func _add_placed_visual(action_data: Dictionary) -> void:
	var kind := str(action_data["type"])
	if kind == "place_pole":
		queue_redraw()
		return
	var tile: Vector2i = action_data["tile"]
	var frame := "solar_farm_lvl1" if kind == "place_solar_array" else "battery_storage"
	var pos: Vector2 = world.call("_grid_to_iso", tile.x, tile.y)
	var sprite: Sprite2D = world.call("_add_atlas_sprite", world, world.get("buildings_atlas"), world.get("building_frames"), frame, pos + Vector2(0, -22), 300 + roundi(pos.y), 0.86)
	var source_id := "solar_array:%d" % int(state.solar_arrays[-1].get("id", 0)) if kind == "place_solar_array" else "battery:%d" % int(state.batteries[-1].get("id", 0))
	sprite.name = "%s_%d" % [kind, state.solar_arrays.size() if kind == "place_solar_array" else state.batteries.size()]
	sprite.set_meta("grid_tile", tile)
	sprite.set_meta("grid_kind", kind)
	sprite.set_meta("building_id", source_id)
	sprite.set_meta("grid_offset_y", -22.0)

func _move_building_visual(building_id: String, tile: Vector2i) -> void:
	var pos: Vector2 = world.call("_grid_to_iso", tile.x, tile.y)
	for node in world.get_children():
		if node is Sprite2D and node.has_meta("building_id") and str(node.get_meta("building_id")) == building_id:
			node.set_meta("grid_tile", tile)
			node.position = pos + Vector2(0, float(node.get_meta("grid_offset_y", -26.0)))
			node.z_index = 300 + roundi(pos.y)

func _cancel_mode() -> void:
	preview_locked = false     
	active_build_type = ""
	rover_dispatch_mode = false
	move_mode = false
	moving_building_id = ""
	moving_destination = Vector2i(-1, -1)
	preview_tile = Vector2i(-1, -1)
	preview_valid = false
	preview_panel.visible = false
	preview_confirm.disabled = true
	queue_redraw()

func _request_inspector_switch() -> void:
	if selected_pole_id > 0: _request_switch_pole(selected_pole_id)

func _request_switch_pole(pole_id: int) -> void:
	var pole := _pole_by_id(pole_id)
	if pole.is_empty(): return
	var next: State = State.from_data(state.to_data())
	for item: Dictionary in next.poles:
		if int(item["id"]) == pole_id: item["on"] = not bool(item.get("on", true))
	var before: Dictionary = Grid.compute_grid(state, tuning)
	var after: Dictionary = Grid.compute_grid(next, tuning)
	var stops: Array[String] = []
	for building: Dictionary in state.buildings:
		var id := str(building.get("id", ""))
		if before["assignments"].get(id) == pole_id and after["assignments"].get(id) != pole_id: stops.append(_nice_name(id))
	modal_title.text = "Turn %s %s?" % ["Pole %d" % pole_id, "off" if bool(pole.get("on", true)) else "on"]
	modal_text.text = "This switch costs 0.25 crew-hours.\n%s\nAt night, heaters keep running even when work is switched off." % ("Turning it off stops: " + ", ".join(stops) if not stops.is_empty() else "No buildings lose their grid connection.")
	modal_chart.visible = false
	modal_confirm.text = "Confirm switch"
	modal_confirm.tooltip_text = "Spend 0.25 crew-hours and change this pole's switch."
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(func() -> void: _confirm_switch(pole_id), CONNECT_ONE_SHOT)
	modal_cancel.visible = true
	modal.visible = true
	pending_kind = "switch"

func _confirm_switch(pole_id: int) -> void:
	var result: Dictionary = Grid.apply_action(state, Grid.action("switch", pole_id, tuning))
	if bool(result["ok"]):
		state = result["state"]
		sol_changes.append_array(result["changes"])
	_refresh_all()
	refresh_forecast()
	_return_to_planning_or_close()

func _request_reset_breaker() -> void:
	if selected_pole_id <= 0: return
	var pole := _pole_by_id(selected_pole_id)
	if pole.is_empty() or not bool(pole.get("tripped", false)): return
	modal_title.text = "Reset Pole %d breaker?" % selected_pole_id
	modal_text.text = "This costs 2 crew-hours and 1 material. A breaker trips when its pole carries too much power."
	modal_chart.visible = false
	modal_confirm.text = "Reset breaker"
	_clear_modal_confirm_actions()
	var pole_id := selected_pole_id
	modal_confirm.pressed.connect(func() -> void: _confirm_reset(pole_id), CONNECT_ONE_SHOT)
	modal.visible = true
	modal_cancel.visible = true

func _confirm_reset(pole_id: int) -> void:
	var result: Dictionary = Grid.apply_action(state, Grid.action("reset_breaker", pole_id, tuning))
	if bool(result["ok"]):
		state = result["state"]
		sol_changes.append_array(result["changes"])
	_refresh_all()
	refresh_forecast()
	_return_to_planning_or_close()

func _restore_planning_button() -> void:
	modal_confirm.text = "Start night"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(_start_night)
	modal_chart.visible = true
	modal_confirm.visible = true

func _clear_modal_confirm_actions() -> void:
	for connection: Dictionary in modal_confirm.pressed.get_connections():
		modal_confirm.pressed.disconnect(connection["callable"])

func _close_modal() -> void:
	_return_to_planning_or_close()

func _return_to_planning_or_close() -> void:
	if planning_screen:
		_open_planning_screen()
	else:
		modal.visible = false
		_restore_planning_button()

func _start_night() -> void:
	planning_screen = false
	is_paused = speed <= 0.0
	modal.visible = false
	_restore_planning_button()

func _simulation_hour() -> void:
	var previous_sol := state.sol
	var before_charge := _battery_charge()
	var was_reserve_fault := bool(state.flags.get("reserve_fault", false))
	var weather: Dictionary = Hazards.weather_for_sol(state)
	var result: Dictionary = Grid.tick(state, [], rng, weather, tuning)
	state = result["state"]
	last_generation = float(result["generation"])
	last_demand = float(result["demand"])
	var grid: Dictionary = result["grid"]
	for building: Dictionary in state.buildings:
		var id := str(building.get("id", ""))
		var building_power_load := float(grid["building_loads"].get(id, 0.0))
		if building_power_load > 0.0:
			var is_night := str(result["phase"]) == "Evening" or str(result["phase"]) == "Night"
			sol_changes.append({"cause": "power_use", "detail": "Power -%.1f: %s%s" % [building_power_load, _nice_name(id), " (heater on at night)" if is_night and float(building.get("heater_load", 0)) > 0 else ""]})
	for change: Dictionary in result["changes"]:
		sol_changes.append(change)
		if str(change.get("cause", "")) == "store_warning":
			_show_toast(str(change.get("detail", "A supply is running low.")))
	if state.sol != previous_sol:
		_show_debrief(before_charge, _battery_charge())
		var old_badges := BadgeSystem.load_earned()
		var new_badges := BadgeSystem.earned_for_state(state)
		BadgeSystem.save_earned(new_badges)
		for badge_id: String in new_badges:
			if not old_badges.has(badge_id):
				hud_hint.text = "Badge earned: %s" % str(BadgeSystem.BADGES.filter(func(item: Dictionary) -> bool: return item["id"] == badge_id)[0]["name"])
		state.hour = 0
		_maybe_show_story_dilemma()
	var critical_change: Dictionary = {}
	for change: Dictionary in result["changes"]:
		var cause := str(change.get("cause", ""))
		if cause == "overload" or cause == "dust_storm" or cause == "solar_particle_event" or (cause == "battery_reserve" and not was_reserve_fault):
			critical_change = change
			break
	if not critical_change.is_empty():
		if story_dilemma_open:
			queued_critical_event = critical_change
		else:
			_show_critical_event(critical_change)
	if bool(state.flags.get("mission_failed", false)):
		_show_failure(str(state.flags.get("failure_cause", "supplies")))
	var new_phase := Grid.phase_for_hour(state.hour)
	_refresh_all()
	refresh_forecast()
	if new_phase == "Evening" and str(result["phase"]) != "Evening" and not planning_screen and not bool(state.flags.get("mission_failed", false)):
		var night_forecast: Dictionary = Grid.forecast_night(state, weather, tuning)
		if night_forecast.get("reserve_hour") != null:
			_open_planning_screen()
		elif evening_notice_sol != state.sol:
			evening_notice_sol = state.sol
			_show_toast("Evening: your battery should last until dawn.")

func _show_debrief(before_charge: float, after_charge: float) -> void:
	var lines := PackedStringArray()
	lines.append("Sol %d complete, battery %.1f to %.1f" % [maxi(1, state.sol - 1), before_charge, after_charge])
	var shown := 0
	for change: Dictionary in sol_changes:
		if shown >= 3: break
		var cause := str(change.get("cause", "change"))
		var detail := str(change.get("detail", "Something changed"))
		if cause == "load_shedding" or cause == "overload" or cause == "battery_reserve":
			lines.append(detail)
			shown += 1
	debrief_toast_text.text = "\n".join(lines)
	debrief_toast_text.tooltip_text = "Why: power-use lines show building loads. Load-shedding means power was cut to save energy. A breaker trips to protect an overloaded pole."
	debrief_toast.visible = true
	debrief_toast.modulate.a = 1.0
	debrief_toast_time = 6.0
	sol_changes.clear()
	if state.sol > 30:
		_open_handover_report()

func _show_toast(message: String) -> void:
	debrief_toast_text.text = message
	debrief_toast_text.tooltip_text = "Crew reports update here. Important emergencies pause the outpost."
	debrief_toast.visible = true
	debrief_toast.modulate.a = 1.0
	debrief_toast_time = 6.0

func _show_critical_event(change: Dictionary) -> void:
	story_options_box.visible = false
	modal_title.text = "OUTPOST ALERT"
	modal_text.text = str(change.get("detail", "A critical system needs attention."))
	modal_chart.visible = false
	modal_confirm.text = "Continue"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(func() -> void: modal.visible = false; is_paused = false, CONNECT_ONE_SHOT)
	modal_cancel.visible = false
	modal.visible = true
	is_paused = true

func _maybe_show_story_dilemma() -> void:
	var chapter: Dictionary = Story.chapter_for_sol(state.sol)
	var dilemma_id := ""
	match str(chapter.get("id", "")):
		"first_power": dilemma_id = "panel_field"
		"findings": dilemma_id = "science_or_food"
		"storm": dilemma_id = "storm_prep"
		_: return
	var shown: Array = state.flags.get("story_dilemmas_shown", [])
	if shown.has(dilemma_id):
		return
	shown.append(dilemma_id)
	state.flags["story_dilemmas_shown"] = shown
	story_dilemma_open = true
	modal_title.text = "%s · Sol %d" % [str(chapter.get("name", "Chapter")), state.sol]
	modal_text.text = "%s\nChoose a plan. Each choice shows its costs and changes." % str(chapter.get("lesson", "Choose how to prepare."))
	modal_chart.visible = false
	modal_confirm.visible = false
	modal_cancel.visible = false
	for child in story_options_box.get_children():
		story_options_box.remove_child(child)
		child.queue_free()
	for option: Dictionary in Story.options_for(dilemma_id):
		var option_id := str(option.get("id", ""))
		var action_data: Dictionary = Story.choose_action(dilemma_id, option_id)
		var effects_text := _story_effect_text(action_data.get("effects", {}))
		var can_afford := _story_action_affordable(action_data)
		var option_text := "%s\n%s" % [str(option.get("option", "Choose")), effects_text]
		if not can_afford:
			option_text += "\nNeed more supplies"
		var button := _button(option_text, "This choice changes the supplies shown. It will appear in the handover report.")
		button.custom_minimum_size = Vector2(0, 54)
		button.disabled = not can_afford
		button.pressed.connect(func() -> void: _choose_story_option(dilemma_id, option_id))
		story_options_box.add_child(button)
	if story_options_box.get_child_count() == 0 or story_options_box.get_children().all(func(item: Node) -> bool: return (item as Button).disabled):
		var skip_button := _button("Keep the current plan\nNo cost · no change", "No resources are spent. This choice is recorded as keeping the current plan.")
		skip_button.custom_minimum_size = Vector2(0, 54)
		skip_button.pressed.connect(func() -> void: _choose_story_option(dilemma_id, "skip"))
		story_options_box.add_child(skip_button)
	story_options_box.visible = true
	modal.visible = true
	is_paused = true

func _choose_story_option(dilemma_id: String, option_id: String) -> void:
	var action_data: Dictionary
	if option_id == "skip":
		action_data = {"type": "event_choice", "choice_id": "skip", "option": "Keep the current plan", "effects": {}, "cost": {}}
	else:
		action_data = Story.choose_action(dilemma_id, option_id)
	var result: Dictionary = Grid.apply_action(state, action_data)
	if not bool(result.get("ok", false)):
		modal_text.text = "That plan needs more supplies: %s. Choose another plan." % str(result.get("reason", "not enough supplies"))
		return
	state = result["state"]
	sol_changes.append_array(result["changes"])
	story_dilemma_open = false
	modal.visible = false
	story_options_box.visible = false
	_restore_planning_button()
	is_paused = speed <= 0.0
	_refresh_all()
	refresh_forecast()
	if not queued_critical_event.is_empty():
		var event: Dictionary = queued_critical_event
		queued_critical_event.clear()
		_show_critical_event(event)

func _story_action_affordable(action_data: Dictionary) -> bool:
	var cost: Dictionary = action_data.get("cost", {})
	for key: String in cost:
		var amount := float(cost[key])
		if amount <= 0.0:
			continue
		var available := 0.0
		match key:
			"air": available = state.air
			"water": available = state.water
			"food": available = state.food
			"materials": available = state.materials
			"earth_parts": available = state.earth_parts
			"crew_hours": available = state.crew_hours
			"power": available = _battery_charge()
			_: available = 0.0
		if available < amount:
			return false
	return true

func _story_effect_text(effects: Dictionary) -> String:
	var lines: Array[String] = []
	for key: String in effects:
		var amount := float(effects[key])
		var label := key.replace("_", " ")
		if key == "power": label = "battery power"
		lines.append("%s %.1f %s" % ["+" if amount >= 0.0 else "−", absf(amount), label])
	return "Changes: " + (", ".join(lines) if not lines.is_empty() else "no supply change")

func _show_failure(cause: String) -> void:
	story_options_box.visible = false
	modal_title.text = "MISSION FAILED"
	modal_text.text = "The %s store ran out. The crew cannot continue." % cause
	modal_chart.visible = false
	modal_confirm.text = "Retry with a new seed"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(_retry_campaign, CONNECT_ONE_SHOT)
	modal_cancel.visible = false
	modal.visible = true
	is_paused = true

func _continue_debrief() -> void:
	if state.sol > 30:
		_open_handover_report()
		return
	modal.visible = false
	is_paused = false
	_restore_planning_button()

func _open_handover_report() -> void:
	var report: Dictionary = Story.handover_report(state)
	var lines := PackedStringArray()
	for key: String in report["ratings"].keys(): lines.append("%s: %s" % [key.capitalize(), str(report["ratings"][key])])
	lines.append("\nMost influential choices:")
	for decision: Dictionary in report["influential_decisions"]: lines.append("Sol %d · %s" % [int(decision["sol"]), str(decision["option"])])
	lines.append("\nRequests for next crew: %d" % report["next_crew_requests"].size())
	lines.append(str(report["learned"]))
	modal_title.text = "Handover Report · seed %d" % state.mission_seed
	modal_text.text = "\n".join(lines)
	modal_chart.visible = false
	modal_confirm.text = "Retry with a new seed"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(_retry_campaign, CONNECT_ONE_SHOT)
	modal_cancel.text = "Close report"
	modal_cancel.visible = true
	for connection: Dictionary in modal_cancel.pressed.get_connections():
		modal_cancel.pressed.disconnect(connection["callable"])
	modal_cancel.pressed.connect(func() -> void: modal.visible = false, CONNECT_ONE_SHOT)
	modal.visible = true
	BadgeSystem.write_mission_patch(state.mission_seed, BadgeSystem.load_earned(), "Jezero outpost")

func _retry_campaign() -> void:
	state = Story.retry_with_new_seed(state, tuning)
	rng.seed = state.mission_seed
	state.sol = 1
	state.hour = 6
	sol_changes.clear()
	planning_screen = false
	story_dilemma_open = false
	queued_critical_event.clear()
	is_paused = false
	last_generation = 0.0
	last_demand = 0.0
	modal.visible = false
	_refresh_all()
	refresh_forecast()

func _open_planning_screen() -> void:
	planning_screen = true
	is_paused = true
	_layout_interface()
	modal_title.text = "Evening plan · Sol %d" % state.sol
	modal_chart.visible = true
	modal_confirm.visible = true
	modal_confirm.text = "Start night"
	_clear_modal_confirm_actions()
	modal_confirm.pressed.connect(_start_night)
	modal_cancel.visible = false
	modal.visible = true
	refresh_forecast()

func refresh_forecast() -> void:
	if state == null: return
	var weather: Dictionary = Hazards.weather_for_sol(state)
	var forecast: Dictionary = Grid.forecast_night(state, weather, tuning)
	modal_chart.points = forecast["trajectory"]
	modal_chart.reserve = float(tuning["reserve_fraction"])
	modal_chart.capacity = maxf(1.0, _battery_capacity())
	modal_chart.reserve_hour = forecast["reserve_hour"]
	modal_chart.zero_hour = forecast["zero_hour"]
	var reserve_hour: Variant = forecast["reserve_hour"]
	var zero_hour: Variant = forecast["zero_hour"]
	if reserve_hour == null and zero_hour == null:
		modal_text.text = "Your battery lasts until dawn. Switches and heaters are included."
	elif zero_hour == null:
		modal_text.text = "Your battery stays above empty until dawn. It reaches reserve near %s. Heaters stay on at night." % _hour_label(int(reserve_hour))
	else:
		modal_text.text = "Your battery reaches empty near %s. %s" % [_hour_label(int(zero_hour)), "Switch off the lab to save power." if state.buildings.any(func(item: Dictionary) -> bool: return str(item.get("id", "")) == "laboratory") else "Try switching off a low-priority building to save power."]
	modal_chart.queue_redraw()
	_refresh_all()

func _refresh_all() -> void:
	_refresh_hud()
	_refresh_inspector()
	_update_build_button_states()
	grid_button.button_pressed = show_grid
	grid_button.text = "GRID · ON" if show_grid else "GRID · G"
	if preview_panel != null and preview_panel.visible: _update_preview()
	if clean_button != null: clean_button.disabled = state.crew_hours < 1.0
	queue_redraw()

func _refresh_hud() -> void:
	if state == null: return
	_update_rover_label()
	var active_weather: Dictionary = Hazards.weather_for_sol(state)
	var generation := Grid.solar_generation(state, tuning, active_weather)
	var charge := _battery_charge()
	var capacity := maxf(1.0, _battery_capacity())

	power_stat.title.text = "⚡ BATTERY  %.0f / %.0f   (use %.1f · solar %.1f)" % [charge, capacity, last_demand, generation]
	power_stat.bar.max_value = capacity
	power_stat.bar.value = charge

	air_stat.title.text = "AIR  %.1f" % state.air
	air_stat.bar.max_value = 3.0          # the starting amount
	air_stat.bar.value = state.air

	food_stat.title.text = "FOOD  %.1f" % state.food
	food_stat.bar.max_value = 3.6         # the starting amount
	food_stat.bar.value = state.food

	var dose_limit := float(tuning.get("dose_warning_limit_msv", 100.0))
	dose_stat.title.text = "DOSE  %.2f / %.0f mSv" % [state.dose, dose_limit]
	dose_stat.bar.max_value = dose_limit
	dose_stat.bar.value = state.dose
	var dose_fraction := state.dose / maxf(dose_limit, 0.001)
	var dose_color := GREEN if dose_fraction < 0.7 else GOLD if dose_fraction < 1.0 else RED
	(dose_stat.bar.get_theme_stylebox("fill") as StyleBoxFlat).bg_color = dose_color

	var phase := Grid.phase_for_hour(state.hour)
	var icon := "☀" if state.hour >= 6 and state.hour < 18 else "☾"
	var until_event := 18 - state.hour if state.hour < 18 else 6 + (24 - state.hour)
	var next_sun_event := "dusk" if state.hour < 18 else "dawn"
	hud_clock.text = "SOL %d  ·  %s %s\n%d h TO %s" % [state.sol, icon, phase.to_upper(), until_event, next_sun_event.to_upper()]
	hud_clock.tooltip_text = "Sol means Martian day. Battery reserve is the protected last 20%. A heater keeps modules warm during the night."
	
func _refresh_inspector() -> void:
	if inspector_text == null or state == null: return
	var building_selected := selected_pole_id <= 0 and selected_building_id != ""
	var rover_selected := selected_rover_inspector
	if toggle_work_button != null:
		var sel := _building_by_id(selected_building_id)
		toggle_work_button.visible = building_selected
		toggle_work_button.disabled = sel.is_empty() or bool(sel.get("life_support", false)) or state.crew_hours < 0.25
	if pole_switch_button != null:
		pole_switch_button.visible = selected_pole_id > 0
	if pole_reset_button != null:
		pole_reset_button.visible = selected_pole_id > 0 and bool(_pole_by_id(selected_pole_id).get("tripped", false))
	var rover: Dictionary = _rover_by_id("Nomad-1")
	if rover_dispatch_button != null:
		rover_dispatch_button.visible = rover_selected
		rover_dispatch_button.disabled = rover.is_empty() or bool(rover.get("stuck", false)) or str(rover.get("status", "ready")) in ["dispatched", "traveling"]
	if rover_recover_button != null:
		rover_recover_button.visible = rover_selected and not rover.is_empty() and bool(rover.get("stuck", false))
		rover_recover_button.disabled = state.crew_hours < float(tuning["action_costs"]["rover_recover"]["crew_hours"]) or _battery_charge() < float(tuning["action_costs"]["rover_recover"]["power"])
	if rover_charge_button != null:
		rover_charge_button.visible = rover_selected
		rover_charge_button.disabled = rover.is_empty() or not _rover_grid_connected(rover) or float(rover.get("charge", 0.0)) >= float(rover.get("capacity", 0.0))
	if rover_selected:
		var charge := float(rover.get("charge", 0.0))
		var capacity := maxf(0.1, float(rover.get("capacity", 1.0)))
		var samples: Array = rover.get("cargo_samples", [])
		inspector_title.text = "NOMAD-1 · ROVER"
		inspector_text.text = "Charge: %.0f / %.0f (%.0f%%)\nStatus: %s%s\nRange: %.0f tiles\nSamples: %d\n\nCrew: %.1f h · Shared battery: %.0f" % [charge, capacity, charge / capacity * 100.0, str(rover.get("status", "ready")).capitalize(), " · stuck" if bool(rover.get("stuck", false)) else "", float(rover.get("range", 0)), samples.size(), state.crew_hours, _battery_charge()]
		inspector_text.tooltip_text = "Rover charge powers travel. Range is the farthest Nomad-1 can drive from its current tile. A sample site must be in range."
		return
	if selected_pole_id > 0:
		var pole := _pole_by_id(selected_pole_id)
		var grid: Dictionary = Grid.compute_grid(state, tuning)
		var pole_load := float(grid["pole_loads"].get(selected_pole_id, 0.0))
		var covers: Array[String] = []
		for building: Dictionary in state.buildings:
			if Grid._distance(pole.get("tile", Vector2i.ZERO), building.get("tile", Vector2i.ZERO)) <= float(pole.get("radius", 0.0)):
				covers.append(_nice_name(str(building.get("id", ""))))
		var hops := int(grid["hop_counts"].get(selected_pole_id, 0))
		var loss := (1.0 - pow(1.0 - float(tuning["line_loss_per_hop"]), hops)) * 100.0
		inspector_title.text = "Pole %d" % selected_pole_id
		inspector_text.text = "Load: %.1f / %.1f power\nBuildings covered: %d\nLine loss: %.0f%%\nSwitch: %s%s\n\nWater: %.1f\nMaterials: %.0f\nEarth parts: %.0f\nCrew time: %.1f h" % [pole_load, float(pole.get("capacity", 0)), covers.size(), loss, "ON" if bool(pole.get("on", false)) else "OFF", " · breaker tripped" if bool(pole.get("tripped", false)) else "", state.water, state.materials, state.earth_parts, state.crew_hours]
		inspector_text.tooltip_text = "Load is power being used. Capacity is the most a pole can safely carry. Line loss is power lost on the wire path. A breaker trips to protect a pole from too much load."
	elif building_selected:
		var building := _building_by_id(selected_building_id)
		var grid: Dictionary = Grid.compute_grid(state, tuning)
		var is_powered: bool = grid["assignments"].get(selected_building_id) != null
		var faulted := bool(building.get("faulted", false)) or bool(building.get("low_power_fault", false))
		var work_text := "ON"
		if bool(building.get("life_support", false)): work_text = "ON (life support, can't be switched off)"
		elif not bool(building.get("work_enabled", true)): work_text = "OFF (saving power)"
		inspector_title.text = _nice_name(selected_building_id)
		inspector_text.text = "Grid: %s\nDraw now: %.2f power/hr\nWork: %s\nPriority: %s\nNight heater: %.2f/hr%s\n\nCrew time: %.1f h" % [
			"POWERED" if is_powered else "NO POWER",
			float(grid["building_loads"].get(selected_building_id, 0.0)),
			work_text, str(building.get("priority", "normal")),
			float(building.get("heater_load", 0.0)),
			"\nLow-power fault" if faulted else "",
			state.crew_hours]
		inspector_text.tooltip_text = "Draw is what this building uses right now. Turning its work off saves that power, but the night heater keeps running."
	else:
		inspector_title.text = "Outpost stores"
		inspector_text.text = "Water: %.1f\nMaterials: %.0f\nEarth parts: %.0f\nCrew time: %.1f h\n\nClick a pole to inspect its load and switch. Click a building to see its power state." % [state.water, state.materials, state.earth_parts, state.crew_hours]
		inspector_text.tooltip_text = "Water, materials, Earth parts, and crew-hours are kept here so the top bar stays simple."
		
func _update_build_button_states() -> void:
	var needs := {"solar_array": {"materials": 10.0, "earth_parts": 1.0, "crew_hours": 3.0}, "battery": {"materials": 12.0, "earth_parts": 2.0, "crew_hours": 4.0}, "power_pole": {"materials": 8.0, "earth_parts": 1.0, "crew_hours": 2.0, "power": 1.0}, "weather_station": {"materials": 16.0, "earth_parts": 1.0, "crew_hours": 5.0}}
	for kind: String in build_buttons:
		var cost: Dictionary = needs[kind]
		var affordable := state.materials >= float(cost["materials"]) and state.earth_parts >= float(cost["earth_parts"]) and state.crew_hours >= float(cost["crew_hours"])
		if kind == "power_pole": affordable = affordable and _battery_charge() >= float(cost["power"])
		build_buttons[kind].disabled = not affordable
	if quick_pole_button != null:
		quick_pole_button.disabled = build_buttons["power_pole"].disabled

func _move_connection_summary(action_data: Dictionary) -> String:
	if total_cost_placeholder(action_data) <= 0.0: return "Fixed buildings cannot move."
	var result: Dictionary = Grid.apply_action(state, action_data)
	if not bool(result["ok"]): return "Move unavailable: %s" % result["reason"]
	var before: Dictionary = Grid.compute_grid(state, tuning)
	var after: Dictionary = Grid.compute_grid(result["state"], tuning)
	var changes: Array[String] = []
	for building: Dictionary in state.buildings:
		var id := str(building.get("id", ""))
		if before["assignments"].get(id) != after["assignments"].get(id): changes.append(_nice_name(id))
	return "Grid connections changing: " + (", ".join(changes) if not changes.is_empty() else "none")

func total_cost_placeholder(action_data: Dictionary) -> float:
	return Grid.total_cost(action_data)

func _pole_at_tile(tile: Vector2i) -> int:
	for pole: Dictionary in state.poles:
		if pole.get("tile", Vector2i(-1, -1)) == tile: return int(pole["id"])
	return -1

func _pole_by_id(id: int) -> Dictionary:
	for pole: Dictionary in state.poles:
		if int(pole.get("id", -1)) == id: return pole
	return {}

func _building_tile(id: String) -> Vector2i:
	for building: Dictionary in state.buildings:
		if str(building.get("id", "")) == id: return building.get("tile", Vector2i(-1, -1))
	if id.begins_with("solar_array:"):
		for panel: Dictionary in state.solar_arrays:
			if "solar_array:%d" % int(panel.get("id", 0)) == id: return panel.get("tile", Vector2i(-1, -1))
	if id.begins_with("battery:"):
		for battery: Dictionary in state.batteries:
			if "battery:%d" % int(battery.get("id", 0)) == id: return battery.get("tile", Vector2i(-1, -1))
	return Vector2i(-1, -1)

func _battery_charge() -> float:
	var total := 0.0
	for battery: Dictionary in state.batteries: total += float(battery.get("charge", 0.0))
	return total

func _battery_capacity() -> float:
	var total := 0.0
	for battery: Dictionary in state.batteries: total += float(battery.get("capacity", 0.0))
	return total

func _build_cost_text(kind: String) -> String:
	match kind:
		"solar_array": return "10 materials · 1 Earth part · 3 crew-hours"
		"battery": return "12 materials · 2 Earth parts · 4 crew-hours"
		"power_pole": return "8 materials · 1 Earth part · 2 crew-hours · 1 power"
	return ""

func _cost_text(cost: Dictionary) -> String:
	var parts: Array[String] = []
	for key: String in cost:
		parts.append("%.1f %s" % [float(cost[key]), key.replace("_", " ")])
	return ", ".join(parts)

func _nice_name(id: String) -> String:
	return id.replace("_", " ").capitalize() if id != "" else "Outpost"

func _hour_label(hour: int) -> String:
	var h := posmod(hour, 24)
	return "%d %s" % [h % 12 if h % 12 != 0 else 12, "AM" if h < 12 else "PM"]
