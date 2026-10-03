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
5. The UI listens to `tick_completed`, `selection_changed`, `focus_mode_changed`, `world_event`, and
   `export_completed`.

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
- Interactive ticks run on one persistent worker thread, `_worker_loop()`. A job goes in through
  one semaphore and its presentation delta comes back through another, and
  `is_worker_tick_in_flight()` reports a posted tick that has not been applied yet.
  `synchronize_worker()` blocks for that tick at save and load boundaries, and `_exit_tree()` joins
  the thread before the scripts it runs are unloaded.
- The stats snapshot is frozen with `make_read_only()` when it is written. `tick_completed` and the
  worker hand-off pass that dictionary by reference; `StatsSystem.get_snapshot()` still returns an
  editable copy.
- `world_event` re-emits the events the view acts on (`VIEW_EVENT_TYPES`: `AgentDied`,
  `AgentBorn`, `AgentReproduced`, `HerdSplit`), always on the main thread: from the frame `_apply_worker_frame()`
  applies, or as they happen in `step_once()`. The view listens there, not on `event_bus`, which
  is replaced on every start and load. The bus `initialize()` creates moves to the worker thread
  in `enable_interactive_worker()`, so the manager stops watching it first; watching starts after
  the world is built, so the founders' births are not forwarded. Death events carry
  `data.group_id`, the herd the animal belonged to, and `data.age`, the age it died at, awake
  (`kill_agent()`) or asleep (`_emit_dormant_death()`, where `agent_id` stays -1 and
  `data.record_id` is the id the animal had). A kill in a sleeping sector names no hunter in the
  world's ledger, so the report credits one of that sector's hungry hunters, picked by hashing
  the victim's id (`data.killer_record_id`, `killer_sex`, `killer_species`; never the shared rng).
  Births carry the newborn's `data.sex`, and asleep its `data.record_id` and its
  mother's `data.mother_id`; a herd split carries the herd it came out of (`data.group_id`)
  and how many left (`data.moved`). All of it is reporting for the view's story; none of it
  is read back by the world
- `get_display_time()` is the view's clock: the last tick plus how far the next has come. Effects
  run on it, so they stop while paused and keep pace at 4x and 10x

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
- `segment_clear()` lets a body that starts a hair inside a solid's reach move away from
  it or along it, never deeper; a point query still reports the contact. A neighbour's
  push, rounded, can leave a body there, and blocking every move from such a spot froze
  it for good: the local grid found a way round but its first leg was rejected

### `ResourceSystem`

Responsibilities:

- Stores grass biomass per cell
- Grows it logistically: `growth_rate x biomass x (1 - biomass / cap)`, scaled by the biome
  and the season. A grazed-down sward recovers slowly, a half-grown one fastest, so how
  hard a range is grazed decides what it yields, and grass can run out. This is what holds
  herbivore numbers; `balance.population_regulation` is a guard rail above it.
- `stubble_fraction` of each cell's cap cannot be eaten. Growth restarts from it, so a
  stripped cell comes back. The cell searches and the AI see only the grazable part
  (`get_available_biomass()`); `get_biomass()` is the whole sward, for overlays and stats.
- Steps one slice of the grid per tick (`growth_stride_ticks`), each cell by the time since
  its last turn, with the phase taken from the tick so a loaded save keeps the schedule.
  `get_regrowing_cell_count()` reports the cells below their cap, and the metrics snapshot
  carries it as `grass_regrowing_cells`.
- Applies terrain multipliers to initial biomass, growth, and max biomass
- Reports total biomass, mean density, and biomass totals by biome

### `FearField`

Where prey have learnt to expect predators (`scripts/world/fear_field.gd`): a coarse grid,
`fear.cell_size_in_grass_cells` grass cells to a side. A kill adds `kill_risk` where it
happened, a grazer's scare `scare_risk` where it stood, and hungry sleeping hunters sharing
a sector with prey add `hunt_pressure_risk` per second at the herd; each deposit lands in
full on its cell, at half strength beside it and a quarter diagonally. Risk halves every
`half_life_seconds`. It has no randomness and its decay schedule comes from the tick.

Grazers read it when choosing grass (`WorldState.grass_target_tiers()`): fed, they want a
good sward on ground within `perception.risk_tolerance`, then any full bite there, and
only then risky ground; hungry, they ignore risk. The same tiers drive a sleeping herd's
grass goal, and neither path grazes underfoot on ground above tolerance unless hungry. So
grass regrows where predators hunt until hunger pushes a herd back in - a trophic cascade
that nothing scripts. `ecology_audit.gd` reports it as meadow grass density on feared
ground against the rest.

### `TrailField`

Where animals have been walking (`scripts/world/trail_field.gd`): a grid
`trails.cell_size_in_grass_cells` grass cells to a side holding the distance walked through
each cell. Only travel counts: an awake animal whose action is in `trails.travel_actions`
(to water, to a carcass, after prey, back to the herd) and a sleeping herd whose goal is in
`trails.travel_goals`, and neither below `trails.min_speed`. Grazing and wandering cover as
much ground and go nowhere; counted, they put a blot under every herd and no path between
them. Awake animals are sampled one tick in `_TRAIL_SAMPLE_STRIDE` from the main agent loop
and credited for the ticks skipped. Sleeping ones mark the whole of the step
`_drift_dormant_members()` gave them (`deposit_segment()`): a coarse step is longer than a
cell, and marking only the landing drew dotted lines. Wear halves every
`half_life_seconds`, on a strided sweep keyed to the tick like the other fields, and is
saved with the world.

Shipped at half a grass cell and a 900 s half-life. At a quarter cell each animal drew its
own hairline and no cell gathered enough wear to show; at 300 s a path faded before the
herd came back along it. `scripts/dev/trail_dump.gd` writes the field to a PNG from a
headless run, for tuning without a windowed capture.

Nothing in the simulation reads it: it exists for `GroundTraces` to draw. A test runs the
same world with the field on and off and requires identical animals.

### `StatsSystem`

Responsibilities:

- Maintains cumulative counters for births, deaths, hunts, carcasses, and water/grass events
- Samples time-series snapshots at configured intervals
- Tracks average and max simulation step time

Current snapshot categories:

- populations
- animals at risk: `starvation_risk_<species>_count` (hunger at or past `critical_hunger`) and
  `thirst_risk_<species>_count` (thirst at or past `critical_thirst`); a sleeping sector is
  judged by its species' averages, so its animals count all together or not at all
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
  Scores actions, applies stickiness and switch thresholds, and returns an explainable decision.
  The reason is written only under `context.diagnostics` (the inspected animal, or
  `debug.ai_diagnostics`): «selected X at s (fragments)», «dropped X (veto); …», and the three
  «kept X …» forms, which carry the kept action's own fragments so a course kept can be explained
  too. `WhyText` reads these back into Russian for the card
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

Grazing rules that full fidelity depends on (each was a cause of herbivores starving
with grass all around them, found with a probe that followed every starving animal):

