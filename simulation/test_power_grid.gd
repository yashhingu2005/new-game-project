extends Node

const Tuning = preload("res://simulation/tuning.gd")
const State = preload("res://simulation/mission_state.gd")
const Grid = preload("res://simulation/power_grid.gd")
const PlacementRules = preload("res://simulation/placement_rules.gd")
const Hazards = preload("res://simulation/hazards.gd")
const Rovers = preload("res://simulation/rover_system.gd")
const Research = preload("res://simulation/research_system.gd")
const Communications = preload("res://simulation/communications_system.gd")
const Story = preload("res://simulation/story_system.gd")
const DataSources = preload("res://data/sources.gd")
const Badges = preload("res://simulation/badge_system.gd")

var failures: int = 0

func _ready() -> void:
	_run_tests()

func _run_tests() -> void:
	_test_clock_and_solar_curve()
	_test_chain_and_broken_chain()
	_test_redundancy()
	_test_overload_trip()
	_test_line_loss()
	_test_night_heaters()
	_test_forecast_matches_night()
	_test_reserve_fault()
	_test_determinism()
	_test_action_costs()
	_test_priority_shedding()
	_test_placement_rules()
	_test_move_cost_scaling()
	_test_switch_updates_forecast()
	_test_decision_ledger_and_delayed_effects()
	_test_seeded_hazard_windows()
	_test_sky_dust_and_panel_dust_are_separate()
	_test_weather_station_warning_and_power()
	_test_particle_event_safe_mode_and_shelter()
	_test_rover_grid_charging()
	_test_rover_sample_and_bulk_collection()
	_test_stuck_rover_recovery_cost()
	_test_research_requires_discovery_and_prerequisites()
	_test_research_pauses_at_night_and_can_corrupt()
	_test_campaign_cannot_finish_every_research_node()
	_test_supply_requests_cutoff_cooldown_and_blackout()
	_test_comms_replies_stale_advice_and_cargo_arrival()
	_test_story_chapter_windows_and_dilemmas()
	_test_handover_uses_decision_ledger_and_retry_seed()
	_test_data_sources_are_labeled_and_cited()
	_test_badges_and_generated_patch()
	_test_default_start_and_first_night()
	_test_cleaning_prevents_reserve_breaches()
	_test_dust_causes_reserve_breach_without_cleaning()
	_test_toggle_work_night_and_midnight()
	_test_habitat_work_toggle_is_noop()
	_test_store_failure_state()
	_test_production_requires_power_and_work()
	_test_zero_cost_story_choice_is_recorded()
	_test_rover_dispatch_preview_and_action()
	if failures == 0:
		print("PASS: 40 Godot simulation tests")
	else:
		push_error("FAIL: %d Godot simulation test(s)" % failures)
	await get_tree().create_timer(15.0).timeout
	get_tree().quit(0 if failures == 0 else 1)

func _check(value: bool, label: String) -> void:
	if not value:
		failures += 1
		push_error(label)

func _empty_state() -> State:
	var state: State = State.new()
	state.solar_arrays.assign([{"id": 1, "tile": Vector2i(0, 0), "count": 4, "dust": 0.0}])
	state.batteries.assign([{"id": 1, "tile": Vector2i(0, 0), "capacity": 100.0, "charge": 100.0}])
	state.poles.assign([_pole(1, Vector2i(0, 0), 3.0, 100.0)])
	state.buildings.assign([])
	state.hour = 12
	return state

func _pole(id: int, tile: Vector2i, radius: float, capacity: float, enabled: bool = true) -> Dictionary:
	return {"id": id, "tile": tile, "radius": radius, "capacity": capacity, "standby": 0.1, "tier": 1, "on": enabled, "tripped": false}

func _building(id: String, tile: Vector2i, power_load: float, priority: String = "normal", life_support: bool = false) -> Dictionary:
	return {"id": id, "type": id, "tile": tile, "level": 1, "power_load": power_load, "priority": priority,
		"work_enabled": true, "heater_load": 0.8, "insulation": 0, "faulted": false,
		"low_power_fault": false, "life_support": life_support, "life_support_floor": power_load * 0.7}

func _test_clock_and_solar_curve() -> void:
	var t: Dictionary = Tuning.preset("game")
	_check(Grid.phase_for_hour(7) == "Morning", "Morning phase")
	_check(Grid.phase_for_hour(12) == "Midday", "Midday phase")
	_check(Grid.phase_for_hour(17) == "Evening", "Evening phase")
	_check(Grid.phase_for_hour(22) == "Night", "Night phase")
	_check(is_zero_approx(Grid.solar_curve(0, t)), "No solar at midnight")
	_check(is_equal_approx(Grid.solar_curve(12, t), 1.0), "Solar peaks at noon")
	_check(is_zero_approx(Grid.solar_curve(6, t)), "Solar starts smoothly at dawn")
	_check(Grid.solar_curve(9, t) > Grid.solar_curve(7, t), "Solar rises smoothly after dawn")
	var real: Dictionary = Tuning.preset("real")
	_check(is_equal_approx(float(real["solar_peak_per_panel"]), 0.177), "Real preset basis")
	_check(is_equal_approx(float(real["mars_sol_earth_hours"]), 24.660), "Mars sol duration is distinct from the time-compressed game clock")
	var exposure := Grid.advance_sol(_empty_state(), null, {}, real)
	_check(is_equal_approx(float(exposure["state"].dose), 0.67), "Real preset uses the cited Curiosity RAD daily dose rate")

