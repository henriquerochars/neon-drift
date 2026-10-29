class_name UiText
extends RefCounted
## Text formatting shared by the screens and the HUD.

const PLACE_SUFFIXES: Array[String] = ["TH", "ST", "ND", "RD"]
const TEEN_LOW: int = 11
const TEEN_HIGH: int = 13
const SECONDS_PER_MINUTE: int = 60
const HUNDRED: int = 100
const HUNDREDTHS: float = 100.0
const PERCENT: float = 100.0


static func money(amount: int) -> String:
	return "$%d" % amount


static func race_time(seconds: float) -> String:
	var clamped: float = maxf(seconds, 0.0)
	var minutes: int = int(clamped) / SECONDS_PER_MINUTE
	var secs: int = int(clamped) % SECONDS_PER_MINUTE
	var hundredths: int = int((clamped - floorf(clamped)) * HUNDREDTHS)
	return "%d:%02d.%02d" % [minutes, secs, hundredths]


static func place(value: int) -> String:
	var tens: int = value % HUNDRED
	var suffix: String = PLACE_SUFFIXES[0]
	if tens < TEEN_LOW or tens > TEEN_HIGH:
		var unit: int = value % 10
		if unit < PLACE_SUFFIXES.size():
			suffix = PLACE_SUFFIXES[unit]
	return "%d%s" % [value, suffix]


static func percent(fraction: float) -> String:
	return "%d%%" % int(roundf(clampf(fraction, 0.0, 1.0) * PERCENT))


static func tier_pips(tier: int, max_tier: int) -> String:
	var text: String = ""
	for index: int in range(max_tier):
		text += "#" if index < tier else "-"
	return text
