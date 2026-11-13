extends Node2D

const WORLD_SIZE := 64
const TILE_W := 128.0
const TILE_H := 64.0
const TILE_METERS := 50.0
const HEIGHT_PIXELS_PER_METER := 1.8
const HAB := Vector2i(32, 32)
const ELEVATION_MAP_PATH := "res://assets/outpost_zero/terrain/jezero_elevation_m.csv"

var terrain_atlas: Texture2D
var buildings_atlas: Texture2D
var rover_atlas: Texture2D
var terrain_frames: Dictionary
var building_frames: Dictionary
var rover_frames: Dictionary
var camera: Camera2D
var world_modulate: CanvasModulate
var terrain_elevations: PackedFloat32Array = PackedFloat32Array()
var base_elevation_m: float = 0.0
var dragging := false
var drag_origin := Vector2.ZERO
var _tex_cache := {}


func _ready() -> void:
	world_modulate = CanvasModulate.new()
	world_modulate.name = "Day Night Lighting"
	add_child(world_modulate)
	set_time_of_day(12.0)
	terrain_atlas = load("res://assets/outpost_zero/terrain/terrain_atlas.png")
	buildings_atlas = load("res://assets/outpost_zero/buildings/buildings_atlas.png")
	rover_atlas = load("res://assets/outpost_zero/vehicles/rover_spritesheet.png")
	terrain_frames = _read_frames("res://assets/outpost_zero/terrain/terrain_atlas.json")
	building_frames = _read_frames("res://assets/outpost_zero/buildings/buildings_atlas.json")
	rover_frames = _read_frames("res://assets/outpost_zero/vehicles/rover_atlas.json")
	_load_elevation_map()
	_build_world()
	_build_colony()
	_add_rover()
	_setup_camera()

func set_time_of_day(hour: float) -> void:
	if world_modulate == null:
		return
	var key_hours: Array[float] = [0.0, 5.0, 6.0, 8.0, 12.0, 16.0, 18.0, 19.5, 21.0, 24.0]
	var key_colors: Array[Color] = [
		Color(0.30, 0.34, 0.56),
		Color(0.30, 0.34, 0.56),
		Color(0.95, 0.62, 0.50),
		Color(1.0, 0.86, 0.75),
		Color(1.0, 1.0, 1.0),
		Color(1.0, 0.92, 0.82),
		Color(1.0, 0.54, 0.40),
		Color(0.45, 0.38, 0.60),
		Color(0.30, 0.34, 0.56),
		Color(0.30, 0.34, 0.56),
	]
	var normalized_hour: float = fposmod(hour, 24.0)
	for index in range(key_hours.size() - 1):
		if normalized_hour <= key_hours[index + 1]:
			var span: float = key_hours[index + 1] - key_hours[index]
			var weight: float = (normalized_hour - key_hours[index]) / span
			world_modulate.color = key_colors[index].lerp(key_colors[index + 1], weight)
			return
	world_modulate.color = key_colors[0]

func _load_elevation_map() -> void:
	terrain_elevations.resize(WORLD_SIZE * WORLD_SIZE)
	terrain_elevations.fill(0.0)
	var file: FileAccess = FileAccess.open(ELEVATION_MAP_PATH, FileAccess.READ)
	if file == null:
		push_warning("Jezero elevation map is missing; using level terrain.")
		return
	var row_index: int = 0
	while not file.eof_reached() and row_index < WORLD_SIZE:
		var line: String = file.get_line().strip_edges()
		if line.is_empty():
			continue
		var values: PackedStringArray = line.split(",")
		if values.size() != WORLD_SIZE:
			push_warning("Jezero elevation row %d has an invalid tile count." % row_index)
			continue
		for gx in range(WORLD_SIZE):
			terrain_elevations[row_index * WORLD_SIZE + gx] = float(values[gx])
		row_index += 1
	if row_index != WORLD_SIZE:
		push_warning("Jezero elevation map has %d of %d rows; remaining terrain will be level." % [row_index, WORLD_SIZE])
	base_elevation_m = _elevation_at(HAB.x, HAB.y)

