extends Node

const TestAssertScript := preload("res://scripts/tests/test_assert.gd")

const SUITES := [
	{"name": "EvaluatorTests", "script": preload("res://scripts/tests/evaluator_tests.gd")},
	{"name": "SelectorTests", "script": preload("res://scripts/tests/selector_tests.gd")},
	{"name": "StateTests", "script": preload("res://scripts/tests/state_tests.gd")},
	{"name": "SimulationTests", "script": preload("res://scripts/tests/simulation_tests.gd")},
]


func _ready() -> void:
	call_deferred("_run_suites")


func _run_suites() -> void:
	var total_checks := 0
	var total_failures := 0
	for suite_entry in SUITES:
		var suite = suite_entry["script"].new()
		var asserts = TestAssertScript.new()
		suite.run(asserts)
		total_checks += asserts.check_count
		if asserts.has_failures():
			total_failures += asserts.failures.size()
			print("FAIL %s (%d failures)" % [suite_entry["name"], asserts.failures.size()])
			for failure in asserts.failures:
				print("  - %s" % str(failure))
		else:
			print("PASS %s (%d checks)" % [suite_entry["name"], asserts.check_count])
		suite = null
		asserts = null

	print("Test summary: %d checks, %d failures" % [total_checks, total_failures])
	queue_free()
	await get_tree().process_frame
	get_tree().quit(1 if total_failures > 0 else 0)
