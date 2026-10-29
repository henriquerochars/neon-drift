class_name DriverInputSource
extends RefCounted
## Abstract producer of DriverInput. Subclasses: LocalDriverInputSource (keyboard, gamepad,
## touch), ScriptedDriverInputSource (tests, replays), AiDriver (src/gameplay/ai).

var input: DriverInput = DriverInput.new()


## Fill `input` for this physics tick and return it. Edge flags must be true for one tick only.
func sample(_delta: float) -> DriverInput:
	return input
