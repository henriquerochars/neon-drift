extends GdUnitTestSuite
## PlayerProfile and GameSettings round-trip through user:// files.

const PROFILE_PATH: String = "user://test-profile.json"
const SETTINGS_PATH: String = "user://test-settings.cfg"


func after_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_PATH))


func test_profile_buy_repair_and_round_trip() -> void:
	PlayerProfile.reset()
	assert_bool(PlayerProfile.buy_part(&"hornet", &"engine", 2, 900)).is_true()
	assert_bool(PlayerProfile.buy_part(&"hornet", &"engine", 1, 400)).is_false()
	assert_bool(PlayerProfile.buy_part(&"hornet", &"armour", 3, 999999)).is_false()
	PlayerProfile.set_paint(&"hornet", 5)
	PlayerProfile.set_integrity(&"hornet", 40.0)
	assert_bool(PlayerProfile.repair(&"hornet", 100)).is_true()
	var money: int = PlayerProfile.money
	assert_int(PlayerProfile.save_profile(PROFILE_PATH)).is_equal(OK)
	PlayerProfile.reset()
	assert_bool(PlayerProfile.load_profile(PROFILE_PATH)).is_true()
	assert_int(PlayerProfile.money).is_equal(money)
	assert_int(PlayerProfile.tier_of(&"hornet", &"engine")).is_equal(2)
	assert_int(PlayerProfile.paint_of(&"hornet")).is_equal(5)
	assert_float(PlayerProfile.integrity_of(&"hornet")).is_equal(100.0)
	PlayerProfile.reset()


func test_settings_round_trip_and_name_sanitising() -> void:
	GameSettings.apply_to_window = false
	GameSettings.music_volume = 0.25
	GameSettings.player_name = GameSettings.sanitize_name("  neon racer xyz  ")
	assert_str(GameSettings.player_name).is_equal("NEON RACER")
	assert_int(GameSettings.save_settings(SETTINGS_PATH)).is_equal(OK)
	GameSettings.music_volume = 1.0
	GameSettings.load_settings(SETTINGS_PATH)
	assert_float(GameSettings.music_volume).is_equal(0.25)
	assert_str(GameSettings.sanitize_name("")).is_equal(GameSettings.DEFAULT_NAME)
	GameSettings.apply()
