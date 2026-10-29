class_name LobbyScreen
extends UiScreen
## ONLINE: connect panel (HOST with a port, JOIN with address + port) and the room: 8 seat
## rows, car/paint pickers, READY toggle, host-only track picker and START, status line.
## All NetSession traffic goes through LobbyAdapter; without the net lane the room opens as
## a local preview so the flow can be exercised and captured.

const DEFAULT_ADDRESS: String = "127.0.0.1"
const PREVIEW_STATUS: String = "NET LANE PENDING - LOCAL PREVIEW"
const HOSTING_FORMAT: String = "HOSTING ON PORT %d"
const JOINING_FORMAT: String = "JOINING %s:%d"
const FAILED_FORMAT: String = "FAILED: %s"
const DISCONNECTED_TEXT: String = "DISCONNECTED"
const WAITING_TEXT: String = "WAITING FOR PLAYERS"
const BAD_PORT_TEXT: String = "PORT MUST BE 1..65535"
const MAX_PORT: int = 65535
const EMPTY_SEAT_TEXT: String = "- EMPTY -"
const READY_TEXT: String = "READY"
const READY_MARK: String = "RDY"
const NOT_READY_TEXT: String = "NOT READY"
const SEAT_FORMAT: String = "%d."
const SEAT_COLUMN_WIDTHS: Array[float] = [12.0, 60.0, 46.0]
const SEAT_LOCAL_COLOR: Color = Color("#3ad1e2")
const SEAT_COLOR: Color = Color("#e8e8f0")
const SEAT_EMPTY_COLOR: Color = Color("#5a5670")
const SWATCH_SIZE: Vector2 = Vector2(7, 7)

var car_index: int = 0
var paint: int = 0
var track_index: int = 0
var is_ready: bool = false
var preview_mode: bool = false

var _handlers: Dictionary = {}

@onready var connect_panel: Control = %ConnectPanel
@onready var room_panel: Control = %RoomPanel
@onready var player_label: Label = %PlayerLabel
@onready var address_edit: LineEdit = %AddressEdit
@onready var port_edit: LineEdit = %PortEdit
@onready var host_button: Button = %HostButton
@onready var join_button: Button = %JoinButton
@onready var back_button: Button = %BackButton
@onready var seats_box: VBoxContainer = %SeatsBox
@onready var car_label: Label = %CarLabel
@onready var car_prev_button: Button = %CarPrevButton
@onready var car_next_button: Button = %CarNextButton
@onready var paint_swatch: ColorRect = %PaintSwatch
@onready var paint_prev_button: Button = %PaintPrevButton
@onready var paint_next_button: Button = %PaintNextButton
@onready var track_row: Control = %TrackRow
@onready var track_label: Label = %TrackLabel
@onready var track_prev_button: Button = %TrackPrevButton
@onready var track_next_button: Button = %TrackNextButton
@onready var ready_button: Button = %ReadyButton
@onready var start_button: Button = %StartButton
@onready var leave_button: Button = %LeaveButton
@onready var status_label: Label = %StatusLabel


func _ready() -> void:
	super()
	_handlers = {
		&"seats_changed": _on_seats_changed,
		&"race_requested": _on_race_requested,
		&"connection_failed": _on_connection_failed,
		&"disconnected": _on_disconnected,
	}
	host_button.pressed.connect(host)
	join_button.pressed.connect(join)
	back_button.pressed.connect(back)
	car_prev_button.pressed.connect(step_car.bind(-1))
	car_next_button.pressed.connect(step_car.bind(1))
	paint_prev_button.pressed.connect(step_paint.bind(-1))
	paint_next_button.pressed.connect(step_paint.bind(1))
	track_prev_button.pressed.connect(step_track.bind(-1))
	track_next_button.pressed.connect(step_track.bind(1))
	ready_button.pressed.connect(toggle_ready)
	start_button.pressed.connect(start)
	leave_button.pressed.connect(leave_room)
	player_label.text = GameSettings.player_name
	address_edit.text = DEFAULT_ADDRESS
	port_edit.text = str(Constants.DEFAULT_PORT)
	car_index = _car_index_of(PlayerProfile.selected_car)
	paint = PlayerProfile.paint_of(PlayerProfile.selected_car)
	LobbyAdapter.connect_signals(_handlers)
	_build_seat_rows()
	show_connect()


