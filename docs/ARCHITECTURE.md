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

Interactive runs transfer ownership of the mutable simulation to `SimulationWorker`.
The initial state and explicit save/load boundaries use a full presentation snapshot;
normal ticks send sequenced deltas with compact active-agent records, changed carcasses,
grass cells, sectors, groups, metrics, and events. The presentation world updates its
spatial index only for added, removed, and moved agents. A missing sequence forces a
full resynchronization before another delta is applied.

## Core Subsystems

### `SimulationManager`

Responsibilities:

- Owns the simulation clock and fixed-step loop
- Applies a per-frame catch-up cap to avoid simulation spiral-of-death
- Tracks pause state, speed multiplier, selected agent, follow mode, and LOD focus rect
- Bridges world state to UI and telemetry
- Measures worker step, snapshot construction, main-thread apply, render phases,
  actual simulation speed, and dropped simulation time independently

Key behavior:

- Interactive LOD is camera-driven and only activates when a valid focus rect exists.
- Headless runs have no camera rect, so `_build_lod_context()` substitutes a fixed
  `simulation_lod.headless_active_radius` box at the world center. Agents outside it drop to the
  coarse tiers and their sectors can go dormant, which means headless benchmarks measure the LOD
  path, not full-fidelity simulation. Disable `simulation_lod.enabled` for a full-fidelity run.

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

Escape destination selection evaluates seven headings against all currently
visible threats. It rejects invalid body positions, ranks sight breaks and
minimum predator distance before route cost, and submits only the three best
terrain candidates to the persistent fair navigation queue. The chosen target
is retained until arrival, blockage, a material threat-direction change, or the
configured refresh interval.

Grass target resolution is deliberately two-stage:

1. `_find_local_grass_target()` scans the cells the agent can reach by walking, bounded by
   `navigation.grass_local_reach_cells` steps of walkable neighbours. This needs no path
   search and is what a grazing animal actually does, so it is tried first.
2. Only when nothing edible is within walking reach does the search fall back to the
   per-sector cache (`_find_sector_grass_candidate()`) plus a budgeted path. That cache
   picks its candidate relative to the *sector centre*, so it is a coarse "there is grass
   over there" hint for travel, not a per-agent answer — resolving it first sends every
   herbivore in a sector to the same cell while they stand on untouched meadow.

The grass grid and the terrain grid share a cell index space. That only holds while
`grass.cell_size` equals `terrain.cell_size`; both the walkability checks and the path
goals above depend on it, so the two must be changed together.

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

### `ScenerySystem`

- Owns deterministic prop records with stable IDs, base positions, physical
  radius, cover radius, opacity, movement cost and render metadata
- Indexes those records spatially for rendering, swept body collision and sight
- Treats tree canopies as visual extent only: trunks and stones block, bushes
  slow movement and attenuate sight, and minor biome decoration stays passable
- Refines terrain routes on a body-sized local grid and slides collision-limited
  movement along a clear tangent

### `ResourceSystem`

Responsibilities:

- Stores grass biomass per cell
- Regrows biomass every tick, stepping only the cells currently below their local maximum.
  Consumption adds a cell to that working set and a cell drops out once it refills, so the
  per-tick cost tracks grazing pressure instead of grid size. In a warmed-up world roughly
  1% of cells are regrowing at any moment. `get_regrowing_cell_count()` exposes the set size,
  and the metrics snapshot reports it as `grass_regrowing_cells`.
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
- search starts, prey reacquisitions, search expirations, and average completed
  chase duration

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

### `WorldProjection`

- Single seam between simulation space and screen space, currently the identity transform
- Everything that draws a simulation position goes through `to_screen()`; mouse picking, view
  culling and the LOD focus rect come back through `to_world()` / `world_rect_covering()`
- Exists so an isometric view stays a change to this file plus the tile shape

### `TerrainTileRenderer`

- Paints the terrain grid into two `TileMapLayer` children, biomes below obstacles
- Builds its `TileSet` at runtime from `visuals.json` instead of a `.tres`, so swapping an art
  pack needs no resource kept in sync
- Reads `TerrainSystem` only; repainted on bind and on restart

### `AgentSpriteRenderer`

- Keeps one metadata `MultiMeshInstance2D` per species while `SceneSpriteBatch`
  packs species, carcass and prop atlases into one visible MultiMesh
