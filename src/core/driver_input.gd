class_name DriverInput
extends RefCounted
## One frame of driver intent. Produced only by DriverInputSource subclasses.

## -1 (left) .. 1 (right).
var steer: float = 0.0
## 0 .. 1.
var throttle: float = 0.0
## 0 .. 1.
var brake: float = 0.0
## Edge-triggered: true only on the tick the button was pressed.
var nitro: bool = false
## Edge-triggered: true only on the tick the button was pressed.
var jump: bool = false


func reset() -> void:
	steer = 0.0
	throttle = 0.0
	brake = 0.0
	nitro = false
	jump = false


func copy_from(other: DriverInput) -> void:
	steer = other.steer
	throttle = other.throttle
	brake = other.brake
	nitro = other.nitro
	jump = other.jump
