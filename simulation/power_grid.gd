class_name OutpostPowerGrid
extends RefCounted

const MissionState = preload("res://simulation/mission_state.gd")
const Tuning = preload("res://simulation/tuning.gd")
const Hazards = preload("res://simulation/hazards.gd")

const PRIORITY_RANK := {"low": 0, "normal": 1, "high": 2}

static func phase_for_hour(hour: int) -> String:
	var h := posmod(hour, 24)
	if h >= 6 and h < 10: return "Morning"
	if h >= 10 and h < 16: return "Midday"
	if h >= 16 and h < 18: return "Evening"
	return "Night"

static func solar_curve(hour: float, tuning: Dictionary = {}) -> float:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var day_hours := 24.0 * float(t["day_fraction"])
	var start := (24.0 - day_hours) * 0.5
	var local_hour := fposmod(hour, 24.0)
	var progress := (local_hour - start) / day_hours
	if progress < 0.0 or progress > 1.0:
		return 0.0
	return maxf(0.0, sin(PI * progress))

static func compute_grid(state: MissionState, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var data := state.to_data()
	var poles: Array = data["poles"]
	var solar_sources: Array[Dictionary] = []
	var solar_scale := solar_curve(state.hour, t)
	for panel: Dictionary in data["solar_arrays"]:
		var panel_output := 0.0
		if state.sol >= int(panel.get("offline_until_sol", 0)):
			var sky_factor := 1.0 - clampf(float(state.flags.get("sky_dust_factor", 0.0)), 0.0, 1.0)
			panel_output = float(panel.get("count", 1)) * float(t["solar_peak_per_panel"]) * (1.0 - clampf(float(panel.get("dust", 0.0)), 0.0, 1.0)) * sky_factor * solar_scale
		if panel_output > 0.001:
			solar_sources.append({"tile": panel.get("tile", Vector2i.ZERO), "output": panel_output, "kind": "solar"})
	for battery: Dictionary in data["batteries"]:
		if float(battery.get("charge", 0.0)) > 0.001 and state.sol >= int(battery.get("offline_until_sol", 0)):
			solar_sources.append({"tile": battery.get("tile", Vector2i.ZERO), "output": 0.0, "kind": "battery"})

	var hop_counts: Dictionary = {}
	var queue: Array[int] = []
	for i in poles.size():
		var pole: Dictionary = poles[i]
		if not bool(pole.get("on", true)) or bool(pole.get("tripped", false)):
			continue
		for source: Dictionary in solar_sources:
			if _distance(pole.get("tile", Vector2i.ZERO), source["tile"]) <= float(pole.get("radius", 0.0)):
				hop_counts[int(pole["id"])] = 0
				queue.append(i)
				break
	var head := 0
	while head < queue.size():
		var current_index := queue[head]
		head += 1
		var current: Dictionary = poles[current_index]
		var current_id := int(current["id"])
		var next_hops := int(hop_counts[current_id]) + 1
		for j in poles.size():
			if j == current_index:
				continue
			var candidate: Dictionary = poles[j]
			var candidate_id := int(candidate["id"])
			if not bool(candidate.get("on", true)) or bool(candidate.get("tripped", false)):
				continue
			if _distance(current.get("tile", Vector2i.ZERO), candidate.get("tile", Vector2i.ZERO)) > minf(float(current.get("radius", 0.0)), float(candidate.get("radius", 0.0))):
				continue
			if not hop_counts.has(candidate_id) or next_hops < int(hop_counts[candidate_id]):
				hop_counts[candidate_id] = next_hops
				queue.append(j)

	var energized: Array[int] = []
	var pole_loads: Dictionary = {}
	var pole_spare: Dictionary = {}
	var by_id: Dictionary = {}
	for pole: Dictionary in poles:
		var id := int(pole["id"])
		by_id[id] = pole
		if hop_counts.has(id):
			energized.append(id)
			pole_loads[id] = float(pole.get("standby", 0.0))
			pole_spare[id] = float(pole.get("capacity", 0.0)) - float(pole_loads[id])
		else:
			pole_loads[id] = 0.0
			pole_spare[id] = -INF
	energized.sort()
	var buildings: Array = data["buildings"]
	var ordered := buildings.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a.get("id", "")) < str(b.get("id", "")))
	var assignments: Dictionary = {}
	var building_loads: Dictionary = {}
	var powered: Array[String] = []
	var reasons: Array[String] = []
	var total_demand := 0.0
	var total_loss := 0.0
	var night := state.hour >= 18 or state.hour < 6
	for building: Dictionary in ordered:
		var id := str(building.get("id", "building"))
		var tile: Vector2i = building.get("tile", Vector2i.ZERO)
		if state.sol < int(building.get("offline_until_sol", 0)):
			assignments[id] = null
			building_loads[id] = 0.0
			reasons.append("%s offline until Sol %d" % [id, int(building["offline_until_sol"])])
			continue
		var building_load := _building_load(building, night, t)
		var candidates: Array[int] = []
		for pole_id: int in energized:
			var pole: Dictionary = by_id[pole_id]
			if _distance(pole.get("tile", Vector2i.ZERO), tile) <= float(pole.get("radius", 0.0)):
				candidates.append(pole_id)
		if candidates.is_empty():
			assignments[id] = null
			building_loads[id] = 0.0
			reasons.append("%s unpowered: no energized pole in range" % id)
			continue
		candidates.sort_custom(func(a: int, b: int) -> bool:
			if is_equal_approx(float(pole_spare[a]), float(pole_spare[b])): return a < b
			return float(pole_spare[a]) > float(pole_spare[b]))
		var chosen := candidates[0]
		assignments[id] = chosen
		building_loads[id] = building_load
		powered.append(id)
		pole_loads[chosen] = float(pole_loads[chosen]) + building_load
		pole_spare[chosen] = float(pole_spare[chosen]) - building_load
		var hops := int(hop_counts[chosen])
		var delivered_fraction := pow(1.0 - float(t["line_loss_per_hop"]), hops)
		total_demand += building_load / maxf(delivered_fraction, 0.001)
		total_loss += building_load * (1.0 - delivered_fraction) / maxf(delivered_fraction, 0.001)
	for pole_id: int in energized:
		var pole: Dictionary = by_id[pole_id]
		var hops := int(hop_counts[pole_id])
		var standby := float(pole.get("standby", 0.0))
		var fraction := pow(1.0 - float(t["line_loss_per_hop"]), hops)
		total_demand += standby / maxf(fraction, 0.001)
		total_loss += standby * (1.0 - fraction) / maxf(fraction, 0.001)
	var overloaded: Array[int] = []
	for pole_id: int in energized:
		if float(pole_loads[pole_id]) > float(by_id[pole_id].get("capacity", 0.0)):
			overloaded.append(pole_id)
			reasons.append("Pole %d overloaded: breaker trips" % pole_id)
	for pole: Dictionary in poles:
		if not bool(pole.get("on", true)):
			reasons.append("Pole %d off: switched off" % int(pole["id"]))
		elif bool(pole.get("tripped", false)):
			reasons.append("Pole %d off: breaker tripped" % int(pole["id"]))
	return {"energized_poles": energized, "powered_buildings": powered, "assignments": assignments, "building_loads": building_loads,
		"pole_loads": pole_loads, "total_demand": total_demand, "total_loss": total_loss,
		"overloaded_poles": overloaded, "reasons": reasons, "hop_counts": hop_counts}

