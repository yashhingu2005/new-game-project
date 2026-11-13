class_name OutpostTuning
extends RefCounted

## All simulation figures live here. Values are placeholders unless a basis is stated.
const GAME := {
	"sol_hours": 24, # Placeholder: time-compressed game clock uses 24 hourly steps per Sol.
	"mars_sol_earth_hours": 24.660, # Mars mean solar day is 24 h 39 m 35.244 s. Source: https://www.giss.nasa.gov/tools/mars24/help/notes.html
	"day_fraction": 0.5, # Placeholder: 12 simulated hours of daylight.
	"solar_peak_per_panel": 6.0, # Placeholder game power units/panel/hour.
	"dust_per_sol": 0.03, # Exaggerated gameplay rate; real observed rates are much lower.
	"storm_light_factor": 0.35, # Placeholder.
	"battery_capacity": 180.0, # Placeholder game power units per battery.
	"battery_tech_bonus": 45.0, # Placeholder.
	"charge_efficiency": 0.9, # Placeholder.
	"discharge_efficiency": 0.9, # Placeholder.
	"reserve_fraction": 0.2, # Placeholder reserve threshold for gameplay.
	"dose_warning_limit_msv": 100.0, # Placeholder game warning line, not a crew medical limit.
	"dose_per_sol_msv": 3.0, # Exaggerated play rate; about 0.67 mSv/day was reported by Curiosity RAD. Source: https://www.nasa.gov/news-release/nasa-rover-results-include-first-age-measurement-on-mars-and-help-for-human-exploration/
	"air_per_sol": 0.15, # Placeholder air consumption per Sol.
	"water_per_sol": 0.2, # Placeholder water consumption per Sol.
	"food_per_sol": 0.18, # Placeholder food consumption per Sol.
	"greenhouse_food_per_sol": 0.12, # Placeholder greenhouse production per Sol.
	"oxygen_generator_air_per_sol": 0.12, # Placeholder oxygen production per Sol.
	"water_recycler_water_per_sol": 0.16, # Placeholder recycled water per Sol.
	"workshop_materials_per_sol": 2.0, # Placeholder workshop production per Sol.
	"rover_charge_per_tile": 0.5, # Placeholder Nomad-1 battery units used per tile travelled.
	"store_warning_fraction": 0.25, # Placeholder low-store warning point.
	"air_capacity": 3.0, # Placeholder air store capacity for warning display.
	"water_capacity": 4.0, # Placeholder water store capacity for warning display.
	"food_capacity": 3.6, # Placeholder food store capacity for warning display.
	"cargo_materials": 20.0, # Placeholder Sol 14 cargo materials.
	"cargo_earth_parts": 3.0, # Placeholder Sol 14 cargo Earth parts.
	"heater_load": 0.8, # Placeholder power units/module/hour.
	"line_loss_per_hop": 0.04, # Placeholder.
	"insulation_reduction_per_level": 0.15, # Placeholder.
	"max_insulation_reduction": 0.75, # Placeholder.
	"life_support_floor": 0.7, # Placeholder fraction of minimum life-support draw.
	"pole_tiers": {
		1: {"radius": 5.0, "capacity": 18.0, "standby": 0.25}, # Placeholder tier 1.
		2: {"radius": 7.0, "capacity": 36.0, "standby": 0.5}, # Placeholder tier 2.
		3: {"radius": 10.0, "capacity": 72.0, "standby": 0.75}, # Placeholder tier 3.
	},
	"action_costs": {
		"switch": {"crew_hours": 0.25}, # Placeholder action cost.
		"reset_breaker": {"crew_hours": 2.0, "materials": 1.0}, # Placeholder action cost.
		"clean_panels": {"crew_hours": 1.0}, # Placeholder action cost.
		"recover_safe_mode": {"crew_hours": 2.0}, # Placeholder recovery time.
		"shelter_drill": {"crew_hours": 0.5}, # Placeholder drill time.
		"raise_shielding": {"crew_hours": 4.0, "materials": 12.0}, # Placeholder build cost.
		"rover_dispatch": {"crew_hours": 2.0, "power": 4.0}, # Placeholder rover task energy and crew time.
		"rover_recover": {"crew_hours": 3.0, "power": 8.0}, # Placeholder soft-sand recovery cost.
		"rover_emergency_recharge": {"power": 15.0}, # Placeholder shared-grid recharge draw.
		"repair_building": {"crew_hours": 3.0, "materials": 2.0}, # Placeholder action cost.
		"upgrade_building": {"crew_hours": 4.0, "materials": 10.0, "earth_parts": 1.0}, # Placeholder action cost.
		"toggle_work": {"crew_hours": 0.25}, # Placeholder action cost.
	},
	"building_costs": {
		"solar_array": {"crew_hours": 3.0, "materials": 10.0, "earth_parts": 1.0}, # Placeholder build cost.
		"battery": {"crew_hours": 4.0, "materials": 12.0, "earth_parts": 2.0}, # Placeholder build cost.
		"weather_station": {"crew_hours": 5.0, "materials": 16.0, "earth_parts": 1.0}, # Placeholder build cost.
		"pole": {
			1: {"crew_hours": 2.0, "power": 1.0, "materials": 8.0, "earth_parts": 1.0},
			2: {"crew_hours": 2.0, "power": 1.0, "materials": 14.0, "earth_parts": 2.0},
			3: {"crew_hours": 2.0, "power": 1.0, "materials": 22.0, "earth_parts": 3.0},
		},
	},
	"move_materials_per_tile": 0.5, # Placeholder, multiplied by building size.
	"move_crew_hours_per_tile": 0.75, # Placeholder, multiplied by building size.
	"move_tiles_per_downtime_sol": 5.0, # Placeholder.
}