func enter(args: Dictionary) -> void:
	if args.has("reason"):
		show_connect()
		set_status(str(args["reason"]))
	if bool(args.get("room", false)) and LobbyAdapter.is_online():
		show_room()
	else:
		host_button.grab_focus()


func leave() -> void:
	LobbyAdapter.disconnect_signals(_handlers)


func in_room() -> bool:
	return room_panel.visible


func show_connect() -> void:
	room_panel.visible = false
	connect_panel.visible = true


func show_room() -> void:
	connect_panel.visible = false
	room_panel.visible = true
	refresh()
	ready_button.grab_focus()


func port() -> int:
	return int(port_edit.text) if port_edit.text.is_valid_int() else -1


func host() -> void:
	var port_value: int = port()
	if port_value < 0 or port_value > MAX_PORT:
		set_status(BAD_PORT_TEXT)
		return
	var error: int = LobbyAdapter.host(
		port_value, GameSettings.player_name, current_car().id, paint
	)
	if error == ERR_UNAVAILABLE:
		_open_preview()
		return
	if error != OK:
		set_status(FAILED_FORMAT % error_string(error))
		return
	preview_mode = false
	set_status(HOSTING_FORMAT % port_value)
	show_room()


func join() -> void:
	var port_value: int = port()
	if port_value < 0 or port_value > MAX_PORT:
		set_status(BAD_PORT_TEXT)
		return
	var address: String = address_edit.text.strip_edges()
	var error: int = LobbyAdapter.join(
		address, port_value, GameSettings.player_name, current_car().id, paint
	)
	if error == ERR_UNAVAILABLE:
		_open_preview()
		return
	if error != OK:
		set_status(FAILED_FORMAT % error_string(error))
		return
	preview_mode = false
	set_status(JOINING_FORMAT % [address, port_value])
	show_room()


func leave_room() -> void:
	RaceBus.ui_cancelled.emit()
	LobbyAdapter.leave()
	is_ready = false
	preview_mode = false
	show_connect()
	host_button.grab_focus()


func back() -> void:
	if in_room():
		leave_room()
		return
	RaceBus.ui_cancelled.emit()
	go(ScreenRouter.SCREEN_MENU)


func current_car() -> CarDef:
	return Catalog.cars()[car_index]


func current_track() -> TrackDef:
	return Catalog.tracks()[track_index]


func step_car(delta: int) -> void:
	car_index = posmod(car_index + delta, Catalog.cars().size())
	paint = PlayerProfile.paint_of(current_car().id)
	PlayerProfile.selected_car = current_car().id
	LobbyAdapter.set_car(current_car().id, paint)
	refresh()


func step_paint(delta: int) -> void:
	paint = posmod(paint + delta, Constants.PAINT_COUNT)
	PlayerProfile.set_paint(current_car().id, paint)
	LobbyAdapter.set_car(current_car().id, paint)
	refresh()


func step_track(delta: int) -> void:
	track_index = posmod(track_index + delta, Catalog.tracks().size())
	refresh()


func toggle_ready() -> void:
	is_ready = not is_ready
	LobbyAdapter.set_ready(is_ready)
	refresh()


## Host only: asks NetSession to start on the selected track.
func start() -> void:
	if not LobbyAdapter.is_host():
		return
	if preview_mode:
		set_status(PREVIEW_STATUS)
		return
	LobbyAdapter.request_start(current_track().id)


func set_status(text: String) -> void:
	status_label.text = text


func refresh() -> void:
	car_label.text = current_car().display_name.to_upper()
	paint_swatch.color = PaintShift.paint_color(paint)
	track_label.text = current_track().display_name.to_upper()
	ready_button.text = READY_TEXT if is_ready else NOT_READY_TEXT
	var is_host: bool = LobbyAdapter.is_host()
	track_row.visible = is_host
	start_button.visible = is_host
	_refresh_seats(_current_seats())


