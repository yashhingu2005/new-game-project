extends Node2D

const WORLD_SIZE := 64
const TILE_W := 128.0
const TILE_H := 64.0
const HAB := Vector2i(32, 32)

var terrain_atlas: Texture2D
var buildings_atlas: Texture2D
var rover_atlas: Texture2D
var terrain_frames: Dictionary
var building_frames: Dictionary
var rover_frames: Dictionary
var camera: Camera2D
var world_modulate: CanvasModulate
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
	var dist := Vector2(gx - HAB.x, gy - HAB.y).length()
	if dist <= 5.2:
		return "rocky_plains" if (gx + gy) % 3 == 0 else "sand_dust"
	var river_y := roundi(18.0 + gx * 0.45 + sin((gx + 101) * 0.22) * 4.5)
	if abs(gy - river_y) <= 1.8:
		return "river_channel"
	var tributary_x := roundi(42.0 - gy * 0.35 + cos(gy * 0.25) * 3.5)
	if gy < 34 and abs(gx - tributary_x) <= 1.4:
		return "river_channel"
	for crater in [Vector3(16, 20, 4.2), Vector3(48, 16, 5.0), Vector3(18, 48, 4.5), Vector3(50, 46, 4.0), Vector3(10, 34, 3.2)]:
		var d := Vector2(gx - crater.x, gy - crater.y).length()
		if d < crater.z - 1.1:
			return "crater_floor"
		if d <= crater.z + 0.4:
			return "rocky_hills"
	if (gy == 23 and gx >= 22 and gx <= 39 and gx != 28 and gx != 29 and gx != 35) or (gx == 43 and gy >= 25 and gy <= 41 and gy != 31 and gy != 32 and gy != 38) or (gx == 21 and gy >= 26 and gy <= 40 and gy != 30 and gy != 31 and gy != 36) or (gy == 44 and gx >= 25 and gx <= 41 and gx != 32 and gx != 33):
		return "cliff_ridge"
	var h: float = absf(sin(gx * 12.9898 + gy * 78.233 + 101.0) * 43758.5453)
	var frac: float = h - floorf(h)
	if frac > 0.88: return "boulder_field"
	if frac > 0.76: return "rocky_hills"
	if frac > 0.64: return "geological_outcrop"
	if frac > 0.36: return "rocky_plains"
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
			_add_atlas_sprite(ground, terrain_atlas, terrain_frames, _terrain_frame(_terrain_type(gx, gy), gx, gy), iso, 10 + gx + gy)

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
		var pos := _grid_to_iso(item[1], item[2])
		var sprite := _add_atlas_sprite(self, buildings_atlas, building_frames, item[0], pos + Vector2(0, -26), 300 + roundi(pos.y))
		sprite.name = item[3].to_lower().replace(" ", "_")
		_add_label(item[3], pos + Vector2(0, 39), 300 + roundi(pos.y) + 1, Color("dce5eb"))
	# Auxiliary modules from the Phaser colony layout.
	for item in [["habitat_airlock", 33, 32], ["oxygen_generator", 37, 32], ["battery_storage", 28, 34], ["hydroponic_beds", 35, 29]]:
		var pos := _grid_to_iso(item[1], item[2])
		_add_atlas_sprite(self, buildings_atlas, building_frames, item[0], pos + Vector2(0, -22), 300 + roundi(pos.y), 0.86)

func _add_rover() -> void:
	var pos := _grid_to_iso(34, 31)
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
