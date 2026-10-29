class_name UiScreen
extends Control
## Base of every screen: router access, enter/leave hooks, first focus and the UI sound
## signals (RaceBus.ui_moved / ui_confirmed / ui_cancelled) wired on every button and slider.

## Emitted by embedded screens (options inside the pause menu) instead of routing.
signal closed

const BACK_SUFFIX: String = "Back"

var router: ScreenRouter
## True when hosted by another screen; back() then emits `closed` instead of routing.
var embedded: bool = false


func _ready() -> void:
	wire_sounds(self)


## Called by the router after the screen is in the tree.
func enter(_args: Dictionary) -> void:
	focus_first()


## Called by the router right before the screen is removed.
func leave() -> void:
	pass


## Gives keyboard/gamepad focus to the first focusable button of the screen.
func focus_first() -> void:
	var first: Control = _first_focusable(self)
	if first != null:
		first.grab_focus()


func go(screen: StringName, args: Dictionary = {}) -> void:
	if router != null:
		router.go(screen, args)


## Default back action: embedded screens close, routed screens return to the menu.
func back() -> void:
	RaceBus.ui_cancelled.emit()
	if embedded:
		closed.emit()
	else:
		go(ScreenRouter.SCREEN_MENU)


## Connects the UI sound signals on every button and slider below `node` (rows added at
## runtime call this on themselves).
func wire_sounds(node: Node) -> void:
	for child: Node in node.get_children():
		if child is BaseButton:
			var button: BaseButton = child
			button.focus_entered.connect(_on_ui_moved)
			if not button.name.ends_with(BACK_SUFFIX):
				button.pressed.connect(_on_ui_confirmed)
		elif child is Range:
			var range_control: Range = child
			range_control.value_changed.connect(_on_range_changed)
		wire_sounds(child)


func _first_focusable(node: Node) -> Control:
	for child: Node in node.get_children():
		if child is Control:
			var control: Control = child
			if not control.is_visible_in_tree():
				continue
			if control.focus_mode != Control.FOCUS_NONE and control is BaseButton:
				return control
			var nested: Control = _first_focusable(control)
			if nested != null:
				return nested
	return null


func _on_ui_moved() -> void:
	RaceBus.ui_moved.emit()


func _on_ui_confirmed() -> void:
	RaceBus.ui_confirmed.emit()


func _on_range_changed(_value: float) -> void:
	RaceBus.ui_moved.emit()