func _test_chain_and_broken_chain() -> void:
	var state := _empty_state()
	state.solar_arrays.assign([{"id": 1, "tile": Vector2i.ZERO, "count": 1, "dust": 0.0}])
	state.batteries.assign([])
	state.poles.assign([_pole(1, Vector2i(0, 0), 2.1, 10), _pole(2, Vector2i(2, 0), 2.1, 10), _pole(3, Vector2i(4, 0), 2.1, 10)])
	state.buildings.assign([_building("hab", Vector2i(6, 0), 1)])
	var result: Dictionary = Grid.compute_grid(state)
	_check(result["energized_poles"] == [1, 2, 3], "Pole chain energizes")
	_check(result["powered_buildings"].has("hab"), "End of chain powers building")
	state.poles[1]["on"] = false
	result = Grid.compute_grid(state)
	_check(result["energized_poles"] == [1], "Broken chain cuts off poles beyond")
	_check(not result["powered_buildings"].has("hab"), "Broken chain cuts off building")

func _test_redundancy() -> void:
	var state := _empty_state()
	state.solar_arrays.assign([{"id": 1, "tile": Vector2i.ZERO, "count": 1, "dust": 0.0}])
	state.batteries.assign([])
	state.poles.assign([_pole(1, Vector2i(0, 0), 4, 10), _pole(2, Vector2i(4, 0), 4, 10)])
	state.buildings.assign([_building("hab", Vector2i(2, 0), 1)])
	_check(Grid.compute_grid(state)["powered_buildings"].has("hab"), "Overlapping poles power building")
	state.poles[0]["on"] = false
	_check(Grid.compute_grid(state)["powered_buildings"].has("hab"), "Second pole provides redundant path")

func _test_overload_trip() -> void:
	var state := _empty_state()
	state.batteries[0]["charge"] = 100
	state.poles.assign([_pole(1, Vector2i.ZERO, 4, 1)])
	state.buildings.assign([_building("lab", Vector2i.ZERO, 5)])
	var result: Dictionary = Grid.tick(state)
	_check(bool(result["state"].poles[0]["tripped"]), "Overloaded pole trips breaker")
	_check(not bool(result["state"].poles[0]["on"]), "Tripped pole is off")
	_check(str(result["changes"].filter(func(change: Dictionary) -> bool: return change.get("cause") == "overload").size()) == "1", "Trip cause is recorded")

func _test_line_loss() -> void:
	var state := _empty_state()
	state.hour = 20
	state.solar_arrays.assign([])
	state.batteries.assign([{"id": 1, "tile": Vector2i(-2, 0), "capacity": 100.0, "charge": 100.0}])
	state.poles.assign([_pole(1, Vector2i.ZERO, 2, 50), _pole(2, Vector2i(2, 0), 2, 50), _pole(3, Vector2i(4, 0), 2, 50)])
	state.buildings.assign([_building("hab", Vector2i(4, 0), 10)])
	var result: Dictionary = Grid.compute_grid(state)
	_check(int(result["hop_counts"][3]) == 2, "Line hop count follows chain")
	_check(float(result["total_loss"]) > 0.0, "Line loss is accounted for")

func _test_night_heaters() -> void:
	var state := _empty_state()
	state.hour = 20
	state.solar_arrays.assign([])
	state.buildings.assign([_building("module", Vector2i.ZERO, 0)])
	var night_demand: float = Grid.compute_grid(state)["total_demand"]
	state.hour = 12
	var day_demand: float = Grid.compute_grid(state)["total_demand"]
	_check(night_demand > day_demand, "Night heater load remains active")
	_check(is_zero_approx(Grid.solar_curve(20)), "Night solar output is zero")

func _test_forecast_matches_night() -> void:
	var state := _empty_state()
	state.hour = 18
	state.solar_arrays.assign([])
	state.batteries[0]["charge"] = 80.0
	state.buildings.assign([_building("hab", Vector2i.ZERO, 2, "high", true)])
	var forecast: Dictionary = Grid.forecast_night(state)
	var current: State = State.from_data(state.to_data())
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x0A57
	var predicted: Array = forecast["trajectory"]
	var matched := true
	for i in predicted.size():
		var next: Dictionary = Grid.tick(current, [], rng)
		current = next["state"]
		if not is_equal_approx(float(predicted[i]["charge"]), float(next["battery_charge"])): matched = false
	_check(matched, "Forecast battery matches actual night ticks")
	_check(predicted.size() == 12, "Night forecast covers evening through dawn")

func _test_reserve_fault() -> void:
	var state := _empty_state()
	state.hour = 22
	state.solar_arrays.assign([])
	state.batteries[0]["charge"] = 1.0
	state.buildings.assign([_building("hab", Vector2i.ZERO, 3, "high", true)])
	var result: Dictionary = Grid.tick(state)
	_check(bool(result["reserve_hit"]), "Battery crossing reserve is reported")
	_check(bool(result["state"].buildings[0]["low_power_fault"]), "Connected building enters low-power fault")

