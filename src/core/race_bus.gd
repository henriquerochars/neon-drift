extends Node
## Autoload signal bus for everything that happens in a race or the menus. Emitters are the
## race manager (or RaceSync for remote events) and the UI; listeners are HUD, audio, VFX.

signal race_phase_changed(phase: StringName)
signal countdown_tick(value: int)
signal race_started
signal lap_completed(participant_id: int, lap: int)
signal car_finished(participant_id: int, place: int, time: float)
signal race_finished(results: Array[Dictionary])
signal nitro_activated(participant_id: int)
signal jump_started(participant_id: int)
signal car_landed(participant_id: int, hard: bool)
signal car_crushed(attacker_id: int, victim_id: int)
signal car_bumped(participant_id: int)
signal scenery_hit(participant_id: int)
signal offroad_changed(participant_id: int, offroad: bool)
signal screen_changed(screen: StringName)
signal ui_moved
signal ui_confirmed
signal ui_cancelled
signal purchase_made(part_id: StringName)