- A bite counts only if the cell holds `WorldState.GRASS_SCRAP_BIOMASS`, or the bite
  wanted if that is less. A cell grazed to its stubble regrows by hundredths a second;
  taking those crumbs counted as eating, and between decisions the grazer acted on its
  stale target, so it stood and nibbled until it starved. The decision snapshot's
  target is replaced when the grazer moves on.
- On its way to the patch it chose, a fed grazer stops only for a full bite underfoot;
  a hungry one for anything that repays twice the hunger it gains while chewing
  (`WorldState.underfoot_bite_floor()`). Herds out of energy crawled past half-grazed
  swards towards patches their herd-mates ate first.
- The unit tests run the game's tick rate and decision interval where a behaviour
  depends on them: deciding every tick, as the base fixture does, hid the first cause.

### Herd migration

A herd moves on before its pasture is gone (`WorldState._update_herd_migrations()`,
config `species.<id>.herd.migration`). Left to their own grass searches, members took the
nearest cell with a bite left, their neighbours ate it first, and the herd lingered on
ground it had eaten until the weakest starved, with fresh pasture a few cells away.

- Every `_MIGRATION_CHECK_INTERVAL_TICKS` each herd - awake members and sleeping records
  counted together - weighs the grass within `pasture_radius_cells` of its centre
  against what its members eat in `horizon_seconds` (`hunger_rate / nutrition_gain` each).
- Below `leave_fraction` of that, it picks the pasture that feeds it best per second of walking there and
  eating, from candidates one pasture radius apart, each weighed exactly as the herd
  weighs its own ground: grass it can use (at most its need) over
  `horizon_seconds` plus the walk, among patches within `search_radius` - and no further
  than the herd covers at half speed before its average member reaches `exempt_hunger`
  - that still hold its need once other migrating herds' shares are taken off, on ground
  within the species' `risk_tolerance`, with water in `water_search_radius`.
- The destination (`herd_migrations`, saved with the world) holds until the herd's
  centre is within the pasture radius of it, another herd has eaten it, or
  `give_up_seconds` pass. On arrival the herd stays `settle_seconds` before it weighs its
  ground again. The gap between arriving where the whole need is and leaving at
  `leave_fraction` of it is what lets a herd eat a pasture down: without it, herds
  re-weighed the new ground from a centre a little off the destination and moved on
  after five seconds, all day long (seed 7: herbivores 279 -> 130 with grass at 0.73).
- Awake members walk there with the herd when idle (state `migrate`) and take their
  grass targets at the destination, eating underfoot on the way; sleeping parts get the
  goal kind `migrate`, a directed goal. A member at `exempt_hunger` (50) or hungrier ignores the
  destination and takes the nearest grass, following its herd by cohesion alone. With the
  line at 80, hungry members dragged towards grass hundreds of units ahead were two
  thirds of the herbivores that starved at full fidelity, when fed to dead took fifty
  seconds.
  Migrating herds wear trails.
- `follow_asleep` (off by default) decides whether sleeping parts take the `migrate`
  goal. Off, the herd still decides and its awake members follow, while sleeping parts
  keep to their own grass search, which already heads for the grass nearest them.
- Measured with `audit_matrix.py`, seeds 1-8, 1440 s, against migration off. LOD:
  with sleeping parts following, herbivore late mean 222 against 259, lower on 6 of 8
  seeds; with awake members only, 280 against 259, higher on 6 of 8 (lowest 200
  against 182, higher on 7 of 8). Full fidelity, where every herd is awake: 221 against
  220, higher on 5 of 8, with the spread over seeds down from 66 to 42 - migration lifts
  the poor maps and trims the rich ones. No interval clears zero; an earlier reading of
  three seeds had called it a clear win.
- No randomness: ties go to the first candidate on the lattice and the check runs on
  the tick.

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

- Single seam between simulation space and screen space: the identity in the top-down style,
  a 2:1 diamond plus a lift per elevation level in the isometric one
- Everything that draws a simulation position goes through `to_screen()`; mouse picking, view
  culling and the LOD focus rect come back through `to_world()` / `world_rect_covering()`
- `visuals.level_height_px` is in art pixels, the skirt step drawn in the isometric atlas. The
  lift on screen is that times `TerrainTileRenderer.iso_art_scale()` (3 with 96-unit cells),
  which `MainController` passes to `configure()`, so a sprite rises exactly as far as the
  ground under it. Until 2026-09-27 it was not scaled, and the tiles sank instead of rising:
  sprites, overlays and the ground layer stood 64 px per level away from their ground and
  no relief showed

### `TerrainTileRenderer`

- Top-down, paints the terrain grid into two `TileMapLayer` children, biomes below obstacles.
  Isometric, one y-sorted layer: each cell picks the tile alternative for its level, whose
  `texture_origin` raises the art one skirt step per level (Godot draws a tile at its cell
  minus `texture_origin`, so raising means a larger y)
- Builds its `TileSet` at runtime from `visuals.json` instead of a `.tres`, so swapping an art
  pack needs no resource kept in sync
- Reads `TerrainSystem` only; repainted on bind and on restart

### `GroundTraces`

- Shows what the ecology has done to the ground, in the normal view: how much grass each
  cell holds as a share of its cap, on a ramp through `ground.bare_color`, `dry_color`,
  `mid_color` and `lush_color`, each reached in full at its `grass_stops` share (bare earth,
  dry straw, the tile as drawn, the refuges fear leaves ungrazed), and paths where
  `TrailField` wear passes `ground.trail_range`. The ramp used to tint only below 0.4 and
  above 0.62, so ground grazed to half looked untouched. Missing keys take the defaults in
  `GroundTraces.GROUND_DEFAULTS`
- A quad per walkable terrain cell placed through `WorldProjection` at the cell's elevation,
  UV carrying the world position. `shaders/ground_traces.gdshader` reads grass, grass caps
  (`ResourceSystem.export_caps()`) and trails from float textures built straight from the
  packed arrays, so a refresh runs no loop in script
- Top-down: one `MeshInstance2D` after `TerrainTiles` at the same z, above the biome tiles
  and below obstacles, animals and overlays, under `DayNightTint`
- Isometric: one mesh per diagonal row of cells, each a child of the terrain's y-sorted layer
  placed just after its row's tiles, so raised ground in front covers the tint behind it as
  it covers the ground. A single mesh drawn over the tiles painted the tint of low cells
  over the cliffs in front of them
- Draws the watering holes too, under the animals and darkened at night with the ground: a
  signed distance field (`WaterMask.bake()`, negative inside water, overlapping ponds joined)
  baked once per world at half a terrain cell per texel, since ponds never move. The shader
  shades water from shallow to deep with the distance, puts foam at the rim and a sand shore
  outside it, bends the edge with noise and runs ripples on wall time. Water used to show only
  as a debug disc drawn over the animals. It is on by default and independent of
  `ground.enabled`; ponds stay walkable, so animals wade, and obstacles and props crossing a
  pond draw over it. In the isometric view each row mesh carries the water at its cells' height
