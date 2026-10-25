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

### Rivers (`terrain.rivers`)

Rivers are part of the terrain (`TerrainSystem._generate_rivers`), laid after the obstacles and
before the map is joined into one piece. They have a generator of their own, seeded from the
world's seed, so the world's stream is not drawn from; off (no block or `enabled` false), the
world is bit for bit the one without them.

- **The bed.** Each of `count` rivers runs from a source inland, away from the ponds, to the
  map's edge at least `min_length_fraction` of the map away. It follows the cheapest way
  (`AStarGrid2D`, eight-way) over noise that makes it wind, round the ponds, along low ground
  where the map has relief, and clear of the rivers before it, smoothed by three rounds of
  Chaikin into `rivers[i].points`.
- **The water.** Each cell holds water (`_water`: none, deep, ford). Deep cells within
  `half_width_cells` of the bed are obstacles (`water`): routes, legs, grass, spawns, dens and
  sleeping herds keep out of them as out of a cliff. Fords every `ford_every_cells`,
  `ford_width_cells` wide, are walkable at `ford_cost` times the ground's cost (a multiplier in
  `get_move_cost_at_index`), bare, and at the lower bank's level. A corridor joining two pieces
  of the map through a river makes a ford there.
- **Drinking.** A point on each bank every `access_every_cells` is a small source in
  `water_sources` marked `permanent` (`WorldState._add_river_banks`), so whatever finds and
  drinks from a pond finds and drinks from a river. `WaterSystem` gives them no level: they are
  left out of `mean_radius`, `mean_level` and the demand unit (`pond_count()`), never fill or
  dry, and give every drink.
- **Sight and scenery.** An animal sees across a river (`ScenerySystem.terrain_clear(..., sight)`);
  no tree or stone stands in one.
- **Drawn.** `WaterMask.stamp_river` adds the bed to the ponds' distance field, segment by
  segment, owned by no pond, so it never shrinks; over a ford the field stays just below the
  edge and reads as shallows. The ground mesh takes the deep cells too. In isometric the
  ground's own tile is drawn under the water. The minimap paints deep water and fords from the
  terrain, and draws no circle for a bank. Each river has a name of its own («у Быстрой реки»),
  labelled once, at its middle bank.
- **A setup option** («Реки»: нет / две), off by default and on in the living reserve. Tuned on
  LOD 2880 s × 8 seeds against the same worlds without rivers (hares at 2.5):

  | Variant | Deer | Deer births | Deer dead of thirst |
  |---|---|---|---|
  | Without rivers | 202 | 921 | 76 |
  | Rivers (fords every 16 cells, cost 2.5) | 158 (−22 %) | 825 | 58 |
  | Softer (fords every 10, cost 1.5, narrower) | 168 (−17 %) | 818 | 38 |

  Foxes, grouse and hares were even, and no species was lost. Deer lose births, not lives, and
  more and cheaper fords barely help, so going round to them is not the cause. Left to look into:
  dens drawn to the banks' water, and hunters by the herds that come to drink there.

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

### `WaterSystem`

Watering holes that fill and dry (`scripts/world/water_system.gd`, owned by `WorldState`).
Each pond holds a level, 0 to 1 of its basin. It moves by the season's balance
(`water_levels.balance` per season id, eased between seasons by `Climate.blend_by_season()`:
spring +2.0, summer -0.6, autumn +0.2, winter +0.6, in basins per season), faster the
smaller the pond (`(R̄ / R) ^ size_exponent`), and by what is drunk against the pond's capacity
in thirst points: `capacity_seasons` (6) times the thirst of one starting herd in a season, or
the map's thirst per pond if that is more (`WorldState._water_demand_unit()`, so a pond lasts
as long on every map size and difficulty), scaled by `(R / R̄) ^ capacity_exponent`. A drought
year - a hash of the year and the world's seed under `drought_chance` (0.25), never the first
- multiplies the dry seasons by `drought_strength` (1.4). A scenario may name drought years
whatever the hash says, the first among them (`drought_years`), and start the ponds lower than
full (`initial_level`); with neither the world is as before.

On the large map (radii 180-280, mean 230), left alone, a radius-180 pond falls to about a sixth
late in summer, a 230 one to about half, a 280 one to two thirds; one a herd drinks from dries
late in summer and is back early in autumn. A drought dries the 180 ones on their own and takes
a 230 one to about a quarter. Autumn and winter rains fill them all again, so the dry spell
runs from late summer into early autumn. Over six years on eight seeds a normal summer dried
about 5 of the 52 ponds at once (1-11), a drought summer about 16 (14-21).

The first settings (summer -0.75, autumn -0.15, winter +0.05, capacity 5, drought x1.6) left
30 to all 52 ponds dry from late autumn to spring: drinking crowded onto the ponds still wet
and drank them dry in turn, and a winter balance of +0.05 brought none back. Thirst took a
quarter of the deer that died (against 8 % with ponds that never change) and a drought year up
to 93 % of the deer alive when it began; a pure model of the levels with drinking spread over
the wet ponds reproduces the cascade. With the rains, thirst is 8 % of deer deaths again and
the worst drought year took 13.5 %.

- A pond keeps `bank_radius` and `index`; its `radius`, which every drinker, query and drawing
  reads, is the water's edge, `bank_radius * sqrt(level)`. What needs the basin (the water
  mask, `_sector_has_water()`, place names) reads `bank_radius`
- Dry at `dry_level` (0.02), wet again only at `wet_level` (0.10); each change becomes a
  `PondDried` / `PondRefilled` event once (`_emit_pond_transitions()`, a view event) and a
  counter (`ponds_dried`, `ponds_refilled`)
- Drinking goes through `WorldState.drink_water()`: the species' `drink_restore` while ponds
  never change, else no more than the animal's thirst and what the pond holds, none from a
  dry pond. Awake drinkers check the pond is still wet (`live_water()`) - a target can be a
  few ticks old - and forget dry ones (`AgentBase.forget_water()`), memories and the
  predator's ambush included. Queries (`query_water_sources()`, `_resolve_water_source()`)
  skip dry ponds; a thirsty animal with none in reach heads for the nearest wet pond anywhere
  (`_water_target_for()`), and with every pond dry the drink utility vetoes («воды нигде нет»)
- A sleeping group passes dry ponds by (`_find_nearest_water_goal()`), drinks its goal down
  for every head (`_dormant_drink()`, the pond found by its centre), gets nothing and no rest
  at a dry one and chooses again at once; a herd also leaves ground where no water is wet
  within its `water_search_radius`, however green
- Saved with the world (`"water"`, levels and dry flags); a save from before keeps its ponds
  full, and its own bundle has no `water_levels`, so they never change. Off
  (`water_levels.enabled`, or the climate off) the ponds never change and every query keeps
  its old path
- A pond can be added while the world runs - one the player digs (Player orders):
  `WaterSystem.add_source()` gives it the next `index`, grows every level array with it and
  measures it against the mean radius and demand unit the map began with
  (`WaterSystem.demand_unit` is kept for this), so no other pond's capacity moves. The world's
  `water_sources` and the system's list are one array, so `WorldState._add_pond_source()`
  appends to it and grows the arrays in one step. Levels for another number of ponds than the
  world has are refused with a warning, never silently

### `Weather` (`world.weather`)

The weather (`scripts/world/weather.gd`) is, like `Climate`, a pure function of time. It has
nothing to save, reads the same on the worker and in the view, and never draws from the world's
stream.

- **Spells.** Time is cut into spells of `spell_seconds` (40 s: three to a season, which here
  lasts one 120 s day). Each spell's kind is drawn from its season's `seasons` weights by a hash
  of the spell's number and the world's seed. A spell eases in from the one before over
  `ease_seconds`.
- **Kinds.** Clear, rain, downpour, fog, snow (winter only), heat (summer only). Each changes:
  - `water`: the ponds' balance, in seasons of fill a season, added to `water_levels.balance`
    (`Climate.water_bias`);
  - `regrowth`: the grass;
  - `metabolism` and `thirst`: the needs (`Climate.thirst_multiplier`, on live and dormant
    thirst alike);
  - `perception`: sight;
  - `movement`: pace (`Climate.movement_multiplier`, in `move_with_vector`).
- **Evened out.** `water`, `regrowth`, `metabolism` and `thirst` are evened against the
  season's mean over its weights: the mean is taken off `water` and divided out of the rest.
  The weather thus varies a season's spells without moving its average, and the balance the
  ecology was tuned to holds. Sight and pace are not evened: a fog is a fog.
- **Applied.** `WorldState.sample_climate()` samples the clock and applies the weather over it
  (`Climate.apply_weather()`), every tick and on load. The view does the same with each worker
  frame. Off - with no block, `enabled` false, or no seasons - every weather field is neutral
  (1.0 or 0.0), and the world matches a world without weather bit for bit.
- **Votes.** A rain, a dry spell or a cold snap ordered (by the reserve's votes) also brings
  its weather for the power's `weather_seconds`: a downpour, heat, snow. These are
  `world_events` of kind `weather` (`forced` in `Weather.evaluate()`). The view gets
  `world_events` as a revisioned frame block.
- **Drawn.** `WeatherOverlay`, a full-screen rect under every panel, shades the map with
  `weather.gdshader`: slanting rain streaks, drifting snowflakes, fog noise, the warm tint of
  heat. It is cut to 3-pixel art pixels, anchored to the world as the camera pans, dimmed with
  the day's light, and stilled when the game is paused. `Weather.visual()` gives each channel's
  strength, eased between spells, and a kind's `draws` names its channel (a downpour draws
  rain). The season bar names the weather: «Весна · Год 1 · Ливень».
- **Tuned** on LOD 2880 s × 8 seeds against the same worlds without weather:

  | Metric | Without | With |
  |---|---|---|
  | Deer | 197 | 199 (+1 %) |
  | Foxes | 42 | 43 (+2 %) |
  | Grouse | 119 | 119 |
  | Species lost | 0 | 0 |
  | Deaths of thirst, share of deer deaths | 6 % | 9 % |
  | Ponds drying up | 63 | 134 (twice as often) |

  The first try (rain 1.0, downpour 3.0, heat -1.0 with thirst ×1.4) doubled the deaths of
  thirst and trebled the drying. A pond at its floor does not take the mean back: evening the
  balance holds the average inflow, not the levels. Kills did not move (138 either way), so the
  sleeping hunt, which has no sight, needs no fog factor. The scenarios turn the weather off:
  their goals were tuned without it.

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
- inherited traits: `trait_<name>_<species>`, each trait's mean over the species' awake and
  sleeping animals (1.0 with none left, or without heredity)

### Player orders (`PlayerCommands`, `PlayerState`)

- The player acts on the world through orders: `SimulationManager.enqueue_command(type,
  params)` queues `{seq, type, params}` (`PlayerCommands.make()`, the params deep-copied) on
  the main thread and returns its number. The queue goes to the tick being launched - into
  `step_once()`, or into the worker's job under its mutex and from there as an argument to
  `SimulationWorker.step()` - and `WorldState.step(..., commands)` carries the orders out
  first thing: after the clock and `_reset_performance_counters()`, before anything moves, so
  their events carry that tick and come back in its frame. On a paused game an order waits for
  the first tick after it; `initialize()` and `shutdown()` drop orders given to the last world
- `WorldState._apply_player_commands()` looks each order's power up in
  `player_command_handlers` (a Callable taking the order and returning `{ok, reason, ...}`;
  none means refused as `unknown_power`), asks `PlayerState.refusal()` for its charges and
  cooldown, and pays for it with `spend()` only when the handler carried it out. A refusal
  costs nothing and changes nothing else. Every order, carried out or refused, goes into
  `PlayerState.journal` `{seq, tick, type, params, result}` and raises a `PlayerCommand` event
  (in `VIEW_EVENT_TYPES`) with `seq`, `power`, `ok` and `reason`. Nothing is drawn from `rng`
