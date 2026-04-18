# Architecture Overview

## Purpose

This document describes the current structure of `Engine of Ecosystem`, the main runtime flow, the hybrid AI model, and the responsibilities of each major subsystem.

## Runtime Flow

1. `MainController` boots the interactive scene and initializes `SimulationManager`.
2. `SimulationManager` loads config, seeds the RNG, creates `EventBus`, `StatsSystem`, `TelemetryLogger`, and `WorldState`.
3. `WorldState` builds terrain, resources, water sources, initial populations, and spatial acceleration structures.
4. Every fixed simulation tick:
   - `ResourceSystem` regrows grass.
   - Each living agent runs either a full behavior tick or a lightweight LOD maintenance tick.
   - Full AI ticks resolve high-level agent state, build one utility context, select or keep an action, and execute it through the existing movement and interaction helpers.
   - Pending removals, pending spawns, and carcass lifecycle updates are flushed.
   - The spatial grid and LOD counters are rebuilt.
   - `StatsSystem` samples the world and emits snapshots to the UI.
5. The UI listens to `tick_completed`, `selection_changed`, `focus_mode_changed`, and `export_completed`.

## Core Subsystems

### `SimulationManager`

Responsibilities:

- Owns the simulation clock and fixed-step loop
- Applies a per-frame catch-up cap to avoid simulation spiral-of-death
- Tracks pause state, speed multiplier, selected agent, follow mode, and LOD focus rect
- Bridges world state to UI and telemetry

Key behavior:

- Interactive LOD is camera-driven and only activates when a valid focus rect exists.
- Headless runs use the same simulation logic but effectively stay in full simulation mode.

### `WorldState`

Responsibilities:

- Owns the world bounds, agents, carcasses, water sources, and navigation-related systems
- Spawns initial herbivores and predators
- Steps all simulation entities
- Resolves movement against terrain walkability
- Manages carcass spawning, feeder reservation, consumption, and expiration

Important world queries:

- nearby agents via `SpatialGrid`
- reachable grass via `ResourceSystem` + terrain-aware logic
- water source lookup
- carcass lookup and reservation
- group center lookup for herd/flock logic

### `TerrainSystem`

Responsibilities:

- Generates biome layout
- Applies obstacles such as cliffs and dense forest
- Stores walkability and movement cost
- Provides pathfinding helpers and cached navigation data

Current terrain features:

- biomes: meadow, forest, drought, swamp
- biome-dependent move cost
- biome-dependent forage initialization and regrowth multipliers
- obstacle blocking and chokepoint creation

### `ResourceSystem`

Responsibilities:

- Stores grass biomass per cell
- Regrows biomass every tick
- Applies terrain multipliers to initial biomass, regrowth, and max biomass
- Reports total biomass and biomass totals by biome

### `StatsSystem`

Responsibilities:

- Maintains cumulative counters for births, deaths, hunts, carcasses, and water/grass events
- Samples time-series snapshots at configured intervals
- Tracks average and max simulation step time

Current snapshot categories:

- populations
- death causes
- hunger / energy averages
- hunt success rate
- grass biomass totals
- carcass totals
- blocked terrain ratio
- LOD counts

## Agent Model

### `AgentBase`

Shared state includes:

- needs: energy, hunger, thirst, age
- AI runtime: `ai_state`, `current_action`, action age, switch reason, utility scores
- navigation: path cells, path index, repath timing, stuck timer
- targeting: `target_agent_id`, `target_position`
- memory: recent water sources and kin IDs
- runtime: interaction timers, attack cooldown, chase timer, LOD tier

Shared capabilities include:

- needs update and survival checks
- action-decision bookkeeping for debug and anti-thrashing
- terrain-aware movement and inertia movement
- water memory management
- path state reset and movement to target
- reproduction eligibility checks

### Hybrid AI Layer

The runtime AI is split into additive layers:

- `agent.state`
  Legacy execution label used by movement helpers, energy recovery rules, LOD priority, and overlays