- Softens the biome borders too. The terrain grid is square cells, so its biomes met in a
  staircase; now a fragment near a cell's edge looks a noise-warped way into the neighbouring
  cell - the warp stepped to the art's pixel - and takes that cell's surface when it is another
  walkable biome on the same level, so both sides fray into each other in pixel steps.
  `biome_image()` bakes per cell the biome's index, its height and whether it is walkable, once
  per world. Top-down the surface is read from the style's terrain atlas in world space (the
  tile map's rotation variant may differ under it); isometric it is the biome's colour, which
  is what the placeholder diamonds' top faces are, and skirts are left alone. Obstacle cells draw
  above this layer and keep their square edges. Composite: tile, border, grass and trails, water
- Refreshes every `ground.update_interval_ticks`. With the worker running, the manager asks
  it for the whole grass and trail grids on exactly those ticks (`ground` in the result),
  independent of the grass debug overlay's dirty-cell delta

### `AgentSpriteRenderer`

- Keeps one metadata `MultiMeshInstance2D` per species while `SceneSpriteBatch`
  packs species, carcass and prop atlases into one visible MultiMesh
- Frames are derived from existing agent fields (state, action, velocity, id) and the simulation
  clock, so no visual state is stored on `AgentBase` and headless runs stay bit-identical
- Depth sorting uses every object's projected base across species, carcasses and
  scenery; equal-depth ties put carcasses below animals and passable cover above
- Animals, props and carcasses darken at night with the ground (`DayNightTint`). Their atlas
  shaders used to be unshaded, which in Godot skips the canvas modulate along with lights,
  so at midnight every animal and tree stood in daylight on dark-blue ground
- Wind: plants sway in `scene_atlas.gdshader`. The batch is shared with animals and bodies for
  painter order and every instance channel is taken, so a prop is told by where its frame sits
  in the packed atlas: `SceneSpriteBatch.configure_wind()` passes the props band and one weight
  per prop slot (`sway_weights()`, from `visuals.wind.weights` by prop group). The quad's top is
  sheared and its ground edge stays; VERTEX is still the quad's own and MODEL_MATRIX holds the
  instance transform, so the shift is divided by the quad's width and the phase comes from where
  the prop stands - a gust runs across the field. Wall time, so trees move in a paused photo;
  stilled in the overview (`set_wind_paused()`). No CPU cost: static entries stay cached
- Interpolated positions are accepted only through a body-clear corridor; the
  sprite, shadow, selection marker and follow camera read the same render position
- An animal that dies in view plays its species' `dead` row (`DyingSprites`, from
  `world_event`), where it was last drawn and facing the way it was drawn. Every row in the
  pack falls, flushes red at the blow and fades back to the body's own colours, at frames
  that differ by species, so the row lists which to play: a kill (`kill_frames`) runs through
  the reddest frame and stops on the next, still flushed, and any other death
  (`fall_frames`) skips the red. A test reads the atlases to hold the lists to the art. A dead
  animal leaves the simulation in the tick it dies, so the row had never been drawn.
  The sprite closes the tick-long gap between where it was drawn and where it died, runs on
  `SimulationManager.get_display_time()` (it stops on pause and keeps pace at 4x) and holds
  back the body it leaves until it starts to fade, then crossfades into it. Off screen, in a
  sleeping sector (no sprite) and in overview a death only leaves its body; at most
  `effects.death.max_active` play at once
- A body is drawn from its own species' carcass sheet (`species.<id>.carcass_atlas`, built by
  `tools/build_carcass_atlases.py` from the species' atlas): whole, then opened with the ribs
  across it, then bones on the stain it left, as its meat goes (`carcass.stages`). It starts
  from the frame the fall ended on, so the fall hands over in place: lying the way the animal
  fell (`carcass_direction()`, remembered for each death seen; a death nobody saw lies a way
  fixed by the body's id), at the size it had (a fawn's body is small), flushed red only
  after a kill. Until 2026-10-03 every species left the deer's body, and a fresh one was the
  deer's red flash frame, so a fox turned into a deer as it fell and a starved animal turned
  red. A species without a sheet falls back on the shared `visuals.carcass` one
- `EventEffects`, a child node, marks what just happened in view on the same clock: dust
  behind a herbivore or predator running in a chase (the hunter in `hunt_prey`, the prey
  fleeing or panicking), one puff per `effects.dust.spacing_px` of ground it covers, so a
  faster animal raises more; a burst of puffs and a flash where a kill fell; a ring and
  sparkles where a young animal was born (`reason` `reproduction`), while the newborn grows
  in from a third of its size with a small overshoot. Birds raise no dust: their run row is
  flight. In a pond the dust is spray. Dust, bursts and rings lie on the ground just above
  the shadows, under the sprites, and darken at night with it; the flash and the sparkles are
  added light above the sprites, unshaded, so they stay bright at night. The marks sit in an
  `EffectQueue`, capped at `effects.max_active`, recycled through a free list and scattered
  by a hash of the animal's id rather than a random stream, so the view advances no
  generator. Nothing is drawn in overview

### `WorldView`

- World-space input (click to select) plus the world border, selection ring and state labels
- Terrain and agent drawing moved to the two renderers above

### `MainController`

- Binds simulation, camera, overlays, charts, minimap, and HUD
- Keeps the LOD focus rect synced with the camera view
- Handles pause menu and restart flow
- Rebinds the ecology strip and the herd card on every world it adopts, from the setup
  screen or a save: the strip's species come from the bundle, and the card's losses belong
  to the world they were heard in
- The herd card and the selection card stand in one bottom-left `CardStack`, which steps
  right of the Tab panel as a whole

### Story: names, family tree, pins (`scripts/story/`)

- `StoryBook` tells the world as a story about its animals and is what the animal's card, its
  tag, the pinned list and the event feed read. It hears `world_event` on the main thread and
  is saved with the world (`SaveSystem.save()`'s `story`; a save without one starts a new
  story). Nothing in it reaches the simulation
- `PlaceNames`: a Russian name for every watering hole («Тихая заводь») and for districts of
  roughly equal size (about one per 2200x2200 units, so two dozen on the large map), each named
  after the biome it has most of against the whole map («Ольховый бор», «Совиное болото», «Медовый
  луг»). Biomes alone do not make places: the meadow is one patch over half the map, and the woods
  and dry ground are hundreds of small ones. Picked by hashing the world seed and the index, an
  adjective's use kept to its fair share; declined with its noun (gender; genitive for «у Тихой
  заводи», the locative with «на»/«в» for «на Медовом лугу»). `place_at()` gives the pond within
  1.6 radii, else the district. Kept with the story, so a later word list leaves an old world's
  names alone
- `AnimalNames`: a Russian name for every animal from a list for its species and sex (157 a
  sex for deer, 84 for grouse, 50 for foxes: each list holds more than half the largest
  starting population any preset gives, so a numbered name stays rare until a population
  outgrows its start), the first of a few picks hashed from its id that no living animal
  answers to, so the same world names the same animals. Only when every pick is
  taken does a name get a number, «Ветка II», the lowest one no living Ветка holds; a death
  gives it back. Founders are named in id order as the world is adopted, newborns as they are
  heard, animals waking far off when the interface next refreshes
