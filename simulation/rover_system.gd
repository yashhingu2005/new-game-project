class_name OutpostRoverSystem
extends RefCounted

const Grid = preload("res://simulation/power_grid.gd")
const State = preload("res://simulation/mission_state.gd")
const Tuning = preload("res://simulation/tuning.gd")
const Research = preload("res://simulation/research_system.gd")

## Tribute classes describe capabilities only; these are not the real NASA vehicles.
const CLASSES := {
	"sojourner": {"label": "Sojourner tribute scout", "range": 8, "sample": true, "bulk": false, "drill": false, "flight": false},
	"spirit": {"label": "Spirit tribute rover", "range": 18, "sample": true, "bulk": false, "drill": false, "flight": false},
	"curiosity": {"label": "Curiosity tribute rover", "range": 24, "sample": true, "bulk": false, "drill": true, "flight": false},
	"perseverance": {"label": "Perseverance tribute rover", "range": 32, "sample": true, "bulk": false, "drill": true, "flight": false},
	"ingenuity": {"label": "Ingenuity tribute scout", "range": 40, "sample": false, "bulk": false, "drill": false, "flight": true},
	"rassor": {"label": "RASSOR-class hauler", "range": 16, "sample": false, "bulk": true, "drill": false, "flight": false},
}
const TERRAIN_SAMPLES := {
	"clay": "hydrated minerals", "river_channel": "hydrated minerals",
	"geological_outcrop": "basalt and rock", "rocky_hills": "basalt and rock",
	"crater_floor": "regolith", "sand_dust": "regolith", "research_site": "salts and special minerals",
}

static func capabilities(rover_class: String) -> Dictionary:
	return CLASSES.get(rover_class.to_lower(), {}).duplicate(true)

static func can_collect_sample(rover: Dictionary, terrain_kind: String) -> bool:
	return bool(capabilities(str(rover.get("class", ""))).get("sample", false)) and TERRAIN_SAMPLES.has(terrain_kind)

static func dispatch_preview(rover: Dictionary, destination: Vector2i, terrain_kind: String, tuning: Dictionary = {}) -> Dictionary:
	if bool(rover.get("stuck", false)):
		return {"valid": false, "reason": "Nomad-1 is stuck. Recover it first."}
	if str(rover.get("status", "ready")) in ["dispatched", "traveling"]:
		return {"valid": false, "reason": "Nomad-1 is already on a trip."}
	if destination.x < 0 or destination.y < 0 or destination.x >= 64 or destination.y >= 64:
		return {"valid": false, "reason": "outside the map"}
	var origin: Vector2i = rover.get("tile", Vector2i.ZERO)
	var distance := Vector2(origin).distance_to(Vector2(destination))
	if distance <= 0.0:
		return {"valid": false, "reason": "choose a different tile"}
	var max_range := float(rover.get("range", capabilities(str(rover.get("class", ""))).get("range", 0)))
	if distance > max_range:
		return {"valid": false, "reason": "outside Nomad-1's range"}
	if not can_collect_sample(rover, terrain_kind):
		return {"valid": false, "reason": "no sample site here"}
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var energy := ceilf(distance * float(t.get("rover_charge_per_tile", 0.5)))
	if float(rover.get("charge", 0.0)) < energy:
		return {"valid": false, "reason": "Nomad-1 needs more rover battery"}
	var charge_after_trip := float(rover.get("charge", 0.0)) - energy
	var return_risk := charge_after_trip < energy
	return {"valid": true, "reason": "sample site in range", "distance": distance, "rover_charge": energy,
		"sample": str(TERRAIN_SAMPLES[terrain_kind]), "may_get_stuck": return_risk,
		"charge_after_trip": charge_after_trip}

static func collect_sample(state: State, rover_id: String, terrain_kind: String) -> Dictionary:
	for rover: Dictionary in state.rovers:
		if str(rover.get("id", "")) != rover_id: continue
		if bool(rover.get("stuck", false)): return {"ok": false, "reason": "rover is stuck"}
		if not can_collect_sample(rover, terrain_kind): return {"ok": false, "reason": "this rover cannot collect that sample"}
		var sample := {"type": str(TERRAIN_SAMPLES[terrain_kind]), "terrain": terrain_kind, "grams": 25.0, "sol": state.sol} # Placeholder sample mass.
		state.samples.append(sample)
		rover["cargo_samples"].append(sample.duplicate(true))
		return {"ok": true, "sample": sample, "discovered": Research.discover_from_sample(state, str(sample["type"]))}
	return {"ok": false, "reason": "rover not found"}

static func collect_bulk(state: State, rover_id: String, tonnes: float) -> Dictionary:
	for rover: Dictionary in state.rovers:
		if str(rover.get("id", "")) != rover_id: continue
		if not bool(capabilities(str(rover.get("class", ""))).get("bulk", false)):
			return {"ok": false, "reason": "bulk loads need the RASSOR-class hauler"}
		var amount := maxf(0.0, tonnes)
		rover["bulk_tonnes"] = float(rover.get("bulk_tonnes", 0.0)) + amount
		state.bulk_regolith_tonnes += amount
		return {"ok": true, "tonnes": amount}
	return {"ok": false, "reason": "rover not found"}

static func charge_from_grid(state: State, rover_id: String, amount: float, tuning: Dictionary = {}) -> Dictionary:
	var rover: Dictionary = {}
	for candidate: Dictionary in state.rovers:
		if str(candidate.get("id", "")) == rover_id: rover = candidate; break
	if rover.is_empty(): return {"ok": false, "reason": "rover not found"}
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var grid: Dictionary = Grid.compute_grid(state, t)
	var tile: Vector2i = rover.get("tile", Vector2i.ZERO)
	var connected := false
	for pole: Dictionary in state.poles:
		if grid["energized_poles"].has(int(pole["id"])) and Grid._distance(tile, pole.get("tile", Vector2i.ZERO)) <= float(pole.get("radius", 0.0)):
			connected = true
			break
	if not connected: return {"ok": false, "reason": "rover is outside an energized pole's range"}
	var requested := minf(maxf(0.0, amount), float(rover.get("capacity", 0.0)) - float(rover.get("charge", 0.0)))
	if requested <= 0.0: return {"ok": false, "reason": "rover battery is already full"}
	var solar := Grid.solar_generation(state, t)
	var battery_draw := maxf(0.0, requested - solar)
	if Grid._battery_charge(state) < battery_draw: return {"ok": false, "reason": "the shared grid does not have enough power"}
	Grid._set_resource(state, "power", Grid._battery_charge(state) - battery_draw)
	rover["charge"] = float(rover.get("charge", 0.0)) + requested
	return {"ok": true, "power_used": requested, "battery_used": battery_draw}

static func dispatch_action(rover_id: String, destination: Vector2i, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	return {"type": "rover_dispatch", "target_id": rover_id, "tile": destination, "cost": t["action_costs"]["rover_dispatch"].duplicate(true)}

static func recovery_action(rover_id: String, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	return {"type": "rover_recover", "target_id": rover_id, "cost": t["action_costs"]["rover_recover"].duplicate(true)}

static func emergency_recharge_action(rover_id: String, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	return {"type": "rover_emergency_recharge", "target_id": rover_id, "amount": 15.0,
		"cost": t["action_costs"]["rover_emergency_recharge"].duplicate(true)}