func _test_determinism() -> void:
	var state := _empty_state()
	state.hour = 23
	var a_rng := RandomNumberGenerator.new()
	var b_rng := RandomNumberGenerator.new()
	a_rng.seed = 2468
	b_rng.seed = 2468
	var weather := {"dust_devil_clean": 0.5}
	var a: Dictionary = Grid.advance_sol(state, a_rng, weather)
	var b: Dictionary = Grid.advance_sol(state, b_rng, weather)
	_check(a["state"].to_data() == b["state"].to_data(), "Fixed seed produces identical Sol result")
	_check(a["changes"] == b["changes"], "Fixed seed produces identical debrief changes")

func _test_action_costs() -> void:
	var t: Dictionary = Tuning.preset()
	var pole: Dictionary = Grid.place_pole_action(Vector2i(4, 4), 2, 7, t)
	_check(Grid.total_cost(pole) > 0.0, "Pole placement has a nonzero cost")
	_check(Grid.total_cost(Grid.action("switch", 1, t)) > 0.0, "Switch action has a nonzero cost")
	_check(Grid.total_cost(Grid.action("reset_breaker", 1, t)) > 0.0, "Breaker reset has a nonzero cost")
	_check(Grid.total_cost(Grid.action("clean_panels", null, t)) > 0.0, "Panel cleaning has a nonzero cost")
	_check(Grid.total_cost(Grid.action("repair_building", "hab", t)) > 0.0, "Repair has a nonzero cost")
	_check(Grid.total_cost(Grid.action("upgrade_building", "hab", t)) > 0.0, "Upgrade has a nonzero cost")
	var a := {"deltas": {"air": -2.0, "materials": 1.0}}
	var b := {"deltas": {"air": -1.0, "materials": -1.0}}
	_check(not Grid.strictly_dominates_choice(a, b) and not Grid.strictly_dominates_choice(b, a), "Sibling event options have a tradeoff")

func _test_priority_shedding() -> void:
	var state := _empty_state()
	state.solar_arrays.assign([{"id": 1, "tile": Vector2i.ZERO, "count": 1, "dust": 0.0}])
	state.batteries[0]["charge"] = 0.0
	state.poles.assign([_pole(1, Vector2i.ZERO, 10, 100)])
	state.buildings.assign([_building("life", Vector2i.ZERO, 2, "high", true), _building("lab", Vector2i.ZERO, 5, "low")])
	var result: Dictionary = Grid.tick(state)
	_check(result["shed"].has("lab"), "Low-priority work sheds before life support")

func _test_placement_rules() -> void:
	var state := _empty_state()
	var free_site: Dictionary = PlacementRules.validate(state, Vector2i(1, 0), "battery", "sand_dust")
	_check(bool(free_site["valid"]), "Powered clear tile is valid")
	var cliff: Dictionary = PlacementRules.validate(state, Vector2i(1, 0), "battery", "cliff_ridge")
	_check(not bool(cliff["valid"]) and cliff["reason"] == "cliff", "Cliff tile is rejected")
	var unexplored: Dictionary = PlacementRules.validate(state, Vector2i(1, 0), "battery", "sand_dust", false)
	_check(not bool(unexplored["valid"]) and unexplored["reason"] == "unexplored", "Unexplored tile is rejected")
	var overlap: Dictionary = PlacementRules.validate(state, Vector2i.ZERO, "battery", "sand_dust")
	_check(not bool(overlap["valid"]) and overlap["reason"] == "overlaps another building", "Occupied tile is rejected")
	state.hour = 20
	state.solar_arrays.assign([])
	state.batteries[0]["charge"] = 0.0
	state.poles[0]["on"] = false
	var unpowered: Dictionary = PlacementRules.validate(state, Vector2i(1, 0), "battery", "sand_dust")
	_check(not bool(unpowered["valid"]) and unpowered["reason"] == "not powered", "Unpowered tile is rejected")

func _test_move_cost_scaling() -> void:
	var state := _empty_state()
	state.buildings.assign([_building("lab", Vector2i(1, 1), 1)])
	var near: Dictionary = Grid.move_building_action(state, "lab", Vector2i(2, 1))
	var far: Dictionary = Grid.move_building_action(state, "lab", Vector2i(10, 1))
	_check(float(far["cost"]["materials"]) > float(near["cost"]["materials"]), "Move material cost scales with distance")
	_check(float(far["cost"]["crew_hours"]) > float(near["cost"]["crew_hours"]), "Move crew cost scales with distance")
	_check(int(far["downtime"]) >= int(near["downtime"]), "Move downtime scales with distance")
	var moved: Dictionary = Grid.apply_action(state, near)
	_check(bool(moved["ok"]), "Move action applies through the shared action system")
	_check(int(moved["state"].buildings[0]["offline_until_sol"]) == state.sol + int(near["downtime"]), "Moved building records downtime")
	var array_move: Dictionary = Grid.move_building_action(state, "solar_array:1", Vector2i(3, 0))
	var moved_array: Dictionary = Grid.apply_action(state, array_move)
	_check(bool(moved_array["ok"]), "Solar array can use move mode")
	_check(moved_array["state"].solar_arrays[0]["tile"] == Vector2i(3, 0), "Moved solar array changes tile")
	_check(float(array_move["cost"]["materials"]) > 0.0, "Solar array move shows size-scaled cost")