- `Lineage`: parents (an awake birth's `AgentReproduced` names both, told apart by sex; a birth
  asleep its mother), birth and death times, the cause and the killer, where it died, the
  generation (founders are the first), children and living descendants. An animal not seen born
  is dated by the age it had when met, or when it died (`met`, `met_age`; founders were born
  before the clock started). Running counts, kept with the save and rebuilt from the tree for a
  save without them: kills per hunter, and living and all descendants per animal - a birth adds
  one to every distinct ancestor, a death takes one off. The longest dead are forgotten past
  30000 animals
- `FamilyTree`: three generations around one animal for the chronicle - four grandparents, two
  parents, the first `MAX_CHILDREN` children (the living first) and how many more - and what each
  relative's box says (name and sex, kind, age, or «†» and the cause)
- `StoryRecords`: the chronicle's records from one pass over the tree - the oldest alive, the
  longest lives, the largest living families, the best hunters - three each, ties to the lower id
- `Epitaph`: what is said of an animal when it dies - «Ветка, олениха — старейшая на карте.
  Прожила 2 года и 1 сезон. 7 детёнышей (живы 3), 12 живых потомков. Погибла у Тихой заводи:
  задрал лис Рыжик.» Written by `StoryBook` for a pinned animal, the selected one (or the one the
  selection let go of within `RELEASE_GRACE` seconds) and a record holder; the records it held
  are read just before its death is noted, against tops refreshed every `RECORDS_TTL` seconds
  rather than per death, and «прожила дольше всех» needs at least a year. `epitaph_written`
  carries it to `EpitaphCard`; the feed tells that death by it, in gold, never folded; the dead
  pinned row is crossed and has it for a tooltip
- Pins: up to eight animals the player keeps an eye on, from the card's «Закрепить». A pin
  does not keep an animal's sector awake, so a world plays the same with pins or without; a
  pinned animal asleep is followed through its sector's aggregate, and its death and its young
  there through the ids sleeping births and deaths carry
- `PinnedBar`: the pinned animals at the top left by name and kind, «вдали» while asleep,
  «погиб(ла)» once dead. A click selects and follows one awake, sends the camera to where one
  sleeps (and selects it when it wakes) or fell; a right click unpins
- The animal's card names it («Ветка ♀ · олениха») and gives its family: the parents as links
  that do the same, children and how many live, living descendants and the generation
- `StoryLog` writes the event feed: what happened to whom in a short Russian line («Ветка,
  олениха из Стада №3, погибла: задрал лис Рыжик», «Пополнение в Стаде №3: оленёнок Звёздочка,
  мать — Ветка», «Стадо №3 разделилось: 12 голов ушли в новое Стадо №8»), with the grammar from
  `HudText`. Only what the player looks at gets a line of its own - an event in view (the
  renderer's visible rect), in the selected animal's herd, or of a pinned animal, its death,
  its young or its kill, asleep or awake; the rest is counted and summed up for the whole map
  once a simulated minute («За минуту по всей карте: хищники — 4 оленя · голод — 2 лисы ·
  родились — 6 оленят»). A run of the same thing in one herd within 12 s folds into one line
  with a number. 40 lines are kept; they are not saved. The log holds its book weakly, since
  the book holds the log
- `StoryFeed` shows the newest seven above the minimap with the time of day, pinned animals in
  gold and the summaries dimmer; a click selects the animal the line names while it lives (the
  hunter, the newborn) or sends the camera to where it happened. Dark like the season bar and
  the strip, hidden by the start menu like the minimap

### `HerdCard`

- The selected animal's herd, above its own card, in Russian: the herd's name and number
  («Травоядные · Стадо №5»), how many there are with how many sleep far off and how many
  are young, the means of their energy, food and water as the selection card's bars
  (`AgentReadout.need_bars()`, against the selected animal's own thresholds), how many
  hunters are after them now, the last loss with its cause and how long ago, and a toggle
  that follows the herd (`focus_mode` "flock")
- Shown while a herding animal is selected: a species whose `role.social` is `herd` (grazers
  and scavengers), never a predator, which keeps to a pair. It goes when the selection dies
  and while the start menu is up
- `HerdReadout` works it out apart from the drawing: awake members from the living agents,
  sleeping ones from the aggregates of sleeping sectors (young = count less the mature),
  hunters as awake animals of a species that eats this one, in `seek_prey`, `chase`,
  `search_last_seen` or `attack`, whose target is a member. `HerdLossLog` keeps each herd's
  last death from `world_event` - death events carry `group_id`, asleep or awake - and
  forgets an id a split hands out, since ids are reused
- The selection card's Follow is pressed only while the camera follows the animal itself;
  pressed during a herd follow, it switches to the animal

### `GameCamera`

- Supports pan, zoom, zoom-to-cursor, follow smoothing, and bounds clamping
- Follow mode can target either the selected agent or the selected herd center

### `DebugPanel`

- The developer's panel, in Russian like the rest: offered only in developer mode
  (`debug.developer_mode`, F12 while playing), then shown and hidden by Tab with the charts
- Pause, step, speed control
- Follow mode selector
- LOD toggle
- Overlay toggles
- Summary, selected agent inspector, event log, export status
- Selected-agent AI visibility: AI state, current action, action age, decision reason, utility scores

### `PlayerBar`

- What a player needs, at the top left: pause, the speeds from `debug.speed_steps`, three
  layers (grass, danger from `show_fear`, chases), «Летопись» and help. Built in code; it reports what was
  pressed and `MainController` applies it, keeping the bar and the developer panel in step
- Up while a world runs with nothing over it; it steps aside for the developer panel, which
  has the same controls, and for the menus

### `HudText`

- Every word the interface shows about the world, in Russian: species and the animals in them
  by sex and age, herds and their cases («из Стада №3»), biomes, causes of death, actions and
  states, and the grammar they need - a verb in the animal's gender, the form a noun takes
  after a number. A test checks every `AgentAction` and state has words, and that no English
  label is left in the main scene

### `ChartsPanel`

- Draws population and trend charts from sampled telemetry history

### `MiniMap`

- Renders static terrain overview plus dynamic agents and camera viewport
- Supports click / drag camera repositioning
- Its tooltip names the place under the cursor (`PlaceNames.place_at()`); `PixelUiTheme` styles
  tooltips on parchment

### `SettingsStore`, `SettingsPanel`

- The player's own settings, apart from the game's config: full screen and the interface's size
  (75, 90, 100, 110, 125 %; at 150 % the selected animal's card alone fills the left column of
  the 1600x900 layout), in `user://settings.cfg` through `ConfigFile`, read and applied in
  `MainController._ready()` before the first frame and written on every change. The panel opens
  from the pause menu's «Настройки» and the setup screen's, like help, and goes back there; F11
  switches full screen from anywhere. Volume waits for sound
- The interface's size is the window's `content_scale_factor`. With `canvas_items` stretch that
  scales the world too, so `GameCamera.set_ui_scale()` divides its zoom (and its zoom limit) by
  the same factor and the map keeps its size on screen; `user_zoom()` is the magnification the
  player chose, which `PlaceLabels` fades on
- `MainController._layout_hud()` keeps a small canvas tidy each frame: the season bar and the
  strip step right of the player bar, and `HerdCard.set_room(false)` lets the herd card give way
  when the selected animal's card and the pinned list leave it no room (with slack before it
  comes back)
- Esc on the setup screen no longer opens the pause menu behind it, which before the first world
  had no buttons wired and on closing handed the mouse to a world under the menu

### `PhotoMode`, `GifRecorder`, `GifEncoder`

- Photo mode (P, «Фото» on the player bar) hides the HUD's single CanvasLayer - never panel by
  panel, since the cards show themselves again on the next tick - with the overlays, the world
  border, the place names and the selection ring (`AgentRenderer.show_selection_ring`), and gives
  back exactly what was shown. The camera keeps moving; world clicks are off. Its own bar on a
  CanvasLayer above: «Снимок», «GIF 10 с», «Пауза»/«Пуск», «Скрыть» (H), «Выйти» (Esc, P)
- PNG: the bar hidden for a drawn frame, then the viewport read back at full size. Files go to
  `OS.SYSTEM_DIR_PICTURES/Engine of Ecosystem`, or `user://photos` without one; the bar names the
  file and offers «Открыть папку» (`OS.shell_show_in_file_manager`)
- GIF: `GifRecorder` grabs the window 15 times a second for 10 seconds on the main thread (the
  only one that may read the screen back), crops off the red frame that marks the recording,
  scales to 640 wide, and feeds a coding thread through a queue; each frame lasts as long as it
  really did until the next. The owner polls it each frame afterwards, so nothing calls back
  across threads, and quitting mid-film waits for the file. `GifEncoder` is plain GDScript: one
  palette from the first frame - a median cut of its 15-bit histogram plus a 27-colour lattice for
  colours it lacked - colours looked up once per 15-bit value, LZW with growing code width and a
  clear when the table fills, a NETSCAPE loop. Measured on this Mac: 147 frames in 10 s, about
  9 MB, the game's frame time 9 ms on average and 28 ms at worst while recording

### `WhyText`

- The card's «Почему:» line: the selected animal's last reason (shipped for the inspected animal
  only, `simulation_worker.gd`) read back into Russian - what it dropped and why («перестала
  пастись — наелась»), what it does now and the two strongest fragments («жажда, вода рядом»),
  the forced reasons («убегает — рядом опасность») and a hunt's state («ищет, где видела
  добычу»). Every evaluator label and veto has words, which a test checks against the evaluators'
  source; reasons in tests come from the real `ActionSelector`. The card holds a switch's words
  `WHY_HOLD_MSEC` before the reasons for going on replace them

