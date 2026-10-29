extends GdUnitTestSuite
## HudOverlay fed by a fake race implementing the contract methods; flashes react to RaceBus.

const HUD_SCENE: String = "res://src/ui/hud/hud_overlay.tscn"
const LOCAL_ID: int = 0
const RIVAL_ID: int = 1
const SPEED: float = 4000.0
const RACE_TIME: float = 65.5
const LAPS: int = 3
const FLASH_WAIT_MS: int = 1200

var _hud: HudOverlay
var _race: FakeRace


class FakeRace:
	extends Node
	## Duck-typed stand-in for RaceScene (docs/ARCHITECTURE.md "Race scene contract").

	var config: RaceConfig = RaceConfig.new()
	var track_model: TrackModel
	var race_time: float = RACE_TIME
	var states: Dictionary = {}
	var places: Dictionary = {LOCAL_ID: 2, RIVAL_ID: 1}
	var laps: Dictionary = {LOCAL_ID: 2, RIVAL_ID: 2}

	func _init() -> void:
		config.laps = LAPS
		track_model = TrackModel.new(Catalog.track(&"coast"))
		var local: CarState = CarState.new()
		local.speed = SPEED
		local.nitro = 0.5
		local.thrusters = 0.25
		local.integrity = 80.0
		local.progress = track_model.length
		states[LOCAL_ID] = local
		var rival: CarState = CarState.new()
		rival.progress = track_model.length * 2.0
		states[RIVAL_ID] = rival

	func state_of(id: int) -> CarState:
		return states.get(id)

	func stats_of(_id: int) -> CarStats:
		return Catalog.stats_for(&"vortex", {})

	func place_of(id: int) -> int:
		return int(places.get(id, 1))

	func lap_of(id: int) -> int:
		return int(laps.get(id, 0))

	func local_id() -> int:
		return LOCAL_ID

	func standings() -> Array[int]:
		return [RIVAL_ID, LOCAL_ID]


func before_test() -> void:
	var scene: PackedScene = load(HUD_SCENE) as PackedScene
	_hud = auto_free(scene.instantiate()) as HudOverlay
	add_child(_hud)
	_race = auto_free(FakeRace.new()) as FakeRace
	add_child(_race)
	await await_idle_frame()
	_hud.bind(_race)


func after_test() -> void:
	AudioDirector.stop_all()
	_hud.unbind()


func test_refresh_reads_the_contract() -> void:
	_hud.refresh()
	assert_str(_hud.speed_label.text).is_equal("100")
	assert_str(_hud.lap_label.text).is_equal("LAP 2/3")
	assert_str(_hud.time_label.text).is_equal("1:05.50")
	assert_str(_hud.place_label.text).is_equal("2ND")
	assert_float(_hud.nitro_bar.value).is_equal(0.5)
	assert_float(_hud.thruster_bar.value).is_equal(0.25)
	assert_float(_hud.integrity_bar.value).is_greater(0.0)
	assert_int(_hud.strip.fractions.size()).is_equal(2)
	assert_int(_hud.strip.local_index).is_equal(1)
	assert_float(_hud.strip.fractions[1]).is_equal_approx(1.0 / LAPS, 0.001)


func test_countdown_and_go_flash() -> void:
	RaceBus.countdown_tick.emit(3)
	assert_bool(_hud.is_flash_visible()).is_true()
	assert_str(_hud.flash_text()).is_equal("3")
	RaceBus.countdown_tick.emit(1)
	assert_str(_hud.flash_text()).is_equal("1")
	RaceBus.race_started.emit()
	assert_str(_hud.flash_text()).is_equal(HudOverlay.GO_TEXT)
	await await_millis(FLASH_WAIT_MS)
	assert_bool(_hud.is_flash_visible()).is_false()


func test_lap_crush_landing_and_finish_react_only_to_the_local_car() -> void:
	RaceBus.lap_completed.emit(RIVAL_ID, 1)
	assert_bool(_hud.is_flash_visible()).is_false()
	RaceBus.lap_completed.emit(LOCAL_ID, 1)
	assert_str(_hud.flash_text()).is_equal("LAP 2")
	RaceBus.car_crushed.emit(RIVAL_ID, LOCAL_ID)
	assert_str(_hud.flash_text()).is_equal(HudOverlay.CRUSHED_TEXT)
	RaceBus.car_landed.emit(LOCAL_ID, false)
	assert_str(_hud.flash_text()).is_equal(HudOverlay.CRUSHED_TEXT)
	RaceBus.car_landed.emit(LOCAL_ID, true)
	assert_str(_hud.flash_text()).is_equal(HudOverlay.HARD_LANDING_TEXT)
	assert_bool(_hud.is_finish_visible()).is_false()
	RaceBus.car_finished.emit(RIVAL_ID, 1, 90.0)
	assert_bool(_hud.is_finish_visible()).is_false()
	RaceBus.car_finished.emit(LOCAL_ID, 2, 95.0)
	assert_bool(_hud.is_finish_visible()).is_true()
	assert_str(_hud.finish_label.text).is_equal("FINISH! 2ND")


func test_text_helpers() -> void:
	assert_str(UiText.place(1)).is_equal("1ST")
	assert_str(UiText.place(2)).is_equal("2ND")
	assert_str(UiText.place(3)).is_equal("3RD")
	assert_str(UiText.place(8)).is_equal("8TH")
	assert_str(UiText.place(11)).is_equal("11TH")
	assert_str(UiText.race_time(0.0)).is_equal("0:00.00")
	assert_str(UiText.race_time(125.25)).is_equal("2:05.25")
	assert_str(UiText.money(1500)).is_equal("$1500")
	assert_str(UiText.tier_pips(2, 3)).is_equal("##-")


func after() -> void:
	AudioDirector.stop_all()