func _test_switch_updates_forecast() -> void:
	var state := _empty_state()
	state.hour = 18
	state.solar_arrays.assign([])
	state.batteries[0]["charge"] = 20.0
	state.buildings.assign([_building("hab", Vector2i.ZERO, 4, "high", true)])
	var before: Dictionary = Grid.forecast_night(state)
	var switch_action: Dictionary = Grid.action("switch", 1)
	var switched: Dictionary = Grid.apply_action(state, switch_action)
	var after: Dictionary = Grid.forecast_night(switched["state"])
	_check(before["zero_hour"] != null, "Baseline forecast reaches empty battery")
	_check(after["zero_hour"] == null, "Switching off pole updates the forecast")

func _test_decision_ledger_and_delayed_effects() -> void:
	var state := _empty_state()
	state.hour = 23
	var choice := {"id": "storm_prep", "option": "Save crew time", "deltas": {"materials": -2.0},
		"delayed_effects": [{"trigger_sol": 2, "description": "storm preparation", "effects": {"food": -0.25}}],
		"legacy_tags": ["prepared_for_storm"]}
	var result: Dictionary = Grid.tick(state, [Grid.event_choice_as_action(choice)])
	var next: State = result["state"]
	_check(next.decision_ledger.size() == 1, "Major option is recorded in the decision ledger")
	_check(next.decision_ledger[0]["legacy_tags"].has("prepared_for_storm"), "Decision legacy tags are retained")
	_check(next.delayed_effects.is_empty(), "Due delayed effect is removed after firing")
	_check(is_equal_approx(next.food, state.food - 0.25 - 0.18 / 24.0), "Delayed effect fires on its trigger Sol alongside hourly food use")
	_check(result["changes"].any(func(change: Dictionary) -> bool: return change.get("cause") == "delayed_effect"), "Delayed effect explains itself in the debrief")

func _test_seeded_hazard_windows() -> void:
	var a := Hazards.schedule_for_seed(12345)
	var b := Hazards.schedule_for_seed(12345)
	_check(a == b, "Hazard schedule is repeatable for a fixed seed")
	var regional: Dictionary = a.filter(func(item: Dictionary) -> bool: return item["type"] == "regional_storm")[0]
	var global_storm: Dictionary = a.filter(func(item: Dictionary) -> bool: return item["type"] == "global_storm")[0]
	_check(int(regional["start_sol"]) >= 10 and int(regional["start_sol"]) <= 12, "Regional storm lands in its story window")
	_check(int(global_storm["start_sol"]) >= 20 and int(global_storm["start_sol"]) <= 22, "Large storm lands in its story window")

func _test_sky_dust_and_panel_dust_are_separate() -> void:
	var state := _empty_state()
	state.sol = 10
	state.hour = 23
	state.hazard_schedule = [{"type": "regional_storm", "start_sol": 10, "end_sol": 10}]
	state.solar_arrays[0]["dust"] = 0.3
	var weather: Dictionary = Hazards.weather_for_sol(state)
	state.hour = 12
	var clear_generation := Grid.solar_generation(state, Tuning.preset(), {"storm_light_factor": 1.0})
	var storm_generation := Grid.solar_generation(state, Tuning.preset(), weather)
	_check(float(weather["storm_light_factor"]) < 1.0 and storm_generation < clear_generation, "Sky dust reduces sunlight generation")
	state.hour = 23
	var result: Dictionary = Grid.tick(state, [Grid.action("clean_panels")], null, weather)
	_check(is_equal_approx(float(result["state"].solar_arrays[0]["dust"]), 0.03 * 1.8), "Cleaning panels during a storm is followed by continuing dust settlement")
	_check(is_equal_approx(float(state.solar_arrays[0]["dust"]), 0.3), "Sky dust does not mutate the panel dust layer")

func _test_weather_station_warning_and_power() -> void:
	var state := _empty_state()
	state.sol = 10
	state.hazard_schedule = [{"type": "regional_storm", "start_sol": 10, "end_sol": 10}]
	var late: Dictionary = Hazards.weather_for_sol(state)
	_check(str(late["warning"]).begins_with("Late warning"), "No powered station gives a late Earth warning")
	var station: Dictionary = Grid.apply_action(state, Grid.place_weather_station_action(Vector2i(1, 0)))
	var early: Dictionary = Hazards.weather_for_sol(station["state"])
	_check(str(early["warning"]).begins_with("Storm warning"), "A powered weather station gives a useful warning")
	var switched: Dictionary = Grid.apply_action(station["state"], Grid.action("switch", 1))
	var off_grid: Dictionary = Hazards.weather_for_sol(switched["state"])
	_check(str(off_grid["warning"]).begins_with("Late warning"), "Switching off the grid can remove the early warning")