### `ChronicleWindow`

- «Летопись», a parchment window over the map while the world runs: «Родословная» draws
  `FamilyTree.around()` - grandparents, parents, the animal, its first eight children (the
  living first) and how many more - as boxes and lines; relatives nobody knows are left out, and
  a founder's says «основатель: родители неизвестны». A click on a relative re-centres the tree
  and asks `MainController._focus_animal()` for the camera; «Назад» walks back. «Рекорды» lists
  `StoryRecords`; a click opens that animal's family. Refreshed every 1.5 s while open
- Opened by L (`toggle_chronicle`, by physical key so a Russian layout presses it too), the
  player bar's «Летопись», the card's «родословная» link and the epitaph card; Esc closes it
  before the pause menu would open

### `EpitaphCard`

- Parchment card at the right under the strip's level, clear of the selected animal in the middle
  and of the strip at any interface size, with the epitaph of a death worth remembering, «Где
  это» (camera to the place) and «Родословная» (the chronicle); ten seconds each, counted only
  while the game runs, several queued; hidden by the start menu

### `PlaceLabels`

- Draws `PlaceNames` on the map: pond names once zoomed in past `visuals.places.pond_zoom`, district
  names between `district_zoom_min` and `district_zoom_max`, each faded over a band rather than
  popped. Constant size on screen, outlined, unshaded so night leaves them legible, placed through
  `WorldProjection` at the ground's height. Redraws only when the camera moves

### `EcologyStrip`

- How the land is doing, always on screen under the season bar and hidden only by the start
  menu, in Russian like the season bar: per species the count with an arrow while it rises
  or falls by more than 3% (or two animals) over the last minute, how many are close to
  starving and to dying of thirst (`starvation_risk_*`, `thirst_risk_*`), how many were
  killed in that minute (cumulative `deaths_predation_*`, a dash for species nothing hunts),
  and each biome's grass as a share of what its cells can hold
- `EcologyReadout` works the figures out from the stats snapshots and the series, apart
  from the drawing, and gives each a level the strip colours it by: risk past 10% / 25% of
  the species, kills past 2% / 5% of it a minute, grass below 30% / 18% of its biome's
  capacity. The grass levels come off four 96-minute runs, where the whole map's share kept
  between 0.21 and 0.71, mostly 0.3 to 0.5, and dipped in winter; a world starts at 0.47
- The capacity is summed once per world object, so the copy the worker hands the view gets
  its own. `HudText` holds the Russian names the strip and the herd card share

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

Agents are forced into `LOD0` (`_is_priority_lod_agent()`) when:

- selected
- seeking or chasing prey, searching where it was last seen, attacking, fleeing, or reproducing
- in `panic`
- actively targeting another agent

Eating, drinking and feeding on a carcass are not on the list: an animal doing them in the
`LOD1` / `LOD2` rings does so on its full ticks only.

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

A sector whose agents are all `LOD2` sleeps: its agents become records, and per-species,
per-group aggregates decide for them as a herd. Every record keeps its own position,
hunger, thirst, energy and age; an aggregate effect reaches a record as a change, never as
an assignment. Every species must be able to complete its whole loop in this abstraction,
or the abstraction becomes a one-way sink. These invariants keep the two paths honest:

- **Needs kill animal by animal.** A record dies of hunger or thirst at the same
  `lifecycle.*_death_threshold` a live animal does (`_dormant_need_deaths()`). Judged on the
  herd's mean, a herd of eighty went in fifteen seconds once the mean passed 98, and whole
  herds died out one after another. A herd heads for water for its thirstiest member, not
  only once the mean is critical.
- **A herd has to reach its food.** It looks for grass nearest itself
  (`_find_dormant_grass_goal()`), not by the sector's centre, takes a route round terrain
  from the same budgeted search live animals use (`_dormant_herd_waypoint()`), and its
  hungry members walk to grass a few cells around them (`_dormant_step_towards_grass()`).
  None of this mattered while grass was underfoot everywhere; with grass that runs out, a
  herd that walks at a cliff or stands on a grazed patch starves.

