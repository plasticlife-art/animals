extends RefCounted

## Which scenarios the player has won, kept beside the settings (`user://progress.cfg`): the
## scenarios page marks them «Пройден». Only a mark - nothing is locked behind it.

static var path := "user://progress.cfg"


static func won_ids() -> Array:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return []
	return config.get_value("scenarios", "won", [])


static func has_won(scenario_id: String) -> bool:
	return won_ids().has(scenario_id)


static func record_win(scenario_id: String) -> void:
	if scenario_id == "" or has_won(scenario_id):
		return
	var config := ConfigFile.new()
	config.load(path)
	var won: Array = won_ids()
	won.append(scenario_id)
	config.set_value("scenarios", "won", won)
	config.save(path)
