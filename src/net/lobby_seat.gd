class_name LobbySeat
extends Resource
## One lobby slot as replicated by the host: who sits there, what they drive, whether ready.
## Seat 0 is always the host. Serialised to a Dictionary for the seats RPC.

const KEY_PEER_ID: String = "peer_id"
const KEY_SEAT: String = "seat"
const KEY_READY: String = "ready"

var peer_id: int = Constants.INVALID_ID
## Seat index 0..Constants.MAX_PLAYERS - 1; the host sits at 0.
var seat: int = 0
var name: String = GameSettings.DEFAULT_NAME
var car_id: StringName = LobbyProfile.DEFAULT_CAR
var paint: int = 0
var tiers: Dictionary = {}
var integrity: float = LobbyProfile.MAX_INTEGRITY
var ready: bool = false


static func make(seat_peer_id: int, seat_index: int, profile: LobbyProfile) -> LobbySeat:
	var result: LobbySeat = LobbySeat.new()
	result.peer_id = seat_peer_id
	result.seat = seat_index
	result.apply_profile(profile)
	return result


static func from_dictionary(data: Dictionary) -> LobbySeat:
	var result: LobbySeat = make(
		int(data.get(KEY_PEER_ID, Constants.INVALID_ID)),
		clampi(int(data.get(KEY_SEAT, 0)), 0, Constants.MAX_PLAYERS - 1),
		LobbyProfile.from_dictionary(data)
	)
	result.ready = bool(data.get(KEY_READY, false))
	return result


func apply_profile(profile: LobbyProfile) -> void:
	name = profile.name
	car_id = profile.car_id
	paint = profile.paint
	tiers = profile.tiers.duplicate()
	integrity = profile.integrity


func profile() -> LobbyProfile:
	return LobbyProfile.make(name, car_id, paint, tiers, integrity)


func to_dictionary() -> Dictionary:
	var data: Dictionary = profile().to_dictionary()
	data[KEY_PEER_ID] = peer_id
	data[KEY_SEAT] = seat
	data[KEY_READY] = ready
	return data