func _elevation_at(gx: int, gy: int) -> float:
	if terrain_elevations.size() != WORLD_SIZE * WORLD_SIZE:
		return 0.0
	var safe_x: int = clampi(gx, 0, WORLD_SIZE - 1)
	var safe_y: int = clampi(gy, 0, WORLD_SIZE - 1)
	return float(terrain_elevations[safe_y * WORLD_SIZE + safe_x])

func _height_offset_px(gx: int, gy: int) -> float:
	return (_elevation_at(gx, gy) - base_elevation_m) * HEIGHT_PIXELS_PER_METER

func _terrain_slope(gx: int, gy: int) -> float:
	var west_x: int = maxi(0, gx - 1)
	var east_x: int = mini(WORLD_SIZE - 1, gx + 1)
	var north_y: int = maxi(0, gy - 1)
	var south_y: int = mini(WORLD_SIZE - 1, gy + 1)
	var east_run: float = maxf(1.0, float(east_x - west_x) * TILE_METERS)
	var north_run: float = maxf(1.0, float(south_y - north_y) * TILE_METERS)
	var slope_x: float = (_elevation_at(east_x, gy) - _elevation_at(west_x, gy)) / east_run
	var slope_y: float = (_elevation_at(gx, south_y) - _elevation_at(gx, north_y)) / north_run
	return sqrt(slope_x * slope_x + slope_y * slope_y)

func _local_roughness(gx: int, gy: int) -> float:
	var neighbor_total: float = 0.0
	var neighbor_count: int = 0
	for offset_y in range(-1, 2):
		for offset_x in range(-1, 2):
			if offset_x == 0 and offset_y == 0:
				continue
			var sample_x: int = gx + offset_x
			var sample_y: int = gy + offset_y
			if sample_x < 0 or sample_x >= WORLD_SIZE or sample_y < 0 or sample_y >= WORLD_SIZE:
				continue
			neighbor_total += _elevation_at(sample_x, sample_y)
			neighbor_count += 1
	if neighbor_count == 0:
		return 0.0
	var neighbor_mean: float = neighbor_total / float(neighbor_count)
	return absf(_elevation_at(gx, gy) - neighbor_mean)

func _read_frames(path: String) -> Dictionary:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed.get("frames", {}) if parsed is Dictionary else {}

func _frame_rect(frames: Dictionary, name: String) -> Rect2:
	var entry: Dictionary = frames.get(name, {})
	var frame: Dictionary = entry.get("frame", {})
	return Rect2(frame.get("x", 0), frame.get("y", 0), frame.get("w", 1), frame.get("h", 1))

func _atlas_texture(atlas: Texture2D, frames: Dictionary, name: String) -> AtlasTexture:
	var key := "%d:%s" % [atlas.get_instance_id(), name]
	if _tex_cache.has(key): return _tex_cache[key]
	var region := AtlasTexture.new()
	region.atlas = atlas
	region.region = _frame_rect(frames, name)
	_tex_cache[key] = region
	return region

func _grid_to_iso(gx: float, gy: float) -> Vector2:
	return Vector2((gx - gy) * TILE_W * 0.5, (gx + gy) * TILE_H * 0.5)

func _tile_hash(gx: int, gy: int) -> int:
	return abs((gx * 73856093) ^ (gy * 19349663)) % 100

func _terrain_type(gx: int, gy: int) -> String:
	var slope: float = _terrain_slope(gx, gy)
	var roughness: float = _local_roughness(gx, gy)
	var tile_noise: int = _tile_hash(gx, gy)
	if slope >= 0.12:
		return "cliff_ridge"
	if slope >= 0.085:
		return "rocky_hills"
	if roughness >= 1.8:
		return "geological_outcrop"
	if slope >= 0.045 and tile_noise >= 88:
		return "boulder_field"
	if slope >= 0.055 or (roughness >= 0.8 and tile_noise >= 65):
		return "rocky_plains"
	return "sand_dust"

