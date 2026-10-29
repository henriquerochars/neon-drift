class_name ResultsScreen
extends UiScreen
## Race results: 8 rows (place, name, car, time), the local earnings, money before -> after
## and the race seed. Records the result and the final integrity into PlayerProfile and saves.
## Buttons: RACE AGAIN (same config, new seed) / GARAGE / MENU, or BACK TO ROOM online.

const MONEY_FORMAT: String = "%s\n> %s"
const EARNINGS_FORMAT: String = "+%s"
const SEED_FORMAT: String = "SEED %d"
const DNF_TEXT: String = "DNF"
const LOCAL_COLOR: Color = Color("#3ad1e2")
const ROW_COLOR: Color = Color("#e8e8f0")
const COLUMN_WIDTHS: Array[float] = [24.0, 70.0, 52.0, 46.0]

var results: Array[Dictionary] = []
var local_id: int = Constants.INVALID_ID
var config: RaceConfig
var online: bool = false
var earnings: int = 0
var local_place: int = 0
var money_before: int = 0

@onready var rows_box: VBoxContainer = %RowsBox
@onready var place_label: Label = %PlaceLabel
@onready var earnings_label: Label = %EarningsLabel
@onready var money_label: Label = %MoneyLabel
@onready var seed_label: Label = %SeedLabel
@onready var again_button: Button = %AgainButton
@onready var garage_button: Button = %GarageButton
@onready var menu_button: Button = %MenuButton
@onready var room_button: Button = %RoomButton


func _ready() -> void:
	super()
	again_button.pressed.connect(race_again)
	garage_button.pressed.connect(to_garage)
	menu_button.pressed.connect(to_menu)
	room_button.pressed.connect(to_room)


func enter(args: Dictionary) -> void:
	var raw: Variant = args.get("results", [])
	var entries: Array[Dictionary] = []
	if raw is Array:
		entries.assign(raw)
	present(
		entries,
		int(args.get("local_id", Constants.INVALID_ID)),
		float(args.get("integrity", PlayerProfile.FULL_INTEGRITY)),
		args.get("config") as RaceConfig,
		bool(args.get("online", false))
	)


## Shows the table and records place, earnings and integrity into the profile.
func present(
	entries: Array[Dictionary],
	local: int,
	integrity: float,
	race_config: RaceConfig = null,
	is_online: bool = false
) -> void:
	results = entries.duplicate()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _place(a) < _place(b))
	local_id = local
	config = race_config
	online = is_online
	money_before = PlayerProfile.money
	earnings = 0
	local_place = 0
	for entry: Dictionary in results:
		if int(entry.get("id", Constants.INVALID_ID)) == local_id:
			earnings = int(entry.get("earnings", 0))
			local_place = _place(entry)
	if local_place > 0:
		PlayerProfile.record_result(local_place, earnings)
	var participant: RaceConfig.Participant = config.local_participant() if config != null else null
	if participant != null:
		PlayerProfile.set_integrity(participant.car_id, integrity)
		if online:
			LobbyAdapter.set_car(participant.car_id, PlayerProfile.paint_of(participant.car_id))
	UiPaths.save_profile()
	_build_rows()
	place_label.text = UiText.place(local_place) if local_place > 0 else DNF_TEXT
	earnings_label.text = EARNINGS_FORMAT % UiText.money(earnings)
	money_label.text = (
		MONEY_FORMAT % [UiText.money(money_before), UiText.money(PlayerProfile.money)]
	)
	seed_label.text = SEED_FORMAT % (config.seed if config != null else 0)
	again_button.visible = not online and config != null
	garage_button.visible = not online
	menu_button.visible = not online
	room_button.visible = online
	focus_first()


func race_again() -> void:
	if config == null or router == null or router.launcher == null:
		return
	var next: RaceConfig = RaceLauncher.build_solo_config(
		PlayerProfile.selected_car, config.track_id, randi()
	)
	router.launcher.launch(next)


func to_garage() -> void:
	go(ScreenRouter.SCREEN_GARAGE)


func to_menu() -> void:
	go(ScreenRouter.SCREEN_MENU)


func to_room() -> void:
	go(ScreenRouter.SCREEN_LOBBY, {"room": true})


func _build_rows() -> void:
	for child: Node in rows_box.get_children():
		rows_box.remove_child(child)
		child.queue_free()
	for entry: Dictionary in results:
		var is_local: bool = int(entry.get("id", Constants.INVALID_ID)) == local_id
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 2)
		var car: CarDef = Catalog.car(StringName(str(entry.get("car_id", ""))))
		var car_name: String = car.display_name.to_upper() if car != null else "?"
		var finished: bool = bool(entry.get("finished", true))
		var time_text: String = (
			UiText.race_time(float(entry.get("time", 0.0))) if finished else DNF_TEXT
		)
		var cells: Array[String] = [
			UiText.place(_place(entry)), str(entry.get("name", "")).to_upper(), car_name, time_text
		]
		for index: int in range(cells.size()):
			var label: Label = Label.new()
			label.text = cells[index]
			label.custom_minimum_size = Vector2(COLUMN_WIDTHS[index], 0.0)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			label.add_theme_color_override(&"font_color", LOCAL_COLOR if is_local else ROW_COLOR)
			if index == cells.size() - 1:
				label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			row.add_child(label)
		rows_box.add_child(row)


func _place(entry: Dictionary) -> int:
	return int(entry.get("place", Constants.MAX_PLAYERS))
