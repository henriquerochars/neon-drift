class_name SelectScreen
extends UiScreen
## Solo flow: car select (sprite, name, description, stat bars, paint) then track select
## (name, description, thumbnail, laps). Confirming the track launches the race through
## RaceLauncher with a random seed shown later on the results screen.

const PAGE_CAR: StringName = &"car"
const PAGE_TRACK: StringName = &"track"
const CAR_TITLE: String = "SELECT CAR"
const TRACK_TITLE: String = "SELECT TRACK"
const COUNTER_FORMAT: String = "%d / %d"
const LAPS_FORMAT: String = "%d LAPS"
const PRIZE_FORMAT: String = "1ST PRIZE %s"
const THUMBNAIL_SCALE: float = 0.5

var page: StringName = PAGE_CAR
var car_index: int = 0
var track_index: int = 0

@onready var title_label: Label = %TitleLabel
@onready var counter_label: Label = %CounterLabel
@onready var name_label: Label = %NameLabel
@onready var description_label: Label = %DescriptionLabel
@onready var preview: CarPreview = %Preview
@onready var swatch: ColorRect = %Swatch
@onready var stat_panel: StatPanel = %StatPanel
@onready var thumbnail: TextureRect = %Thumbnail
@onready var laps_label: Label = %LapsLabel
@onready var prize_label: Label = %PrizeLabel
@onready var car_box: Control = %CarBox
@onready var track_box: Control = %TrackBox
@onready var prev_button: Button = %PrevButton
@onready var next_button: Button = %NextButton
@onready var confirm_button: Button = %ConfirmButton
@onready var back_button: Button = %BackButton


func _ready() -> void:
	super()
	prev_button.pressed.connect(step.bind(-1))
	next_button.pressed.connect(step.bind(1))
	confirm_button.pressed.connect(confirm)
	back_button.pressed.connect(back)
	car_index = _car_index_of(PlayerProfile.selected_car)
	show_cars()


func enter(_args: Dictionary) -> void:
	confirm_button.grab_focus()


func show_cars() -> void:
	page = PAGE_CAR
	title_label.text = CAR_TITLE
	car_box.visible = true
	track_box.visible = false
	stat_panel.visible = true
	refresh()


func show_tracks() -> void:
	page = PAGE_TRACK
	title_label.text = TRACK_TITLE
	car_box.visible = false
	track_box.visible = true
	stat_panel.visible = false
	refresh()


func step(delta: int) -> void:
	if page == PAGE_CAR:
		car_index = posmod(car_index + delta, Catalog.cars().size())
	else:
		track_index = posmod(track_index + delta, Catalog.tracks().size())
	refresh()


func current_car() -> CarDef:
	return Catalog.cars()[car_index]


func current_track() -> TrackDef:
	return Catalog.tracks()[track_index]


## Car page: stores the selection and moves on to the tracks. Track page: launches the race.
func confirm() -> void:
	if page == PAGE_CAR:
		PlayerProfile.selected_car = current_car().id
		show_tracks()
		return
	launch_race(randi())


func launch_race(seed: int) -> void:
	var config: RaceConfig = RaceLauncher.build_solo_config(
		PlayerProfile.selected_car, current_track().id, seed
	)
	if router != null and router.launcher != null:
		router.launcher.launch(config)


func back() -> void:
	RaceBus.ui_cancelled.emit()
	if page == PAGE_TRACK:
		show_cars()
	else:
		go(ScreenRouter.SCREEN_MENU)


func refresh() -> void:
	if page == PAGE_CAR:
		_refresh_car()
	else:
		_refresh_track()


func _refresh_car() -> void:
	var car: CarDef = current_car()
	counter_label.text = COUNTER_FORMAT % [car_index + 1, Catalog.cars().size()]
	name_label.text = car.display_name.to_upper()
	description_label.text = car.description
	preview.set_car(car, PlayerProfile.paint_of(car.id))
	swatch.color = PaintShift.paint_color(PlayerProfile.paint_of(car.id))
	stat_panel.refresh(car, PlayerProfile.parts.get(car.id, {}))


func _refresh_track() -> void:
	var track: TrackDef = current_track()
	counter_label.text = COUNTER_FORMAT % [track_index + 1, Catalog.tracks().size()]
	name_label.text = track.display_name.to_upper()
	description_label.text = track.description
	thumbnail.texture = track.background
	laps_label.text = LAPS_FORMAT % track.laps
	var prize: int = track.prizes[0] if not track.prizes.is_empty() else 0
	prize_label.text = PRIZE_FORMAT % UiText.money(prize)


func _car_index_of(car_id: StringName) -> int:
	var cars: Array[CarDef] = Catalog.cars()
	for index: int in range(cars.size()):
		if cars[index].id == car_id:
			return index
	return 0