func _terrain_frame(kind: String, gx: int, gy: int) -> String:
	var h := _tile_hash(gx, gy)
	match kind:
		"sand_dust": return "sand_patches" if h < 35 else ("dust_covered_terrain" if h < 65 else "mars_soil")
		"river_channel": return "ice_deposits" if h < 18 else "ancient_riverbed"
		"rocky_plains": return "small_rocks" if h < 35 else ("rocky_terrain" if h < 70 else "mars_soil")
		"crater_floor": return "ice_deposits" if h < 22 else "craters"
		"geological_outcrop": return "mineral_deposits"
		"boulder_field": return "large_boulders"
		"rocky_hills": return "rocky_terrain" if h < 50 else "small_rocks"
		"cliff_ridge": return "cliffs"
	return "mars_soil"

func _add_atlas_sprite(parent: Node, atlas: Texture2D, frames: Dictionary, frame_name: String, pos: Vector2, z: int, scale_factor := 1.0) -> Sprite2D:
	var sprite := Sprite2D.new()
	sprite.texture = _atlas_texture(atlas, frames, frame_name)
	sprite.position = pos
	sprite.z_index = z
	sprite.scale = Vector2.ONE * scale_factor
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	parent.add_child(sprite)
	return sprite

func _build_world() -> void:
	var ground := Node2D.new()
	ground.name = "64x64 Jezero Crater"
	add_child(ground)
	for gx in WORLD_SIZE:
		for gy in WORLD_SIZE:
			var iso := _grid_to_iso(gx, gy)
			var depth: int = 10 + gx + gy
			var height_offset: float = _height_offset_px(gx, gy)
			_add_relief_faces(ground, gx, gy, iso, height_offset, depth)
			_add_atlas_sprite(ground, terrain_atlas, terrain_frames, _terrain_frame(_terrain_type(gx, gy), gx, gy), iso - Vector2(0.0, height_offset), depth)

func _add_relief_faces(parent: Node2D, gx: int, gy: int, iso: Vector2, height_offset: float, depth: int) -> void:
	var current_elevation: float = _elevation_at(gx, gy)
	if gx + 1 < WORLD_SIZE:
		var east_elevation: float = _elevation_at(gx + 1, gy)
		if not is_equal_approx(current_elevation, east_elevation):
			var east_offset: float = _height_offset_px(gx + 1, gy)
			var east_top: float = maxf(height_offset, east_offset)
			var east_bottom: float = minf(height_offset, east_offset)
			var east_depth: int = depth if current_elevation > east_elevation else depth + 1
			var east_face := PackedVector2Array([
				Vector2(iso.x + TILE_W * 0.5, iso.y - east_top),
				Vector2(iso.x, iso.y + TILE_H * 0.5 - east_top),
				Vector2(iso.x, iso.y + TILE_H * 0.5 - east_bottom),
				Vector2(iso.x + TILE_W * 0.5, iso.y - east_bottom),
			])
			_add_relief_face(parent, east_face, east_depth, Color(0.37, 0.16, 0.10))
	if gy + 1 < WORLD_SIZE:
		var south_elevation: float = _elevation_at(gx, gy + 1)
		if not is_equal_approx(current_elevation, south_elevation):
			var south_offset: float = _height_offset_px(gx, gy + 1)
			var south_top: float = maxf(height_offset, south_offset)
			var south_bottom: float = minf(height_offset, south_offset)
			var south_depth: int = depth if current_elevation > south_elevation else depth + 1
			var south_face := PackedVector2Array([
				Vector2(iso.x - TILE_W * 0.5, iso.y - south_top),
				Vector2(iso.x, iso.y + TILE_H * 0.5 - south_top),
				Vector2(iso.x, iso.y + TILE_H * 0.5 - south_bottom),
				Vector2(iso.x - TILE_W * 0.5, iso.y - south_bottom),
			])
			_add_relief_face(parent, south_face, south_depth, Color(0.46, 0.21, 0.12))

