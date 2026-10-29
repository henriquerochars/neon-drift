class_name LocalDriverInputSource
extends DriverInputSource
## The only place that reads Input (AGENTS.md rule 6). Keyboard, gamepad and touch share the
## same InputMap actions; the virtual stick injects actions through Input.action_press.

const ACTION_LEFT: StringName = &"steer_left"
const ACTION_RIGHT: StringName = &"steer_right"
const ACTION_ACCELERATE: StringName = &"accelerate"
const ACTION_BRAKE: StringName = &"brake"
const ACTION_NITRO: StringName = &"nitro"
const ACTION_JUMP: StringName = &"jump"
const ACTION_PAUSE: StringName = &"pause"

## When false (menus, countdown) the source returns a neutral input.
var enabled: bool = true


func sample(_delta: float) -> DriverInput:
	if not enabled:
		input.reset()
		return input
	input.steer = Input.get_axis(ACTION_LEFT, ACTION_RIGHT)
	input.throttle = Input.get_action_strength(ACTION_ACCELERATE)
	input.brake = Input.get_action_strength(ACTION_BRAKE)
	input.nitro = Input.is_action_just_pressed(ACTION_NITRO)
	input.jump = Input.is_action_just_pressed(ACTION_JUMP)
	return input


static func is_pause_pressed() -> bool:
	return Input.is_action_just_pressed(ACTION_PAUSE)
