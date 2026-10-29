class_name RaceContacts
extends RefCounted
## Detects contacts between participants and with roadside scenery for one physics tick.
## Pure detection: the race scene applies the CarSim rules and broadcasts the events.


class Contact:
	extends RefCounted
	var kind: StringName = &""
	## Attacker (crush) or first car (bump) or the only car (scenery).
	var a: int = 0
	## Victim (crush) or second car (bump); unused for scenery.
	var b: int = 0


const KIND_CRUSH: StringName = &"crush"
const KIND_BUMP: StringName = &"bump"
const KIND_SCENERY: StringName = &"scenery"
## Seconds before the same pair can bump again.
const BUMP_COOLDOWN: float = 0.5
const SCENERY_COOLDOWN: float = 0.6
## Lateral tolerance before the object's offset still counts as a hit (road half widths).
const SCENERY_MARGIN: float = 0.1
## Lateral extent of a roadside object beyond its offset (road half widths).
const SCENERY_WIDTH: float = 0.6
const PAIR_STRIDE: int = 1024

var _track: TrackModel
var _pair_cooldown: Dictionary = {}
var _scenery_cooldown: Dictionary = {}
var _scenery_by_segment: Dictionary = {}


func setup(track: TrackModel) -> void:
	_track = track
	_pair_cooldown = {}
	_scenery_cooldown = {}
	_scenery_by_segment = {}
	for item: TrackModel.SceneryItem in track.scenery:
		var list: Array = _scenery_by_segment.get(item.segment, [])
		list.append(item)
		_scenery_by_segment[item.segment] = list


func detect(participants: Array[RaceParticipant], delta: float) -> Array[Contact]:
	var contacts: Array[Contact] = []
	_cool_down(delta)
	for i: int in range(participants.size()):
		var first: RaceParticipant = participants[i]
		for j: int in range(i + 1, participants.size()):
			var second: RaceParticipant = participants[j]
			var contact: Contact = _pair_contact(first, second)
			if contact != null:
				contacts.append(contact)
		var scenery: Contact = _scenery_contact(first)
		if scenery != null:
			contacts.append(scenery)
	return contacts


func _cool_down(delta: float) -> void:
	for key: Variant in _pair_cooldown.keys():
		var left: float = float(_pair_cooldown[key]) - delta
		if left <= 0.0:
			_pair_cooldown.erase(key)
		else:
			_pair_cooldown[key] = left
	for key: Variant in _scenery_cooldown.keys():
		var left: float = float(_scenery_cooldown[key]) - delta
		if left <= 0.0:
			_scenery_cooldown.erase(key)
		else:
			_scenery_cooldown[key] = left


func _pair_contact(first: RaceParticipant, second: RaceParticipant) -> Contact:
	var a: CarState = first.state
	var b: CarState = second.state
	if a.finished or b.finished:
		return null
	if not CarSim.overlaps(a, b, _track.length):
		return null
	var key: int = mini(first.id, second.id) * PAIR_STRIDE + maxi(first.id, second.id)
	if first.landed_this_tick and not b.airborne:
		return _make(KIND_CRUSH, first.id, second.id)
	if second.landed_this_tick and not a.airborne:
		return _make(KIND_CRUSH, second.id, first.id)
	if a.airborne or b.airborne or _pair_cooldown.has(key):
		return null
	_pair_cooldown[key] = BUMP_COOLDOWN
	return _make(KIND_BUMP, first.id, second.id)


func _scenery_contact(participant: RaceParticipant) -> Contact:
	var state: CarState = participant.state
	if state.finished:
		return null
	if absf(state.x) <= 1.0 or state.airborne or _scenery_cooldown.has(participant.id):
		return null
	var items: Array = _scenery_by_segment.get(_track.segment_index(state.z), [])
	for item: TrackModel.SceneryItem in items:
		if signf(item.offset) != signf(state.x):
			continue
		var depth: float = absf(state.x) - absf(item.offset)
		if depth >= -SCENERY_MARGIN and depth < SCENERY_WIDTH:
			_scenery_cooldown[participant.id] = SCENERY_COOLDOWN
			return _make(KIND_SCENERY, participant.id, participant.id)
	return null


static func _make(kind: StringName, a: int, b: int) -> Contact:
	var contact: Contact = Contact.new()
	contact.kind = kind
	contact.a = a
	contact.b = b
	return contact