- `PlayerState` lives in the world the simulation steps: each power's `charges` (-1 for no
  limit) and `cooldown_until` in simulated time, from `data/config/powers.json`. Two orders on
  one charge cannot both pass, and a headless run keeps the same budget as the game. It is
  saved with the world (`export_state()` under `"player"`; a save from before it keeps the
  configured budget and an empty journal). `used` counts the orders carried out by power, as
  `spend()` pays them: the view's copy has no journal, and a scenario's result counts the
  powers there (a save from before `used` has it counted from its journal)
- The view follows it by `revision`, which moves with every charge or cooldown spent: a worker
  frame carries `presentation_block()` when the revision moved and in every full snapshot, so
  a frame lost to a sequence gap does not leave the view behind; `_apply_worker_frame()` takes
  it before the water levels, and applying it twice leaves the view as once. The manager
  raises `player_state_changed` when the view's revision moves, from a frame or an inline tick
- The journal replays exactly only under the same sequence of camera views (the view decides
  which sectors sleep, and with that who draws from `rng`): it is a record for the save and for
  scripted headless runs, not a replay
- With no orders the world is bit for bit as before (identity audits, off 300 s and LOD 600 s)
- «Водопой» (`dig_pond`, `WorldState._command_dig_pond()`): a pond at the order's `position`
  of `player_pond_radius()` - the map's mean pond times `powers.dig_pond.radius_of_mean`, so it
  holds about as long on every map size, where a fixed radius would be a lake on the small map
  and a puddle on the huge one - filled to `start_level` (0.8). It fills, is drunk and dries
  like any other pond from then on. `dig_pond_refusal()` refuses a place half off the map
  (`off_map`), on ground no animal walks (`blocked`), within a quarter of its radius of another
  pond's bank (`too_close`) or with trees or stones on its bank (`overgrown`); the view asks it
  too, to show where a pond can go. Navigation is untouched: water does not block movement
- The dug ponds are the player's (`PlayerState.ponds`, `{position, bank_radius, index}`), not
  the map's: the seed cannot make them again. A save carries them and `import_state()` adds them
  back after the map is built and before the levels (`_restore_player_ponds()`, in the order
  dug, so each takes its index), telling nothing. The view's world adds them from the frame's
  player block the same way (`apply_player_block()`), before the frame's levels; a block
  applied twice adds nothing twice. `SaveSystem.SAVE_VERSION` is 4 so an older build refuses a
  world with dug ponds instead of losing them
- In the view: `GroundTraces.refresh_water_sources()` stamps a dug pond into the baked water
  field (`WaterMask.stamp()`) and hands the field and a shrink texture one pond longer to the
  shader; the minimap redraws it, baking it into its map when ponds have no levels;
  `PlaceNames.name_new_ponds()` names it with an adjective and noun no pond has yet - the map's
  own ponds are named as if none were dug (how many there are sets how often a word repeats),
  so digging renames nothing; and the feed says «Выкопан водопой: Тихий пруд на Медовом лугу»
  wherever the camera is
- «Повести стадо» (`lead_herd`, `WorldState._command_lead_herd()`): the herd `{species,
  group_id}` walks to the order's `position` as a herd moving pastures does - its key in
  `herd_migrations` gets `{goal, since, player: true}` - awake and asleep. Only a species that
  moves pastures (`herd.migration`; not grouse: `not_a_herd`), a herd that is there
  (`no_herd`), a goal on the map (`off_map`) and on open ground (`blocked`), and not further
  than `powers.lead_herd.max_distance` (2400, the migration's own search radius) from the
  herd's centre awake and asleep (`too_far`): dragging hungry animals far is what
  `exempt_hunger` was added against. And one the herd can find its way to: the order runs the
  route search its members walk by, from the herd's centre (`TerrainSystem.find_path()`), and a
  goal past a ridge it finds no way round is refused (`no_route`) - led there, the herd stood
  facing the ridge until the walk timed out - and so is one it finds only a long way round, the
  route's cost past `powers.lead_herd.max_route` (3600; `too_far`): a goal 1000 away in a line
  was 5800 away round a ridge, and the herd walked itself to nothing getting there
- A player's goal is the player's: `_update_herd_migrations()` ends it neither for the herd's
  own patience (`give_up_seconds`) nor for poor grass at the goal - in winter or a drought it
  would fail that within one pass - but only on arrival, when the herd settles to eat as after
  any move (`HerdArrived`), or after `timeout_seconds` (300, `HerdLeadEnded`); both are view
  events. A led member follows up to hunger `powers.lead_herd.exempt_hunger` (85, against 50),
  awake (`herd_migration_goal()`) and asleep. Its sleeping parts go too, whatever
  `follow_asleep` says, once they have drunk: arrival is judged by the centre of the whole herd.
  Awake, a led member walks (`Herbivore._follow_player_lead()`) instead of resting, wandering or
  grazing in place, unless it is drinking or hungry past the threshold, or tired: it rests when it
  chooses to until it has `LED_REST_SHARE` (0.6) of its strength back - driven past its rest, a
  herd led 1000 away had no strength left within 40 s. Walking led (`state` "led") costs half the
  effort of walking anywhere else (`AgentBase.LED_EFFORT`), and past hunger `LED_GRAZE_HUNGER`
  (40) a led member takes a bite of the grass underfoot as it goes (`_take_bite()`, the same bite
  as grazing). Before, a herd led 1500 through a hungry winter lay down every half minute, ate
  nothing on the way, lost its hungriest at 70 and starved before it got there: 58 to 78 hunger
  in four minutes, 15 of 20 dead on one seed. A herd moving on by
  itself only drifts that way when its members have nothing else to do, and a fed led herd
  stood still. A herd that splits while led takes the goal into both halves; one moving on by
  itself lets its new half choose, as it always did
- The herds led are shown from `PlayerState.led_herds` (`{species, group_id, goal, since}`, in
  the player block); the feed says «Стадо №3 в пути: цель на Медовом лугу» and «Стадо №3 дошло
  до цели …», or «… не дошло до цели …» when its time ran out

- «Отстрел» (`cull`, `WorldState._command_cull()`): up to `powers.cull.max_kills` (3) animals of
  `powers.cull.species` (the foxes) nearest the order's point within `cull_radius()` - twice the
  map's mean pond, so it covers as much on every map size - awake or asleep, nearest first and an
  id breaking a tie (`cull_candidates()`), so a worker and an inline world take the same animals.
  The awake die through `kill_agent()`; the sleeping leave their sector's records with a death
  told where they slept (`_emit_dormant_death()`), the sector rebuilt
  (`_refresh_dormant_sector_state()`). They die of `culled` and leave no body - "culled" is not
  among the causes that do (`_maybe_spawn_carcass()`): a fox's carcass would feed the very
  outbreak culled. Refused off the map and where no one of the species is (`no_target`). Their
  cause is counted (`deaths_culled`, per species), named («отстрел»; «отстрелян/отстреляна» on a
  pin or a parent) and kept in the season's summary; the feed tells a cull once, by its order
  («Отстрел у Лисьего брода: 3 лисы»), with no line a fox and no epitaph - one click would raise as
  many as it took
- A world is offered the powers `powers.offered` names (`PlayerState.configure()`): all of them as
  shipped, the sandbox's; a scenario names its own («Долгая сушь»: the waterhole and the lead). A
  power not offered has no budget and is refused as `unknown_power`. A bundle from before the list
  - an old save's - is offered every power it holds

### Scenarios (`scenarios.json`, `ScenarioRunner`)

- A scenario is a world with a goal. `ConfigLoader.load_scenario_bundle(id, selection)` loads
  the setup options the scenario names over the player's (only the style stays the player's -
  and the style must not move the ground, so a scenario pins `terrain.height.levels`), merges its
  `patch` over the bundle, new keys and all (`_apply_options()` passes keys a bundle lacks by),
  and puts its `challenge` in the bundle with its id, label, brief and seed. A save keeps the
  bundle, so the goals and powers a world was begun with go on whatever the file says later.
  `list_scenarios()` is what a start page offers
- `ScenarioRunner` keeps the score from the world the view is shown - the worker's copy too -
  after each tick or frame (`update()`) and from the view's events (`hear()`), and changes
  nothing in the world. The own herd is the herd of `own_herd.species` nearest `own_herd.near`
  (fractions of the map) when it starts, with every half split off it since (`HerdSplit`); it is
  counted awake and asleep, as the herd card counts (`HerdReadout`), and its deaths by cause
  (`AgentDied` carries the group). A goal names what must hold - `share_at_least` of the starting
  count, `thirst_deaths_at_most`, `thirst_share_at_most` - and when: `at_season_start` of a
  season, judged by the season ordinal so the tick the season turns is the one that decides, or
  `days` into it, the `years`-th such season from the start; or `always`. A goal may also hold a
  species to a floor - a count (`species_at_least`) or a share of its own start
  (`species_share_at_least`), counted from the world's census while such a goal or `watch` asks -
  or limit the culls (`culled_at_most`, from the `PlayerCommand` of each cull carried out). Its
  `role` is `win` (won or lost at its moment), `lose` (lost the moment it fails) or `bonus`. Once the result is in (`finished`), the score keeps still and the
  world can be watched on
- `SimulationManager.scenario` keeps the score of the world it runs: begun by `initialize()`,
  hearing the view events as they are forwarded and updated after every inline tick and every
  worker frame applied, its changes raised as `scenario_goal_changed` and `scenario_finished`.
  A world without a challenge has an inactive one - the sandbox, whose powers have no charges,
  only their cooldowns (`powers.json`). The runner keeps its own curve, `[time, own herd, its
  species, each species the challenge `watch`es]` every 5 s and at the result: the stats' series is not saved, and a curve drawn from
  it after a load would begin at the load
- A save carries the score under `scenario`, and `SaveSystem.restore()` takes it back after the
  world and its clock (`import_scenario()`): the starting count, the herd, the deaths and the
  goals decided are the saved ones, and a result already in is not announced again. A scenario
  saves into its own pair of slots (`SCENARIO_SLOTS`), so playing one does not write over the
  world the player left in the sandbox. Every save says when it was written (`saved_at`), and
  Continue opens whichever slot of either kind was written last: by tick, a world begun anew
  lost Continue to an older one that had run longer. A save from before `saved_at` counts as
  the oldest. `SaveSystem.save_dir` lets a test write its slots elsewhere
- `scripts/dev/scenario_probe.gd` plays a scenario without a window through the real order
  queue and the runner: the camera kept on the own herd (`herd`, which keeps it awake as a
  player watching it would) or on the whole map (`overview`), and a fixed rule for the powers -
  none, dig by the herd, lead to the fullest pond in reach, or both - once the water the herd
  drinks from runs low or far (`both/0.05/1500`: only when it is all but gone). The rules read
  the world and draw nothing from its `rng`
- «Долгая сушь» (`long_drought`): the medium map, seed 7, flat ground; the world begins in
  summer (`start_season_index` 1) with seasons of three days, so a summer is six minutes and
  thirst can kill in it; year 0 is a drought (`drought_years`) and the ponds start half full
  (`initial_level` 0.5). Founders are no older than 0.4 of their span (`founder_age_share`;
  0.9 as shipped had a herd of 20 lose up to 13 to old age in twelve minutes, whatever the
  player did). Goals: half the herd at autumn plus a day and a half (`days` 1.5, second 540, when
  the rains have filled about 30 of the 53 ponds again), lost below a quarter at any time, the
  bonus no death of thirst. Powers: one waterhole, filled only half (`start_level` 0.5, against
  0.8 in the sandbox), two leads 60 s apart
- «Первая зима» (`first_winter`, `tutorial`), the first game: the medium map, seed 19, flat ground,
  begun in autumn with seasons of two days, founders young; the own herd the one nearest
  [0.3, 0.72], on poor ground (forest and drought around it, the meadows the scan below found
  1600-2000 away by water); grass growing at half the usual rate from 0.15-0.4 of its cap, and a
  hungry deer leaving no pasture by itself past hunger 30 (`herd.migration.exempt_hunger`, 50
  elsewhere) - the player's lead takes it to 85. Goals: no fewer head at spring than in autumn
  (fawns born late in winter count), a quarter the floor, the bonus not one starved
  (`starvation_deaths_at_most`); three leads; its `hints`, one of them pointing at the grass layer
