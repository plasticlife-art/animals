extends Node

const TestAssertScript := preload("res://scripts/tests/test_assert.gd")

const SUITES := [
	{"name": "P0PerformanceTests", "script": preload("res://scripts/tests/p0_performance_tests.gd")},
	{"name": "P1ObstacleDepthTests", "script": preload("res://scripts/tests/p1_obstacle_depth_tests.gd")},
	{"name": "P2BehaviorTests", "script": preload("res://scripts/tests/p2_behavior_tests.gd")},
	{"name": "P3BalanceTests", "script": preload("res://scripts/tests/p3_balance_tests.gd")},
	{"name": "MovementEcologyTests", "script": preload("res://scripts/tests/movement_ecology_tests.gd")},
	{"name": "EvaluatorTests", "script": preload("res://scripts/tests/evaluator_tests.gd")},
	{"name": "SelectorTests", "script": preload("res://scripts/tests/selector_tests.gd")},
	{"name": "StateTests", "script": preload("res://scripts/tests/state_tests.gd")},
	{"name": "ClimateTests", "script": preload("res://scripts/tests/climate_tests.gd")},
	{"name": "SimulationTests", "script": preload("res://scripts/tests/simulation_tests.gd")},
]


func _ready() -> void:
	call_deferred("_run_suites")


func _run_suites() -> void:
	var total_checks := 0
	var total_failures := 0
	var requested_suite := ""
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		requested_suite = str(args[0]).to_lower()
	for suite_entry in SUITES:
		if requested_suite != "" and str(suite_entry["name"]).to_lower() != requested_suite:
			continue
		print("RUN %s" % suite_entry["name"])
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
	# No queue_free() here. Freeing this node before the await meant the
	# coroutine had no instance left to resume on, so quit() was never reached
	# and the headless process hung until something killed it. The tree is about
	# to quit anyway, so there is nothing worth cleaning up first.
	await get_tree().process_frame
	get_tree().quit(1 if total_failures > 0 else 0)
