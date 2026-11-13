class_name OutpostMissionState
extends RefCounted

const Tuning = preload("res://simulation/tuning.gd")
const Hazards = preload("res://simulation/hazards.gd")

## Typed simulation state. Tile coordinates align with the existing 64x64 world.
var sol: int = 1
var hour: int = 6
var solar_arrays: Array[Dictionary] = []
var batteries: Array[Dictionary] = []
var poles: Array[Dictionary] = []
var buildings: Array[Dictionary] = []
var crew_hours: float = 12.0
var air: float = 3.0
var water: float = 4.0
var food: float = 3.6
var materials: float = 40.0
var earth_parts: float = 5.0
var dose: float = 0.0
var morale: float = 75.0
var flags: Dictionary = {}
var mission_seed: int = 1
var decision_ledger: Array[Dictionary] = []
var delayed_effects: Array[Dictionary] = []
var hazard_schedule: Array[Dictionary] = []
var rovers: Array[Dictionary] = []
var samples: Array[Dictionary] = []
var bulk_regolith_tonnes: float = 0.0

func to_data() -> Dictionary:
	return {
		"sol": sol, "hour": hour,
		"solar_arrays": solar_arrays.duplicate(true), "batteries": batteries.duplicate(true),
		"poles": poles.duplicate(true), "buildings": buildings.duplicate(true),
		"crew_hours": crew_hours, "air": air, "water": water, "food": food,
		"materials": materials, "earth_parts": earth_parts, "dose": dose,
		"morale": morale, "flags": flags.duplicate(true), "mission_seed": mission_seed,
		"decision_ledger": decision_ledger.duplicate(true), "delayed_effects": delayed_effects.duplicate(true),
		"hazard_schedule": hazard_schedule.duplicate(true),
		"rovers": rovers.duplicate(true), "samples": samples.duplicate(true), "bulk_regolith_tonnes": bulk_regolith_tonnes,
	}

static func from_data(data: Dictionary):
	var state = load("res://simulation/mission_state.gd").new()
	state.sol = int(data.get("sol", 1))
	state.hour = int(data.get("hour", 6))
	state.solar_arrays.assign(data.get("solar_arrays", []))
	state.batteries.assign(data.get("batteries", []))
	state.poles.assign(data.get("poles", []))
	state.buildings.assign(data.get("buildings", []))
	state.crew_hours = float(data.get("crew_hours", 12.0))
	state.air = float(data.get("air", 3.0))
	state.water = float(data.get("water", 4.0))
	state.food = float(data.get("food", 3.6))
	state.materials = float(data.get("materials", 40.0))
	state.earth_parts = float(data.get("earth_parts", 5.0))
	state.dose = float(data.get("dose", 0.0))
	state.morale = float(data.get("morale", 75.0))
	state.flags = data.get("flags", {}).duplicate(true)
	state.mission_seed = int(data.get("mission_seed", 1))
	state.decision_ledger.assign(data.get("decision_ledger", []))
	state.delayed_effects.assign(data.get("delayed_effects", []))
	state.hazard_schedule.assign(data.get("hazard_schedule", []))
	state.rovers.assign(data.get("rovers", []))
	state.samples.assign(data.get("samples", []))
	state.bulk_regolith_tonnes = float(data.get("bulk_regolith_tonnes", 0.0))
	return state

static func create_default(tuning: Dictionary = {}):
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var state = load("res://simulation/mission_state.gd").new()
	state.mission_seed = 88421
	state.hazard_schedule = Hazards.schedule_for_seed(state.mission_seed)
	state.rovers.assign([{"id": "Nomad-1", "class": "spirit", "tile": Vector2i(34, 31), "charge": 40.0,
		"capacity": 50.0, "status": "ready", "stuck": false, "range": 18, "cargo_samples": [], "bulk_tonnes": 0.0}])
	state.solar_arrays.assign([{"id": 1, "tile": Vector2i(28, 33), "count": 5, "dust": 0.0}])
	var capacity: float = float(t["battery_capacity"])
	state.batteries.assign([{"id": 1, "tile": Vector2i(28, 34), "capacity": capacity, "charge": 135.0 if is_equal_approx(capacity, 180.0) else capacity * 0.75}])
	var tiers: Dictionary = t["pole_tiers"]
	var starter_pole: Dictionary = tiers[2]
	state.poles.assign([{"id": 1, "tile": Vector2i(32, 31), "radius": starter_pole.radius, "capacity": starter_pole.capacity, "standby": starter_pole.standby, "tier": 2, "on": true, "tripped": false}])
	state.buildings.assign([
		_building("habitat", Vector2i(32, 32), 1.5, "high", true, 0.8, true, true, 3.0),
		_building("airlock", Vector2i(33, 32), 0.2, "high", true, 0.2, false, true, 1.0),
		_building("greenhouse", Vector2i(34, 29), 0.6, "normal", true, 0.5, false, false, 1.5),
		_building("water_recycler", Vector2i(36, 32), 0.5, "high", true, 0.5, false, false, 1.5),
		_building("laboratory", Vector2i(31, 29), 0.3, "low", true, 0.4, false, false, 1.5),
		_building("storm_shelter", Vector2i(31, 35), 0.3, "normal", true, 0.4, false, false, 1.5),
		_building("antenna", Vector2i(28, 30), 0.15, "normal", true, 0.0, false, false, 1.0),
		_building("workshop", Vector2i(35, 35), 0.4, "normal", true, 0.4, false, false, 2.0),
		_building("oxygen_generator", Vector2i(37, 32), 0.4, "high", true, 0.4, false, false, 1.0),
		_building("hydroponics", Vector2i(35, 29), 0.2, "normal", true, 0.2, false, false, 1.0),
	])
	return state

static func _building(kind: String, tile: Vector2i, power_load: float, priority: String, enabled: bool, heater: float, life_support: bool, fixed: bool = false, size_factor: float = 1.0) -> Dictionary:
	return {"id": kind, "type": kind, "tile": tile, "level": 1, "power_load": power_load, "priority": priority, "work_enabled": enabled, "heater_load": heater, "insulation": 1, "faulted": false, "low_power_fault": false, "life_support": life_support, "life_support_floor": power_load * 0.7, "fixed": fixed, "size_factor": size_factor}