func _add_relief_face(parent: Node2D, points: PackedVector2Array, depth: int, face_color: Color) -> void:
	var face := Polygon2D.new()
	face.polygon = points
	face.color = face_color
	face.z_index = depth
	parent.add_child(face)

func _build_colony() -> void:
	var buildings := [
		["habitat_lvl1", 32, 32, "ARES COMMAND HABITAT"],
		["solar_farm_lvl1", 28, 33, "HELIOS SOLAR FARM"],
		["greenhouse_lvl1", 34, 29, "DEMETER GREENHOUSE"],
		["water_recycler_lvl1", 36, 32, "AQUIFER WATER RECYCLER"],
		["laboratory_lvl1", 31, 29, "SAGAN SAMPLE LAB"],
		["radiation_shelter_lvl1", 31, 35, "STORM SHELTER"],
		["communication_tower_lvl1", 28, 30, "DEEP SPACE COMMS"],
		["repair_workshop_lvl1", 35, 35, "VULCAN ROVER GARAGE"],
	]
	for item in buildings:
		var tile_x: int = int(item[1])
		var tile_y: int = int(item[2])
		var pos := _grid_to_iso(tile_x, tile_y) - Vector2(0.0, _height_offset_px(tile_x, tile_y))
		var sprite := _add_atlas_sprite(self, buildings_atlas, building_frames, item[0], pos + Vector2(0, -26), 300 + roundi(pos.y))
		sprite.name = item[3].to_lower().replace(" ", "_")
		_add_label(item[3], pos + Vector2(0, 39), 300 + roundi(pos.y) + 1, Color("dce5eb"))
	# Auxiliary modules from the Phaser colony layout.
	for item in [["habitat_airlock", 33, 32], ["oxygen_generator", 37, 32], ["battery_storage", 28, 34], ["hydroponic_beds", 35, 29]]:
		var tile_x: int = int(item[1])
		var tile_y: int = int(item[2])
		var pos := _grid_to_iso(tile_x, tile_y) - Vector2(0.0, _height_offset_px(tile_x, tile_y))
		_add_atlas_sprite(self, buildings_atlas, building_frames, item[0], pos + Vector2(0, -22), 300 + roundi(pos.y), 0.86)

func _add_rover() -> void:
	var pos := _grid_to_iso(34, 31) - Vector2(0.0, _height_offset_px(34, 31))
	var rover := _add_atlas_sprite(self, rover_atlas, rover_frames, "rover_scan_0", pos + Vector2(0, -10), 300 + roundi(pos.y) + 2)
	rover.name = "Nomad-1 Rover"
	_add_label("NOMAD-1 (100%)", pos + Vector2(0, 28), 300 + roundi(pos.y) + 3, Color("ffc857"))

func _add_label(text_value: String, pos: Vector2, depth: int, color: Color) -> void:
	var label := Label.new()
	label.text = text_value
	label.custom_minimum_size.x = 320
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = pos + Vector2(-160, -10)
	label.z_index = depth
	label.add_theme_font_size_override("font_size", 26)   # was 10
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_shadow_color", Color("101827"))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	label.add_to_group("world_labels")
	add_child(label)


func _setup_camera() -> void:
	camera = Camera2D.new()
	camera.name = "Colony Camera"
	add_child(camera)
	camera.position = _grid_to_iso(HAB.x, HAB.y)
	camera.zoom = Vector2(0.6, 0.6)
	camera.make_current()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			dragging = event.pressed
			drag_origin = event.position
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			camera.zoom = (camera.zoom * 1.12).clamp(Vector2(0.06, 0.06), Vector2(1.1, 1.1))
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			camera.zoom = (camera.zoom / 1.12).clamp(Vector2(0.06, 0.06), Vector2(1.1, 1.1))
	elif event is InputEventMouseMotion and dragging:
		var delta: Vector2 = event.position - drag_origin
		camera.position -= delta / camera.zoom.x
		drag_origin = event.position
		
func _process(_delta: float) -> void:
	var readable := camera.zoom.x >= 0.35
	for l in get_tree().get_nodes_in_group("world_labels"):
		l.visible = readable
