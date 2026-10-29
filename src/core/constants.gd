class_name Constants
extends RefCounted
## Project-wide constants declared by the architect. Gameplay numbers live in
## data/balance/physics.csv (see Balance) and the .tres content under data/.

const MAX_PLAYERS: int = 8
const VIEWPORT_WIDTH: int = 320
const VIEWPORT_HEIGHT: int = 180
const PAINT_COUNT: int = 8
const DEFAULT_PORT: int = 7777
const INVALID_ID: int = -1

## Participant ids: local or AI participants are 0..7; online participants use the peer id.
const HOST_PEER_ID: int = 1

## Tuning slots, in garage display order.
const SLOTS: Array[StringName] = [
	&"engine",
	&"turbo",
	&"tires",
	&"nitro_tank",
	&"thrusters",
	&"armour",
]
const SLOT_TIERS: int = 3

## Race phases emitted on RaceBus.race_phase_changed.
const PHASE_WAITING: StringName = &"waiting"
const PHASE_COUNTDOWN: StringName = &"countdown"
const PHASE_RACING: StringName = &"racing"
const PHASE_FINISHED: StringName = &"finished"

## Paint colours (hue shift targets), index = paint id.
const PAINTS: Array[Color] = [
	Color("#e23a3a"),
	Color("#f2b134"),
	Color("#3ad1e2"),
	Color("#8d4fd6"),
	Color("#ff5fb4"),
	Color("#3bd36a"),
	Color("#e8e8f0"),
	Color("#23232e"),
]
