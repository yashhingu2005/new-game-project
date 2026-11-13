class_name OutpostCommunicationsSystem
extends RefCounted

const State = preload("res://simulation/mission_state.gd")
const Grid = preload("res://simulation/power_grid.gd")
const Tuning = preload("res://simulation/tuning.gd")

const REQUEST_CUTOFF_SOL := 5 # Story schedule placeholder.
const CARGO_ARRIVAL_SOL := 14 # Story schedule placeholder.
const BLACKOUT_START_SOL := 28 # Final three Sols of the 30-Sol campaign.
const CARGO_MANIFEST := ["solar_cells", "battery_chemistry", "spare_wiring", "seed_pack"] # Fictional campaign cargo; placeholder.

static func state_data(state: State) -> Dictionary:
	if not state.flags.has("communications"):
		state.flags["communications"] = {"next_request_sol": 1, "requests": [], "replies": [], "inbox": [], "cargo_landed": false, "manifest": CARGO_MANIFEST.duplicate()}
	return state.flags["communications"]

static func in_blackout(state: State) -> bool:
	return state.sol >= BLACKOUT_START_SOL

static func request_from_earth(state: State, request: String) -> Dictionary:
	if in_blackout(state): return {"ok": false, "reason": "The Sun is between Mars and Earth; messages are paused."}
	var comms: Dictionary = state_data(state)
	if state.sol < int(comms.get("next_request_sol", 1)):
		return {"ok": false, "reason": "The antenna needs a few Sols before it can send another request."}
	var grid: Dictionary = Grid.compute_grid(state)
	if not grid["powered_buildings"].has("antenna"):
		return {"ok": false, "reason": "The antenna needs power before it can contact Earth."}
	var light_time := 3 + posmod(state.mission_seed + state.sol * 7, 20) # Flavor estimate within cited Mars-Earth range, not an ephemeris.
	var record := {"item": request, "requested_sol": state.sol, "for_next_crew": state.sol > REQUEST_CUTOFF_SOL,
		"light_time_minutes": light_time, "light_time_note": "One-way signal estimate; Mars-Earth light time varies from about 3 to 22 minutes. Source: https://science.nasa.gov/mars/mars-relay-network/"}
	if record["for_next_crew"]:
		state.flags["handover_requests"] = state.flags.get("handover_requests", [])
		state.flags["handover_requests"].append(record.duplicate(true))
	else:
		comms["requests"].append(record)
		comms["replies"].append({"item": request, "sent_sol": state.sol, "arrives_sol": state.sol + 1,
			"light_time_minutes": light_time, "light_time_note": record["light_time_note"]})
	comms["next_request_sol"] = state.sol + 3 # Placeholder cooldown.
	return {"ok": true, "record": record, "reason": "This request is for the next crew." if record["for_next_crew"] else "Earth's reply is expected next Sol."}

static func process_sol(state: State) -> Array[Dictionary]:
	var comms: Dictionary = state_data(state)
	var delivered: Array[Dictionary] = []
	if not in_blackout(state):
		for message: Dictionary in comms["inbox"]:
			if state.sol - int(message.get("sent_sol", state.sol)) > 1:
				message["stale"] = true
		for i in range(comms["replies"].size() - 1, -1, -1):
			var reply: Dictionary = comms["replies"][i]
			if int(reply.get("arrives_sol", 999)) > state.sol: continue
			reply["stale"] = state.sol - int(reply.get("sent_sol", state.sol)) > 1
			reply["text"] = "Earth's advice may be stale; the message took a Sol to arrive and conditions can change."
			comms["inbox"].append(reply)
			delivered.append(reply)
			comms["replies"].remove_at(i)
	if state.sol >= CARGO_ARRIVAL_SOL and not bool(comms.get("cargo_landed", false)):
		comms["cargo_landed"] = true
		comms["landed_sol"] = state.sol
		var tuning: Dictionary = Tuning.preset()
		var materials := float(tuning["cargo_materials"])
		var earth_parts := float(tuning["cargo_earth_parts"])
		state.materials += materials
		state.earth_parts += earth_parts
		delivered.append({"cause": "cargo_landing", "detail": "Cargo landed: +%.0f materials and +%.0f Earth parts." % [materials, earth_parts]})
	return delivered

static func cargo_manifest(state: State) -> Array[String]:
	var comms: Dictionary = state_data(state)
	var items: Array[String] = []
	for item: Variant in comms.get("manifest", []): items.append(str(item))
	return items