- `agent.ai_state`
  High-level FSM-like state such as `alive`, `panic`, `engaged`, `dead`
- `agent.current_action`
  Utility-selected intent such as `graze`, `drink`, `rest`, `hunt_prey`, or `scavenge_carcass`

Utility selection is shared under `scripts/agents/ai/`:

- `UtilityContext`
  One deterministic perception snapshot built once per full AI tick
- `StatePolicy`
  Declares which actions are legal in the current high-level state
- `ActionSelector`
  Scores actions, applies stickiness and switch thresholds, and returns an explainable decision
- evaluators
  Species-relevant utility functions for each action

Anti-thrashing is handled centrally through:

- current action bonus / stickiness
- minimum commitment ticks
- switch threshold delta
- forced interrupts on emergency state changes or invalid targets

### Herbivore

High-level states:

- `alive`
- `panic`
- `dead`

Utility actions inside `alive`:

- graze
- drink
- rest
- explore
- join herd

`panic` restricts the decision space to flee and herd-join behavior.

### Predator

High-level states:

- `alive`
- `engaged`
- `dead`

Utility actions inside `alive`:

- hunt prey
- scavenge carcass
- drink
- rest
- investigate water
- pair cohesion
- patrol

`engaged` keeps existing locked flows such as chase, attack, carcass feeding, water investigation, and reproduction instead of re-scoring every tick.

## UI Layer

### `MainController`

- Binds simulation, camera, overlays, charts, minimap, and HUD
- Keeps the LOD focus rect synced with the camera view
- Handles pause menu and restart flow

### `GameCamera`

- Supports pan, zoom, zoom-to-cursor, follow smoothing, and bounds clamping
- Follow mode can target either the selected agent or the selected herd center

### `DebugPanel`

- Pause, step, speed control
- Follow mode selector
- LOD toggle
- Overlay toggles
- Summary, selected agent inspector, event log, export status
- Selected-agent AI visibility: AI state, current action, action age, decision reason, utility scores

### `ChartsPanel`

- Draws population and trend charts from sampled telemetry history

### `MiniMap`

- Renders static terrain overview plus dynamic agents and camera viewport
- Supports click / drag camera repositioning

### `OverlayRenderer`

Overlay categories currently supported:

- biomes
- obstacles
- grass density
- water
- carcasses
- selected path
- population density
- target lines
- chase lines
- selected vision radius
- herd relations

## LOD Model

Interactive LOD is conservative and camera-driven.

- `LOD0`: full behavior tick every simulation tick
- `LOD1`: full behavior tick at a slower interval
- `LOD2`: full behavior tick at the slowest interval

Agents are forced into `LOD0` when:

- selected
- currently interacting
- chasing, fleeing, attacking, reproducing, feeding, drinking, or scavenging
- in `panic`
- actively targeting another agent

On skipped ticks, distant agents still:

- age
- accumulate hunger / thirst
- recover or lose energy
- die from starvation, thirst, or old age
- advance by inertia without full perception or decision-making

## Configuration Notes

### `world.json`

- controls world size, tick rate, water, terrain generation, navigation limits, and spawn counts

### `species.json`

- tunes each species independently without code changes

### `balance.json`

- tunes cross-species rules, shared lifecycle thresholds, selector thresholds, and utility evaluator weights

### `debug.json`

- controls HUD defaults, overlay defaults, UI refresh frequency, and LOD settings

## Built-In Tests

The project includes an internal headless test runner in `scenes/tests/test_runner.tscn`.

Current suites cover:

- evaluator dominance checks
- selector stickiness and threshold behavior
- state-policy expectations
- small simulation regression scenarios
- deterministic action/state traces across repeated seeded runs

## Known Gaps

- No authored scenarios or scenario editor
- No save/load or replay flow
- No genetics or seasonal systems
- One prey species and one predator species only
- Debug rendering is functional, not art-driven
