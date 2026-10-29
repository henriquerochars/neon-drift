class_name ShowcaseDriver
extends AiDriver
## An AiDriver that also fires nitro and the thrusters on scheduled racing ticks. Used only by
## the README showcase captures (tools/playtest/capture_showcase.gd), never by the game.

## Racing ticks (counted from the first sample after GO) on which to press nitro / jump.
var nitro_ticks: Array[int] = []
var jump_ticks: Array[int] = []
var tick: int = 0


func sample(delta: float) -> DriverInput:
	var result: DriverInput = super(delta)
	if nitro_ticks.has(tick):
		result.nitro = true
	if jump_ticks.has(tick):
		result.jump = true
	tick += 1
	return result


## Parses "120,480" into [120, 480]; empty or missing text gives an empty list.
static func parse_ticks(text: String) -> Array[int]:
	var result: Array[int] = []
	for part: String in text.split(",", false):
		if part.strip_edges().is_valid_int():
			result.append(part.strip_edges().to_int())
	return result
