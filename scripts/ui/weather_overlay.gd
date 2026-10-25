class_name WeatherOverlay
extends ColorRect

## The weather on screen: rain, snow, fog and the tint of heat (`Weather.visual()`, drawn by
## `weather.gdshader`) over the map and under every panel. Read each frame from the view's world
## at the time the sprites are drawn at, so a spell eases in on screen as it does in the world, a
## vote's weather (`world_events`) shows the moment it is felt, and a paused game holds it still.
## Hidden in a world without weather.

const WEATHER_SHADER := preload("res://shaders/weather.gdshader")
## The weather's pixels on screen, whatever the zoom: the art's pixel size at the usual zoom.
const PIXEL := 3.0

var simulation_manager = null
var _shader := ShaderMaterial.new()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	color = Color.WHITE
	_shader.shader = WEATHER_SHADER
	material = _shader
	visible = false


func bind(manager) -> void:
	simulation_manager = manager


func _process(_delta: float) -> void:
	var world = simulation_manager.world_state if simulation_manager != null else null
	if world == null or not world.weather_on:
		visible = false
		return
	var time: float = simulation_manager.simulation_time + simulation_manager.get_tick_alpha() * simulation_manager.tick_duration
	var clock: Dictionary = Climate.evaluate(simulation_manager.config_bundle.get("world", {}).get("climate", {}), time)
	var shown: Dictionary = Weather.visual(world.weather_config, str(clock.get("season_id", "spring")), time, world.trait_world,
		world.weather_forced())
	visible = float(shown["rain"]) + float(shown["snow"]) + float(shown["fog"]) + float(shown["heat"]) > 0.001
	if not visible:
		return
	_shader.set_shader_parameter("time", time)
	_shader.set_shader_parameter("scroll", -get_viewport().get_canvas_transform().origin)
	_shader.set_shader_parameter("rect_size", size)
	_shader.set_shader_parameter("pixel", PIXEL)
	for part in ["rain", "snow", "fog", "heat"]:
		_shader.set_shader_parameter(part, float(shown[part]))
	_shader.set_shader_parameter("light", clock.get("light_color", Color.WHITE))