static func total_cost(action_data: Dictionary) -> float:
	var costs: Dictionary = action_data.get("cost", {})
	var total := 0.0
	for value: Variant in costs.values():
		total += absf(float(value))
	return total

static func place_pole_action(tile: Vector2i, tier: int = 1, pole_id: int = 0, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var spec: Dictionary = t["pole_tiers"].get(tier, t["pole_tiers"][1])
	var cost: Dictionary = t["building_costs"]["pole"].get(tier, t["building_costs"]["pole"][1]).duplicate(true)
	return {"type": "place_pole", "pole_id": pole_id, "tile": tile, "tier": tier, "spec": spec.duplicate(true),
		"cost": cost}

static func place_solar_array_action(tile: Vector2i, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	return {"type": "place_solar_array", "tile": tile, "count": 1,
		"cost": t["building_costs"]["solar_array"].duplicate(true)}

static func place_battery_action(tile: Vector2i, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	return {"type": "place_battery", "tile": tile, "capacity": float(t["battery_capacity"]),
		"cost": t["building_costs"]["battery"].duplicate(true)}

static func place_weather_station_action(tile: Vector2i, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	return {"type": "place_weather_station", "tile": tile, "cost": t["building_costs"]["weather_station"].duplicate(true)}

static func move_building_action(state: MissionState, building_id: String, destination: Vector2i, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var building: Dictionary = {}
	var target_kind := "building"
	for item: Dictionary in state.buildings:
		if str(item.get("id", "")) == building_id: building = item
	if building.is_empty() and building_id.begins_with("solar_array:"):
		target_kind = "solar_array"
		for item: Dictionary in state.solar_arrays:
			if "solar_array:%d" % int(item.get("id", 0)) == building_id: building = item
	if building.is_empty() and building_id.begins_with("battery:"):
		target_kind = "battery"
		for item: Dictionary in state.batteries:
			if "battery:%d" % int(item.get("id", 0)) == building_id: building = item
	if building.is_empty() or bool(building.get("fixed", false)):
		return {"type": "move_building", "target_id": building_id, "target_kind": target_kind, "tile": destination, "downtime": 0, "cost": {}}
	var origin: Vector2i = building.get("tile", Vector2i.ZERO)
	var distance := Vector2(origin).distance_to(Vector2(destination))
	var size_factor := float(building.get("size_factor", 1.5 if target_kind != "building" else 1.0))
	return {"type": "move_building", "target_id": building_id, "target_kind": target_kind, "tile": destination,
		"downtime": maxi(1, ceili(distance * size_factor / float(t["move_tiles_per_downtime_sol"]))),
		"cost": {"crew_hours": ceilf(distance * size_factor * float(t["move_crew_hours_per_tile"])), "materials": ceilf(distance * size_factor * float(t["move_materials_per_tile"]))}}

static func apply_action(state: MissionState, action_data: Dictionary) -> Dictionary:
	var next: MissionState = MissionState.from_data(state.to_data())
	var result := _apply_action(next, action_data)
	return {"state": next, "changes": result["changes"], "ok": result["ok"], "reason": result["reason"]}

static func action(type: String, target_id: Variant = null, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var costs: Dictionary = t["action_costs"].get(type, {}).duplicate(true)
	return {"type": type, "target_id": target_id, "cost": costs}

static func event_choice_as_action(choice_data: Dictionary) -> Dictionary:
	var cost: Dictionary = {}
	for key: String in choice_data.get("deltas", {}).keys():
		cost[key] = -float(choice_data["deltas"][key])
	return {"type": "event_choice", "choice_id": choice_data.get("id", ""), "option": choice_data.get("option", ""),
		"effects": choice_data.get("deltas", {}).duplicate(true), "delayed_effects": choice_data.get("delayed_effects", []).duplicate(true),
		"legacy_tags": choice_data.get("legacy_tags", []).duplicate(true), "cost": cost}

static func strictly_dominates_choice(a: Dictionary, b: Dictionary) -> bool:
	var ad: Dictionary = a.get("deltas", {})
	var bd: Dictionary = b.get("deltas", {})
	var keys: Dictionary = {}
	for key: String in ad.keys(): keys[key] = true
	for key: String in bd.keys(): keys[key] = true
	var strictly_better := false
	for key: String in keys:
		var av := float(ad.get(key, 0.0))
		var bv := float(bd.get(key, 0.0))
		if av < bv: return false
		if av > bv: strictly_better = true
	return strictly_better

static func solar_generation(state: MissionState, tuning: Dictionary = {}, weather: Dictionary = {}) -> float:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var output := 0.0
	var storm_factor := float(weather.get("storm_light_factor", 1.0))
	for panel: Dictionary in state.solar_arrays:
		if state.sol < int(panel.get("offline_until_sol", 0)): continue
		output += float(panel.get("count", 1)) * float(t["solar_peak_per_panel"]) * (1.0 - clampf(float(panel.get("dust", 0.0)), 0.0, 1.0)) * solar_curve(state.hour, t) * storm_factor
	return output

static func tick(state: MissionState, actions: Array[Dictionary] = [], rng: RandomNumberGenerator = null, weather: Dictionary = {}, tuning: Dictionary = {}) -> Dictionary:
	var t: Dictionary = tuning if not tuning.is_empty() else Tuning.preset()
	var next: MissionState = MissionState.from_data(state.to_data())
	var changes: Array[Dictionary] = []
	var generator := rng if rng != null else RandomNumberGenerator.new()
	if rng == null: generator.seed = 1
	var active_weather: Dictionary = weather.duplicate(true)
	if active_weather.is_empty() and not next.hazard_schedule.is_empty():
		active_weather = Hazards.weather_for_sol(next)
	if not active_weather.is_empty():
		next.flags["sky_dust_factor"] = 1.0 - float(active_weather.get("storm_light_factor", 1.0))
	for action_data: Dictionary in actions:
		var result := _apply_action(next, action_data)
		changes.append_array(result["changes"])
		if not result["ok"]: changes.append({"cause": "action_rejected", "detail": result["reason"]})
	var grid := compute_grid(next, t)
	for pole_id: int in grid["overloaded_poles"]:
		for pole: Dictionary in next.poles:
			if int(pole["id"]) == pole_id:
				pole["tripped"] = true
				pole["on"] = false
				changes.append({"cause": "overload", "detail": "Pole %d breaker tripped" % pole_id})
	grid = compute_grid(next, t)
	var generation := solar_generation(next, t, active_weather)
	var total_charge := _battery_charge(next)
	var available := generation + total_charge * float(t["discharge_efficiency"])
	var shed: Array[String] = []
	if float(grid["total_demand"]) > available:
		var candidates := next.buildings.duplicate()
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var ra: int = PRIORITY_RANK.get(str(a.get("priority", "normal")), 1)
			var rb: int = PRIORITY_RANK.get(str(b.get("priority", "normal")), 1)
			if ra == rb: return str(a.get("id", "")) < str(b.get("id", ""))
			return ra < rb)
		for building: Dictionary in candidates:
			if float(grid["total_demand"]) <= available: break
			if not bool(building.get("work_enabled", true)) or bool(building.get("life_support", false)): continue
			building["work_enabled"] = false
			shed.append(str(building.get("id", "building")))
			changes.append({"cause": "load_shedding", "detail": "%s work load shed: insufficient generation and battery" % building.get("id", "building")})
			grid = compute_grid(next, t)
	var demand := float(grid["total_demand"])
	var deficit := maxf(0.0, demand - generation)
	var charged_from_solar := maxf(0.0, generation - demand)
	var remaining_deficit := deficit
	for battery: Dictionary in next.batteries:
		if next.sol < int(battery.get("offline_until_sol", 0)): continue
		var available_charge := float(battery.get("charge", 0.0))
		var draw := minf(available_charge, remaining_deficit / maxf(float(t["discharge_efficiency"]), 0.001))
		battery["charge"] = maxf(0.0, available_charge - draw)
		remaining_deficit = maxf(0.0, remaining_deficit - draw * float(t["discharge_efficiency"]))
	for battery: Dictionary in next.batteries:
		if next.sol < int(battery.get("offline_until_sol", 0)): continue
		var capacity := float(battery.get("capacity", 0.0))
		if charged_from_solar > 0.0:
			var incoming := minf(capacity - float(battery.get("charge", 0.0)), charged_from_solar * float(t["charge_efficiency"]))
			battery["charge"] = float(battery.get("charge", 0.0)) + incoming
			charged_from_solar = maxf(0.0, charged_from_solar - incoming / maxf(float(t["charge_efficiency"]), 0.001))
	var capacity_total := 0.0
	for battery: Dictionary in next.batteries:
		if next.sol >= int(battery.get("offline_until_sol", 0)): capacity_total += float(battery.get("capacity", 0.0))
	var after_charge := _battery_charge(next)
	var reserve_hit := capacity_total > 0.0 and after_charge <= capacity_total * float(t["reserve_fraction"])
	if reserve_hit:
		next.flags["reserve_fault"] = true
		for building: Dictionary in next.buildings:
			if grid["assignments"].get(str(building.get("id", ""))) != null:
				building["low_power_fault"] = true
		changes.append({"cause": "battery_reserve", "detail": "Battery reached reserve; connected buildings entered low-power fault"})
	else:
		next.flags["reserve_fault"] = false
		for building: Dictionary in next.buildings:
			building["low_power_fault"] = false
	var dust_per_sol := Hazards.panel_dust_rate(active_weather, t)
	if state.hour == 23:
		for panel: Dictionary in next.solar_arrays:
			panel["dust"] = clampf(float(panel.get("dust", 0.0)) + dust_per_sol, 0.0, 1.0)
			if float(active_weather.get("dust_devil_clean", 0.0)) > 0.0 and generator.randf() < float(active_weather["dust_devil_clean"]):
				panel["dust"] = maxf(0.0, float(panel["dust"]) - 0.05)
				changes.append({"cause": "dust_devil", "detail": "Dust devil cleaned a panel"})
			changes.append({"cause": "dust", "detail": "Panel dust increased by %.3f" % dust_per_sol})
	var powered_ratio := 1.0 if demand <= 0.0 else clampf((generation + total_charge - after_charge) / demand, 0.0, 1.0)
	# Resource rates are distributed across the 24 hourly simulation steps.
	next.air = maxf(0.0, next.air - float(t["air_per_sol"]) * powered_ratio / 24.0)
	next.water = maxf(0.0, next.water - float(t["water_per_sol"]) * powered_ratio / 24.0)
	next.food = maxf(0.0, next.food - float(t["food_per_sol"]) / 24.0)
	var food_produced := 0.0
	var air_produced := 0.0
	var water_produced := 0.0
	var materials_produced := 0.0
	var powered_buildings: Array[String] = grid["powered_buildings"]
	for building: Dictionary in next.buildings:
		if not bool(building.get("work_enabled", true)) or not powered_buildings.has(str(building.get("id", ""))):
			continue
		match str(building.get("type", building.get("id", ""))):
			"greenhouse":
				food_produced += float(t["greenhouse_food_per_sol"]) / 24.0
			"oxygen_generator":
				air_produced += float(t["oxygen_generator_air_per_sol"]) / 24.0
			"water_recycler":
				water_produced += float(t["water_recycler_water_per_sol"]) / 24.0
			"workshop":
				materials_produced += float(t["workshop_materials_per_sol"]) / 24.0
	next.food = minf(float(t["food_capacity"]), next.food + food_produced)
	next.air = minf(float(t["air_capacity"]), next.air + air_produced)
	next.water = minf(float(t["water_capacity"]), next.water + water_produced)
	next.materials += materials_produced
	if state.hour == 23:
		if food_produced > 0.0: changes.append({"cause": "production", "detail": "Food +%.2f: greenhouse" % float(t["greenhouse_food_per_sol"])} )
		if air_produced > 0.0: changes.append({"cause": "production", "detail": "Air +%.2f: oxygen generator" % float(t["oxygen_generator_air_per_sol"])} )
		if water_produced > 0.0: changes.append({"cause": "production", "detail": "Water +%.2f: water recycler" % float(t["water_recycler_water_per_sol"])} )
		if materials_produced > 0.0: changes.append({"cause": "production", "detail": "Materials +%.0f: workshop" % float(t["workshop_materials_per_sol"])} )
	var low_fraction := float(t["store_warning_fraction"])
	for key: String in ["air", "water", "food"]:
		var current_store := _resource(next, key)
		var store_capacity := float(t["%s_capacity" % key])
		var warning_flag := "low_store_warning_%s" % key
		if current_store > store_capacity * low_fraction:
			next.flags.erase(warning_flag)
		elif not bool(next.flags.get(warning_flag, false)):
			next.flags[warning_flag] = true
			changes.append({"cause": "store_warning", "detail": "%s is below 25%%" % key.capitalize()})
	if not bool(next.flags.get("mission_failed", false)):
		for key: String in ["air", "water", "food"]:
			if _resource(next, key) <= 0.0:
				next.flags["mission_failed"] = true
				next.flags["failure_cause"] = key
				changes.append({"cause": "mission_failed", "detail": "The %s store ran out." % key})
				break
	next.dose += float(t.get("dose_per_sol_msv", 0.0)) / 24.0
	next.hour += 1
	if next.hour >= 24:
		next.hour = 0
		next.sol += 1
		next.crew_hours = 12.0
		for building: Dictionary in next.buildings: building["work_enabled"] = not bool(building.get("manual_off", false))
		var next_weather := Hazards.weather_for_sol(next)
		next.flags["sky_dust_factor"] = 1.0 - float(next_weather.get("storm_light_factor", 1.0))
		Hazards.process_sol_start(next, changes)
		var comms_before: Dictionary = next.flags.get("communications", {})
		var cargo_was_landed := bool(comms_before.get("cargo_landed", false))
		var delivered: Array = load("res://simulation/communications_system.gd").process_sol(next)
		for message: Dictionary in delivered:
			if str(message.get("cause", "")) == "cargo_landing":
				changes.append(message)
			else:
				changes.append({"cause": "earth_reply", "detail": "Earth replied about %s" % str(message.get("item", "your request"))})
		var comms_after: Dictionary = next.flags.get("communications", {})
		if not cargo_was_landed and bool(comms_after.get("cargo_landed", false)):
			changes.append({"cause": "cargo_landing", "detail": "The scheduled cargo manifest landed on Sol %d" % next.sol})
	_process_delayed_effects(next, changes)
	changes.append({"cause": "clock", "detail": "Sol %d began" % next.sol})
	return {"state": next, "changes": changes, "grid": grid, "generation": generation, "demand": demand,
		"battery_charge": after_charge, "reserve_hit": reserve_hit, "shed": shed, "phase": phase_for_hour(state.hour)}

static func advance_sol(state: MissionState, rng: RandomNumberGenerator = null, weather: Dictionary = {}, tuning: Dictionary = {}) -> Dictionary:
	var current: MissionState = MissionState.from_data(state.to_data())
	var all_changes: Array[Dictionary] = []
	var steps: Array[Dictionary] = []
	var generator := rng if rng != null else RandomNumberGenerator.new()
	if rng == null: generator.seed = 1
	for _hour in 24:
		var result := tick(current, [], generator, weather, tuning)
		current = result["state"]
		all_changes.append_array(result["changes"])
		steps.append(result)
	return {"state": current, "changes": all_changes, "steps": steps}

static func forecast_night(state: MissionState, weather: Dictionary = {}, tuning: Dictionary = {}) -> Dictionary:
	var current: MissionState = MissionState.from_data(state.to_data())
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x0A57
	var trajectory: Array[Dictionary] = []
	var reserve_hour: int = -1
	var zero_hour: int = -1
	var night_started := false
	for _step in 30:
		if current.hour >= 18 or current.hour < 6: night_started = true
		if night_started and not trajectory.is_empty() and current.hour == 6: break
		var result := tick(current, [], rng, weather, tuning)
		current = result["state"]
		trajectory.append({"sol": current.sol, "hour": current.hour, "charge": result["battery_charge"]})
		var cap := 0.0
		for battery: Dictionary in current.batteries: cap += float(battery.get("capacity", 0.0))
		if reserve_hour < 0 and cap > 0.0 and float(result["battery_charge"]) <= cap * float((tuning if not tuning.is_empty() else Tuning.preset())["reserve_fraction"]): reserve_hour = current.hour
		if zero_hour < 0 and float(result["battery_charge"]) <= 0.0: zero_hour = current.hour
	var reserve_result: Variant = null
	var zero_result: Variant = null
	if reserve_hour >= 0: reserve_result = reserve_hour
	if zero_hour >= 0: zero_result = zero_hour
	return {"trajectory": trajectory, "reserve_hour": reserve_result, "zero_hour": zero_result}

static func _apply_action(state: MissionState, action_data: Dictionary) -> Dictionary:
	var changes: Array[Dictionary] = []
	if str(action_data.get("type", "")) == "research_start" and not str(action_data.get("reason", "")).is_empty():
		return {"ok": false, "reason": str(action_data["reason"]), "changes": changes}
	if total_cost(action_data) <= 0.0 and str(action_data.get("type", "")) != "event_choice":
		return {"ok": false, "reason": "zero-cost action", "changes": changes}
	var cost: Dictionary = action_data.get("cost", {})
	if str(action_data.get("type", "")) == "move_building":
		var move_target_found := false
		var target_kind := str(action_data.get("target_kind", "building"))
		if target_kind == "solar_array":
			for panel: Dictionary in state.solar_arrays:
				if "solar_array:%d" % int(panel.get("id", 0)) == str(action_data.get("target_id", "")): move_target_found = true
		elif target_kind == "battery":
			for battery: Dictionary in state.batteries:
				if "battery:%d" % int(battery.get("id", 0)) == str(action_data.get("target_id", "")): move_target_found = true
		else:
			for building: Dictionary in state.buildings:
				if str(building.get("id", "")) == str(action_data.get("target_id", "")) and not bool(building.get("fixed", false)): move_target_found = true
		if not move_target_found: return {"ok": false, "reason": "building cannot be moved", "changes": changes}
	for key: String in cost.keys():
		var amount := float(cost[key])
		if amount > 0.0 and _resource(state, key) < amount: return {"ok": false, "reason": "insufficient %s" % key, "changes": changes}
	for key: String in cost.keys():
		var amount := float(cost[key])
		if amount != 0.0: _set_resource(state, key, _resource(state, key) - amount)
	match str(action_data.get("type", "")):
		"place_solar_array":
			var next_panel_id := 1
			for panel: Dictionary in state.solar_arrays: next_panel_id = maxi(next_panel_id, int(panel.get("id", 0)) + 1)
			state.solar_arrays.append({"id": next_panel_id, "tile": action_data["tile"], "count": int(action_data.get("count", 1)), "dust": 0.0})
			changes.append({"cause": "action", "detail": "Placed solar array %d" % next_panel_id})
		"place_battery":
			var next_battery_id := 1
			for battery: Dictionary in state.batteries: next_battery_id = maxi(next_battery_id, int(battery.get("id", 0)) + 1)
			state.batteries.append({"id": next_battery_id, "tile": action_data["tile"], "capacity": float(action_data["capacity"]), "charge": 0.0})
			changes.append({"cause": "action", "detail": "Placed battery %d" % next_battery_id})
		"place_weather_station":
			state.buildings.append({"id": "weather_station", "type": "weather_station", "tile": action_data["tile"], "level": 1,
				"power_load": 0.35, "priority": "normal", "work_enabled": true, "heater_load": 0.0, "insulation": 0,
				"faulted": false, "low_power_fault": false, "life_support": false, "fixed": false, "size_factor": 1.0})
			changes.append({"cause": "action", "detail": "Built a weather station"})
		"place_pole":
			var spec: Dictionary = action_data["spec"]
			var tile: Vector2i = action_data["tile"]
			var next_id := int(action_data.get("pole_id", 0))
			if next_id <= 0:
				for pole: Dictionary in state.poles: next_id = maxi(next_id, int(pole.get("id", 0)) + 1)
			state.poles.append({"id": next_id, "tile": tile, "radius": spec["radius"], "capacity": spec["capacity"], "standby": spec["standby"], "tier": int(action_data["tier"]), "on": true, "tripped": false})
			changes.append({"cause": "action", "detail": "Placed tier %d pole %d" % [int(action_data["tier"]), next_id]})
		"switch":
			for pole: Dictionary in state.poles:
				if int(pole["id"]) == int(action_data.get("target_id", -1)): pole["on"] = not bool(pole.get("on", true))
			changes.append({"cause": "action", "detail": "Switched pole %s" % action_data.get("target_id", "")})
		"reset_breaker":
			for pole: Dictionary in state.poles:
				if int(pole["id"]) == int(action_data.get("target_id", -1)):
					pole["tripped"] = false
					pole["on"] = true
			changes.append({"cause": "action", "detail": "Reset breaker for pole %s" % action_data.get("target_id", "")})
		"clean_panels":
			for panel: Dictionary in state.solar_arrays: panel["dust"] = 0.0
			changes.append({"cause": "action", "detail": "Cleaned solar panels"})
		"toggle_work":
			for building: Dictionary in state.buildings:
				if str(building.get("id", "")) == str(action_data.get("target_id", "")) and not bool(building.get("life_support", false)):
					var turning_off := bool(building.get("work_enabled", true))
					building["work_enabled"] = not turning_off
					building["manual_off"] = turning_off
			changes.append({"cause": "action", "detail": "Toggled work at %s" % action_data.get("target_id", "")})
		"repair_building":
			for building: Dictionary in state.buildings:
				if str(building.get("id", "")) == str(action_data.get("target_id", "")):
					building["faulted"] = false
					building["low_power_fault"] = false
			changes.append({"cause": "action", "detail": "Repaired building %s" % action_data.get("target_id", "")})
		"upgrade_building":
			for building: Dictionary in state.buildings:
				if str(building.get("id", "")) == str(action_data.get("target_id", "")):
					building["level"] = int(building.get("level", 1)) + 1
					building["insulation"] = int(building.get("insulation", 1)) + 1
			changes.append({"cause": "action", "detail": "Upgraded building %s" % action_data.get("target_id", "")})
		"recover_safe_mode":
			state.flags["safe_mode"] = false
			state.flags["sensor_saturated"] = false
			state.flags["solar_event_recovered"] = true
			for building: Dictionary in state.buildings:
				if bool(building.get("solar_event_fault", false)):
					building["faulted"] = false
					building["solar_event_fault"] = false
			changes.append({"cause": "action", "detail": "Crew restored electronics after the particle event"})
		"shelter_drill":
			state.flags["crew_sheltered_sol"] = state.sol
			for building: Dictionary in state.buildings:
				if str(building.get("type", "")) in ["laboratory", "workshop", "greenhouse"]:
					building["work_enabled"] = false
			changes.append({"cause": "action", "detail": "Crew sheltered; science, repairs, and greenhouse care paused for this Sol"})
		"raise_shielding":
			for building: Dictionary in state.buildings:
				if str(building.get("id", "")) == str(action_data.get("target_id", "")):
					building["shielding"] = mini(3, int(building.get("shielding", 0)) + 1)
			changes.append({"cause": "action", "detail": "Raised module shielding"})
		"rover_dispatch":
			for rover: Dictionary in state.rovers:
				if str(rover.get("id", "")) == str(action_data.get("target_id", "")):
					rover["mission_target"] = action_data.get("tile", rover.get("tile", Vector2i.ZERO))
					rover["status"] = "dispatched"
			changes.append({"cause": "action", "detail": "Dispatched rover %s toward the selected tile" % action_data.get("target_id", "")})
		"rover_recover":
			for rover: Dictionary in state.rovers:
				if str(rover.get("id", "")) == str(action_data.get("target_id", "")):
					rover["stuck"] = false
					rover["status"] = "ready"
			changes.append({"cause": "action", "detail": "Recovered rover %s from soft sand" % action_data.get("target_id", "")})
		"rover_emergency_recharge":
			for rover: Dictionary in state.rovers:
				if str(rover.get("id", "")) == str(action_data.get("target_id", "")):
					rover["charge"] = minf(float(rover.get("capacity", 0.0)), float(rover.get("charge", 0.0)) + float(action_data.get("amount", 15.0)))
			changes.append({"cause": "action", "detail": "Emergency recharge drew power from the shared grid"})
		"research_start":
			var research: Dictionary = state.flags.get("research", {"discovered": [], "completed": [], "project": {}})
			research["project"] = {"node_id": str(action_data.get("target_id", "")), "required_sols": int(action_data.get("sols", 1)), "progress_sols": 0}
			state.flags["research"] = research
			changes.append({"cause": "action", "detail": "Started research project %s" % action_data.get("target_id", "")})
		"move_building":
			var target_kind := str(action_data.get("target_kind", "building"))
			if target_kind == "solar_array":
				for panel: Dictionary in state.solar_arrays:
					if "solar_array:%d" % int(panel.get("id", 0)) == str(action_data.get("target_id", "")):
						panel["tile"] = action_data["tile"]
						panel["offline_until_sol"] = state.sol + int(action_data.get("downtime", 1))
			elif target_kind == "battery":
				for battery: Dictionary in state.batteries:
					if "battery:%d" % int(battery.get("id", 0)) == str(action_data.get("target_id", "")):
						battery["tile"] = action_data["tile"]
						battery["offline_until_sol"] = state.sol + int(action_data.get("downtime", 1))
			else:
				for building: Dictionary in state.buildings:
					if str(building.get("id", "")) != str(action_data.get("target_id", "")): continue
					building["tile"] = action_data["tile"]
					building["offline_until_sol"] = state.sol + int(action_data.get("downtime", 1))
					building["work_enabled"] = false
			changes.append({"cause": "move", "detail": "%s moved; offline for %d Sols" % [action_data.get("target_id", "building"), int(action_data.get("downtime", 1))]})
		"event_choice": _record_event_choice(state, action_data, changes)
		_: return {"ok": false, "reason": "unknown action", "changes": []}
	return {"ok": true, "reason": "", "changes": changes}

static func _record_event_choice(state: MissionState, action_data: Dictionary, changes: Array[Dictionary]) -> void:
	var entry := {"sol": state.sol, "option": str(action_data.get("option", action_data.get("choice_id", ""))),
		"immediate_effects": action_data.get("effects", {}).duplicate(true),
		"delayed_effects": action_data.get("delayed_effects", []).duplicate(true),
		"legacy_tags": action_data.get("legacy_tags", []).duplicate(true)}
	state.decision_ledger.append(entry)
	for effect: Dictionary in entry["delayed_effects"]:
		var queued := effect.duplicate(true)
		queued["source_sol"] = state.sol
		queued["source_option"] = entry["option"]
		state.delayed_effects.append(queued)
	changes.append({"cause": "event_choice", "detail": "Applied event choice %s" % entry["option"]})

static func _process_delayed_effects(state: MissionState, changes: Array[Dictionary]) -> void:
	for i in range(state.delayed_effects.size() - 1, -1, -1):
		var effect: Dictionary = state.delayed_effects[i]
		var due := int(effect.get("trigger_sol", state.sol + 1)) <= state.sol
		var condition: Dictionary = effect.get("condition", {})
		if not condition.is_empty():
			due = bool(state.flags.get(str(condition.get("flag", "")), false)) == bool(condition.get("equals", true))
		if not due:
			continue
		for key: String in effect.get("effects", {}).keys():
			_set_resource(state, key, _resource(state, key) + float(effect["effects"][key]))
		for key: String in effect.get("flags", {}).keys():
			state.flags[key] = effect["flags"][key]
		changes.append({"cause": "delayed_effect", "detail": "Remember when Sol %d: %s" % [int(effect.get("source_sol", 1)), str(effect.get("description", "an earlier choice"))]})
		state.delayed_effects.remove_at(i)

static func _building_load(building: Dictionary, night: bool, tuning: Dictionary) -> float:
	var building_load := 0.0
	if bool(building.get("work_enabled", true)):
		building_load = float(building.get("power_load", 0.0))
		if bool(building.get("life_support", false)): building_load = maxf(building_load, float(building.get("life_support_floor", 0.0)))
	if night:
		var level := maxi(0, int(building.get("insulation", 0)))
		var reduction := minf(float(tuning["max_insulation_reduction"]), level * float(tuning["insulation_reduction_per_level"]))
		building_load += float(building.get("heater_load", 0.0)) * (1.0 - reduction)
	return building_load * float(tuning.get("load_scale", 1.0))

static func _distance(a: Variant, b: Variant) -> float:
	var av := Vector2(float(a.x), float(a.y)) if a is Vector2i or a is Vector2 else Vector2.ZERO
	var bv := Vector2(float(b.x), float(b.y)) if b is Vector2i or b is Vector2 else Vector2.ZERO
	return av.distance_to(bv)

static func _battery_charge(state: MissionState) -> float:
	var charge := 0.0
	for battery: Dictionary in state.batteries:
		if state.sol < int(battery.get("offline_until_sol", 0)): continue
		charge += float(battery.get("charge", 0.0))
	return charge

static func _resource(state: MissionState, key: String) -> float:
	match key:
		"crew_hours": return state.crew_hours
		"air": return state.air
		"water": return state.water
		"food": return state.food
		"materials": return state.materials
		"earth_parts": return state.earth_parts
		"dose": return state.dose
		"morale": return state.morale
		"power": return _battery_charge(state)
	return 0.0

static func _set_resource(state: MissionState, key: String, value: float) -> void:
	match key:
		"crew_hours": state.crew_hours = value
		"air": state.air = value
		"water": state.water = value
		"food": state.food = value
		"materials": state.materials = value
		"earth_parts": state.earth_parts = value
		"dose": state.dose = value
		"morale": state.morale = value
		"power":
			var remaining := value
			for battery: Dictionary in state.batteries:
				if state.sol < int(battery.get("offline_until_sol", 0)): continue
				var used := minf(float(battery.get("charge", 0.0)), remaining)
				battery["charge"] = float(battery.get("charge", 0.0)) - used
				remaining -= used