- **Kills are single-sourced.** `_resolve_dormant_predation()` is the only place a dormant
  kill happens. `_reconcile_dormant_records()` picks the victims and leaves each one's
  carcass where it stood, sized exactly as a live death's, so no meat exists without a
  body and sleeping hunters eat from those bodies. Predation is deliberately absent from
  `_apply_dormant_metabolism_to_aggregate()`.
- **Intake goes through the same ledgers and knobs as the live path.** Dormant scavenging
  debits the real carcass via `consume_carcass()`, so a dormant aggregate and a live
  predator can never eat the same meat. Meat converts to hunger and energy through
  `carcass_nutrition_gain` / `carcass_energy_gain`, exactly as `Predator._scavenge_or_feed()`
  does.

Kill volume and old-age deaths accumulate as float debts on the sector and the aggregate
rather than rounding per step: rounding per step needed four co-located predators to
produce a single kill, so dormant predation was silently always zero.

Only the LOD window is awake. A sector outside it sleeps even with a predator and prey in
it, or beside a window full of predators: the coarse step settles that hunt. An animal that
walks out of the window joins the sleeping sector it walked into at the end of the tick
(`_absorb_strays_into_dormant_sectors()`), unless it is a priority agent (above) or
selected, and a sleeper that walks into the window, or into a sector kept awake by a chase,
wakes on its own (`_migrate_dormant_sector_records()`). Until 2026-09-30 the sectors around
the window were woken whenever a predator was in one or in the window beside it, and
`_sleep_far_sectors()` put them back to sleep at the end of the same tick, each of them
about a thousand times a minute. The coarse step never ran there, since the sector was
awake whenever steps ran, and its animals lived as `LOD2` agents - one full tick in 24 in
overview - with their group goals rebuilt every tick. Predators starved in that ring beside
fresh carcasses, and the prey nobody ate there drew more predators in: in one 48-minute LOD
run 39 of the 45 predators that starved died in those twelve sectors, a quarter of the map
(`scripts/dev/predator_probe.gd`).

Every predator in a sleeping sector shares one aggregate, a pack, and a pack looks for food
or water when its hungriest or thirstiest member is a margin past the floor
(`_DORMANT_PEAK_HUNGER_MARGIN`, `_DORMANT_PEAK_THIRST_MARGIN`), as a herd goes to water for
its thirstiest. By the mean alone a pack of twenty sat just under the feeding floor and
wandered while half of it was hungry. The peaks are tallied when a group is built as well as
at the reconcile (`_tally_dormant_member()`): each coarse step ends by rebuilding its
sector's groups (`_migrate_dormant_sector_records()`), and the next step picks goals before
it reconciles, so whatever goal selection reads has to survive the rebuild. Until 2026-10-02
the peak thirst did not, and no sleeping herd ever went to water for its thirstiest member.

Sleeping hunters catch each prey species as readily as `dormant_ecology.prey_catchability`
says: it scales the kill debt, chooses which herd a kill comes from, and weighs the prey
pressure that draws sleeping hunters to a sector, from a list ranked by it apart from the
head count live hunters patrol by. The coarse ledger has no chase, and scavengers - which
outrun a predator at a sprint and see it at 260 - were three quarters of sleeping predators'
kills against a fifth of live ones'; over 96 minutes of LOD they were eaten out on four
seeds of eight. A group of carrion eaters no longer sets out for a body that will have
rotted (`carcass.ttl_seconds`) before it arrives.

A sleeping group heads for the water nearest it in a straight line, and a route search that
finishes without reaching it rules that water out for the group (`unreachable_water`), so
the next goal refresh picks other water. Nearest in a straight line was often across a
cliff: on seed 1 a flock of 54 scavengers stood 700 units from a pond it had no route to,
the four nearest sources all out of its reach, and was down to 13 five minutes later, dying
of thirst 1360 units from water it could reach. The list lasts as long as the group sleeps,
even once it has moved somewhere it could reach that water from.

None of this reaches a run at full fidelity, which stays identical. Measured with
`audit_matrix.py`, seeds 1-8, 96-minute LOD runs, against the code of 2026-10-01: no
species was lost on any seed, against five seeds (without the water change: two);
scavengers' late-half low 92 against 36 and predators' 45 against 35; herbivores dying of
thirst 214 a run against 616, and scavengers 11 against 19. Herbivores now reach water and
are held by grass instead: 1482 starved against 996. Sleeping predators still took half
their kills from scavengers, against a fifth live.

That was where they hunted, not what they could catch. A hungry pack used to stay in its
sector whenever there was any prey in it at all, and scavengers follow packs for their
leavings. The coarse ledger has no chase, so its kills are limited by hunger alone, and a
pack among a flock ate whatever was at hand. On three seeds half of sleeping predators'
kills were made with no herbivore within 768 units, against 18% of live ones', and a
sleeping pack took its scavengers from among some 58 of them with 25 predators about,
where a live one took them from among 9 with 4. A pack now hunts where it stands only
while that is as good a hunt as any within its reach, scored as the sectors it picks
between are (`find_prey_pressure_goal()`), with no way to go. A lower `prey_catchability`
only slowed the same kills: at 0.05 and 0.03 the share of scavengers fell on some seeds and
not others, predators starved twice as often, and at 0.05 the scavengers died out on one
seed of eight.

Measured with `audit_matrix.py`, seeds 1-8, 96-minute LOD runs, against the code before:
scavengers are 0.30 of predators' kills against 0.56 (0.21 at full fidelity), 0.022 a
predator-minute against 0.055 (0.023), and herbivores 0.044 against 0.035 (0.088). No
species was lost. Predators spent less of the late half on their cap, 0.79 against 0.90,
and starved 0.22 times an hour a head against 0.11 (0.37 at full fidelity). On two seeds
they fell to 10 and 29 and came back; on the one probed, an age cohort was dying and too
few pairs reached breeding energy to replace it (see Known Gaps). Full fidelity stays
identical.

`_split_oversized_herds()` runs for live and sleeping animals together. Offspring join
their parents' herd and nothing ever left one, so herds only grew, and one too big for its
range starves and is never replaced. A herd past its species' `herd.split_size` divides
at the median of the axis it is spread widest on; the far half takes the next group id.

This path uses no `rng` calls, so it cannot perturb the shared RNG stream that determinism
depends on. That covers waking too: a dormant newborn's sex comes from `_deterministic_sex()` on
its id, and `_restore_dormant_agent()` hands `configure()` a throwaway generator for the wander
angle it rolls. `SimulationTests._test_dormant_path_leaves_rng_untouched` pins both.

Determinism therefore holds for the same seed and the same LOD context. Which agents run a full
tick follows the camera, and full ticks do draw from `rng` - wander, attack rolls - so a run
watched differently diverges. `_test_determinism_with_lod_and_dormancy` replays one fixed headless
context through sleep and wake.

