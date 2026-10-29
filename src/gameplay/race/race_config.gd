class_name RaceConfig
extends RefCounted
## Everything a RaceScene needs to start. Built by the UI (solo) or by NetSession (online).

const KIND_LOCAL: StringName = &"local"
const KIND_AI: StringName = &"ai"
const KIND_REMOTE: StringName = &"remote"


class Participant:
	extends RefCounted
	## Unique in the race: seat index 0..7 offline, peer id online.
	var id: int = 0
	var display_name: String = ""
	var car_id: StringName = &"vortex"
	var paint: int = 0
	## slot -> tier, as stored in PlayerProfile.parts[car_id].
	var tiers: Dictionary = {}
	var kind: StringName = KIND_AI
	## Starting integrity 0..100 (PlayerProfile.integrity_of for the local player).
	var integrity: float = 100.0
	## AI only: 0..1 skill.
	var skill: float = 0.5


var track_id: StringName = &"coast"
var laps: int = 3
var seed: int = 1
var online: bool = false
var participants: Array[Participant] = []


func add_participant(
	id: int, display_name: String, car_id: StringName, kind: StringName, paint: int = 0
) -> Participant:
	var participant: Participant = Participant.new()
	participant.id = id
	participant.display_name = display_name
	participant.car_id = car_id
	participant.kind = kind
	participant.paint = paint
	participants.append(participant)
	return participant


func local_participant() -> Participant:
	for participant: Participant in participants:
		if participant.kind == KIND_LOCAL:
			return participant
	return null