- Tuned headless on eight such starts - for each seed the herd on the poorest ground with a meadow
  by water within a lead's reach (`scan_herds`, scratch: pasture within the herd's radius against
  the best on 16 bearings to 2400) - with the camera on the herd. The winter as first set (seed
  11, normal grass, herds moving on by themselves) never got hungry: with no powers the herd met
  spring 7 times of 8, 1.14 its autumn size, mean hunger never past 45, and a rule leading it to
  grass never fired. Slower grass, less of it and hungrier deer brought starvation (4 a winter)
  but the lead could not cure it: led deer lay down every half minute, ate nothing on the way
  and dropped out past hunger 70, so a lead to a meadow 1500 away killed the herd it was meant to
  feed - which is why the lead was changed (bites on the way, half the effort, followed to 85).
  With that lead and deer hungrier by 60 % a winter starved a deer in 80 s and any walk over bare
  ground was fatal; at the usual hunger, long winter and poor ground, no powers met spring at
  full size 3 times of 8 (0.83 on average; 1.1 deaths of hunger, 2.2 of thirst), leading to the
  most grass in 1500 by water once hunger passed 30 6 of 8 (0.97). Seed 19 is the clearest of
  the eight: 0.65 with no powers (5 dead of thirst, 1 of hunger), 1.3 with two leads and none dead
- «Слишком много лис» (`too_many_foxes`): the medium map, seed 7, flat ground, begun in autumn;
  sixty foxes (cap 120) that hunt well (`attack.base_success_chance` 0.55 against 0.38), founders
  young. Goals: the own herd no smaller than at the start two autumns on (`years` 2, second 960),
  lost below a quarter at any time, the bonus no more than 12 foxes culled. Powers: eight culls
  and two leads; the foxes' curve is watched beside the herd's
- Tuned headless (`scenario_probe.gd`, camera on the herd, two years). The outbreak as first
  planned - more foxes, a higher cap, begun in spring - did not threaten a herd: its fawns outran
  the foxes (the herd grew on average with 24, 48, 60 or 72 foxes, below half on at most 2 seeds of
  4), the foxes stood on their cap all two years and never crashed, and the deer as a species
  ended at 290-320 against 500 with the usual 24 foxes, never below their start. Begun in autumn,
  no fawns for most of a year, and with foxes that hunt well, the herd with no powers ended at
  0.31 of its start on 4 seeds (0.87 on 8: the seeds differ more than the variants - one herd
  grows threefold whatever the foxes, another dies of thirst or hunger). A cull in spring is
  undone within a minute, litters filling the cap; one in autumn or winter holds to spring. On
  eight seeds, eight culls: with no powers the herd was no smaller after two years on 2 of 8, culling
  the foxes gathered by it out of their season on 7 of 8 (16 culled on average; the bonus kept on
  2), spending every shot at once on 7 of 8 (18; the bonus never), leading it away from them on 3
  of 8. The foxes cannot be culled out: at their cap whatever was shot, the moderation is the
  bonus's
- Tuned on eight seeds with the camera on the herd. With no powers the herd was lost on 8 of 8
  (a ninth of it left at second 540 on average, 18 of 20 dead of thirst); digging and leading
  once its water ran low won 8 of 8 (0.72 left, 4 of thirst), and acting only once the water was
  all but gone 7 of 8 (0.83, 2.6) - the one lost to foxes, which took 15 of that herd. Once a led
  herd rested when tired and a lead a long way round was refused, both won 8 of 8 (0.82 left and
  2.4 of thirst; 0.84 and 1.9), the bonus kept on 4 and 3 of the eight - when to dig did not
  matter. With the waterhole filled to half, acting early won 4 of 8 (0.44 left, 11.4 of thirst):
  dug at second 126 on average it was drunk dry by the end of summer; acting late (dug at 173)
  won 7 of 8 (0.77, 5.0). Filled to 0.6, 6 and 7 of 8. Every pond
  but the dug one is dry from about second 300 until the rains bring them back from about 480 (7
  wet at 480, 20 at 510, about 28 at 540), and the deer die from the end of summer into autumn,
  about 270 s after their last drink: decided at the start of autumn, as first
  planned, the herd with no powers still had 85 % and lost it in the next two minutes. Ponds
  starting at 0.7 left the powers no lever (the same with them as without); autumn rains of 0.6
  instead of 0.2 won 6 of 8 without them; ponds at 0.35 left the dug pond the only water on the
  map from second 190, every herd came to it, ate the grass round it to nothing and starved
  there (17 of 20 of the own herd), being too hungry to move pastures. The drought takes the
  whole species down with it: about 250 deer at second 360, 45-115 at second 600

### The living reserve (`scripts/reserve/`, `--reserve`, `reserve.json`)

A world on a stream that its viewers act on through the chat. Launched with
`Godot --path . -- --reserve` (`--fresh` for a new world), it takes the place of the start page.

- **The world** comes from `ConfigLoader.load_reserve_bundle()`: the setup options of
  `reserve.json` `selection` over the defaults (wolves on), the powers `offered` (the steward's
  three, `adopt`, the weather, `release`, `immigrate`) with the settings `reserve.json` `powers`
  changes (a cull's cooldown, which many viewers share), and a `reserve` key in the bundle. That
  key is what `SaveSystem.kind_of()` reads: the reserve saves to `reserve_a/b.dat`, which
  `latest_slot()` without a kind (Continue) never opens, and goes on from the newest on start.
  The save carries the session under `reserve`.
- **Orders from viewers are ordinary player commands** (`enqueue_command`), so they are
  deterministic, journaled and carried by the worker like the steward's:
  - `adopt` names a ward: the animal nearest the focus herd that no one cares for. A viewer has
    one living ward. `WorldState.adoptions` holds `{name, viewer, viewer_name, species, since,
    died_at}` by id; a ward's death sets `died_at` (`_note_ward_death`, awake or asleep). The
    latest `keep_dead` dead wards are kept. The view gets them as a revisioned frame block.
    `StoryBook.name_of()` prefers a ward's name, the selection card names the guardian, and a
    ward's adoption and death are told in the feed wherever they happen.
  - `rain` and `drought` move every pond's level by `share`.
  - `cold_snap` and `bloom` are timed `world_events` that scale metabolism or regrowth while
    they last; they are saved.
  - `release` brings a pair, a herd or a pack in from an edge point hashed from the tick, grown
    and in no state to breed on arrival; a pair takes the nearest vacant territory.
    `immigrate` is the same handler with its own settings, used only by the rescue.
- **`ReserveSession`** turns chat lines into those orders and tells back what came of them
  (`told`). It is kept apart from any window, so a server can run it later.
  - `ChatCommands` parses «!word arg» through `reserve.json` `commands` and cleans ward names:
    letters, spaces and hyphens, a length limit and a blocked list.
  - `ViewerBook` keeps viewers by `platform:user_id`: the name shown (no markup characters), the
    fund backed, per-viewer cooldowns and when last seen. It forgets the longest unseen past
    `viewers_kept`. The view's story keeps `story_animals` animals in the reserve, not 30 000:
    it is saved every two minutes, for days.
  - `VoteRound` opens a vote of three events every `every_seconds` for `open_seconds`; the most
    votes win and are carried out.
  - Funds (`teams`) count their members active since the last count; the biggest has its perk.
  - The steward's powers aim at the focus herd: a pond in the nearest free spot (at most
    `steward.max_ponds`), the best grass within the lead's reach, the foxes nearest it - none
    while fewer than `steward.cull_floor` are left.
  - Newcomers by a vote or a fund's perk do not come to a species at its `ceilings`.
  - The **rescue** checks every `every_seconds`: a species the world began with that is down to
    fewer than its `below` has `immigrate` ordered, at most once per `gap_seconds`. A reserve
    that runs for days cannot lose a species for good.
  - All times are simulated seconds, so a saved reserve picks up where it stopped.
- **`ViewerLink`** listens on 127.0.0.1 (`link`) for one JSON object per line. The bridge
  `tools/stream_bridge/bridge.py` (standard library only) writes them, reading Twitch's IRC
  anonymously and YouTube's live chat with an API key, within its daily quota. Only «!» lines
  are passed on.
- **`ReserveDirector`** is the camera with no one at the controls. Each shot (`director`, real
  seconds), in order of priority:
  1. an animal a viewer asked for (`!моё`);
  2. the weightiest moment of the last `moment_seconds` whose animal is still about: an
     adoption, a kill, an arrival, a pair's or pack's hunt, a herd alarm, a territory taken, a
     birth;
  3. by turns, each living ward and the focus herd.

  A sleeping target is reached by moving the camera there and selecting it once its sector
  wakes. The herd of what it follows becomes the session's focus, so the viewers' powers go
  where the stream looks.
- **`ReserveOverlay`** stands top left in place of the herd card. It shows:
  - the commands, every other 15 s replaced by one of the reserve's tables (`ReserveRecords`):
    the eldest living wards, the wards with most living descendants in the story, each fund's
    perks this year;
  - the vote with its count, or the time to the next;
  - the funds and the living wards;
  - the last lines told.

  The player's bar, powers and goals are hidden.
- **`WardTags`** marks every awake ward on the map, under the panels: a ring at its feet in the
  colour of its guardian's fund (the species' `ui_color`) and «Ветка · Вася» above it. Names that
  would overlap give way to the one nearest the bottom of the screen and stay clear of the
  selected animal's own tag.
- **`ReserveBanner`** shows the big news across the top for 4 s each, the weightiest waiting
  first: a ward's death or young (told by the session from `AgentDied`, `AgentReproduced` and
  `AgentBorn`), the year's summary (`ReserveRecords.year_summary()`, when the climate's year
  turns), a vote's outcome, newcomers, a fund's perk.
- **Autosaves do not stop the screen.** On the autosave tick the view asks for the world
  (`SimulationManager.request_world_export()`). The worker exports and deep-copies it on its own
  thread right after the next tick; `world_exported` hands it over on the main thread, while the
  worker waits, so the clock, the stream and the counters read with it are the same tick's.
  `SaveSystem.save_exported()` then chooses the slot (reading both slots whole) and writes it on
  a pool thread, into a `.part` file renamed over the slot once whole. Quitting waits for it
  (`finish_writing()`). Without the worker the export is taken at once.
- **Measured** with `scripts/dev/reserve_soak.gd`: headless, LOD on, made-up viewers at 30
  commands a minute (a quarter wards, a third votes, a fifth funds, the rest the steward's
  powers), an autosave every 2 minutes. Seed 7, four hours:

  | Species | Mean | Least | Most |
  |---|---|---|---|
  | Deer | 243 | 131 | 341 |
  | Foxes | 41 | 30 | 56 |
  | Grouse | 122 | 109 | 126 |
  | Wolves | 17 | 8 | 30 |

  No species was lost and no rescue was needed. Tick 19.6 ms on average (p95 at most 42 ms),
  memory 99-237 MB with no trend, saves up to 5 MB in 289 ms. Before the cull floor and the
  ceilings, the same viewers culled the foxes out in an hour, taking every pair the rescue
  sent, and brought the wolves from 10 to 30.

  A save loads back with every count, ward, use of a power and session field the same. Queued
  orders are not saved, so the soak carries them out first. After a load, the reserve drifts as
  any world does once its caches are cold. `check_save.gd` promises the populations for 200
  ticks; after 600, 1 to 3 foxes differ, in a plain world with wolves as in the reserve.

## Agent Model

### `AgentBase`

Shared state includes:

- needs: energy, hunger, thirst, age
- AI runtime: `ai_state`, `current_action`, action age, switch reason, utility scores
- navigation: path cells, path index, repath timing, stuck timer, whether the route last
  walked reaches its goal (`path_reachable`), and the carcasses, ponds and patrol goals it found
  no route to and leaves alone for a while (`unreachable_targets`)
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

### Heritable traits (`Traits`)

- Each animal carries four multipliers on its species' values, 1.0 being the species as
  `species.json` writes it: `trait_speed`, `trait_vision`, `trait_appetite`, `trait_longevity`.
  They are agent fields; the shared species dictionaries never change. They ride in every
  runtime record (`traits`), so they travel through sleep, waking and saves
