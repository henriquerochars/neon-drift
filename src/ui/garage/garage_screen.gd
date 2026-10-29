class_name GarageScreen
extends UiScreen
## Tuning screen: car tabs, rotating preview, money, six slot rows (BUY), paint and repair
## rows, a detail line for the focused row and live stat bars. Saves the profile when leaving.

const ROW_SCENE: PackedScene = preload("res://src/ui/garage/garage_row.tscn")
const REPAIR_PRICE_PER_POINT: int = 5
const MESSAGE_SECONDS: float = 1.5
const BOUGHT_FORMAT: String = "INSTALLED %s"
const NO_MONEY_TEXT: String = "NOT ENOUGH MONEY"
const REPAIRED_TEXT: String = "REPAIRED"
const DETAIL_FORMAT: String = "%s: %s"
const MAXED_DETAIL: String = "ALL TIERS INSTALLED"
const PAINT_DETAIL: String = "PAINT: CYCLE THE BODY COLOUR"
const REPAIR_DETAIL: String = "REPAIR: %s PER MISSING POINT"

var car_index: int = 0
var slot_rows: Dictionary = {}
var paint_row: GarageRow
var repair_row: GarageRow

var _message_timer: Timer

@onready var prev_button: Button = %PrevButton
@onready var next_button: Button = %NextButton
@onready var car_name_label: Label = %CarNameLabel
@onready var preview: CarPreview = %Preview
@onready var stat_panel: StatPanel = %StatPanel
@onready var money_label: Label = %MoneyLabel
@onready var detail_label: Label = %DetailLabel
@onready var message_label: Label = %MessageLabel
@onready var rows_box: VBoxContainer = %RowsBox
@onready var back_button: Button = %BackButton


func _ready() -> void:
	super()
	prev_button.pressed.connect(prev_car)
	next_button.pressed.connect(next_car)
	back_button.pressed.connect(back)
	_build_rows()
	wire_sounds(rows_box)
	_message_timer = Timer.new()
	_message_timer.one_shot = true
	_message_timer.wait_time = MESSAGE_SECONDS
	_message_timer.timeout.connect(func() -> void: message_label.text = "")
	add_child(_message_timer)
	preview.rotating = true
	select_car(_index_of(PlayerProfile.selected_car))


func enter(_args: Dictionary) -> void:
	var first_row: GarageRow = slot_rows[Constants.SLOTS[0]]
	first_row.action_button.grab_focus()


func leave() -> void:
	UiPaths.save_profile()


func current_car() -> CarDef:
	return Catalog.cars()[car_index]


func select_car(index: int) -> void:
	var cars: Array[CarDef] = Catalog.cars()
	car_index = posmod(index, cars.size())
	PlayerProfile.selected_car = current_car().id
	preview.set_car(current_car(), PlayerProfile.paint_of(current_car().id))
	refresh()


func next_car() -> void:
	select_car(car_index + 1)


func prev_car() -> void:
	select_car(car_index - 1)


## Buys the next tier of `slot` for the current car. Returns true when installed.
func buy(slot: StringName) -> bool:
	var part: PartDef = next_part(slot)
	if part == null:
		return false
	var car_id: StringName = current_car().id
	if not PlayerProfile.buy_part(car_id, slot, part.tier, part.price):
		show_message(NO_MONEY_TEXT)
		return false
	RaceBus.purchase_made.emit(part.id)
	show_message(BOUGHT_FORMAT % part.display_name.to_upper())
	refresh()
	return true


func next_part(slot: StringName) -> PartDef:
	var tier: int = PlayerProfile.tier_of(current_car().id, slot)
	for part: PartDef in Catalog.parts_for_slot(slot):
		if part.tier == tier + 1:
			return part
	return null


func cycle_paint(step: int = 1) -> void:
	var car_id: StringName = current_car().id
	PlayerProfile.set_paint(car_id, PlayerProfile.paint_of(car_id) + step)
	preview.set_paint(PlayerProfile.paint_of(car_id))
	refresh()


func repair_price() -> int:
	var missing: float = PlayerProfile.FULL_INTEGRITY - PlayerProfile.integrity_of(current_car().id)
	return int(ceilf(missing)) * REPAIR_PRICE_PER_POINT


func repair() -> bool:
	if not PlayerProfile.repair(current_car().id, repair_price()):
		show_message(NO_MONEY_TEXT)
		return false
	show_message(REPAIRED_TEXT)
	refresh()
	return true


func show_message(text: String) -> void:
	message_label.text = text
	_message_timer.start()


## Detail line for a row: part name and description, or what the paint/repair rows do.
func show_detail(row: GarageRow) -> void:
	if row == paint_row:
		detail_label.text = PAINT_DETAIL
	elif row == repair_row:
		detail_label.text = REPAIR_DETAIL % UiText.money(REPAIR_PRICE_PER_POINT)
	elif row.part == null:
		detail_label.text = MAXED_DETAIL
	else:
		detail_label.text = (
			DETAIL_FORMAT % [row.part.display_name.to_upper(), row.part.description.to_upper()]
		)


func refresh() -> void:
	var car: CarDef = current_car()
	car_name_label.text = car.display_name.to_upper()
	money_label.text = UiText.money(PlayerProfile.money)
	for slot: StringName in Constants.SLOTS:
		var row: GarageRow = slot_rows[slot]
		var part: PartDef = next_part(slot)
		var affordable: bool = part != null and part.price <= PlayerProfile.money
		row.show_slot(slot, PlayerProfile.tier_of(car.id, slot), part, affordable)
	paint_row.show_paint(PlayerProfile.paint_of(car.id))
	var price: int = repair_price()
	repair_row.show_repair(PlayerProfile.integrity_of(car.id), price, price <= PlayerProfile.money)
	stat_panel.refresh(car, PlayerProfile.parts.get(car.id, {}))
	var focused: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if focused != null and focused.get_parent() is GarageRow:
		show_detail(focused.get_parent() as GarageRow)


func _build_rows() -> void:
	for slot: StringName in Constants.SLOTS:
		var row: GarageRow = _add_row("Row%s" % String(slot).to_pascal_case())
		row.action_pressed.connect(buy.bind(slot))
		slot_rows[slot] = row
	paint_row = _add_row("RowPaint")
	paint_row.action_pressed.connect(cycle_paint.bind(1))
	repair_row = _add_row("RowRepair")
	repair_row.action_pressed.connect(repair)


func _add_row(row_name: String) -> GarageRow:
	var row: GarageRow = ROW_SCENE.instantiate() as GarageRow
	row.name = row_name
	rows_box.add_child(row)
	row.focused.connect(show_detail.bind(row))
	return row


func _index_of(car_id: StringName) -> int:
	var cars: Array[CarDef] = Catalog.cars()
	for index: int in range(cars.size()):
		if cars[index].id == car_id:
			return index
	return 0