func _test_particle_event_safe_mode_and_shelter() -> void:
	var state := _empty_state()
	state.hour = 23
	state.buildings.assign([_building("laboratory", Vector2i.ZERO, 1), _building("greenhouse", Vector2i.ZERO, 1)])
	state.hazard_schedule = [{"type": "solar_particle_event", "start_sol": 2, "end_sol": 2}]
	var event: Dictionary = Grid.tick(state)
	_check(bool(event["state"].flags.get("safe_mode", false)), "Particle event resets electronics into safe mode")
	_check(float(event["state"].dose) > float(state.dose), "Unprotected crew receive an exaggerated event dose")
	var recovery: Dictionary = Grid.apply_action(event["state"], Grid.action("recover_safe_mode"))
	_check(bool(recovery["ok"]) and not bool(recovery["state"].flags.get("safe_mode", true)), "Safe mode can be cleared with a crew action")
	var shelter := _empty_state()
	shelter.buildings.assign([_building("greenhouse", Vector2i.ZERO, 1), _building("laboratory", Vector2i.ZERO, 1)])
	var drill: Dictionary = Grid.apply_action(shelter, Grid.action("shelter_drill"))
	_check(not bool(drill["state"].buildings[0]["work_enabled"]) and not bool(drill["state"].buildings[1]["work_enabled"]), "Shelter drill pauses greenhouse care and science")
	var protected := _empty_state()
	protected.sol = 2
	protected.hazard_schedule = state.hazard_schedule
	protected.flags["crew_sheltered_sol"] = 2
	var protected_changes: Array[Dictionary] = []
	Hazards.process_sol_start(protected, protected_changes)
	_check(is_zero_approx(float(protected.dose)), "Sheltering blocks the event dose spike")

func _test_rover_grid_charging() -> void:
	var state := _empty_state()
	state.hour = 20
	state.rovers.assign([{"id": "Nomad-1", "class": "spirit", "tile": Vector2i(1, 0), "charge": 0.0, "capacity": 20.0, "stuck": false}])
	var before := float(state.batteries[0]["charge"])
	var result: Dictionary = Rovers.charge_from_grid(state, "Nomad-1", 8.0)
	_check(bool(result["ok"]), "Connected rover can recharge from the shared grid")
	_check(is_equal_approx(float(state.rovers[0]["charge"]), 8.0), "Grid energy reaches the rover battery")
	_check(float(state.batteries[0]["charge"]) < before, "Night rover recharge competes with the habitat battery")

func _test_rover_sample_and_bulk_collection() -> void:
	var state := _empty_state()
	state.rovers.assign([{"id": "Spirit", "class": "spirit", "cargo_samples": []}, {"id": "Hauler", "class": "rassor", "bulk_tonnes": 0.0}])
	var sample: Dictionary = Rovers.collect_sample(state, "Spirit", "clay")
	_check(bool(sample["ok"]) and sample["sample"]["type"] == "hydrated minerals", "Spirit tribute rover collects research samples")
	_check(not bool(Rovers.collect_bulk(state, "Spirit", 1.0)["ok"]), "Scout rovers cannot collect bulk materials")
	var bulk: Dictionary = Rovers.collect_bulk(state, "Hauler", 1.25)
	_check(bool(bulk["ok"]) and is_equal_approx(state.bulk_regolith_tonnes, 1.25), "Hauler collects tonnes of building material separately")
	_check(not Rovers.can_collect_sample(state.rovers[0], "water_ice"), "No easy water ice is assigned to Jezero terrain")

func _test_stuck_rover_recovery_cost() -> void:
	var state := _empty_state()
	state.rovers.assign([{"id": "Spirit", "class": "spirit", "charge": 20.0, "capacity": 40.0, "stuck": true, "status": "stuck"}])
	var action := Rovers.recovery_action("Spirit")
	_check(Grid.total_cost(action) > 0.0, "Soft-sand recovery shows crew and power cost")
	var result: Dictionary = Grid.apply_action(state, action)
	_check(bool(result["ok"]) and not bool(result["state"].rovers[0]["stuck"]), "Crew can recover a stuck rover through a costed action")

func _test_research_requires_discovery_and_prerequisites() -> void:
	var state := _empty_state()
	_check(not bool(Research.can_start(state, "P1")["ok"]), "Research cannot start before a discovery")
	Research.discover_from_sample(state, "hydrated minerals")
	var blocked: Dictionary = Research.can_start(state, "A2")
	_check(not bool(blocked["ok"]) and str(blocked["reason"]).contains("A1"), "Research prerequisite is enforced")
	var atmosphere_nodes := Research.discover_from_reading(state, "atmosphere")
	_check(atmosphere_nodes.has("A1") and atmosphere_nodes.has("E1"), "Atmosphere reading unlocks matching research")
	var p1 := Research.start_action(state, "A1")
	var started: Dictionary = Grid.apply_action(state, p1)
	_check(bool(started["ok"]) and not started["state"].flags["research"]["project"].is_empty(), "Developing a node uses the shared costed action system")