- Speed scales `move_with_vector()` and the readers that bypass it: the overlap push, the
  predator's patrol reach, the attack's prey-speed ratio (against the prey's own top speed), a
  sleeping group's travel (its members' mean, `avg_traits`) and a sleeping grazer's walk to
  grass. Vision scales `WorldState.perception_radius()`, so every search radius and the
  normaliser dividing by it move together, and the patrol's raw sight reads. Appetite scales
  the hunger rate and what each bite of grass or meat takes off it, so a quick metabolism eats
  as much, in shorter, more frequent meals; strength never moves with it. It used to repay in
  rest recovered: breeding needs a fed animal and a rested one, and spread across both
  thresholds it cost the grazers a sixth of their births and a third of their numbers on seed 1
  (`am-traits-diag`). Longevity is the pace of life: it scales maturity,
  the wait between young, old age and max age, awake and asleep (`_tally_dormant_member()`,
  `_dormant_record_can_reproduce()`)
- Every advantage costs (`species.<id>.traits`): a run burns the species' sprint or chase
  energy times `speed ^ run_cost_exponent`; hunger rises by `speed_hunger` per unit of extra
  speed and `vision_hunger` per unit of extra sight, on top of appetite (`trait_hunger`); a
  quick metabolism starves sooner and fills up sooner; a long life matures late and breeds
  less often, which is what it costs a species that matures in seconds
- Founders spread up to `founder_spread` around 1.0; a young one takes its parents' mean and up
  to `mutation` either way, inside `clamp` (`longevity_clamp` for longevity). An awake birth
  copies both parents' traits when it is queued, since a parent may be gone by the flush; a
  sleeping one pairs each mother with her mate (`fathers_this_step`, or the males the reconcile
  picks for an unpaired count), and its `AgentBorn` names the father. Birth events carry what
  the young inherited, for the family tree
- Every draw hashes the animal's id, a salt and the world's seed (`Traits.unit()`, overflow-safe
  like `_mul32()`), so two worlds' founders differ; the shared `rng` is never drawn. Off, or
  with every animal at 1.0, a world plays bit-for-bit as one without traits: each hook
  multiplies by exactly 1.0. `TraitsTests` checks it on a small world and the
  identity audits (`ecology_audit.gd` with `species.<id>.traits.enabled=false`) against main
- Asleep, a group's step is one number a need, so its members share it by what they inherited
  (`_dormant_trait_weigh()`, `_share_dormant_need_shift()`): rising hunger by each one's
  `trait_hunger`, a hunter's or a scavenger's meal by speed times sight times appetite;
  strength evenly. A sleeping grazer walks to grass at its own speed and is fed by each bite
  by its appetite. Without these, speed and sight were free asleep, where most of a large map is
- Selection asleep is simplified: traits weigh who dies, never how many. A sleeping kill takes
  the record whose distance to the hunters, times `(speed x vision)^4`, is least; starvation
  the hungriest, whose traits already made it so; old age the highest age over longevity
- Measured on 8 seeds, 2880 s in LOD, heredity off against on (`audit_matrix.py`): no species
  lost; the populations' late means within their paired intervals - herbivores -4 [-41..33],
  predators -0.3 [-3.8..3.1], scavengers +4 [-1.8..10], scavengers on their cap more of the
  time (+0.23 [0.04..0.42]). Trait means moved at most 8 % (scavenger sight) of their 25 %, and
  longevity at most 6.5 % of its 10 %, both ways across seeds. The first two tries lost the
  grazers a third of their numbers on some seeds: founders hashed from the id alone were the
  same animals on every map, and appetite repaid in strength (see above)
- Shown on the animal's card, the two it differs in most («Черты: скорость −7 %, аппетит +4 %»)
  with all four in the tooltip - a line, not two, since a second pushed the herd card out from
  under two pins; the herd's means on the herd card's head-count tooltip; in the family tree's
  tooltips; and in the chronicle's «Черты»

### Breeding season and litters (`Breeding`)

- Young come from late winter to midsummer, most in spring, none in autumn or winter. The
  season is a curve along `Climate.season_position` (seasons since the start of spring, 0..4,
  a straight line through the year, unlike the eased multipliers): `world.climate.
  breeding_curve` `[[0,1],[0.6,1],[1.5,0],[3.75,0]]` - open through the first 60 % of spring,
  closing over the next 108 s to midsummer, opening again over the last 30 s of winter; a 210 s
  window, 44 % of the year, exactly 1.0 at t=0. A species may carry its own
  `species.<id>.breeding.curve`, and grouse do: `[[0,1],[1.2,1],[2,0],[3.5,0]]`, midwinter to
  late summer. A sleeping flock breeds only right after a meal - its energy decays above the
  rest ceiling (`_dormant_energy_recovery_ceiling()`) - and in a spring with little carrion
  whole flocks sat near zero energy through the season: on the shared curve grouse died out
  on two of eight seeds within six years
- A male breeds whenever the curve is above 0; a female where it is 1, and on its ramps when
  her own draw for the year (`Traits.unit(id, FERTILITY_SALT + year, world)`) lies below it.
  The season so opens and closes over its ramps rather than in one step, a sleeping pair and
  an awake one get the same answer, and nothing is stored or drawn from `rng`
- One question everywhere: `WorldState.can_breed(agent)` (`can_reproduce()` and
  `is_fertile()`) for an awake animal and its mate - deer and grouse in their tick and mate
  search, a predator in its override, first thing in `_attempt_reproduce()` (before it re-bonds
  or leaves a carcass; the engaged flow comes in without asking) and in
  `_is_valid_mate_candidate()`; `_dormant_record_can_breed()` for a sleeping group's tally and
  its births. `get_reproductive_capacity()` is never gated
- A spring is shorter than a deer's 200 s wait, so a mating brings a litter: `litter_mean` young
  (its fraction a hashed chance of one more), at most `litter_max` - deer 1.7 (at most 2), foxes
  3 (at most 4), grouse 4 (at most 6), in `species.<id>.breeding`. Twins every time overshot:
  without dry ponds the deer climbed to 720 on one seed and starved by the hundred. Capacity is
  reserved for the whole litter; near the cap a pair has as many as there is room for. Asleep,
  the litters are reserved together and handed out by the females' ids; a pair left nothing does
  not breed. `births_this_step` names a mother (and `fathers_this_step` a father) once a young,
  so the reconcile makes each newborn as before. Cost and wait are once a mating. A parent keeps
  only the first of a litter as kin (`_flush_spawns()`), or a fox pair's kin centre would drag
  it towards the den
- Off - the block switched off, missing from an old save's own bundle, or the climate off -
  a species breeds all year one young at a time, bit for bit as before (`BreedingTests`, and
  the identity audits with `species.<id>.breeding.enabled=false`)
- Measured with ponds drying, against both off on the same code (`audit_matrix.py`, LOD): over
  2880 s on 8 seeds no species lost; late means herbivores +30 [-14..73] (+14 %), predators
  -1.3 [-2.7..0.0], scavengers -3.5 [-8.6..1.7] (the yearly sawtooth: no young from late
  summer to midwinter); thirst 6.7 % of herbivore deaths (7.8 % off), the worst drought year
  23 %; the tick's p95 in spring 1.08 times autumn's and no higher than off's. Over 5760 s on 8
  seeds nothing died out either, where off lost its grouse on one seed; grouse fell to 12 on one
  seed and 26 on another before their next young, predators never below 19, the worst drought
  year took 27 % of the herbivores. That needed the fix for targets out of reach
  (`AgentBase.unreachable_targets`): before it foxes died out on one seed of four and grouse on
  another. At full fidelity (4 seeds, 1440 s) herbivores came out 47 % below off, and 22 % with
  the buck and herd rules below (see Known Gaps)

### Who pairs with whom

