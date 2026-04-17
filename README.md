# Engine of Ecosystem

`Engine of Ecosystem` is a Godot 4.6 ecosystem simulation prototype focused on the simulation layer first: deterministic ticking, autonomous herbivore and predator behavior, world resources, telemetry, and debug tooling.

The current build simulates a continuous 2D world with grass regrowth, fixed water sources, herbivore herds, predator hunting, reproduction, aging, and event-driven telemetry. The game-facing presentation is intentionally minimal and built around inspection, overlays, and exportable metrics.

## Requirements

- Godot 4.6

## Run

### Interactive scene

1. Open the project in Godot.
2. Run the project, or open `res://scenes/main/main.tscn`.
3. Press `Tab` to show or hide the HUD. The HUD starts hidden by default.

### Headless scene

1. Open `res://scenes/main/headless_runner.tscn`.
2. Configure `total_ticks`, `seed_override`, and `export_on_finish` in the inspector.
3. Run the scene. It executes the simulation, prints a summary, optionally exports telemetry, and quits automatically.

## Controls

- `Tab`: toggle HUD visibility
- `Esc`: open or close the pause menu
- `W`, `A`, `S`, `D`: pan camera
- Mouse wheel: zoom
- Middle mouse drag: pan camera
- Left click: select the nearest agent under the cursor

From the HUD you can:

- pause or resume the simulation
- single-step one tick
- switch speed between `1x`, `2x`, `4x`, and `10x`
- inspect the selected agent
- review recent events
- toggle debug overlays
- export telemetry

## Default Simulation Setup

The shipped config in `data/config/` currently starts with:

- seed `1337`
- tick rate `20` ticks per second
- world size `3200 x 1800`
- `240` herbivores in `12` groups
- `24` predators
- `6` water sources
- grass biomass cells with regrowth

## Implemented Systems

- Fixed-step simulation manager with deterministic seeded RNG
- JSON-driven configuration loading for world, species, balance, and debug settings
- Renewable grass resource grid and queryable water sources
- Spatial grid acceleration for neighborhood and density queries
- Herbivore behavior for wandering, regrouping, grazing, drinking, fleeing, resting, and reproduction
- Predator behavior for patrol, prey selection, chase, attack, feeding, drinking, resting, mate following, and reproduction
- Lifecycle rules for hunger, thirst, energy depletion, predation, and old age
- Event bus for births, deaths, feeding, water use, and predation outcomes
- Runtime stats collection for populations, births, deaths, hunger, energy, hunt success, biomass, and step timings
- In-game telemetry panels with charts, event log, agent inspection, and overlay toggles

## Telemetry Exports

Using the export button or the headless runner writes files to `user://exports` by default:

- `metrics_<timestamp>_seed_<seed>.csv`
- `metrics_<timestamp>_seed_<seed>.json`
- `events_<timestamp>_seed_<seed>.csv`
- `events_<timestamp>_seed_<seed>.json`
- `summary_<timestamp>_seed_<seed>.json`

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
  overlay_renderer.gd
  world_view.gd
data/config/
  balance.json
  debug.json
  species.json
  world.json
```

## Config Files

- `data/config/world.json`: seed, tick rate, world bounds, spatial partitioning, grass settings, water sources, spawn counts
- `data/config/species.json`: per-species movement, perception, metabolism, feeding, reproduction, and aging values
- `data/config/balance.json`: shared thresholds, herd and hunt weights, attack tuning, lifecycle thresholds, stats sampling
- `data/config/debug.json`: HUD speeds, selection radius, chart history, visible event count, export directory, overlay defaults

## Current Limitations

- The prototype models one herbivore species and one predator species.
- Rendering is debug-oriented rather than art-driven.
- There is no obstacle navigation, terrain cost system, shelter logic, genetics, seasons, or save/load flow.
- Runtime verification was limited to static inspection here because no local Godot CLI was available in this workspace.