func _test_research_pauses_at_night_and_can_corrupt() -> void:
	var state := _empty_state()
	Research.discover_from_sample(state, "basalt and rock")
	var started: Dictionary = Grid.apply_action(state, Research.start_action(state, "P1"))
	state = started["state"]
	var progress := Research.advance_sol(state, true)
	_check(bool(progress["advanced"]) and Research.project_days_remaining(state) == 1, "Powered lab advances research by a Sol")
	var paused := Research.advance_sol(state, false)
	_check(not bool(paused["advanced"]) and Research.project_days_remaining(state) == 1, "Night lab shutoff pauses a project")
	var corrupt := Research.advance_sol(state, true, true)
	_check(not bool(corrupt["advanced"]) and int(state.flags["research"]["project"]["progress_sols"]) == 0, "Particle event can corrupt project progress")
	var finished := Research.advance_sol(state, true)
	Research.advance_sol(state, true)
	_check(not bool(finished["complete"]) and state.flags["research"]["completed"].has("P1"), "A project eventually completes after the lost progress is rebuilt")

func _test_campaign_cannot_finish_every_research_node() -> void:
	var total_sols := 0
	for node: Dictionary in Research.NODES.values(): total_sols += int(node["sols"])
	_check(Research.NODES.size() == 12, "Research tree includes twelve nodes in five branches")
	_check(total_sols > Research.CAMPAIGN_SOLS, "Minimum one-project-at-a-time research duration exceeds the 30-Sol campaign")

func _test_supply_requests_cutoff_cooldown_and_blackout() -> void:
	var state := _empty_state()
	state.buildings.assign([_building("antenna", Vector2i.ZERO, 0.15)])
	var first: Dictionary = Communications.request_from_earth(state, "spare_wiring")
	_check(bool(first["ok"]) and int(first["record"]["light_time_minutes"]) >= 3, "Powered antenna sends a request with a Mars light-time estimate")
	var cooldown: Dictionary = Communications.request_from_earth(state, "seed_pack")
	_check(not bool(cooldown["ok"]), "Request cooldown is enforced")
	state.sol = 6
	var late: Dictionary = Communications.request_from_earth(state, "solar_cells")
	_check(bool(late["ok"]) and bool(late["record"]["for_next_crew"]), "After the cutoff, requests are added to the handover for the next crew")
	_check(state.flags["handover_requests"].size() == 1, "Late supply request is retained for handover")
	state.sol = 28
	_check(Communications.in_blackout(state), "Final three Sols are in communications blackout")
	_check(not bool(Communications.request_from_earth(state, "parts")["ok"]), "Blackout blocks new requests")

func _test_comms_replies_stale_advice_and_cargo_arrival() -> void:
	var state := _empty_state()
	state.buildings.assign([_building("antenna", Vector2i.ZERO, 0.15)])
	Communications.request_from_earth(state, "battery_cells")
	state.sol = 2
	var delivered := Communications.process_sol(state)
	_check(delivered.size() == 1 and int(delivered[0]["arrives_sol"]) == 2, "Earth reply arrives the following Sol")
	state.sol = 4
	Communications.process_sol(state)
	_check(bool(state.flags["communications"]["inbox"][0]["stale"]), "Unread advice becomes visibly stale after conditions have time to change")
	state.sol = Communications.CARGO_ARRIVAL_SOL
	var materials_before := state.materials
	var parts_before := state.earth_parts
	Communications.process_sol(state)
	_check(bool(state.flags["communications"]["cargo_landed"]), "Scheduled cargo lands around Sol 14")
	_check(is_equal_approx(state.materials, materials_before + 20.0) and is_equal_approx(state.earth_parts, parts_before + 3.0), "Cargo landing replenishes building materials and Earth parts")
	_check(Communications.cargo_manifest(state).size() <= 4, "Cargo manifest has a fixed limited slot count")

func _test_default_start_and_first_night() -> void:
	var tuning: Dictionary = Tuning.preset()
	var state: State = State.create_default(tuning)
	_check(int(state.solar_arrays[0]["count"]) == 5, "Default solar array starts with five panels")
	_check(is_equal_approx(float(state.batteries[0]["capacity"]), 180.0) and is_equal_approx(float(state.batteries[0]["charge"]), 135.0), "Default battery starts at 135 of 180 power units")
	var rng := RandomNumberGenerator.new()
	rng.seed = state.mission_seed
	var reserve_breach := false
	var clear_weather := {"storm_light_factor": 1.0, "dust_per_sol": 0.0, "dust_devil_clean": 0.0}
	for _hour in 24:
		var result: Dictionary = Grid.tick(state, [], rng, clear_weather, tuning)
		reserve_breach = reserve_breach or bool(result["reserve_hit"])
		state = result["state"]
	_check(not reserve_breach, "Default start survives its first night without a reserve breach")

func _test_cleaning_prevents_reserve_breaches() -> void:
	var tuning: Dictionary = Tuning.preset()
	var state: State = State.create_default(tuning)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5501
	var reserve_breach := false
	var clear_weather := {"storm_light_factor": 1.0, "dust_per_sol": 0.03, "dust_devil_clean": 0.0}
	for _hour in 720:
		var actions: Array[Dictionary] = []
		if state.hour == 6 and state.sol > 1 and posmod(state.sol, 3) == 0:
			actions.append(Grid.action("clean_panels", null, tuning))
		var result: Dictionary = Grid.tick(state, actions, rng, clear_weather, tuning)
		reserve_breach = reserve_breach or bool(result["reserve_hit"])
		state = result["state"]
	_check(not reserve_breach, "Cleaning panels every three Sols prevents reserve breaches across 30 clear Sols")

