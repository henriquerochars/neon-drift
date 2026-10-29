class_name MenuScreen
extends UiScreen
## Main menu: SOLO RACE, ONLINE, GARAGE, OPTIONS, QUIT. Shows the player name and money.

@onready var solo_button: Button = %SoloButton
@onready var online_button: Button = %OnlineButton
@onready var garage_button: Button = %GarageButton
@onready var options_button: Button = %OptionsButton
@onready var quit_button: Button = %QuitButton
@onready var name_label: Label = %NameLabel
@onready var money_label: Label = %MoneyLabel
@onready var record_label: Label = %RecordLabel


func _ready() -> void:
	super()
	solo_button.pressed.connect(solo_race)
	online_button.pressed.connect(online)
	garage_button.pressed.connect(garage)
	options_button.pressed.connect(options)
	quit_button.pressed.connect(quit)
	PlayerProfile.changed.connect(refresh)
	GameSettings.changed.connect(refresh)
	refresh()


func enter(_args: Dictionary) -> void:
	solo_button.grab_focus()


func refresh() -> void:
	name_label.text = GameSettings.player_name
	money_label.text = UiText.money(PlayerProfile.money)
	record_label.text = "%d RACES  %d WINS" % [PlayerProfile.races, PlayerProfile.wins]


func solo_race() -> void:
	go(ScreenRouter.SCREEN_SELECT)


func online() -> void:
	go(ScreenRouter.SCREEN_LOBBY)


func garage() -> void:
	go(ScreenRouter.SCREEN_GARAGE)


func options() -> void:
	go(ScreenRouter.SCREEN_OPTIONS)


func quit() -> void:
	get_tree().quit()