- A female needs `reproduction.energy_threshold` at the moment of mating, and a doe (66 of 100,
  losing 2.4 a second) has it only for the dozen seconds after a meal. A male needs
  `male_energy_threshold` where his species sets one - 0 for deer, grouse and foxes - and
  otherwise only to be grown, fed (`max_hunger`), watered (`max_thirst`) and past his wait
  (`cooldown`): `AgentBase.breeding_energy_threshold()`, read by `can_reproduce()` awake and by
  `_dormant_record_can_reproduce()` asleep, so the two still agree. He pays `birth_energy_cost`
  all the same, down to 0. Foxes got it with Rare prey: at full fidelity a fox is above its 70
  for about half a minute after a big meal and near 0 the rest of the time (the median over the
  last two minutes of every fox's life on seed 1), so two of them were seldom ready at once
- With `reproduction.herd_mates` a deer or a grouse goes to the nearest ready animal of the
  other sex anywhere in its herd (`Herbivore._choose_mate()`, the lower id on a tie), from
  `WorldState.herd_members()`: each herd's awake animals, kept beside `_group_state_cache` but
  not in it, since the worker sends that cache to the view. Without the key, or for an animal
  outside a herd, the first ready one within `perception.mate_search_radius` not of another
  herd, as before. A sleeping group with it pairs anywhere in itself. The mate is looked for
  before the danger (`safe_radius`): a buck is ready for most of the season, and nearly always
  nobody in his herd is ready for him
- Why: awake herds graze spread out. At full fidelity a deer's nearest herd-mate was 94 to 214
  away and the herd 460 to 850 from its centre within the first 1440 s, against a mate search of
  128, and both partners had to be at 66 at once. As herds thinned the meetings stopped, and with
  them the births: over twelve years the deer died out (Known Gaps had it)
- Off - `herd_mates` false and `male_energy_threshold` absent or equal to `energy_threshold` -
  the world is bit for bit as before (identity audits, off 300 s and LOD 600 s)
- Measured against the old rules on the same seeds (`audit_matrix.py`). At full fidelity over
  1440 s on 4 seeds the deer came out 22 % below off (231 late against 298; 157, 47 % below,
  with the old rules), with 376 births a run against 224 and lows of 135 to 175 against 86 to
  140. Counted on seed 1 over three years, 44 to 47 % of the grown does had young in a year,
  against 24 to 34 % with the old rules, the cap (720) far off: not the season's one litter a
  year holds the rest back but, most likely, the doe's own moment - at 66, fed and watered at
  once, on her fertile days, with no fox near. In LOD over 2880 s on 8 seeds nothing died out
  and the deer stayed where they were (219 late against 239 with the old rules and 209 off,
  lows 123 in the mean against 121): a sleeping herd was packed and fed to full strength
  anyway. The herd search takes 0.24 % of the tick at full fidelity (`_choose_mate()`), all of
  `_attempt_reproduce()` 1.8 % against 1.3 %, and the tick 8 % more with 41 % more deer alive
  (600 s, seed 1, the two runs side by side)
- Over twelve years it did not save live play (5760 s, seeds 1 and 2): the food chain broke
  as often, elsewhere. With the season the foxes died out in year 7 on seed 1 and the deer fell
  to 2 by year 12 on seed 2, where with the old rules the deer died out in year 9 on seed 1 and
  all lived on seed 2; with no season the deer lived on both seeds and the foxes died out
  (years 7 and 12), where the old rules lost the deer (years 8 and 10). In LOD over 5760 s on 8
  seeds the grouse died out on seed 2 and the deer fell to 16 on seed 4 after a bigger boom
  and stayed low for years; with the old rules nothing died out, but grouse fell to 12 and 26.
  The rules for deer alone lost the grouse on two seeds. The late deer mean was the same (247).
  What breaks the chain now is on the foxes' side (Known Gaps)

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

### Seasonal pastures (`herd.migration.seasonal`)

A herd remembers where it settled best in each season (`WorldState.herd_pastures`, by herd
key: `{seen, seasons: {season_id: {position, forage, year}}}`, saved, copied to both halves of
a split, sent to the view when `herd_pastures_revision` moves).

- Written on arrival after a walk, its own or the player's (`_remember_pasture()`): the grass
  within the pasture radius, kept when more than `replace_share` of what it remembers, or
  when that is `forget_years` old.
- On its first weighing in a new season (`seen`) a herd that remembers a pasture for it sets
  out for it (`_seasonal_return()`, `HerdMigrates` with `remembered`) when the place is still
  good - grass for `leave_fraction` of its need, water within `water_search_radius`, ground
  within its `risk_tolerance` (`_pasture_fit()`) - farther than its own pasture, within
  `search_radius`, and with `switch_ratio` times the grass it has where it stands. A dried
  pond or a grazed-out meadow is not gone back to.
- When it moves on for want of grass, the remembered place scores `memory_bonus` times its
  grass in `_find_migration_pasture()`, if it is still good.
- The herd card names the season's pasture («Летние угодья у Ольхового бора»), the feed a
  return for the selected herd or one in view. Asleep or awake alike, with nothing drawn.

### Herd flight (`herd.flight`)

A threat seen by one member alarms its herd (`WorldState.herd_alarms`, by herd key: `{since,
until, source, raiser, threat, heading, goal, goal_tick}`, saved).

- `raise_herd_alarm()`: a member that sees predators raises the alarm or keeps it up
  (`hold_seconds` past the last sighting); every `escape_refresh_ticks` the one seeing the
  threat sets the herd's way - from the nearest threat through the herd's centre, leaning
  `sighter_lean` towards its own flight - and one goal for all of it,
  `choose_escape_destination()` at `escape_distance_cells`.
- `herd_alarm_for()`: a member hears it within `alarm_radius_cells` of where it was raised,
  `distance / alarm_speed_cells` seconds after - the herd ripples into flight, the near first,
  with no chains of hearing and no spatial query. One at `exempt_thirst` or `exempt_hunger`
  does not take an alarm it only heard: it keeps to its water or grass until it sees a
  threat itself. Without that, thirsty deer were run off the ponds by alarms raised elsewhere
  in the herd and deaths of thirst rose by two thirds.
- `Herbivore._flee_with_herd()`: for the goal, kept with the others (`_herd_vector()` with no
  wander, so no `rng`) and, seeing the threat itself, leaning away from it
  (`herd_weights.flee * own_flee_share`); where the threat stands the way the herd runs, the
  member runs its own way.
- Asleep there are no alarms: `dormant_catchability` scales the prey a sleeping hunter can
  catch, for the share of kills flight costs awake (0.9 for deer: at 0.85 sleeping foxes took
  grouse for deer, at 0.95 the shares matched awake ones).
- `raised_by` "hunting": only a predator on the hunt alarms the herd; a fed fox walking by is
  run from by those who see it. Alarmed by every fox patrolling among them, herds stood in
  flight instead of grazing and drinking.
- Calibrated with pair hunting (LOD 2880 s, seeds 1-8): deer -6 % to -15 %, foxes -1 %,
  grouse -1 %; every animal awake (720 s, seeds 1-4): deer +4 %.
- `HerdAlarm` is counted (`herd_alarms`), not told in the feed. Grouse (`Scavenger` is a
  `Herbivore`) flee as a flock with their own `species.scavenger.herd.flight`.

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

### Hunting together (`hunt.pair`, `hunt.pack`)

A hunter's companions (`Predator._companions()`) are its mate, bonded back, with `hunt.pair`,
or the other members of its pack (`world.herd_members()`) with `hunt.pack`; their settings come
from `_party_config()`.

- A companion's prey, in sight of it and within `join_vision_share` of this one's sight, is
  taken first (`_mates_prey()`), and is not lost while a companion sees it (`_mate_sees()`);
  the chase's leash (`chase_break_radius`) stretches to the party's sight meanwhile.
- Roles are settled once per prey (`_pair_role_for()`): the nearest to it drives, the others
  flank (`flank`, «заходит наперерез»), ties to the lower id; `_pair_rank` is how many were
  nearer. A flanker runs for `flank_point()` - the intercept of the prey's run at its own
  sprint, no more than `lead_max_seconds` ahead, out to the side by
  `lateral_attack_radii` x attack radius, the offset fading as it closes. A fox takes its own
  side; a pack's flankers fan out by rank, odd to one side, even to the other, each pair
  farther out (`_flank_target()`). No path search of its own: the point is a chase target.
- A blow struck with companions at the prey (`close_partner_attack_radii`) gains
  `attack_bonus` for each, up to `max_helpers`; the kill's death event carries `pair`, which
  the feed tells as «Пара лис загнала оленя», «Волчья стая загнала оленя».
- Asleep: each hungry fox whose mate is hungry too, and each hungry wolf of a pack past the
  first, adds `dormant_kill_multiplier` of a hunter to the sector's kill rate.
- Counted: `pair_hunts` (a flanker taking its part), `pair_attacks`, `pair_kills`.

### Territories (`territory`, `TerritoryRegistry`)

A species with `territory` holds land (`scripts/world/territory_registry.gd`, one registry per
species in `WorldState.territories`, saved, the view's copy sent when its revision moves).

- Dens are placed once, from the map, with nothing drawn from `rng`
  (`TerritoryRegistry.place_dens()`): candidate cells every `step_cells`, each moved within its
  step by a hash of the seed, walkable, half a radius from the edge and within `water_cells`
  of a pond; taken best first by the grass the cells within half a radius can hold
  (a summed-area table over `ResourceSystem.export_caps()`; `den_score` "cover" takes the
  wood instead, which changed nothing measured and is off), and none within `spacing` radii
  of another. On the large map `radius_cells` 12.5 and `spacing` 1.8 give about 17 dens
  (10 cells, 23-26); the gaps between are ground no one holds. `enabled` false switches the
  block off, the only way a scenario's patch can («Слишком много лис»).
- A territory has a male's slot and a female's (`claim()`, `release()`, `partner_of()`,
  `open_slot_near()` by distance then id, `held_at()`); the registry is what is true. The
  founding pairs take the best dens (`_spawn_initial_pairs()` still draws the points, so the
  world's stream runs on as without); any death lets a slot go (`kill_agent()`,
  `_emit_dormant_death()`), and `TerritoryVacated` when the last goes.
- A holder not hungrier than `trespass_hunger` patrols and hunts its own ground only
  (`_home_ground()`, `find_prey_pressure_goal()` with a `keep` test), sweeping a ring at
  `ring_radii` round the den where it holds no prey, and gives up a chase past
  `border_slack` radii (`hunt_fail_border`); one without a territory keeps off everyone's.
- Mates are the two holding a territory (`_ground_to_share()`): a holder and a stranger with
  its slot open - not born there - pair and the stranger takes the slot; two vagrants do not
  breed; co-holders stay mates however far apart (`preferred_mate_break_radius` does not
  apply). Asleep, only co-holders breed. The breeding cap stays, `capacity_multiplier` times
  the start, as a backstop.
- At `dispersal_age_seconds` one without a territory looks every `look_seconds` for the
  nearest open slot not on its birthplace (`natal_territory_id`) - one where a mate already
  waits counting `mate_pull` times nearer - walks there («ищет свой участок», `disperse`) and
  takes it within `claim_radii`; with none open it is a vagrant. Past that age kin cohesion
  keeps only to the mate. After `emigrate_after_seconds` of looking, from the moment it began
  whether a slot was open or not, it leaves the map (cause `emigrated`, no body, «не нашла
  своего участка и ушла с карты»). Without that sink the young the land could not hold piled
  up as vagrants for years - foxes do not starve while there are grouse and carcasses - and
  with the cap lifted the foxes doubled (47 -> 87) and the deer halved.
- Asleep, a group keeping to a territory kills and stalks by `dormant_kill_scale`: it sits
  beside the prey of its ground 2-4 times as many hunter-steps as a pack ranging the map, for
  which the sleeping kill rate was set; at full weight holders killed 76 % more each asleep
  (27 % awake) and trebled the feared ground, and the herds left the best grass and bred less.
- Calibrated (LOD 2880 s, seeds 1-8, with herd flight and pair hunting, against the world
  before them): foxes 42 (-9 %), deer 197 (-17 %, the interval [-45..+10]) and steadier from
  seed to seed, grouse -1 %, no species lost; about 110 leave the map a run.
- Asleep, holders sleep as their territory's group (`predator:-1:t<id>`, young with their
  parents until they are of age) and keep to its ground as awake ones do
  (`_select_dormant_goal()`); vagrants of age settle by the nearest open den
  (`_settle_dormant_vagrants()`), their group making for it.
- The «Участки» layer draws each den's ring: bright held by a pair, faint by one, grey by
  none; the card says «Участок у …», «Ищет свой участок», «Своего участка нет»; the feed a
  pair taking a territory, one emptied, a young one setting out, in view or pinned.

### Hares (`species.hare`, `role.social` "solitary")

Small grass-eaters living alone, the first species on the solitary path (group -1). A setup
option («Зайцы»: есть / нет), on by default and off in the scenarios: forty start.

- **Class.** `Hare` extends `Herbivore` and keeps its grazing, drinking, resting, exploring,
  fleeing and breeding. `HareAI` drops `join_herd` and tunes the rest from `balance.ai.hare`.
  With no herd block there is no herd flight, no migration and no herd card.
- **Body.** Small (body radius 9, drawn at 0.6 of a frame), quick on the dash (sprint 115, a
  fox's 128) and soon tired (sprint cost 3). Quick to breed: grown at 40 s, a litter of about three every
  70 s in season, the season spring into early summer. Short-lived: old from 560 s.
- **Finding each other.** Alone on the whole map, forty hares would hardly ever meet, so a
  solitary species with `<id>_group_count` above 0 starts dealt round that many centres
  within 300 units (`_spawn_initial_solitary`), and looks for a mate within
  `mate_search_radius` (420). Asleep, a sector's hares count as one group-(-1) aggregate, as
  fox pairs do, and breed there by the grass-eaters' sleeping path.
- **Prey.** Foxes hunt them (`predator.role.eats_species`); wolves do not. Prey switching
  weighs them against a reference share of 0.3. Asleep they are caught as readily as deer
  (`dormant_ecology.prey_catchability` 1.0). The capacity cap is 2.5 times the start.
- **Tuned** on LOD 2880 s × 8 seeds against the same worlds without hares:

  | Variant | Deer | Hares | Hares killed by foxes |
  |---|---|---|---|
  | Without hares | 199 | — | — |
  | First try (sprint 140, caught at 0.5 asleep, cap 3) | 175 (−12 %) | 111, at the cap, dying of old age | 24 |
  | Slower (sprint 115, caught at 1.0), cap 3 | 161 (−19 %, the interval clear of zero) | 107, at the cap | 44 |
  | Slower, cap 2 | 193 | 66 ± 23 | 18; lost on one seed of eight |
  | Slower, cap 2.5 (shipped) | 202 (+2 %) | 91, never below the start | 28 |

  Shipped: deer's lowest is up (123 against 98), foxes +7 %, grouse even, no species lost.
  Deer suffer in step with the hares' number: they graze the same grass, and foxes hunting
  them about the herds keep the does from breeding (no birth with a hunter near). Asleep,
  kills go to the biggest aggregate first, and a herd outweighs a sector's hares.
- **Seen.** Their own atlas, composited from the pack's hare sheets by
  `tools/build_pack_atlases.py` (whose direction check skips `Hare_Run`: a hare's leap
  carries its weight forward, which reads as swapped side rows), and a carcass sheet from it
  (`tools/build_carcass_atlases.py`). Names of their own, a tan on the strip and the minimap.

### Wolves (`species.wolf`, `role.social` "pack")

A second hunter, off unless the setup asks for it («Волки — две стаи»: ten in two packs).

- A pack is a group (`group_id`) like a herd, spawned at the dens best first
  (`_spawn_initial_packs()`): its first male and female lead it - mature, mates, holding the
  den's territory - and the rest are its young, born there. The territory records its pack
  (`group`); one taking a slot joins the pack there, or its mate's, or founds one
  (`_pack_for()`).
- Members keep with the pack's centre (`_update_kin_state()`), hunt its ground
  (`territory_of_group()`) and hunt together (`hunt.pack`, above); at
  `dispersal_age_seconds` a member that does not lead leaves (`leave_pack()`, `PackLeft`),
  looks for a territory and founds a pack on it. Asleep a pack sleeps as one group and its
  grown young leave it asleep too.
- Calibrated in the sandbox («Две стаи», LOD 2880 s, seeds 1-8): wolves 10-24 (17.7 on
  average) and none dying out once dispersers were drawn to a waiting mate (`mate_pull` 3) and
  given 300 s to look; deer -19 % against the same world without wolves, foxes +7 %.
- Wolves eat deer only. Their art is the fox's atlas recoloured dun grey
  (`tools/build_wolf_atlas.py`) and drawn larger, until they have their own.

### Rare prey (`prey_preference`)

- A hunter goes after a prey species less readily as it grows rare: `WorldState.
  prey_preference()` is 1 while the species is at least its `balance.prey_switching.
  reference_share` of all the prey on the map (deer 0.5, grouse 0.2), awake and asleep
  counted, and below that its share over the reference, down to `min_preference` (0.1). It
  is worked out once a tick
- Awake, `Predator._choose_prey()` notices a prey only within the part of its sight the
  preference leaves, the area in proportion to it (radius times its square root), so a fox
  sees the last deer only near it and goes for the grouse it meets meanwhile. A chase under
  way is not dropped. Asleep, `_resolve_dormant_predation()` counts a group's catchable heads
  by the preference too, both for the kill rate and for which group is taken first, and
  `_sector_catchable_prey()` steers a sleeping pack the same way
- Why: at full fidelity grouse stay at their cap, so they and their carrion fed 30 to 43
  foxes while the deer dwindled, and the foxes went on killing about as many deer when a few
  dozen were left as when there were hundreds - each deer's risk grew as they grew fewer, and
  the deer were hunted out (seed 2 over twelve years, 52 to 2). With the risk falling as they
  do, a rare species gets the respite it needs to come back
- Off - the block off or absent, or every species at its reference share - the world is bit
  for bit as before (identity audits off 300 s, LOD 600 s; `PreySwitchingTests`)
- Measured with the fox rule of Who pairs with whom, as shipped, against the code before
  both (`audit_matrix.py`). At full fidelity over twelve years the deer held at 87 and 75 and
  up on seeds 1 and 2, where they had fallen to 2 on seed 2, but the foxes died out on both
  (years 7 and 10; see Known Gaps). Over 1440 s on 4 seeds nothing died out, the deer 217 late
  against 231. In LOD over 2880 s on 8 seeds nothing died out, the deer 228 late against 219;
  over 5760 s nothing died out where the code before lost the grouse on one seed, though grouse
  fell to 4 on that seed and the deer to 57 on another. Without the fox rule the switch alone
  lost the grouse on two seeds of eight over twelve years in LOD, and the fox rule alone helps
  the foxes refill after a fall (30 cubs in a spring against 9 on seed 1)

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
- Ponds with levels (`WaterSystem`) shrink towards their middle. The water field is baked once
  against each pond's bank, with the pond that owns each texel (`WaterMask.bake()`, `ids`); a
  round pond whose water stands `s` in from its bank is that field moved by `s`, so the shader
  adds each texel's own pond's shrink (`water_shrink_tex`, a float a pond, refreshed every
  `WATER_REFRESH_TICKS`) before blending (`shrunk_distance()`; `WaterMask.sample_shrunk()` is
  the same maths in script, for tests). The sand stays at the old shore and the bed the water
  left is drawn in `water.bed_color`, deepening over `bed_px`; a dry pond is shrunk past its
  bank. The levels reach the view's world in every worker frame (`"water"`), apart from the
  ground payload, which is off when the ground layer is
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
  above this layer and keep their square edges. Composite: tile, border, grass and trails, water.
  That is `visuals.borders.mode` "fray"; the default is now "field", which curves the borders
  through the cells (`BiomeField`):
  - `bake()` blurs each biome's one-hot mask over the walkable cells (a separable Gaussian, sigma
    0.8 cell, normalised by the blurred walkable mask), and `packed_image()` packs per cell three
    weights (rgb; the fourth is what they leave) with the cell's biome, walkability, height and
    an "all one biome around" flag (a). It goes in `biome_tex` itself: the ground shader already
    binds eight textures, and a ninth was never bound in the Compatibility renderer - it read the
    default white texture, every weight equal, and drew a checker. 0.12 s once per world
  - The shader (`field_surface()`) reads the weights bilinearly at the art pixel, moved by an
    integer-hash noise warp (0.3 cell over 1.5 cells, so `BiomeField.sample()` mirrors it bit for
    bit but float rounding), and draws the biome weighing most; within `dither_band` of a tie the
    first two are chosen between by a 4x4 Bayer test, a ragged fringe of a pixel or two. A pixel
    within `core` (0.32 cell) of its cell's centre, the circle shaped by half the warp, keeps its
    biome, so a lone cell stays a blob (at 0.2 and unshaped it was a perfect coin); a pixel takes
    only a biome some walkable cell of its 3x3 has on its level. Drawn coarser than the art, the
    pixel steps and the dither are left out
  - On an M2 under load the whole large map drew in 12.1-12.9 ms against 11.4-11.7 with "fray",
    the same up close
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
  relative's box says (name and sex, kind, age, or «†» and the cause), with its inherited traits
  for a tooltip. `Lineage` keeps those (`note_traits()`) from the birth event, or from the animal
  when it is met awake
- `TraitHistory`: each species' trait means over the world's whole life for «Черты», a point
  every 30 simulated seconds from the stats snapshot; past 480 points it drops every other one
  and samples half as often, so any age fits. Kept with the story
- `StoryRecords`: the chronicle's records from one pass over the tree - the oldest alive, the
  longest lives, the largest living families, the best hunters - three each, ties to the lower id
- `SeasonLedger`: what each season did, for the season card and «Сезоны». The open season
  counts what the book hears - births (awake and asleep) by species, deaths by species and
  cause, kills per hunter (`other_agent_id` awake, `killer_record_id` asleep, as `killer_of()`
  reads them), the ponds that dried and filled again. The book asks it on every
  `tick_completed`; when `Climate.season_ordinal()` (seasons begun since the world's first, -1
  with the clock off) has moved on, the season closes with each species' count as the world
  stands (`get_population_metrics()`, asleep and awake), so a species' change is exactly its
  births less its deaths; the best hunter (most kills, the lower id on a tie) and the ponds are
  named as strings then (with each pond's gender for the verb), since names are given back at
  death, and the drought flag is the water's own (`WaterSystem.is_drought_year()`), set only on
  the seasons whose balance is a loss. `season_closed(summary)` tells it; `preview()` gives the
  season going as it would close now, for «Сезоны». Through the
  worker a frame of several ticks lands at once, its events before its `tick_completed`, so a
  season ends on the first frame past its boundary and keeps everything up to it. Kept with the
  story under an optional `"seasons"` key, 200 seasons (fifty years); a season met half-way - a
  save without the key, a story begun mid-season - is `partial`
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
  the book holds the log. A pond in view that dries or fills again (`PondDried`,
  `PondRefilled`) gets a line - «Тихая заводь пересохла», «Тихий брод пересох», «В Тихой
  заводи снова вода» (`PlaceNames` keeps each pond's gender and its «в/на» locative); several
  within 12 s fold into «Пересохли Тихая заводь и ещё 3 водоёма»; the rest go into the
  minute's summary («пересохли — 5 водоёмов»), as a summer dries dozens
- `StoryFeed` shows the newest seven above the minimap with the time of day - folded by default
  to its title and the newest line («События · ещё 6 ▾»; a click on the title opens or folds it,
  `set_expanded()`), since seven lines took much of the right of the screen - pinned animals in
  gold and the summaries dimmer; a click selects the animal the line names while it lives (the
  hunter, the newborn) or sends the camera to where it happened. Dark like the season bar and
  the strip, hidden by the start menu like the minimap. It grows upwards from its bottom edge,
  and while a season card or an epitaph stands in the right column it shows only the newest
  rows that fit below it (`fit_below()`, from `MainController._layout_hud()`), not running on
  under the card

### `HerdCard`

- The selected animal's herd, above its own card, in Russian: the herd's name and number
  («Травоядные · Стадо №5»), how many there are with how many sleep far off and how many
  are young, the means of their energy, food and water as the selection card's bars
  (`AgentReadout.need_bars()`, against the selected animal's own thresholds; energy gold, food
  green, water blue, any of them red when low - three greens read only by their order), how many
  hunters are after them now, the last loss with its cause and how long ago, and a toggle that
  follows the herd (`focus_mode` "flock"). The head count's tooltip gives the members' mean
  inherited traits
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
- The pointer resting `EDGE_DELAY` (0.2 s) within `EDGE_MARGIN` (8 px) of the window's edge pans
  that way at the keys' speed (`edge_direction()`), only while the pointer is in the window
  (`NOTIFICATION_WM_MOUSE_ENTER/EXIT`, and not before it first moves - until then its position is
  the corner) and the window has the focus; the delay keeps a pointer leaving the window from
  dragging the map
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

### The steward's interface (`PowersBar`, `PowerTargeting`, `GoalChips`, `ResultWindow`)

- `PowersBar`, at the bottom centre: «Водопой» (Q), «Повести стадо» (E) and «Отстрел» (R) - those
  the world is offered - each with its charges («×1», none in the sandbox) and, while cooling
  down, the seconds to wait; a power spent or cooling is greyed. A line above, wrapped to the
  buttons' width, tells how to aim, or why the last try would not do. Its state
  is the world's (`PlayerState`, from the frames), refreshed on the interface's ticks and on
  `player_state_changed`. Up with the player bar, and only in a world with powers
- `PowerAim` is the aiming, apart from any node so it is tested: arming checks the charges and
  the cooldown (and, to lead, that there is a herd: the selected animal's if it may be led -
  `WorldState.can_lead()` - else, in a scenario, the biggest part of the player's own); its
  preview asks the world the view is shown what the simulation will ask - `dig_pond_refusal()`,
  the herd's reach, the route search, once per cell the pointer enters; for a cull the foxes in its
  circle, the sleeping ones by their sectors' groups (`cull_count()`) - and a click gives the
  order (`enqueue_command()`) or says why not and keeps aiming. `PowerTargeting`, a Node2D after
  `WorldView`, draws it - the pond or the cull's circle green or red («лис в круге: 4» beside the
  pointer: over the circle the species table hid it), the flag with a line from the herd - and takes
  the left click before the world's selection does (unhandled input reaches later nodes first);
  the right click or Esc stops it, and so do a pause, the menus, help, the chronicle and photo
  mode. A paused game aims nothing
- `GoalChips`, above the powers: a chip a goal with its numbers - «Ваше стадо: 17 из 20, нужно 10
  · ещё 2:15», «Не меньше 5 голов», «Ни одной смерти от жажды» - in ink while open, amber while
  it would fail if decided now, green met, red failed; the scenario's own words in the tooltip.
  A species' floor reads «Лисы: 34, не меньше 20», a limit on culling «Отстреляно: 5 из 12». Last,
  where the challenge asks for it (`chips` with "water"), the own herd's water, its members' mean
  awake and asleep («Вода стада: 64»), amber below 60 and red below 30: when to act is read off it.
  An `HFlowContainer`, centred in one row while the room between the cards on the left and the
  map and feed on the right holds it (`fit()`, from `MainController._layout_hud()`), in two when
  not - three or four chips at 125 % in a 1600-wide window ran under both
- `ResultWindow`, in the middle: before play the brief - the scenario, what it asks, its goals,
  «Начать» - over a paused game, with the camera framing the player's herd
  (`GameCamera.frame_world_rect()`, near enough that it is awake) and one of it selected; at the
  end the result - the scenario's own title («Стадо пережило сушь» / «Стадо не пережило сушь»),
  the herd's curve against its species', what is left and the least there was, the dead by
  cause, the powers used and the bonus - with «Смотреть дальше», «Заново» and «В меню», and after
  a win «Следующий сценарий» first, the next in the page's order (`ConfigLoader.next_scenario()`,
  `next_requested`). The game stands still under either and the season card and epitaphs wait
- The start page offers «Сценарии» first: a card a scenario - its name, brief and «Играть» - up
  to three abreast where the window has the width and scrolling where it is short
  (`_fit_scenarios()`, a frame after layout, when a wrapped brief knows its height), played in
  the style the setup page has (`StartMenu.scenario_requested`); «Новая симуляция» is the
  sandbox. The cards replaced a 420-wide column, which with two briefs ran off the top and
  bottom of the window. The first game's card (`tutorial`) says «Начните отсюда», a won one
  «Пройден»: the wins are kept in `user://progress.cfg` (`scenario_progress.gd`), a mark only,
  nothing locked; the cards are built again each time the page opens
- `TutorialHints`, a first game's hints (`challenge.hints`, each `{text, until}`), one at a time
  on parchment under the species line: a hint goes once the player has done what it asks - another
  animal chosen (`select`), the camera following (`follow`), time sped up (`speed`), a lead given
  (`lead`), the feed opened (`feed`) - or after its `seconds` (`time`), or on «Понятно»; one asking
  for what is already so is passed over unseen, and the next comes after 1.2 s. `MainController`
  builds it, hands it those facts every frame and lets it show only over a world in play
  (`_hints_allowed()`: not under the brief, the result, a menu, help, the chronicle or photo
  mode). A scenario started from the page has them; one resumed from a save goes on without

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
- With pond levels on (`WaterSystem`) the ponds are drawn in `_draw()` each refresh at their
  water's edge, a dry one as a faint bed the size of its bank, instead of baked into the static
  terrain image

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
  `StoryRecords`; a click opens that animal's family. «Черты» draws `TraitHistory`: a chart a
  trait, a line a species in its interface colour darkened for the parchment, the species
  dashed across the middle, the scale reaching the furthest point and the latest value at each
  line's end. «Сезоны» lists `SeasonLedger`'s seasons in `SeasonReport`'s words, newest first,
  under the one still going («Лето · год 2 · идёт», its numbers so far from `preview()`, refreshed
  in place); the closed seasons' rows are built again only when a season closes, as two hundred
  of them would be too many to rebuild every refresh. With the clock off: «В этом мире нет
  смены сезонов». Refreshed every 1.5 s while open
- Opened by L (`toggle_chronicle`, by physical key so a Russian layout presses it too), the
  player bar's «Летопись», the card's «родословная» link, the epitaph card and the season card
  (on «Сезоны»); Esc closes it before the pause menu would open

### `EpitaphCard`

- Parchment card at the right under the strip's level, clear of the selected animal in the middle
  and of the strip at any interface size, with the epitaph of a death worth remembering, «Где
  это» (camera to the place) and «Родословная» (the chronicle); ten seconds each, counted only
  while the game runs, several queued; hidden by the start menu. While the season card shows,
  it waits with its countdown stopped (`MainController._layout_hud()`): stacked, the two reached
  down over the event feed

### `SeasonCard`

- The season just over, on the same parchment in the same place as the epitaph card, which
  waits behind it:
  `SeasonReport`'s title and lines from `StoryBook.season_closed` - «Итоги лета · год 2 ·
  засуха», «Олени 278 (+38) · лисы 41 (−6) · тетерева 118 (+12)», «Родились: 74 оленёнка, 12
  лисят, 40 птенцов», «Погибли: хищники — 31, голод — 9, жажда — 4, старость — 38», «Лучший
  охотник: лис Рыжик — 5 добыч», «Пересохли Тихая заводь, Кривой брод и ещё 3 водоёма». Eight
  seconds, counted only while the game runs; a new season's card replaces the old (at 10x a
  season is twelve seconds, so it is on screen two thirds of the time rather than queueing
  behind itself). «Летопись» opens «Сезоны» and puts the card away. Hidden by the start menu, by
  the developer panels (the charts stand where it does) and in photo mode
- `SeasonReport` words a summary: years from 1 as the season bar counts them, «засуха» only on a
  drought year's seasons that lose water (its summer, with autumn's rains), «не с начала» for a
  season met half-way, the young in their own nouns, the dead by cause over every species,
  «Лучшая охотница» for a vixen, a single pond's verb in its gender, three ponds named and more
  cut to «и ещё N водоёмов»; a line with nothing to say is left out