func _test_dust_causes_reserve_breach_without_cleaning() -> void:
	var tuning: Dictionary = Tuning.preset()
	var state: State = State.create_default(tuning)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5501
	var reserve_breach := false
	var clear_weather := {"storm_light_factor": 1.0, "dust_per_sol": 0.03, "dust_devil_clean": 0.0}
	for _hour in 720:
		var result: Dictionary = Grid.tick(state, [], rng, clear_weather, tuning)
		reserve_breach = reserve_breach or bool(result["reserve_hit"])
		state = result["state"]
	_check(reserve_breach, "Uncleaned panel dust causes at least one reserve breach across 30 clear Sols")

func _test_toggle_work_night_and_midnight() -> void:
	var tuning: Dictionary = Tuning.preset()
	var state := _empty_state()
	state.hour = 19
	var lab := _building("lab", Vector2i.ZERO, 2.0)
	lab["heater_load"] = 0.5
	state.buildings.assign([lab])
	var demand_before := float(Grid.compute_grid(state, tuning)["total_demand"])
	var toggled: Dictionary = Grid.tick(state, [Grid.action("toggle_work", "lab", tuning)], null, {"storm_light_factor": 1.0}, tuning)
	var next: State = toggled["state"]
	_check(float(Grid.compute_grid(next, tuning)["total_demand"]) < demand_before, "Switching off a lab lowers night demand while its heater stays on")
	for _hour in 8:
		var result: Dictionary = Grid.tick(next, [], null, {"storm_light_factor": 1.0}, tuning)
		next = result["state"]
	_check(not bool(next.buildings[0]["work_enabled"]) and bool(next.buildings[0]["manual_off"]), "A manual work shutdown survives the midnight rollover")

func _test_habitat_work_toggle_is_noop() -> void:
	var state := _empty_state()
	var habitat := _building("habitat", Vector2i.ZERO, 1.0, "high", true)
	state.buildings.assign([habitat])
	var result: Dictionary = Grid.apply_action(state, Grid.action("toggle_work", "habitat"))
	_check(bool(result["state"].buildings[0]["work_enabled"]), "Habitat work cannot be toggled off")

func _test_store_failure_state() -> void:
	var state := _empty_state()
	state.air = 0.001
	state.buildings.assign([])
	var result: Dictionary = Grid.tick(state, [], null, {"storm_light_factor": 1.0})
	_check(bool(result["state"].flags.get("mission_failed", false)) and str(result["state"].flags.get("failure_cause", "")) == "air", "A store reaching zero records a mission failure and its cause")

func _test_production_requires_power_and_work() -> void:
	var powered := _empty_state()
	powered.food = 1.0
	var greenhouse := _building("greenhouse", Vector2i.ZERO, 0.1)
	greenhouse["heater_load"] = 0.0
	powered.buildings.assign([greenhouse])
	var powered_result: Dictionary = Grid.tick(powered, [], null, {"storm_light_factor": 1.0}, Tuning.preset())
	var powered_food := float(powered_result["state"].food)
	var unpowered := _empty_state()
	unpowered.food = 1.0
	unpowered.poles.assign([])
	unpowered.buildings.assign([greenhouse.duplicate(true)])
	var unpowered_result: Dictionary = Grid.tick(unpowered, [], null, {"storm_light_factor": 1.0}, Tuning.preset())
	var disabled := _empty_state()
	disabled.food = 1.0
	var disabled_greenhouse := greenhouse.duplicate(true)
	disabled_greenhouse["work_enabled"] = false
	disabled.buildings.assign([disabled_greenhouse])
	var disabled_result: Dictionary = Grid.tick(disabled, [], null, {"storm_light_factor": 1.0}, Tuning.preset())
	_check(powered_food > float(unpowered_result["state"].food), "Powered and enabled greenhouse produces food")
	_check(is_equal_approx(float(unpowered_result["state"].food), float(disabled_result["state"].food)), "Unpowered or disabled greenhouse does not produce food")

func _test_zero_cost_story_choice_is_recorded() -> void:
	var state := _empty_state()
	var action_data := {"type": "event_choice", "choice_id": "skip", "option": "Keep the current plan", "effects": {}, "cost": {}}
	var result: Dictionary = Grid.apply_action(state, action_data)
	_check(bool(result["ok"]), "A no-cost story fallback can be applied through the action system")
	_check(result["state"].decision_ledger.size() == 1 and str(result["state"].decision_ledger[0]["option"]) == "Keep the current plan", "A no-cost story fallback appears in the handover ledger")

