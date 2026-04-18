# Engine of Ecosystem

`Engine of Ecosystem` is a Godot 4.6 ecosystem simulation prototype focused on simulation-first gameplay: deterministic ticking, autonomous herbivore and predator behavior, terrain-aware navigation, telemetry, and debug tooling.

The current build simulates a continuous 2D world with biomes, obstacles, grass regrowth, fixed water sources, herbivore herds, predator hunting, carcass scavenging, reproduction, aging, camera follow modes, minimap navigation, telemetry exports, and camera-driven LOD for interactive play.

## Current Build

- Godot version: `4.6`
- Main scene: `res://scenes/main/main.tscn`
- Headless scene: `res://scenes/main/headless_runner.tscn`
- Default seed: `3`
- Tick rate: `18` ticks per second
- World size: `4800 x 2700`
- Initial population: `220` herbivores in `12` herds, `18` predators
- Water sources: `18`
- Terrain: meadow, forest, drought, swamp biomes plus obstacles and chokepoints

## Core Systems

- Deterministic fixed-step simulation with seeded RNG
- JSON-driven configuration for world, species, balance, and debug settings
- Procedural terrain grid with biome-specific move cost and forage multipliers
- Obstacle generation and terrain-aware pathfinding
- Renewable grass resource grid linked to terrain productivity
- Spatial grid acceleration for proximity queries
- Herbivore behavior: wander, regroup, graze, drink, flee, rest, reproduce
- Predator behavior: patrol, select prey, chase, attack, drink, rest, reproduce, scavenge carcasses
- Lifecycle rules: hunger, thirst, energy depletion, predation, old age
- Carcass lifecycle with feeder reservation and meat depletion
- Runtime telemetry, charts, event log, agent inspector, overlays, minimap
- Camera-driven interactive LOD for distant agents

## Run

### Interactive Scene

1. Open the project in Godot.
2. Run the project, or open `res://scenes/main/main.tscn`.
3. Press `Tab` to show or hide the HUD. The HUD starts hidden by default.

### Headless Scene

1. Open `res://scenes/main/headless_runner.tscn`.
2. Configure `total_ticks`, `seed_override`, and `export_on_finish` in the inspector.
3. Run the scene. It executes the simulation, prints a summary, optionally exports telemetry, and quits automatically.

## Controls

- `Tab`: toggle HUD visibility
- `Esc`: open or close the pause menu
- `W`, `A`, `S`, `D`: pan camera
- Mouse wheel / trackpad pinch: zoom
- Middle mouse drag / trackpad pan: pan camera
- Left click on world: select nearest agent and switch follow mode to `Agent`
- Drag or click on minimap: move camera
- Manual pan input while following: clear follow mode

## HUD Features

From the HUD you can:

- pause or resume the simulation
- single-step one tick
- switch speed between configured speed presets
- switch follow mode between `Off`, `Agent`, and `Flock`
- inspect the selected agent
- review recent events
- toggle LOD on or off
- toggle biome, obstacle, carcass, path, density, water, and debug overlays
- export telemetry snapshots and event logs

## Telemetry Exports

Exports are written to `user://exports` by default:

- `metrics_<timestamp>_seed_<seed>.csv`
- `metrics_<timestamp>_seed_<seed>.json`
- `events_<timestamp>_seed_<seed>.csv`
- `events_<timestamp>_seed_<seed>.json`
- `summary_<timestamp>_seed_<seed>.json`

The summary includes population metrics, death causes, hunt success, carcass metrics, blocked terrain ratio, and LOD counters.

## Configuration

- `data/config/world.json`
  World size, tick rate, terrain generation, navigation limits, water sources, spawn counts
- `data/config/species.json`
  Movement, perception, metabolism, feeding, reproduction, and aging for each species
- `data/config/balance.json`
  Shared thresholds, herd weights, hunt rules, carcass behavior, lifecycle rules, stats sampling
- `data/config/debug.json`
  HUD defaults, UI refresh cadence, overlays, export directory, interactive LOD tuning

## Project Structure

```text
scenes/main/
  main.tscn
  headless_runner.tscn
scripts/core/
  config_loader.gd
  event_bus.gd
  headless_runner.gd
  simulation_manager.gd
scripts/world/
  resource_system.gd
  spatial_grid.gd
  terrain_system.gd
  world_state.gd
scripts/agents/
  agent_base.gd
  herbivore.gd
  perception.gd
  predator.gd
  steering.gd
scripts/stats/
  stats_system.gd
  telemetry_logger.gd
scripts/ui/
  charts_panel.gd
  debug_panel.gd
  game_camera.gd
  main_controller.gd
  minimap.gd
  overlay_renderer.gd
  world_view.gd
data/config/
  balance.json
  debug.json
  species.json
  world.json
docs/
  ARCHITECTURE.md
  FEATURE_BACKLOG.md
```

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Feature Backlog](docs/FEATURE_BACKLOG.md)

## Current Limitations

- The prototype still models one herbivore species and one predator species.
- Rendering is debug-oriented rather than art-driven.
- There is no save/load flow, seasons, genetics, shelter logic, or authored scenario editor.
- Headless mode currently runs the same simulation systems but without camera-driven LOD benefits.
