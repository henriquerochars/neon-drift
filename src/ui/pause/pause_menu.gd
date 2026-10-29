class_name PauseMenu
extends CanvasLayer
## Pause overlay for the race wrapper: RESUME / OPTIONS / QUIT TO MENU. Online the race keeps
## running, so the overlay only shows a notice with CLOSE and QUIT.

signal resume_requested
signal quit_requested

const OPTIONS_SCENE_PATH: String = "res://src/ui/options/options_screen.tscn"
const PAUSED_TITLE: String = "PAUSED"
const ONLINE_TITLE: String = "RACE CONTINUES"
const ONLINE_NOTICE: String = "PAUSE IS NOT AVAILABLE ONLINE"
const RESUME_TEXT: String = "RESUME"
const CLOSE_TEXT: String = "CLOSE"

var is_open: bool = false

var _options: UiScreen

@onready var root: Control = %Root
@onready var panel: Control = %Panel
@onready var title_label: Label = %TitleLabel
@onready var notice_label: Label = %NoticeLabel
@onready var resume_button: Button = %ResumeButton
@onready var options_button: Button = %OptionsButton
@onready var quit_button: Button = %QuitButton
@onready var options_holder: Control = %OptionsHolder


func _ready() -> void:
	root.visible = false
	resume_button.pressed.connect(_on_resume_pressed)
	options_button.pressed.connect(show_options)
	quit_button.pressed.connect(_on_quit_pressed)
	for button: Button in [resume_button, options_button, quit_button]:
		button.focus_entered.connect(func() -> void: RaceBus.ui_moved.emit())


func open(online: bool) -> void:
	is_open = true
	root.visible = true
	panel.visible = true
	title_label.text = ONLINE_TITLE if online else PAUSED_TITLE
	notice_label.visible = online
	notice_label.text = ONLINE_NOTICE
	resume_button.text = CLOSE_TEXT if online else RESUME_TEXT
	resume_button.grab_focus()


func close() -> void:
	is_open = false
	root.visible = false
	_close_options()


func show_options() -> void:
	RaceBus.ui_confirmed.emit()
	_close_options()
	var scene: PackedScene = load(OPTIONS_SCENE_PATH) as PackedScene
	_options = scene.instantiate() as UiScreen
	_options.embedded = true
	_options.closed.connect(_on_options_closed)
	options_holder.add_child(_options)
	panel.visible = false
	_options.enter({})


func _close_options() -> void:
	if _options != null:
		options_holder.remove_child(_options)
		_options.queue_free()
		_options = null


func _on_options_closed() -> void:
	_close_options()
	panel.visible = true
	resume_button.grab_focus()


func _on_resume_pressed() -> void:
	RaceBus.ui_confirmed.emit()
	resume_requested.emit()


func _on_quit_pressed() -> void:
	RaceBus.ui_confirmed.emit()
	quit_requested.emit()