### `PlaceLabels`

- Draws `PlaceNames` on the map: pond names once zoomed in past `visuals.places.pond_zoom`, district
  names between `district_zoom_min` and `district_zoom_max`, each faded over a band rather than
  popped. Constant size on screen, outlined, unshaded so night leaves them legible, placed through
  `WorldProjection` at the ground's height. Redraws when the camera moves, and once a second
  while ponds have levels: a pond's name then says how full it is («Тихая заводь · 35 %»,
  `pond_text()`), so where to lead a herd and when to dig is read off the map, and a dry pond's
  name is dimmed (`DRY_DIM`) and says so («· сухо»)

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
- Folded to one line by default - «Олени 244 ▲ · Лисы 24 · Тетерева 88 · Трава 48–56% ▾», each
  count in the colour of its species' worst column (`row_level()`), the grass as the range of
  the biomes' shares in the worst one's (`grass_summary()`) - because the table took a good part
  of the top of the screen. A click opens it or folds it (`set_expanded()`); folded, only the
  line takes the mouse (`_has_point()`), so the rest of its rect is the world's

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
Deer divide past 40, grouse flocks past 20. Grouse flocks used to be left whole: the
flocks whose hens bred most grew while the rest aged away, and by the ninth or tenth year
in LOD one flock held 124 or 125 of the 126 grouse. A sleeping flock shares each carcass
among all its members, so in that flock the hens rarely reached breeding energy, and one
lean season for it was a year without young for every grouse; they then aged out (on the
two seeds probed, 125 to 28 in three years and 125 to 82 in one).

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
- `water_levels` lets the ponds fill and dry (see `WaterSystem`): `balance` per season,
  `capacity_seasons`, `size_exponent`, `capacity_exponent`, `dry_level`, `wet_level`,
  `drought_chance`, `drought_strength`. Only with the climate on; the test fixtures switch it
  off