const REAL := {
	"sol_hours": 24, # Placeholder: 24 simulation steps per time-compressed Sol.
	"mars_sol_earth_hours": 24.660, # Mars mean solar day is 24 h 39 m 35.244 s. Source: https://www.giss.nasa.gov/tools/mars24/help/notes.html
	"day_fraction": 0.5, # UNVERIFIED placeholder average; daylight varies by season and latitude.
	"solar_peak_per_panel": 0.177, # UNVERIFIED: illustrative kW per panel; must be replaced by sourced hardware assumptions.
	"load_scale": 0.0295, # Placeholder: scale gameplay loads to match the REAL panel power unit.
	"dust_per_sol": 0.002, # UNVERIFIED placeholder: mission dust rates vary and need a cited dataset.
	"storm_light_factor": 0.1, # Placeholder: storm opacity varies widely.
	"battery_capacity": 100.0, # Placeholder kWh per battery unit.
	"battery_tech_bonus": 50.0, # Placeholder kWh.
	"charge_efficiency": 0.9, # Placeholder system-level assumption.
	"discharge_efficiency": 0.9, # Placeholder system-level assumption.
	"reserve_fraction": 0.2, # Placeholder battery reserve threshold.
	"dose_warning_limit_msv": 100.0, # Placeholder warning line; no medical limit is implied.
	"dose_per_sol_msv": 0.67, # Curiosity RAD average at Gale Crater for Aug 2012–Jun 2013, not a Jezero forecast. Source: https://www.nasa.gov/news-release/nasa-rover-results-include-first-age-measurement-on-mars-and-help-for-human-exploration/
	"air_per_sol": GAME.air_per_sol, # Placeholder resource drain reused from the game preset.
	"water_per_sol": GAME.water_per_sol, # Placeholder resource drain reused from the game preset.
	"food_per_sol": GAME.food_per_sol, # Placeholder resource drain reused from the game preset.
	"greenhouse_food_per_sol": GAME.greenhouse_food_per_sol, # Placeholder production reused from the game preset.
	"oxygen_generator_air_per_sol": GAME.oxygen_generator_air_per_sol, # Placeholder production reused from the game preset.
	"water_recycler_water_per_sol": GAME.water_recycler_water_per_sol, # Placeholder production reused from the game preset.
	"workshop_materials_per_sol": GAME.workshop_materials_per_sol, # Placeholder production reused from the game preset.
	"rover_charge_per_tile": GAME.rover_charge_per_tile, # Placeholder rover travel rate reused from the game preset.
	"store_warning_fraction": GAME.store_warning_fraction, # Placeholder warning reused from the game preset.
	"air_capacity": GAME.air_capacity, # Placeholder capacity reused from the game preset.
	"water_capacity": GAME.water_capacity, # Placeholder capacity reused from the game preset.
	"food_capacity": GAME.food_capacity, # Placeholder capacity reused from the game preset.
	"cargo_materials": GAME.cargo_materials, # Placeholder cargo reused from the game preset.
	"cargo_earth_parts": GAME.cargo_earth_parts, # Placeholder cargo reused from the game preset.
	"heater_load": 2.0, # Placeholder kW per module.
	"line_loss_per_hop": 0.01, # Placeholder.
	"insulation_reduction_per_level": 0.15, # Placeholder.
	"max_insulation_reduction": 0.75, # Placeholder.
	"life_support_floor": 0.7, # Placeholder minimum-load fraction.
	"pole_tiers": {
		1: {"radius": 5.0, "capacity": 5.0, "standby": 0.02}, # Placeholder tier 1.
		2: {"radius": 7.0, "capacity": 20.0, "standby": 0.04}, # Placeholder tier 2.
		3: {"radius": 10.0, "capacity": 80.0, "standby": 0.08}, # Placeholder tier 3.
	},
	"action_costs": GAME.action_costs, # Placeholder gameplay costs reused in this preset.
	"building_costs": GAME.building_costs, # Placeholder gameplay costs reused in this preset.
	"move_materials_per_tile": GAME.move_materials_per_tile, # Placeholder.
	"move_crew_hours_per_tile": GAME.move_crew_hours_per_tile, # Placeholder.
	"move_tiles_per_downtime_sol": GAME.move_tiles_per_downtime_sol, # Placeholder.
}

static func preset(name: String = "game") -> Dictionary:
	return (REAL if name.to_lower() == "real" else GAME).duplicate(true)
