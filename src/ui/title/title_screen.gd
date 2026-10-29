class_name TitleScreen
extends UiScreen
## Title: two-tone logo over a slowly scrolling sunset panorama and a blinking PRESS START.
## Any ui_accept on the focused start button (or a tap anywhere) goes to the menu.

const SCROLL_SPEED: float = 10.0
const TILE_WIDTH: float = 400.0
const BLINK_INTERVAL: float = 0.5
const BLINK_ON: Color = Color(1.0, 1.0, 1.0, 1.0)
const BLINK_OFF: Color = Color(1.0, 1.0, 1.0, 0.0)

var _blink_timer: Timer

@onready var scroller: TextureRect = %Scroller
@onready var start_button: Button = %StartButton
@onready var tap_catcher: Button = %TapCatcher


func _ready() -> void:
	super()
	start_button.pressed.connect(press_start)
	tap_catcher.pressed.connect(press_start)
	_blink_timer = Timer.new()
	_blink_timer.wait_time = BLINK_INTERVAL
	_blink_timer.timeout.connect(_on_blink)
	add_child(_blink_timer)
	_blink_timer.start()


func _process(delta: float) -> void:
	var x: float = scroller.position.x - SCROLL_SPEED * delta
	if x <= -TILE_WIDTH:
		x += TILE_WIDTH
	scroller.position.x = x


func enter(_args: Dictionary) -> void:
	start_button.grab_focus()


func press_start() -> void:
	go(ScreenRouter.SCREEN_MENU)


func _on_blink() -> void:
	start_button.modulate = BLINK_OFF if start_button.modulate == BLINK_ON else BLINK_ON