func _test_rover_dispatch_preview_and_action() -> void:
	var tuning: Dictionary = Tuning.preset()
	var state: State = State.create_default(tuning)
	var rover: Dictionary = state.rovers[0]
	var destination := Vector2i(36, 31)
	var preview: Dictionary = Rovers.dispatch_preview(rover, destination, "geological_outcrop", tuning)
	_check(bool(preview["valid"]) and is_equal_approx(float(preview["rover_charge"]), 1.0), "Rover dispatch preview checks sample sites, range, and charge")
	_check(not bool(Rovers.dispatch_preview(rover, Vector2i(63, 63), "geological_outcrop", tuning)["valid"]), "Rover dispatch preview rejects destinations beyond range")
	_check(not bool(Rovers.dispatch_preview(rover, destination, "rocky_plains", tuning)["valid"]), "Rover dispatch preview only accepts known sample sites")
	var low_charge_rover: Dictionary = rover.duplicate(true)
	low_charge_rover["charge"] = 15.0
	var risky_trip: Dictionary = Rovers.dispatch_preview(low_charge_rover, Vector2i(52, 31), "geological_outcrop", tuning)
	_check(bool(risky_trip["valid"]) and bool(risky_trip["may_get_stuck"]), "Rover preview warns when its charge cannot cover the return trip")
	var action_data: Dictionary = Rovers.dispatch_action(str(rover["id"]), destination, tuning)
	var result: Dictionary = Grid.apply_action(state, action_data)
	_check(bool(result["ok"]) and str(result["state"].rovers[0]["status"]) == "dispatched", "Dispatch action spends its tuned cost and records the rover destination")

func _test_story_chapter_windows_and_dilemmas() -> void:
	_check(Story.chapter_for_sol(1)["id"] == "landing" and Story.chapter_for_sol(4)["id"] == "landing", "Landing chapter covers Sols 1 through 4")
	_check(Story.chapter_for_sol(5)["id"] == "first_power" and Story.chapter_for_sol(9)["id"] == "first_power", "First power chapter covers Sols 5 through 9")
	_check(Story.chapter_for_sol(10)["id"] == "dust" and Story.chapter_for_sol(14)["id"] == "dust", "Dust chapter covers Sols 10 through 14")
	_check(Story.chapter_for_sol(15)["id"] == "findings" and Story.chapter_for_sol(19)["id"] == "findings", "Findings chapter covers Sols 15 through 19")
	_check(Story.chapter_for_sol(20)["id"] == "storm" and Story.chapter_for_sol(26)["id"] == "storm", "Storm chapter covers Sols 20 through 26")
	_check(Story.chapter_for_sol(27)["id"] == "handover" and Story.chapter_for_sol(30)["id"] == "handover", "Handover chapter covers Sols 27 through 30")
	var options := Story.options_for("storm_prep")
	_check(options.size() == 3, "A story dilemma presents three options")
	for option: Dictionary in options: _check(Grid.total_cost(Grid.event_choice_as_action(option)) > 0.0, "Every dilemma choice has a real cost")
	_check(not Grid.strictly_dominates_choice(options[0], options[1]) and not Grid.strictly_dominates_choice(options[1], options[0]), "Dilemma options preserve trade-offs")

func _test_handover_uses_decision_ledger_and_retry_seed() -> void:
	var state := _empty_state()
	var decision: Dictionary = Grid.apply_action(state, Story.choose_action("science_or_food", "lab"))
	state = decision["state"]
	state.flags["handover_requests"] = [{"item": "solar_cells", "requested_sol": 6, "for_next_crew": true}]
	var report: Dictionary = Story.handover_report(state)
	_check(report["influential_decisions"].size() == 1 and int(report["influential_decisions"][0]["sol"]) == state.sol, "Handover report draws from the decision ledger")
	_check(report["next_crew_requests"].size() == 1, "Handover report carries late supply requests")
	var retry: State = Story.retry_with_new_seed(state)
	_check(retry.mission_seed != state.mission_seed and retry.flags["retry_of_seed"] == state.mission_seed, "Retry records a new deterministic seed")
	_check(retry.hazard_schedule != state.hazard_schedule, "Retry regenerates hazards from its new seed")

func _test_data_sources_are_labeled_and_cited() -> void:
	_check(DataSources.ARCHIVED_SOLAR_EVENTS.size() > 0, "Historic solar replay has an archived event")
	_check(DataSources.ARCHIVED_SOLAR_EVENTS[0]["date"] == "2017-09-06" and DataSources.ARCHIVED_SOLAR_EVENTS[0]["class"] == "X9.3", "September 2017 flare record is identified")
	var has_unverified_label := false
	var has_meda := false
	var has_osdr_note := false
	for record: Dictionary in DataSources.RECORDS:
		if str(record["label"]).contains("UNVERIFIED"): has_unverified_label = true
		if str(record["name"]).contains("MEDA") and str(record["url"]).begins_with("https://"): has_meda = true
		if str(record["name"]).contains("OSDR") and str(record["label"]).contains("Not yet curated"): has_osdr_note = true
	_check(has_meda and has_osdr_note and has_unverified_label, "Data screen cites MEDA and labels unverified or uncurated records")
	_check(DataSources.live_api_key() != "", "Live NASA API key falls back to DEMO_KEY")

func _test_badges_and_generated_patch() -> void:
	var earned: Array[String] = Badges.earned_for_state(State.create_default())
	_check(Badges.BADGES.size() >= 22, "Badge catalog includes the requested families")
	_check(earned.has("foothold") and earned.has("first_light"), "Badge evaluation recognizes a prepared starter outpost")
	var patch_svg := Badges.mission_patch_svg(2468, earned, "Jezero outpost")
	_check(patch_svg.begins_with("<svg") and patch_svg.contains("2468") and patch_svg.contains("Jezero outpost"), "Mission patch includes seed and layout")
	_check(not patch_svg.contains("NASA"), "Mission patch uses no NASA logo")
