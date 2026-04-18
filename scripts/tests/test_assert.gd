class_name TestAssert
extends RefCounted

var check_count: int = 0
var failures: Array = []


func check(condition: bool, message: String) -> void:
	check_count += 1
	if condition:
		return
	failures.append(message)


func equal(actual, expected, message: String) -> void:
	check(actual == expected, "%s (expected=%s actual=%s)" % [message, str(expected), str(actual)])


func near(actual: float, expected: float, tolerance: float, message: String) -> void:
	check(absf(actual - expected) <= tolerance, "%s (expected %.3f actual %.3f)" % [message, expected, actual])


func greater(actual: float, expected: float, message: String) -> void:
	check(actual > expected, "%s (expected > %.3f actual %.3f)" % [message, expected, actual])


func is_true(value: bool, message: String) -> void:
	check(value, message)


func has_failures() -> bool:
	return not failures.is_empty()