- Frames are derived from existing agent fields (state, action, velocity, id) and the simulation
  clock, so no visual state is stored on `AgentBase` and headless runs stay bit-identical
- Depth sorting uses every object's projected base across species, carcasses and
  scenery; equal-depth ties put carcasses below animals and passable cover above
- Interpolated positions are accepted only through a body-clear corridor; the
  sprite, shadow, selection marker and follow camera read the same render position

### `WorldView`

- World-space input (click to select) plus the world border, selection ring and state labels
- Terrain and agent drawing moved to the two renderers above

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

The LOD window's `near_margin` / `mid_margin` default from `world.simulation_lod`
(`near_sector_margin` / `mid_sector_margin`), which `presets.json` scales per map size, so
the active window grows with the map. `debug.json` may override them, but does not by
default — when it did, the per-size values were dead and a tripled map kept a fixed-width
active window, which pushed nearly every sector into dormancy.

### Dormant sectors: the coarse ecology

A sector whose agents are all `LOD2` sleeps: its agents are replaced by per-species,
per-group aggregates carrying a count and mean hunger / thirst / energy / age. Both species
must be able to complete their whole loop in this abstraction, or the abstraction becomes a
one-way sink. Two invariants keep the two paths honest:

- **Kills are single-sourced.** `_resolve_dormant_predation()` is the only place a dormant
  kill happens. Each removed herbivore adds exactly `balance.carcass.meat_total` to the
  sector's meat pool, and no meat exists without a matching death. Predation is
  deliberately absent from `_apply_dormant_metabolism_to_aggregate()`.
- **Intake goes through the same ledgers and knobs as the live path.** Dormant scavenging
  debits the real carcass via `consume_carcass()`, so a dormant aggregate and a live
  predator can never eat the same meat. Meat converts to hunger and energy through
  `carcass_nutrition_gain` / `carcass_energy_gain`, exactly as `Predator._scavenge_or_feed()`
  does.

Kill volume and death rates accumulate as float debts on the sector and the aggregate
rather than rounding per step: rounding per step needed four co-located predators to
produce a single kill, so dormant predation was silently always zero, and it also forced at
least one death per step on any saturated aggregate regardless of its size.

This path uses no `rng` calls, so it cannot perturb the shared RNG stream that determinism
depends on.

## Configuration Notes

### `world.json`

- controls world size, tick rate, water, terrain generation, navigation limits, and spawn counts

- `climate` drives seasons and the day/night cycle. It is read by `Climate`
  (`scripts/world/climate.gd`), which is a **pure function of `simulation_time`** rather than
  accumulated state - `SaveSystem` already round-trips `simulation_time`, so the clock costs
  no save-format change by itself. Save version 2 stores agent perception memory and the
  resolved configuration bundle; version 1 is migrated on read. Anything that starts accumulating here
  has to move the version with it.
  Shipped shape: a day is 120 s, a season is one day, a year is 480 s (8 minutes at 1x).
  Each season declares `regrowth_multiplier`, `metabolism_multiplier` and
  `perception_multiplier`; `day` declares the night versions of the same three plus the light
  ramp. Season and night compose **multiplicatively**.
  Two properties the code depends on:
  - `start_day_phase: 0.5` and `start_season_index: 0` make every multiplier exactly 1.0 at
    `simulation_time == 0`. Four test suites rely on that neutrality; `ClimateTests` asserts
    it directly.
  - `season_transition_fraction` holds each season's declared values for the first 65% and
    eases into the next over the last 35%. A consequence worth knowing when reading charts:
    the *value* leads the *label*, so the last third of autumn already carries winter's
    regrowth. Weather runs ahead of the calendar.
  The multipliers reach the world from `WorldState.step()`, which samples the clock once per
  tick. Three consumers: `ResourceSystem.step()` takes the regrowth scale as a parameter;
  `AgentBase.update_needs()` takes the metabolism scale, and
  `_apply_dormant_metabolism_to_aggregate()` mirrors it for dormant sectors - **these two must
  change together**, or sleeping herds survive winters that kill active ones, invisibly,
  wherever the camera is not; `WorldState.perception_radius()` scales eyesight only, never the
  water and grass search radii, which stand in for memory rather than sight.