- `climate` drives seasons and the day/night cycle. It is read by `Climate`
  (`scripts/world/climate.gd`), which is a **pure function of `simulation_time`** rather than
  accumulated state - `SaveSystem` already round-trips `simulation_time`, so the clock costs
  no save-format change by itself. Save version 3 adds inherited traits (records' `traits`,
  sleeping groups' `avg_traits`); a version 2 save reads neutral traits and keeps its own
  bundle, which has no `traits` block, so it plays on without heredity. Version 2 stores agent
  perception memory and the resolved configuration bundle; version 1 is migrated on read. Anything that starts accumulating here
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
  `max_new_paths_per_tick`. The open heap keeps each node's priority in a `Vector2`, a 32-bit
  float, and a popped entry is stale only if its priority, rounded so, exceeds the node's
  `f_score` rounded the same way: compared with the 64-bit `f_score` as it was, an entry whose
  priority had rounded up looked stale and was dropped, and about half the searches across open
  ground lost their first node and came back unreachable (33 of 64 in the test), as did routes
  round a ridge. Over eight seeds of 48 minutes with LOD, fixing it raised the deer at the end
  from 149 to 214 and their late low from 108 to 132, cut their deaths of thirst from 85 to 54
  and herds moved pastures 286 times instead of 245; the slowest ticks did not change (p95 40
  against 41 ms). Searches run in slices of `path_expansions_per_slice` and resume on a
  later tick, so a lower budget delays routes rather than shortening them. It replaced a
  wall-clock budget that made replays machine-dependent. The shipped 512 (about 5 ms at the
  ~10 µs per expansion measured on the reference MacBook Air) was chosen against that budget on
  the large balanced preset, seed 1337, 600 ticks with LOD off: the same instructions retired
  (358 G, against 352-360 G for the wall-clock build, which varied run to run) and a global path
  queue peaking at 12 instead of 22-28. 768 cost 6.5% more.
  `path_time_warning_ms_per_tick` only reports: a tick whose route search took longer counts in
  the `path_time_warning_ticks` counter and changes nothing.
- `navigation.unreachable_memory_seconds` (30) is how long an awake animal leaves alone a
  carcass, a pond or a patrol goal its route search found no way to: the search gives up at
  `max_search_cells`, or the goal is walled off, and `get_next_waypoint()` says so
  (`AgentBase.path_reachable`). Feeding, drinking, the predator's watch at the water and its
  patrol drop such a target and choose again (`choose_carcass()` and `WorldState.water_for()`
  pass it by). They used to keep it: a one-cell route left the animal standing, a partial one
  walked it away along the searched part, and in the map's centre most awake foxes stood at
  zero energy for whole seasons - starving, thirsting, breeding no more - until their cohort
  died out
- `navigation.prey_pressure_refresh_ticks` throttles the sector-level herbivore census that
  is the simulation's only long-range prey signal. Both the dormant goal selector and the
  live predator patrol read it.

### `species.json`

- tunes each species independently without code changes
- `scavenger.herd.split_size` (20): the flock size past which a grouse flock divides, as a
  herd does (see `_split_oversized_herds()`); 0 or absent leaves flocks whole.
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
- `traits` switches heredity on for the species and tunes it (see Heritable traits):
  `founder_spread`, `mutation`, `clamp`, `longevity_clamp`, and the costs `run_cost_exponent`,
  `speed_hunger`, `vision_hunger`. The test fixtures switch it off (`build_test_bundle()`)
- `breeding` switches the breeding season on for the species and sets its litter
  (`litter_mean`, `litter_max`, optionally its own `curve`; see Breeding season). Only with the
  climate on; the test fixtures switch it off
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

### `powers.json`

- The player's powers, each with `charges` (-1 for no limit) and `cooldown_seconds` of
  simulated time between uses (`PlayerState`), beside its own settings, and `offered`, the ones a
  world has. A scenario overrides them. A save from before the powers takes them as shipped
  (`ConfigLoader.with_shipped_presentation()`).

### `scenarios.json`

- Each scenario: `label` and `brief` for the start page, `seed`, the setup options it names
  (`selection`), a `patch` over the bundle and the `challenge` the runner keeps score by (see
  Scenarios). The order of `order` is the page's.

### `presets.json`

- The setup screen's option groups, each a patch over the base configs. The map sizes are the
  large map scaled by a third, two thirds and one and a half: the world and its cells, every
  perception, body and feeding radius, the ponds' radii and the LOD window's margins. On the
  small and medium maps pond density (`water_generation.sources_per_million_units`) goes the
  other way, by the square, so they have the large map's 52 ponds and a deer anywhere is within
  its water search of one. The huge map keeps the large map's density, 118 ponds: cut to 52, 6
  to 15 % of its deer that died, died of thirst, against under 2 %
- A predator's hunger and thirst rates are the large map's times 1.56 and 1.55 on the small
  map, 1.2 on the medium, 0.8 on the huge: written out as numbers, so a change to the predator's
  `metabolism` in `species.json` has to be carried here too. It once was not - the large map's
  rates fell from 1.25 and 1.0 to 0.2 and 0.18 and the others kept the old ones, five to ten
  times too hungry - and on the small map predators starved out within minutes, while its six
  ponds, further apart than a deer looks, made nearly half the deer that died die of thirst.
  `P3BalanceTests` holds every size to at least the large map's ponds, the deer's reach and a
  predator's rates within twice the large map's

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
- the map sizes as scaled copies of the large map (`P3BalanceTests`): at least its ponds, a
  deer anywhere within reach of one, and a predator's hunger and thirst within twice its rates
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
- heredity (`TraitsTests`): founders and inheritance, clamps, costs, sleeping births with both
  parents, selection asleep, means, saves
- the watering holes (`WaterTests`): a normal year and a drought year for ponds of 180, 230 and
  280, droughts about one year in four and different per world, drinking a pond down and the
  brink it does not flicker across, dry ponds skipped awake and asleep, a thirsty deer going
  to the far wet pond, no water anywhere vetoing the drink, a sleeping group drinking its pond
  down and choosing again at a dry one, memories forgetting dry ponds, levels through a save,
  each change told once, and a world without levels playing exactly as before; the water mask
  knowing each texel's pond and shrinking each by its own amount, the ground layer's shrinks,
  levels reaching the view's world through the worker, every pond noun's «в/на» case, and the
  feed's pond lines, their folding and the minute's summary
- the breeding season (`BreedingTests`): the curve over the year, females opening over its
  ramps, litters, autumn barren and spring twins, a predator out of season keeping its carcass
  and its mate, a fox litter's kin, litters against the cap awake and asleep, a sleeping litter
  with both parents and the shared stream untouched, awake and asleep agreeing, and a world
  without a season playing exactly as before; a spent buck breeding and a spent doe not,
  awake and asleep, a doe finding the nearest ready buck of her herd past the search radius
  and never another herd's, the herd lists following deaths and moves, and a sleeping herd
  pairing across itself
- the season ledger (`SeasonTests`): which season a moment falls in, a season closing on its
  tick with each species changed by exactly its births less its deaths, the best hunter with a
  tie and a kill asleep, dried ponds by name and once each, a season met half-way, the ledger
  through a save and a story saved before it, nothing without a clock, the drought flag only on
  the seasons of a drought year that lose water, and the season going left open; the report's
  words (the title three ways, each line, a huntress, signs, a pond's gender, the long list
  cut), the card replacing, waiting while paused, going after eight seconds and opening the
  chronicle, and «Сезоны» keeping its rows until a season closes, and saying so without a clock
- every route across open ground found, and the long way round a ridge
  (`P0PerformanceTests`), which the search missed while it dropped nodes to its own rounding
- targets out of reach (`ReachTests`): navigation saying when its route search found no way to
  a walled-off goal, a deer leaving such a pond and a predator such a carcass for ones they can
  reach, the memory lapsing and keeping to a dozen, and travelling with the animal's state
- rare prey (`PreySwitchingTests`): the preference following a species' share and its floor,
  a fox among grouse passing the last deer far off and taking one close by, a sleeping fox
  gaining on a kill as much slower as the deer's preference, and nothing changed with the
  block off
- «Водопой» (`WaterholeTests`): a dug pond joining the water with every array in step and no
  other pond's capacity moved; each bad place refused and paid for by nothing; deer awake and
  asleep drinking from it and it drying; it coming back with a save with its level, a deer's
  memory of it and no news; the view's world getting it across a lost frame; the map's ponds
  keeping their names at 52 ponds and the dug one taking a new one through a save; the ground
  stamping it; and the feed telling of it
- «Повести стадо» (`LeadHerdTests`): a led herd going on past bare ground at its goal and its
  own patience until its time runs out, and arriving ends the walk; members up to hunger 85
  following it and a herd moving by itself leaving one at 60 to eat; its sleeping part going,
  a thirsty one drinking first, where `follow_asleep` keeps a herd moving by itself; both halves
  of a split led on; a flock, a missing herd, off the map, a cliff, too far, a walled-in goal and
  one only a long way round refused; a tired member resting and walking on once rested; the walk
  saved; a fed awake herd arriving within half a minute; and the feed telling of it
- the steward's interface (`StewardUiTests`): the buttons' charges, wait and greying, the power
  aimed pressed and the line above it, the sandbox's buttons without charges; aiming a waterhole
  green and red, a click at the edge refused with its reason and one in the open giving the order,
  a cooling power not aimed; aiming a cull - the foxes in its circle counted awake and asleep, red
  where there are none, a click giving the order; the cull button only where it is offered; leading - no herd chosen, the selected deer's herd named, too far,
  walled in, the order naming the herd, the own herd with none selected; the goals' chips with
  their numbers, amber and red; the brief and the result with their words and buttons; the start
  page's «Сценарии» first and «Долгая сушь» played in the chosen style; and every word of it and
  of the help it adds in Russian
- scenarios (`ScenarioTests`): «Долгая сушь» offered and told in Russian; its bundle taking the
  scenario's map size over the player's, the player's look, the same ground whatever the style,
  its water merged over the shipped water and its powers over the shipped powers, and a plain
  world having none of it; the world it begins in summer, in a drought, half full, with its
  powers; the own herd nearest the middle, a split half still its own, counted asleep; its deaths
  by cause and another herd's not; the bonus lost to one death of thirst, the scenario lost
  under a quarter with the open goals settled and `finished` once; the result on the very tick
  autumn begins, or `days` into it; and the score saved, the starting count not taken again;
  the manager keeping it from an inline tick and a worker frame, and none for a plain world,
  whose powers have no charges; a save carrying it and a load taking it back, a result to come
  decided at its time and one already in not announced again; a scenario's own slots, Continue
  opening the save written last, a version 3 save without a time the oldest and still loading;
  and the first season of a world begun in summer seen whole; a goal two summers on, a species'
  floor, the culls counted from the orders and past their limit, the watched species in the curve,
  and all of it saved; and «Слишком много лис» as tuned, its powers only the cull and the lead
- «Отстрел» (`CullTests`): the nearest foxes taken, as many as the power allows and only foxes,
  each told dead of a cull and no body left, the stats counting it; sleeping foxes taken too and
  the census following; off the map, nobody there and only a deer there refused at no cost; a
  worker and an inline world culling alike; the powers offered - all in the sandbox, two in «Долгая
  сушь», all of a bundle without the list; and the feed telling a cull once, with no epitaph
- the player's orders (`PlayerCommandTests`): an order carried out on the tick it was handed
  to, with its event and journal entry on that tick; the same order on the worker thread and
  inline leaving the worlds alike; charges and cooldowns in simulated time, kept through a
  save, and a save from before them; refusals changing nothing; a paused game holding orders
  and a new world forgetting them; and the view's charges following the worker's across a
  lost frame and a frame applied twice

## Measuring Balance

`scripts/dev/ecology_audit.gd` runs one seed deterministically, LOD or full fidelity, with
config overrides as `key=value` arguments, and writes a JSON report: populations over time,
the late-half `regulation` block, counters, timing. One seed says little. The same change
has moved herbivores +44% on one map and -20% on the next. `selection.<group>=<option>`
picks a setup-screen option instead of the default (`selection.map_size=small`). Each minute's
history row carries the season, each species' count, running births and deaths (all, and of
thirst: `herbivore_born`, `_died`, `_thirst`), the ponds (`ponds_dry`, `water_mean`, `drought`)
and the minute's slowest ticks (`tick_p95`), so a season's or a drought year's toll and cost
can be read off the report.

