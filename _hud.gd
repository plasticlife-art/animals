extends SceneTree
func _initialize() -> void:
	var main = load("res://scenes/main/main.tscn").instantiate()
	root.add_child(main)
	for _i in range(3):
		await process_frame
	var m = main.get_node("SimulationManager")
	m.set_lod_enabled(false)
	for _i in range(120):
		m.step_once()
	main.set_hud_visible(true)
	if OS.get_environment("PAUSE") == "1":
		main._toggle_pause_menu() if main.has_method("_toggle_pause_menu") else main._set_pause_menu_visible(true)
	for _i in range(6):
		await process_frame
	var hud = main.get_node("CanvasLayer/HUD")
	print("theme set=", hud.theme != null, "  hud visible=", main.hud_visible)
	root.get_texture().get_image().save_png(OS.get_environment("OUT"))
	quit()
