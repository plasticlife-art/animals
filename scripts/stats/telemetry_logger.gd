class_name TelemetryLogger
extends RefCounted

var export_directory: String = "user://exports"


func initialize(config_bundle: Dictionary) -> void:
	export_directory = str(config_bundle.get("debug", {}).get("export_directory", "user://exports"))


func export_all(seed: int, stats_system: StatsSystem, event_bus, extra_metadata: Dictionary = {}) -> Dictionary:
	var absolute_directory := ProjectSettings.globalize_path(export_directory)
	DirAccess.make_dir_recursive_absolute(absolute_directory)

	var timestamp := Time.get_datetime_string_from_system().replace(":", "-")
	var metrics_path := "%s/metrics_%s_seed_%d.csv" % [absolute_directory, timestamp, seed]
	var metrics_json_path := "%s/metrics_%s_seed_%d.json" % [absolute_directory, timestamp, seed]
	var events_csv_path := "%s/events_%s_seed_%d.csv" % [absolute_directory, timestamp, seed]
	var events_path := "%s/events_%s_seed_%d.json" % [absolute_directory, timestamp, seed]
	var summary_path := "%s/summary_%s_seed_%d.json" % [absolute_directory, timestamp, seed]

	_write_metrics_csv(metrics_path, stats_system.get_series())
	_write_json(metrics_json_path, stats_system.get_series())
	_write_events_csv(events_csv_path, event_bus.get_events())
	_write_json(events_path, event_bus.get_events())
	_write_json(summary_path, {
		"seed": seed,
		"summary": stats_system.get_snapshot(),
		"metadata": extra_metadata,
	})

	return {
		"metrics_csv": metrics_path,
		"metrics_json": metrics_json_path,
		"events_csv": events_csv_path,
		"events_json": events_path,
		"summary_json": summary_path,
	}


func _write_json(path: String, payload) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open export path: %s" % path)
		return
	file.store_string(JSON.stringify(payload, "\t"))


func _write_metrics_csv(path: String, rows: Array) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open export path: %s" % path)
		return
	if rows.is_empty():
		file.store_string("tick,time_seconds\n")
		return

	var headers: Array = rows[0].keys()
	headers.sort()
	file.store_line(",".join(PackedStringArray(headers)))
	for row in rows:
		var values := PackedStringArray()
		for header in headers:
			values.append(str(row.get(header, "")))
		file.store_line(",".join(values))


func _write_events_csv(path: String, rows: Array) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Failed to open export path: %s" % path)
		return
	file.store_line("tick,time_seconds,type,agent_id,other_agent_id,species,position,data")
	for row in rows:
		var csv_row := PackedStringArray([
			str(row.get("tick", "")),
			str(row.get("time_seconds", "")),
			str(row.get("type", "")),
			str(row.get("agent_id", "")),
			str(row.get("other_agent_id", "")),
			str(row.get("species", "")),
			_escape_csv(JSON.stringify(row.get("position", {}))),
			_escape_csv(JSON.stringify(row.get("data", {}))),
		])
		file.store_line(",".join(csv_row))


func _escape_csv(value: String) -> String:
	return "\"%s\"" % value.replace("\"", "\"\"")


func shutdown() -> void:
	export_directory = "user://exports"
