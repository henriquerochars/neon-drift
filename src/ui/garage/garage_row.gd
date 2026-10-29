class_name GarageRow
extends HBoxContainer
## One garage line: a tuning slot (tier pips + next price + BUY), the paint row (swatch +
## NEXT) or the repair row (integrity meter + price + FIX). The part name and description of
## the focused row are shown by the screen in its detail line (`focused`).

signal action_pressed
signal focused

const SLOT_LABELS: Dictionary = {
	&"engine": "ENGINE",
	&"turbo": "TURBO",
	&"tires": "TIRES",
	&"nitro_tank": "NITRO",
	&"thrusters": "THRUST",
	&"armour": "ARMOUR",
}
const MAXED_TEXT: String = "MAX"
const BUY_TEXT: String = "BUY"
const PAINT_ACTION_TEXT: String = "NEXT"
const REPAIR_ACTION_TEXT: String = "FIX"
const REPAIR_OK_TEXT: String = "OK"
const PAINT_FORMAT: String = "%d/%d"

## The part offered by a slot row (null when maxed or not a slot row).
var part: PartDef

@onready var slot_label: Label = %SlotLabel
@onready var tier_label: Label = %TierLabel
@onready var swatch: ColorRect = %Swatch
@onready var meter: MeterBar = %Meter
@onready var info_label: Label = %InfoLabel
@onready var action_button: Button = %ActionButton


func _ready() -> void:
	action_button.pressed.connect(func() -> void: action_pressed.emit())
	action_button.focus_entered.connect(func() -> void: focused.emit())


func show_slot(slot: StringName, tier: int, next_part: PartDef, affordable: bool) -> void:
	part = next_part
	slot_label.text = str(SLOT_LABELS.get(slot, String(slot).to_upper()))
	tier_label.visible = true
	tier_label.text = UiText.tier_pips(tier, Constants.SLOT_TIERS)
	swatch.visible = false
	meter.visible = false
	if next_part == null:
		info_label.text = MAXED_TEXT
		action_button.disabled = true
	else:
		info_label.text = UiText.money(next_part.price)
		action_button.disabled = not affordable
	action_button.text = BUY_TEXT


func show_paint(paint: int) -> void:
	part = null
	slot_label.text = "PAINT"
	tier_label.visible = false
	swatch.visible = true
	swatch.color = PaintShift.paint_color(paint)
	meter.visible = false
	info_label.text = PAINT_FORMAT % [paint + 1, Constants.PAINT_COUNT]
	action_button.text = PAINT_ACTION_TEXT
	action_button.disabled = false


func show_repair(integrity: float, price: int, affordable: bool) -> void:
	part = null
	slot_label.text = "REPAIR"
	tier_label.visible = false
	swatch.visible = false
	meter.visible = true
	meter.set_value(integrity / PlayerProfile.FULL_INTEGRITY)
	var needs_repair: bool = integrity < PlayerProfile.FULL_INTEGRITY
	info_label.text = UiText.money(price) if needs_repair else REPAIR_OK_TEXT
	action_button.text = REPAIR_ACTION_TEXT
	action_button.disabled = not (needs_repair and affordable)
