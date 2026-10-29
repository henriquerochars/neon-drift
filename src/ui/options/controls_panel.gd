class_name ControlsPanel
extends VBoxContainer
## Read-only list of the driving actions with their keyboard and gamepad bindings from InputMap.

const ACTIONS: Array[StringName] = [
	&"steer_left",
	&"steer_right",
	&"accelerate",
	&"brake",
	&"nitro",
	&"jump",
	&"pause",
]
const HEADERS: Array[String] = ["ACTION", "KEYBOARD", "GAMEPAD"]
const COLUMN_WIDTHS: Array[float] = [76.0, 90.0, 110.0]
const NONE_TEXT: String = "-"
const JOIN: String = " / "
const BUTTON_FORMAT: String = "BTN %d"
const AXIS_FORMAT: String = "AX%d%s"
const HEADER_COLOR: Color = Color("#3ad1e2")
const ACTION_COLOR: Color = Color("#ff5fb4")

var _grid: GridContainer


func _ready() -> void:
	_grid = GridContainer.new()
	_grid.columns = HEADERS.size()
	_grid.add_theme_constant_override(&"h_separation", 4)
	_grid.add_theme_constant_override(&"v_separation", 2)
	add_child(_grid)
	move_child(_grid, 0)


## Rebuilds the table from the current InputMap.
func refresh() -> void:
	for child: Node in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	for index: int in range(HEADERS.size()):
		_add_cell(HEADERS[index], COLUMN_WIDTHS[index], HEADER_COLOR)
	for action: StringName in ACTIONS:
		_add_cell(String(action).to_upper().replace("_", " "), COLUMN_WIDTHS[0], ACTION_COLOR)
		_add_cell(keyboard_text(action), COLUMN_WIDTHS[1], Color.WHITE)
		_add_cell(gamepad_text(action), COLUMN_WIDTHS[2], Color.WHITE)


static func keyboard_text(action: StringName) -> String:
	var names: PackedStringArray = PackedStringArray()
	if not InputMap.has_action(action):
		return NONE_TEXT
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventKey:
			var key: InputEventKey = event
			var keycode: Key = (
				key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
			)
			names.append(OS.get_keycode_string(keycode).to_upper())
	return JOIN.join(names) if not names.is_empty() else NONE_TEXT


static func gamepad_text(action: StringName) -> String:
	var names: PackedStringArray = PackedStringArray()
	if not InputMap.has_action(action):
		return NONE_TEXT
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventJoypadButton:
			var button: InputEventJoypadButton = event
			names.append(BUTTON_FORMAT % button.button_index)
		elif event is InputEventJoypadMotion:
			var motion: InputEventJoypadMotion = event
			names.append(AXIS_FORMAT % [motion.axis, "-" if motion.axis_value < 0.0 else "+"])
	return JOIN.join(names) if not names.is_empty() else NONE_TEXT


func _add_cell(text: String, width: float, color: Color) -> void:
	var label: Label = Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(width, 0.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override(&"font_color", color)
	_grid.add_child(label)
