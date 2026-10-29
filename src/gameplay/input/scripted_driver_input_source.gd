class_name ScriptedDriverInputSource
extends DriverInputSource
## Deterministic input for tests and bots: set the fields, or queue timed presses.

var _pending_nitro: bool = false
var _pending_jump: bool = false


func hold(steer: float, throttle: float, brake: float = 0.0) -> void:
	input.steer = steer
	input.throttle = throttle
	input.brake = brake


func press_nitro() -> void:
	_pending_nitro = true


func press_jump() -> void:
	_pending_jump = true


func sample(_delta: float) -> DriverInput:
	input.nitro = _pending_nitro
	input.jump = _pending_jump
	_pending_nitro = false
	_pending_jump = false
	return input