Nothing that decides what the simulation does may read the wall clock. Route search used to stop
for the tick after `path_time_budget_ms_per_tick` of real time; on a busy machine that cut-off fell
on a different request, two same-seed runs gave paths to different animals, and positions drifted
while `rng.state` still matched. The per-tick budget now counts A* node expansions
(`navigation.path_expansion_budget_per_tick`), the last slice of a tick is trimmed to what is left,
and every `Time.get_ticks_usec()` in the simulation feeds a `_ms` counter only.
`_test_path_budget_replays_under_any_clock` replays a path-starved map with every navigation
millisecond setting squeezed to zero.

## Configuration Notes

### `world.json`

- controls world size, tick rate, water, terrain generation, navigation limits, and spawn counts
- `water_sources` is read only when `water_generation` is absent. The shipped config generates
  sources from map area, so it carries no hand-placed list

- `climate` drives seasons and the day/night cycle. It is read by `Climate`
  (`scripts/world/climate.gd`), which is a **pure function of `simulation_time`** rather than
  accumulated state - `SaveSystem` already round-trips `simulation_time`, so the clock costs
  no save-format change by itself. Save version 2 stores agent perception memory and the
  resolved configuration bundle; version 1 is migrated on read. Anything that starts accumulating here
  has to move the version with it. A save plays on with its own bundle but is drawn with
  today's: `ConfigLoader.with_shipped_presentation()` takes `visuals` (apart from `props`,
  which places the scenery) and the debug overlay switches from the shipped files, so an
  old save gets the grass ramp, the water, the effects and animation rows that match the
  atlases
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
- `navigation.path_expansion_budget_per_tick` caps A* node expansions per tick across all
  global route searches, alongside the count caps `path_budget_per_tick` and
  `max_new_paths_per_tick`. Searches run in slices of `path_expansions_per_slice` and resume on a
  later tick, so a lower budget delays routes rather than shortening them. It replaced a
  wall-clock budget that made replays machine-dependent. The shipped 512 (about 5 ms at the
  ~10 µs per expansion measured on the reference MacBook Air) was chosen against that budget on
  the large balanced preset, seed 1337, 600 ticks with LOD off: the same instructions retired
  (358 G, against 352-360 G for the wall-clock build, which varied run to run) and a global path
  queue peaking at 12 instead of 22-28. 768 cost 6.5% more.
  `path_time_warning_ms_per_tick` only reports: a tick whose route search took longer counts in
  the `path_time_warning_ticks` counter and changes nothing.
- `navigation.prey_pressure_refresh_ticks` throttles the sector-level herbivore census that
  is the simulation's only long-range prey signal. Both the dormant goal selector and the
  live predator patrol read it.

### `species.json`

- tunes each species independently without code changes
- Herbivore numbers are set by grass, so its food knobs are balance knobs:
  `feeding.nutrition_gain` (hunger removed per unit of grass; lower means more grass per
  animal), `feeding.good_sward_fraction` (how full a cell must be for a fed grazer to walk
  to it), `perception.risk_tolerance` (the `FearField` risk a fed grazer accepts) and
  `herd.split_size`, and the `herd.migration` block (see Herd migration).
  `reproduction.cooldown`, `maturity_age` and `max_hunger` decide how far
  the herd overshoots its grass before starvation pulls it back. The shipped 200 s and
  90 s were chosen for that overshoot: with 140 s and 60 s a seed-3 world went from 240
  grazers to about 700 and crashed to 80; as shipped it peaks near 400 and holds near 200.
- `metabolism.hunger_rate` and `feeding.nutrition_gain` move together: their ratio is the
  grass a herbivore eats per second (6.7 as shipped), and the rate alone is how long it
  lasts between meals. At 2.0 and 0.3 a grazer went from fed to dead in 50 s, so any walk,
  queue at water or crowded pasture killed. At 0.6667 and 0.1 (150 s, same grass) an
  eight-seed LOD matrix gave 392 herbivores against 280 in the late half (higher on 8 of
  8), starvation 299 against 474 (lower on 7 of 8), grass eaten down to 0.43 from 0.51;
  predators and scavengers unchanged. At full fidelity, same seeds: 293 against 221
  (higher on 7 of 8, interval +19..+125), starvation 192 against 360 (lower on all 8),
  peaks 361 against 332 and a smaller fall after them (47% against 57%). A quarter
  (0.5, 0.075) gained a little more in LOD with bigger swings between maps. The graze utility weighs hunger as it stands, not as time
  to starvation, so a fed grazer now wanders for longer before it eats again.
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
- `lifecycle.founder_age_share` spreads the ages of the animals placed at world generation:
  each starts between newborn and that share of its species' `aging.old_age_start`, and one
  already grown starts part-way through its breeding cooldown. Founders born together grew
  old together - every predator between 1200 and 1440 s - and 48-minute runs lost their
  predators on seeds with prey to spare. Measured with `audit_matrix.py`, seeds 1-8, 2880 s
  LOD: 0.9 against 0 raised the late-half predator low from 19 to 38 and the late mean from
  33 to 45, higher on all eight seeds, and no seed's predators fell below 14. At full
  fidelity, 1440 s, predators held 46-47 to the end instead of falling to 36, and herbivores
  no longer boomed to 338 and crashed with their founders: they peaked at 288 and ended at
  the same 197, with a third fewer starving. The first litters still form a cohort of their
  own, since they fill the predator cap within six minutes and the cap then stops births
  until they age. 0 makes no draws and starts everyone newborn.
- `carcass.meat_by_cause` scales `carcass.meat_total` by how the animal died: a kill is a
  whole body, an animal that starved is skin and bone. With every death worth a full
  carcass, a famine among grazers fed every meat-eater on the map and carrion never limited
  anyone; four carcasses in five expired uneaten. A cause scaled to zero leaves no carcass.
- `dormant_ecology` holds the coarse-path rates: `kill_rate_per_prey_per_second` (break-even
  for a lone dormant predator is `hunger_rate / carcass.meat_total`), `prey_catchability`
  (per prey species, 1 if unlisted; see Dormant sectors), `predator_thirst_trigger_ratio`,
  and `idle_recovery_energy_ratio`. The last one caps how
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
- `developer_mode` offers the developer panel behind Tab; off, as shipped, a player gets the
  bar at the top left. F12 switches it while playing. Like the overlays it is read from the
  installed file even when a save is loaded
- `overlays.show_minimap_water` is on: the minimap marks the watering holes, as the map
  itself now does. `show_water_overlay` is still the debug disc drawn over the animals

### `visuals.json`

- maps biomes and obstacles onto terrain atlas coordinates
- declares per-species sprite atlases, frame size, draw scale, and the animation rows
- holds the speed thresholds that pick between idle, walk and run
- `ground` switches the `GroundTraces` grass and trail tint and sets its colours (RGBA), the
  grass shares each ramp colour is reached at (`grass_stops`), the wear range trails fade in
  over, its refresh interval and the noise that breaks up cell edges
- `water` switches the watering holes on the ground and sets their colours (shallow, deep,
  foam, shore), the field's resolution in terrain cells (`texel_cells`) and lengths in art
  pixels (`*_px`, scaled by cell size / 32 like sprites): depth to the darkest colour, shore
  and foam widths, how far noise bends the edge, ripple size, speed and strength
