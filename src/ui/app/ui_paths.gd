class_name UiPaths
extends RefCounted
## Where the screens persist the profile and the settings. Tests point these at test paths so
## user://profile.json and user://settings.cfg are never touched by a test run.

static var profile_path: String = PlayerProfile.PATH
static var settings_path: String = GameSettings.PATH


static func reset() -> void:
	profile_path = PlayerProfile.PATH
	settings_path = GameSettings.PATH


static func save_profile() -> Error:
	return PlayerProfile.save_profile(profile_path)


static func save_settings() -> Error:
	return GameSettings.save_settings(settings_path)