- `simulation_lod.dormant_travel_reference_sector_size` scales dormant travel speed with
  sector size. `dormant_speed_scale` is fixed, but sector size grows with the map, so
  without this an aggregate has to cover three times the distance per unit of hunger on the
  large map and cross-sector travel becomes lethal rather than merely slow. Speed is clamped
  to `sprint_speed` so a coarse aggregate never outruns a real animal.
- `navigation.prey_pressure_refresh_ticks` throttles the sector-level herbivore census that
  is the simulation's only long-range prey signal. Both the dormant goal selector and the
  live predator patrol read it.

### `species.json`

- tunes each species independently without code changes
- Predator nutrition comes from carcasses only: a kill grants no nutrition by itself, so the
  energy-per-kill knobs are `feeding.food_restore` (the first bite taken at the kill site,
  debited through `consume_carcass()`), `feeding.carcass_consume_rate`,
  `feeding.carcass_nutrition_gain`, `feeding.carcass_energy_gain`, and
  `balance.carcass.meat_total`.
- `feeding.gorge_below_energy_threshold` lets a feeding predator keep eating past the point
  its hunger is satisfied, until it has covered `reproduction.energy_threshold`. Without it
  meat intake is capped by the hunger the predator arrived with, which capped energy income
  below the cost of the hunger cycle that earned the kill and made breeding unreachable.
- `movement.patrol_wander_jitter` is the heading jitter used when patrolling with no prey
  known anywhere in range. It is an order of magnitude smaller than the herding
  `wander_jitter`, because that one decorrelates heading in under a second and diffuses in
  place instead of covering ground.

### `balance.json`

- tunes cross-species rules, shared lifecycle thresholds, selector thresholds, and utility evaluator weights
- `dormant_ecology` holds the coarse-path rates: `kill_rate_per_prey_per_second` (break-even
  for a lone dormant predator is `hunger_rate / carcass.meat_total`),
  `predator_thirst_trigger_ratio`, and `idle_recovery_energy_ratio`. The last one caps how
  far resting alone can carry a dormant aggregate, as a fraction of its own
  `reproduction.energy_threshold`: high enough to leave chase energy for when the sector
  wakes, low enough that a litter still has to be paid for with food. It is deliberately
  expressed against the breeding reserve rather than the shared `rest_energy_resume`, which
  is scaled for the herbivore's smaller maximum and left predators with only a few seconds
  of chase energy.
- Feeding beats pair bonding whenever the two conflict: the mate leash
  (`hunt_rules.kin_chase_break_radius`) is skipped entirely for a predator that is hungry
  enough to feed. Every predator carries a kin centre from the initial pairing, so applying
  it unconditionally made a mate's position one of the largest single causes of lost hunts.
- `prey_isolation` sets the radius and reference count behind how exposed a prey animal is
  judged to be. The radius must sit outside the herd's own `separation_radius`, or every
  animal reads as fully sheltered and both `attack.prey_isolation_bonus` and
  `hunt_weights.isolation` become inert.
- The idle predator actions (`patrol`, `pair_cohesion`, `investigate_water`) veto rather than
  compete once the predator is hungry and has prey or a carcass in reach. Their scores are
  derived from the absence of exactly those signals, so on raw score they outrank hunting;
  a veto also bypasses `selector.stickiness_bonus` and `selector.switch_threshold_delta`,
  which would otherwise pin whichever of them is incumbent.

### `debug.json`

- controls HUD defaults, overlay defaults, UI refresh frequency, and LOD settings

### `visuals.json`

- maps biomes and obstacles onto terrain atlas coordinates
- declares per-species sprite atlases, frame size, draw scale, and the animation rows
- holds the speed thresholds that pick between idle, walk and run

## Built-In Tests

The project includes an internal headless test runner in `scenes/tests/test_runner.tscn`.

Current suites cover:

- swept-radius obstacles, sliding, local route refinement and map boundaries
- bush movement/visibility rules and stable scenery identity
- common prop/animal/carcass depth ordering and collision-safe interpolation
- evaluator dominance checks
- selector stickiness and threshold behavior
- state-policy expectations
- small simulation regression scenarios
- deterministic action/state traces across repeated seeded runs

## Known Gaps

- No authored scenarios or scenario editor
- No replay flow (save/load exists; see `SaveSystem`)
- No genetics
- One prey species and one predator species only
- Debug rendering is functional, not art-driven