- `effects.death` switches the dying animation and sets how long the fall plays and fades
  (simulated seconds) and how many play at once. Which frames of a species' `dead` row a
  death shows sits beside the row, as `kill_frames` and `fall_frames`
- `species.<id>.carcass_atlas` is the species' carcass sheet: three stages across, the four
  directions down, a death without a blow first and a kill after. `carcass` is the shared
  sheet for a species without one, and its `stages` is how many columns both have
- `borders` switches the frayed biome borders and sets how far into a cell they may reach and the
  scale their noise varies over, both in cells (`reach` 0.45, `noise_cells` 0.7). The layer is
  up whenever grass, water or borders are on
- `wind` switches the sway of plants and sets it: `amplitude_px` (canvas pixels at the top of a
  weight-1 prop), `speed`, `gust`, `wavelength_px` of the wave across the field, and `weights` by
  prop group (the Kenney style patch keeps its mossy-rock swamp props still and its cacti nearly
  so). A shipped block, so old saves sway too; `props` stays the save's own
- `effects.dust`, `effects.kill` and `effects.birth` switch and size the dust of a chase
  (which species raise it, ground between puffs, its colour and the spray colour in a
  pond), the burst and flash of a kill, and a birth's ring, sparkles and grow-in
  (`pop_seconds`, `pop_from`); `effects.max_active` caps the marks on screen at once.
  Durations are simulated seconds, `*_px` art pixels

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
- full-world replays through sector sleep and wake, and a shared random stream the dormant path
  never touches
- worker-thread ticks matching the same ticks run inline
- metrics CSV cells that stay in their own columns
- trails: wear deposit and decay, live and sleeping animals, save round trip, and that the
  field changes nothing the animals do; the ground layer's mesh, textures and worker channel
- what the view hears and draws: world events on the main thread and through the worker, the
  display clock, and dying animals (the row, the frames against the atlases, the body held
  back and handed over, nothing played unseen, asleep or in overview); the marks queue (order,
  cap, scatter), a kill's burst, a birth's ring and grow-in, dust once per stride and never
  from a bird, a loaded save drawn with the shipped look, and a world run with the whole view
  attached ending exactly as one run without it
- the always-on readouts: the strip's minute window, trends, levels and grass against each
  biome's capacity, through the worker too; the herd card's counts near and far, young,
  hunters, texts, loss log and when it shows; the Russian words and their grammar, no English
  label left in the main scene, developer mode and the player's bar
- the story: names that stay and number while alive, the family tree from the world's own
  events awake and asleep, pins anywhere, the story's save round trip, the card's family line;
  the feed's lines for what is looked at, folding, the minute's summary and the newest shown

## Measuring Balance

`scripts/dev/ecology_audit.gd` runs one seed deterministically, LOD or full fidelity, with
config overrides as `key=value` arguments, and writes a JSON report: populations over time,
the late-half `regulation` block, counters, timing. One seed says little. The same change
has moved herbivores +44% on one map and -20% on the next.

`scripts/dev/audit_matrix.py` runs variants over many seeds and compares each with a
baseline seed by seed:

```
python3 scripts/dev/audit_matrix.py --out /tmp/matrix --seeds 1-8 --mode lod --seconds 1440 --jobs 4 \
    --variant base --variant slow species.herbivore.metabolism.hunger_rate=1.0
```

- Per metric, the mean and spread over seeds, and against the baseline the mean
  difference with its 95% interval (paired t) and on how many seeds the variant was
  higher. An arrow marks an interval clear of zero.
- `@path=DIR` in a variant runs it from another imported checkout, to compare code.
- Reports are kept per variant and seed and reused when they match, so a matrix resumes
  after an interruption; `--summary-only` rebuilds `summary.md` / `summary.json`. Godot's
  output goes straight to each run's log file, so stopping the matrix leaves the runs
  already going to finish and write their reports. It used to go through a pipe, and a
  stopped matrix killed its runs with SIGPIPE at their last print; `ecology_audit.gd` now
  also writes its report before printing.
- Long matrices are best run from a frozen copy of the checkout (`git checkout-index -a
  --prefix=DIR/`, copy `.godot`, `--import`), so edits in the working tree cannot mix code
  versions between runs.
- Timing is not compared: runs share the machine. Compare instructions retired with
  `/usr/bin/time -l` for cost. A 1440 s LOD run takes 10-25 minutes with four in
  parallel, a full-fidelity one 45-60.
- `scripts/dev/run_p3_matrix.py` is the older acceptance check: survival and
  reproduction per seed, without variants.

## Known Gaps

- Herbivores are limited by grass. Predators and scavengers are limited by meat only part
  of the time: over 2400 s with LOD on seeds 3, 7 and 11, predators spent 24%, 29% and 67%
  of the second half on their `population_regulation` cap and scavengers 43%, 10% and 14%.
  Scavenger appetite is not the knob to close that gap: raising `metabolism.hunger_rate`
  from 0.08 to 0.11 collapsed them on seed 7 and left them on the cap on seed 3
- Sleeping and live predators still eat differently. Both eat about half of a herbivore they
  kill and leave the rest (52% and 53% on three seeds), but a sleeping pack eats about what
  its hunger needs, 10.5 meat a minute a head against 15.4, since a chase costs it no energy
  and resting restores it: it kills 0.044 herbivores a minute a head against 0.088
- Predators in LOD still fall when an age cohort dies. The births that refill the
  `population_regulation` cap make a cohort that ages together, and old age kills within
  about four minutes of age (`aging.old_age_start` to `max_age`), so the cohort dies as one
  and its replacements are born as one in turn, to die together a lifetime later. In
  96-minute LOD runs predators fell to 10 on one seed of eight and to 29 on another, and
  came back. How deep a wave goes depends on how fast pairs replace it. A sleeping pack
  shares each kill among all its members, so they reach breeding energy only when kills
  come close together, and the males ran lowest: on the seed probed most males were short of
  it, and the ready females had no ready male within reach. Three ways to speed replacement
  did worse: feeding at most `max_feeders` members, each to the breeding reserve, halved
  scavenger births on one seed, and scavengers died out or nearly on two seeds of three
  while herbivores fell to 8 on the third; letting a pack eating its kill recover energy as
  one at a carcass does lost the predators on one seed of eight; a father's share of the
  birth cost at 0 for predators (`father_cost_share`, not kept) removed the two deep falls
  but made moderate ones on four other seeds, with predators starving 25 times a run
  against 15. A soft birth cap and a wider old age were tried earlier and rejected as well.
  A fix probably has to spread deaths across ages rather than move births
- No authored scenarios or scenario editor
- No replay flow (save/load exists; see `SaveSystem`)
- No genetics
- Three species, with no variation between animals of the same species
- Terrain and shadow art are placeholders. The opened and picked carcass stages are drawn
  by a script over each species' last death frame, not by an artist
