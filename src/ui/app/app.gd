class_name App
extends Control
## Main scene: hosts the ScreenRouter, the RaceLauncher and the FPS label. Startup = title.

@onready var router: ScreenRouter = %ScreenRouter
@onready var launcher: RaceLauncher = %RaceLauncher


func _ready() -> void:
	launcher.router = router
	router.launcher = launcher
	router.go(ScreenRouter.SCREEN_TITLE)