func _open_preview() -> void:
	preview_mode = true
	set_status(PREVIEW_STATUS)
	show_room()


func _current_seats() -> Array[Dictionary]:
	if preview_mode or not LobbyAdapter.is_online():
		return [
			{
				"peer_id": LobbyAdapter.local_peer_id(),
				"name": GameSettings.player_name,
				"car_id": current_car().id,
				"paint": paint,
				"ready": is_ready,
			}
		]
	return LobbyAdapter.seats()


func _build_seat_rows() -> void:
	for index: int in range(Constants.MAX_PLAYERS):
		var row: HBoxContainer = HBoxContainer.new()
		row.name = "Seat%d" % index
		row.add_theme_constant_override(&"separation", 3)
		var widths: Array[float] = SEAT_COLUMN_WIDTHS
		for column: int in range(widths.size()):
			var label: Label = Label.new()
			label.custom_minimum_size = Vector2(widths[column], 0.0)
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(label)
		var swatch: ColorRect = ColorRect.new()
		swatch.custom_minimum_size = SWATCH_SIZE
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(swatch)
		var ready_label: Label = Label.new()
		ready_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ready_label)
		seats_box.add_child(row)


func _refresh_seats(seats: Array[Dictionary]) -> void:
	var local_peer: int = LobbyAdapter.local_peer_id()
	for index: int in range(Constants.MAX_PLAYERS):
		var row: HBoxContainer = seats_box.get_child(index) as HBoxContainer
		var labels: Array[Label] = []
		for child: Node in row.get_children():
			if child is Label:
				labels.append(child as Label)
		var swatch: ColorRect = row.get_child(SEAT_COLUMN_WIDTHS.size()) as ColorRect
		labels[0].text = SEAT_FORMAT % (index + 1)
		if index >= seats.size():
			_fill_seat(labels, swatch, EMPTY_SEAT_TEXT, "", "", SEAT_EMPTY_COLOR, false)
			continue
		var seat: Dictionary = seats[index]
		var car: CarDef = Catalog.car(StringName(str(seat.get("car_id", ""))))
		var color: Color = (
			SEAT_LOCAL_COLOR if int(seat.get("peer_id", -1)) == local_peer else SEAT_COLOR
		)
		_fill_seat(
			labels,
			swatch,
			str(seat.get("name", "")).to_upper(),
			car.display_name.to_upper() if car != null else "?",
			READY_MARK if bool(seat.get("ready", false)) else "",
			color,
			true
		)
		swatch.color = PaintShift.paint_color(int(seat.get("paint", 0)))


func _fill_seat(
	labels: Array[Label],
	swatch: ColorRect,
	name_text: String,
	car_text: String,
	ready_text: String,
	color: Color,
	show_swatch: bool
) -> void:
	labels[1].text = name_text
	labels[2].text = car_text
	labels[3].text = ready_text
	for label: Label in labels:
		label.add_theme_color_override(&"font_color", color)
	swatch.visible = show_swatch


func _car_index_of(car_id: StringName) -> int:
	var cars: Array[CarDef] = Catalog.cars()
	for index: int in range(cars.size()):
		if cars[index].id == car_id:
			return index
	return 0


func _on_seats_changed(_seats: Variant) -> void:
	if in_room():
		refresh()


func _on_race_requested(track_id: StringName, seed: int) -> void:
	var config: RaceConfig = LobbyAdapter.build_race_config(track_id, seed)
	if router != null and router.launcher != null:
		router.launcher.launch(config)


func _on_connection_failed(reason: String) -> void:
	preview_mode = false
	show_connect()
	set_status(FAILED_FORMAT % reason.to_upper())
	host_button.grab_focus()


func _on_disconnected() -> void:
	preview_mode = false
	is_ready = false
	show_connect()
	set_status(DISCONNECTED_TEXT)
