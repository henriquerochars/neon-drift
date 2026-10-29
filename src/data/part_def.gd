class_name PartDef
extends Resource
## A purchasable tuning part. slot is one of Constants.SLOTS, tier 1..3.

@export var id: StringName = &""
@export var slot: StringName = &"engine"
@export_range(1, 3) var tier: int = 1
@export var display_name: String = ""
@export_multiline var description: String = ""
@export var price: int = 500
## Added to the car's rank for that slot (ranks above 5 are capped by Balance rank_bonus_cap).
@export var rank_bonus: float = 0.5
