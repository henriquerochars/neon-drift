class_name OptionsScreen
extends UiScreen
## Options bound to GameSettings: volumes, fullscreen, vsync, FPS counter, window scale and
## player name. Every change applies and saves immediately. CONTROLS shows the InputMap
## bindings read-only; BACK returns (or closes when embedded in the pause menu).

const VOLUME_STEP: float = 0.05
const LABEL_WIDTH: float = 76.0
const VALUE_WIDTH: float = 30.0
const SLIDER_WIDTH: float = 90.0
const ON_TEXT: String = "ON"
const OFF_TEXT: String = "OFF"
const SCALE_FORMAT: String = "%dX"

var master_slider: HSlider
var music_slider: HSlider
var sfx_slider: HSlider
var scale_slider: HSlider
var fullscreen_toggle: Button
var vsync_toggle: Button
var fps_toggle: Button
var name_edit: LineEdit

var _value_labels: Dictionary = {}

@onready var rows_box: VBoxContainer = %RowsBox
@onready var controls_panel: ControlsPanel = %ControlsPanel
@onready var controls_frame: Control = %ControlsFrame
@onready var main_panel: Control = %MainPanel
@onready var controls_button: Button = %ControlsButton
@onready var back_button: Button = %BackButton
@onready var controls_back_button: Button = %ControlsBackButton


func _ready() -> void:
	super()
	_build_rows()
	wire_sounds(rows_box)
	controls_button.pressed.connect(show_controls)
	controls_back_button.pressed.connect(show_main)
	back_button.pressed.connect(back)
	controls_panel.refresh()
	show_main()


func enter(_args: Dictionary) -> void:
	master_slider.grab_focus()


func show_controls() -> void:
	main_panel.visible = false
	controls_frame.visible = true
	controls_back_button.grab_focus()


func show_main() -> void:
	controls_frame.visible = false
	main_panel.visible = true


func set_music_volume(value: float) -> void:
	music_slider.value = value


func set_player_name(raw: String) -> void:
	GameSettings.player_name = GameSettings.sanitize_name(raw)
	name_edit.text = GameSettings.player_name
	apply_and_save()


func apply_and_save() -> void:
	GameSettings.apply()
	UiPaths.save_settings()


func _build_rows() -> void:
	master_slider = _add_slider("MASTER", GameSettings.master_volume, 0.0, 1.0, VOLUME_STEP)
	master_slider.value_changed.connect(_on_master_changed)
	music_slider = _add_slider("MUSIC", GameSettings.music_volume, 0.0, 1.0, VOLUME_STEP)
	music_slider.value_changed.connect(_on_music_changed)
	sfx_slider = _add_slider("SFX", GameSettings.sfx_volume, 0.0, 1.0, VOLUME_STEP)
	sfx_slider.value_changed.connect(_on_sfx_changed)
	fullscreen_toggle = _add_toggle("FULLSCREEN", GameSettings.fullscreen)
	fullscreen_toggle.toggled.connect(_on_fullscreen_toggled)
	vsync_toggle = _add_toggle("VSYNC", GameSettings.vsync)
	vsync_toggle.toggled.connect(_on_vsync_toggled)
	fps_toggle = _add_toggle("SHOW FPS", GameSettings.show_fps)
	fps_toggle.toggled.connect(_on_fps_toggled)
	scale_slider = _add_slider(
		"WINDOW", GameSettings.window_scale, GameSettings.MIN_SCALE, GameSettings.MAX_SCALE, 1.0
	)
	scale_slider.value_changed.connect(_on_scale_changed)
	name_edit = _add_name_row()
	_refresh_values()


func _add_row(label_text: String) -> HBoxContainer:
	var row: HBoxContainer = HBoxContainer.new()
	row.name = "Row%s" % label_text.to_pascal_case()
	row.add_theme_constant_override(&"separation", 4)
	var label: Label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(label)
	rows_box.add_child(row)
	return row


func _add_slider(
	label_text: String, value: float, min_value: float, max_value: float, step: float
) -> HSlider:
	var row: HBoxContainer = _add_row(label_text)
	var slider: HSlider = HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.custom_minimum_size = Vector2(SLIDER_WIDTH, 0.0)
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)
	var value_label: Label = Label.new()
	value_label.custom_minimum_size = Vector2(VALUE_WIDTH, 0.0)
	value_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_label)
	_value_labels[slider] = value_label
	return slider


func _add_toggle(label_text: String, value: bool) -> Button:
	var row: HBoxContainer = _add_row(label_text)
	var toggle: Button = Button.new()
	toggle.toggle_mode = true
	toggle.button_pressed = value
	toggle.custom_minimum_size = Vector2(VALUE_WIDTH, 0.0)
	toggle.text = ON_TEXT if value else OFF_TEXT
	toggle.toggled.connect(
		func(pressed: bool) -> void: toggle.text = ON_TEXT if pressed else OFF_TEXT
	)
	row.add_child(toggle)
	return toggle


func _add_name_row() -> LineEdit:
	var row: HBoxContainer = _add_row("NAME")
	var edit: LineEdit = LineEdit.new()
	edit.max_length = GameSettings.MAX_NAME_LENGTH
	edit.text = GameSettings.player_name
	edit.custom_minimum_size = Vector2(SLIDER_WIDTH, 0.0)
	edit.text_submitted.connect(set_player_name)
	edit.focus_exited.connect(func() -> void: set_player_name(edit.text))
	row.add_child(edit)
	return edit


func _refresh_values() -> void:
	_set_value_text(master_slider, UiText.percent(master_slider.value))
	_set_value_text(music_slider, UiText.percent(music_slider.value))
	_set_value_text(sfx_slider, UiText.percent(sfx_slider.value))
	_set_value_text(scale_slider, SCALE_FORMAT % int(scale_slider.value))


func _set_value_text(slider: HSlider, text: String) -> void:
	var label: Label = _value_labels[slider]
	label.text = text


func _on_master_changed(value: float) -> void:
	GameSettings.master_volume = value
	_refresh_values()
	apply_and_save()


func _on_music_changed(value: float) -> void:
	GameSettings.music_volume = value
	_refresh_values()
	apply_and_save()


func _on_sfx_changed(value: float) -> void:
	GameSettings.sfx_volume = value
	_refresh_values()
	apply_and_save()


func _on_fullscreen_toggled(pressed: bool) -> void:
	GameSettings.fullscreen = pressed
	apply_and_save()


func _on_vsync_toggled(pressed: bool) -> void:
	GameSettings.vsync = pressed
	apply_and_save()


func _on_fps_toggled(pressed: bool) -> void:
	GameSettings.show_fps = pressed
	apply_and_save()


func _on_scale_changed(value: float) -> void:
	GameSettings.window_scale = int(value)
	_refresh_values()
	apply_and_save()