`scripts/dev/audit_matrix.py` runs variants over many seeds and compares each with a
baseline seed by seed:

```
python3 scripts/dev/audit_matrix.py --out /tmp/matrix --seeds 1-8 --mode lod --seconds 1440 --jobs 4 \
    --variant base --variant slow species.herbivore.metabolism.hunger_rate=1.0
```

- Per metric, the mean and spread over seeds, and against the baseline the mean
  difference with its 95% interval (paired t) and on how many seeds the variant was
  higher. An arrow marks an interval clear of zero. Besides counts, births and deaths:
  each species' share of deaths that were of thirst, the worst drought year (its thirst
  deaths against the species' count when the year began), and the tick p95 overall and
  per minute in spring and in autumn.
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
  A fix probably has to spread deaths across ages rather than move births. Heritable longevity
  (±10 %, `Traits`) does not: in the 8-seed 48-minute matrix with heredity on, the predators'
  late low stayed where it was (39 ± 9 against 41 ± 10); the deep fall left seed 1 (19 to 41)
  and appeared on seeds 4 and 7 (48 to 23, 46 to 29). A tenth of a 1440 s life spreads a cohort's
  deaths by a couple of minutes, inside the four the old-age window already spans
- Live play still loses a species over twelve years, now the foxes. At full fidelity over 5760 s
  (2 seeds) the deer used to die out on both seeds with no season (in years 8 and 10) and on one
  with it (year 9): a live mating needed a doe and a buck of one herd within `mate_search_radius`
  both at `energy_threshold` at once. A buck now needs no strength and a doe looks across her
  herd (Who pairs with whom): 44 to 47 % of the grown does have young in a year against 24 to
  34 %, and over 1440 s the deer are 22 % below off with the season instead of 47 %. Then the
  foxes, fed by grouse at their cap, hunted the thinning deer out (seed 2: from 52 to 2 over five
  years) until rare prey got its respite (Rare prey); the deer now hold, and the foxes die out on
  both seeds (years 7 and 10). `predator_probe.gd` on seed 1 shows why: the first spring's
  litters fill the predator cap (48), births stop while it is full, and that wave ages as one and
  dies within minutes (about 25 deaths of old age in six minutes in year 3); the few left are
  scattered - by then hardly one has a fox of the other sex within 480 - and weak, near 0 energy
  most of the time, and do not refill it before the next wave goes. Over seeds 1 to 4 the chain
  held on two, 3 and 4 (on 4 the deer fell to 21 and the foxes to 9). Taking fertility off as a
  species fills its room did not cure it: from half the cap, or 0.7 of it, fewer vixens and hens
  were open each year, through the season's own draw, so no mating went without young
  (`population_regulation.fertility_start`, not kept). It thinned the foxes instead of spreading
  their ages - 119 cubs against 206 on seed 3, where they then died out - and the chain held on
  one seed of four at 0.7 and on none at 0.5; in LOD over 2880 s the grouse, kept below their
  cap, went two years without young on one seed and died out at 0.5 (fell to 7 at 0.7), where
  without it they never fell below 72. The foxes' trouble is as much their strength, near 0 most
  of the time so that most hunts fail, as the waves. The same cap-and-cohort wave loses grouse in
  LOD (Long runs still dip). A deer window to the end of summer narrowed the 1440 s gap to 12 %
  (before the fix for targets out of reach) but in LOD its births overshot the grass and starved:
  retested over 2880 s on 8 seeds, the deer fell to 9 and 17 on two seeds and ended 20 % below
  off, so it is not shipped
- Long runs dip less. Over twelve years in LOD, with seasons and drying ponds, grouse fell to 12
  on one seed of eight and 26 on another before their next young; with neither, they died out on
  a third; with the buck and herd rules (Who pairs with whom) they held at 58 and up on seven
  seeds and died out on the eighth, and with rare prey's respite as well (Rare prey) they died
  out on none but fell to 4 on that one. The dips were whole years without young, and their cause
  was a flock grown to nearly every grouse there was (see the flock split above). With flocks
  divided past 20 the grouse held at 72 on all eight seeds and no year went without young; past
  30 they fell to 45 on one. The deer paid on two seeds of eight: after a bigger boom they fell
  to 32 and 42 (133 on both before) and stayed low for some years with the foxes on their cap,
  then came back to 207 and 259; across the eight their late mean was 208 against 233, within
  what one seed differs from the next. Over 2880 s in LOD on 8 seeds and 1440 s at full fidelity
  on 4 nothing changed beyond the noise, and foxes took as many grouse as before (32 against 33).
  Four earlier remedies were tried and taken back. Looking further for carrion from the hunger
  they start eating at: flocks flew off to distant bodies away from water and died of thirst in a
  drought year on one seed, and stopped breeding on another. Spreading old age (from 700 to
  1500 s at 0.002 a second instead of 1000 to 1200 at 0.004): the dips went deeper (to 4).
  Sending a hungry flock to the nearest herds, where bodies turn up: grouse held at 72 and up,
  but they ate the kills sleeping packs need to reach breeding energy and foxes died out on one
  seed (58 born against 201). Breeding at hunger up to 60 instead of 40: better on the two seeds
  tried, but over twelve years on the next four foxes died out on one, grouse on another and deer
  fell to 5 on a third. The worst drought year over those twelve years took 27 % of the
  herbivores alive when it began
- No authored scenarios or scenario editor
- No replay flow (save/load exists; see `SaveSystem`)
- Heredity is four multipliers with fixed costs, not a genome: no trade-offs beyond the ones
  written in `species.<id>.traits`, no traits of the body or of behaviour, and asleep only who
  dies is selected, not how many
- Terrain and shadow art are placeholders. The opened and picked carcass stages are drawn
  by a script over each species' last death frame, not by an artist
