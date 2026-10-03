# Engine of Ecosystem

`Engine of Ecosystem` is a Godot 4.6 ecosystem simulation prototype focused on simulation-first gameplay: deterministic ticking, hybrid FSM + utility-based agent AI, terrain-aware navigation, telemetry, and debug tooling.

The current build simulates a continuous 2D world with biomes, obstacles, grass regrowth, fixed water sources, herbivore herds, predator hunting, carcass scavenging, reproduction, aging, camera follow modes, minimap navigation, telemetry exports, built-in headless tests, and camera-driven LOD for interactive play.

## Current Build

- Godot version: `4.6`
- Main scene: `res://scenes/main/main.tscn`
- Headless scene: `res://scenes/main/headless_runner.tscn`
- Default seed: `3`
- Tick rate: `18` ticks per second
- World size: `14400 x 8100`
- Initial population: `240` herbivores in `12` herds, `24` predators
- Water sources: generated from `world.water_generation` and scaled with map area, about 52 on the default large map
- Terrain: meadow, forest, drought, swamp biomes plus obstacles and chokepoints

## Core Systems

- Deterministic fixed-step simulation with seeded RNG
- JSON-driven configuration for world, species, balance, and debug settings
- Hybrid AI pipeline: top-level FSM plus utility-based action selection inside active states
- Procedural terrain grid with biome-specific move cost and forage multipliers
- Obstacle generation and terrain-aware pathfinding
- Renewable grass resource grid linked to terrain productivity
- Spatial grid acceleration for proximity queries
- Herbivore behavior: `alive/panic/dead` AI states with utility-driven graze, drink, rest, explore, herd join, and flee actions
- Predator behavior: `alive/engaged/dead` AI states with utility-driven hunt, scavenge, drink, rest, investigate water, pair cohesion, and patrol actions
- Lifecycle rules: hunger, thirst, energy depletion, predation, old age
- Carcass lifecycle with feeder reservation and meat depletion
- Runtime telemetry, charts, event log, agent inspector with utility scores, overlays, minimap
- Tile-based terrain rendering and animated sprite agents drawn through MultiMesh batches
- Camera-driven interactive LOD for distant agents

## Art Assets

Terrain tiles and agent sprites are driven by `data/config/visuals.json`, which maps biomes,
obstacles, animation rows and frame sizes onto the atlases under `assets/`. Swapping in a
different art pack means replacing the PNGs and editing that manifest - no code changes.

The animal sheets, the props atlas and the UI skin are composited from CraftPix packs by the
scripts in `tools/`, and the top-down style uses the CC0 Kenney roguelike pack. The orthogonal and
isometric terrain atlases, the carcass sheet and the shadow blob are still placeholders generated
by `tools/generate_placeholder_atlases.py`, which also documents the geometry a replacement pack
has to match:

- `assets/tiles/terrain_atlas.png` - 6 tiles of 32px in one row: meadow, forest, drought, swamp,
  cliff, dense_forest
- `assets/sprites/<species>_atlas.png` - 32px frames, 4 per row, 5 rows in order
  `idle`, `walk`, `run`, `eat`, `dead`
- `assets/sprites/carcass_atlas.png` - 3 frames of 32px: fresh, picked, bones

Regenerate them with:

```sh
python3 tools/generate_placeholder_atlases.py
```

### Source art packs

The CraftPix source packs are not in the repository: their license lets the game use the art
but forbids redistributing the source files. Only the atlases composited from them are tracked.
To rebuild those atlases, download each pack into the folder whose `SOURCE.md` names it:

- `assets/craftpix/` - Free Top-Down Hunt Animals Pixel Sprite Pack, read by `tools/build_pack_atlases.py`
- `assets/craftpix-net-200380-free-pixel-art-plants-for-farm/` - Free Pixel Art Plants for Farm, read by `tools/build_prop_atlas.py`
- `assets/craftpix-net-255216-free-basic-pixel-art-ui-for-rpg/` - Free Basic Pixel Art UI for RPG, read by `tools/build_ui_theme.py`

Each folder keeps a `.gdignore`, so Godot neither imports the raw files nor exports them with the
game.

`.gitignore` keeps new copies out of commits, but older local history may still hold them. A
`pre-push` hook refuses any push that would put CraftPix source files on the remote; install it
once per clone:

```bash
cp tools/git-hooks/pre-push "$(git rev-parse --git-common-dir)/hooks/pre-push"
```

## Run

### Interactive Scene

1. Open the project in Godot.
2. Run the project, or open `res://scenes/main/main.tscn`.
3. The main menu opens first. `Новая симуляция` reveals the setup options,
   `Продолжить` resumes the latest autosave, and `Помощь` describes the controls
   and the mechanics. Nothing is simulated until a run is started.
4. Press `Tab` to show or hide the HUD. The HUD starts hidden by default and
   scrolls when its contents outgrow the window.

### Headless Scene

1. Open `res://scenes/main/headless_runner.tscn`.
2. Configure `total_ticks`, `seed_override`, and `export_on_finish` in the inspector.
3. Run the scene. It executes the simulation, prints a summary, optionally exports telemetry, and quits automatically.

### Built-In Tests

Run the internal AI and simulation regression suites with:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --headless --path /Users/plasticlife/Documents/Projects/Animals res://scenes/tests/test_runner.tscn
```

The runner exits `0` when every check passes and `1` when any suite reports a
failure, so it can gate a script or a CI step directly.

Read that exit code from the Godot process itself. Piping the command anywhere -
`| tail`, `| grep`, `| tee` - makes `$?` the status of the last command in the
pipeline instead, which reports success even when tests fail:

```sh
# Wrong: $? belongs to tail, so a failing suite still looks like a pass.
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://scenes/tests/test_runner.tscn | tail -5; echo $?

# Right: redirect to a file, check the status, then read the output.
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . res://scenes/tests/test_runner.tscn > tests.log 2>&1; echo $?
```

## Controls

- `Tab`: toggle HUD visibility
- `Esc`: open or close the pause menu
- `F1`: open or close the help screen
- `F`: toggle follow on the selected agent
- `W`, `A`, `S`, `D`: pan camera
- Mouse wheel / trackpad pinch: zoom
- Mouse wheel over the debug panel: scroll the panel
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
- inspect the selected agent, including AI state, current action, decision reason, and utility scores
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
The metrics carry, per species, how many animals are at risk of starvation (`starvation_risk_<species>_count`) and of thirst (`thirst_risk_<species>_count`); death events carry the herd the animal belonged to (`data.group_id`, -1 for none).

## Configuration

- `data/config/world.json`
  World size, tick rate, terrain generation, navigation limits, water sources, spawn counts
- `data/config/species.json`
  Movement, perception, metabolism, feeding, reproduction, and aging for each species
- `data/config/balance.json`
  Shared thresholds, herd weights, hunt rules, carcass behavior, lifecycle rules, AI selector tuning, evaluator weights, stats sampling
- `data/config/debug.json`
  HUD defaults, UI refresh cadence, overlays, export directory, interactive LOD tuning
- `data/config/presets.json`
  Setup-screen option groups. Each option is a config patch deep-merged over the base
  configs, so adding a group here adds a row to the setup screen with no code change
- `data/config/help.json`
  Sections of the in-game help screen, as BBCode. Adding a section here adds a button
  to that screen with no code change

## Project Structure

```text
scenes/main/
  main.tscn
  headless_runner.tscn
scenes/tests/
  test_runner.tscn
scripts/core/
  config_loader.gd
  event_bus.gd
  headless_runner.gd
  simulation_manager.gd
scripts/agents/ai/
  agent_ai_state.gd
  agent_action.gd
  herbivore_ai.gd
  predator_ai.gd
  action_selector.gd
  evaluators/
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
scripts/tests/
  test_runner.gd
  *_tests.gd
data/config/
  balance.json
  debug.json
  species.json
  world.json
docs/
  ARCHITECTURE.md
```

## Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)

## Seasons and the Day/Night Cycle

The world runs a clock. A day is 120 seconds of simulated time, a season is one day, and a
year is four seasons - 480 seconds, or eight minutes at 1x and under a minute at 10x. It is
configured entirely in `data/config/world.json` under `climate`, and `"enabled": false` turns
the whole thing off.

Three things move with it, multiplied together from the season and the time of day:

| | winter | night |
| --- | --- | --- |
| grass regrowth | x0.40 | unchanged |
| metabolism | x1.15 | x0.85 |
| eyesight | x0.90 | x0.55 |

Eyesight means eyesight: a herbivore's predator detection and a predator's prey detection
shrink after dark, but the radii an animal searches for water and grass with do not. Those are
memory, not sight, and shrinking them would strand herds from water. Animals go blind at
night, not amnesiac.

Herbivores also bed down. `rest` gains a weight proportional to how deep the night is and
`explore` takes the matching penalty, so idle herds settle at dusk and move again at dawn -
while hunger still outscores both, so a hungry animal grazes in the dark. Predators get no
such bias, which is what makes the shrunken herbivore vision worth something.

The clock is a pure function of elapsed simulation time rather than accumulated state, so
saves carry it for free and loading resumes at the same season and hour.

## P0 performance verification

The benchmark scripts load the same preset bundle as the setup screen and write
machine-readable JSON. A headless LOD run represents the whole-map overview;
the LOD-off run is its full-fidelity control:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://scripts/dev/headless_benchmark.gd -- \
  topdown_kenney large balanced true /private/tmp/animals-lod.json 90 600 1337

/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://scripts/dev/headless_benchmark.gd -- \
  topdown_kenney large balanced false /private/tmp/animals-full.json 90 600 1337
```

The complete 3-size x 5-population x 2-style windowed matrix runs each case
three times at 1600x900 logical resolution and combines the reports:

```bash
scripts/dev/run_p0_matrix.sh /private/tmp/animals-p0-matrix 3 720 1337
```

The runner pauses two seconds between fresh Godot processes by default to limit
thermal carry-over (`COOLDOWN_SECONDS=0` disables it). `standard-acceptance.json`
is the release gate for balanced, few-predator, and small-herd presets;
`extreme-report.json` keeps the same uncensored timing and dropped-time fields for
large herds and many predators.

The worker soak enforces a minimum 30-minute measured interval after warmup:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . \
  --script res://scripts/dev/worker_soak.gd -- \
  topdown_kenney large balanced /private/tmp/animals-soak.json 1800 1337
```

The 30-minute soak and the complete 90-run matrix are release gates. Short P0
regression runs should be made without unrelated CPU-heavy jobs so the report
describes this build rather than external contention.

## P1 obstacle and depth verification

`ScenerySystem` owns the authoritative, seeded records for props. Trees and
stones use their base radius for collision; bushes remain passable but add move
cost and sight attenuation. Movement and interpolation sweep the animal body,
and `SceneSpriteBatch` packs props, living species and carcasses into one atlas
and sorts them by projected ground position.

The focused visual scene places animals before and behind solids, inside a bush,
and at the same depth as another species and a carcass. Run it once per style:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . \
  --script res://scripts/dev/p1_visual_audit.gd -- \
  topdown_kenney /private/tmp/animals-p1-visual 1337

/Applications/Godot.app/Contents/MacOS/Godot --path . \
  --script res://scripts/dev/p1_visual_audit.gd -- \
  isometric_craftpix /private/tmp/animals-p1-visual 1337
```

## P2 chase and escape verification

Fleeing herd animals rank seven headings against every visible predator, keep
their chosen route for the configured commitment window, and prefer reachable
positions that break sight. A predator that loses sight keeps `hunt_prey` as its
intent while its execution enters `search_last_seen`: it visits the last
confirmed position and up to four deterministic nearby points before recording
a lost-sight failure.

The headless behavior gate checks both flows and writes a machine-readable report:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
  --script res://scripts/dev/p2_behavior_audit.gd -- \
  /private/tmp/animals-p2-behavior.json 2201
```

The visual scene covers a fleeing animal behind a tree, an animal inside a bush,
and predators searching last-seen positions. Run it once per style:

```bash
/Applications/Godot.app/Contents/MacOS/Godot --path . \
  --script res://scripts/dev/p2_visual_audit.gd -- \
  topdown_kenney /private/tmp/animals-p2-visual 2301

/Applications/Godot.app/Contents/MacOS/Godot --path . \
  --script res://scripts/dev/p2_visual_audit.gd -- \
  isometric_craftpix /private/tmp/animals-p2-visual 2301
```

## Current Limitations

- Three species, and every animal of a species is identical: there is no genetics or individual
  variation.
- Terrain, carcass and shadow art are placeholders, and the isometric style has no real terrain art.
- There is no shelter logic or authored scenario editor.
- A run replays bit-identically only under the same LOD context. Which agents run full ticks
  follows the camera, and full ticks draw from the shared random stream. The dormant sleep, step
  and wake path draws nothing from it.
- Headless mode runs the same simulation systems, but with LOD enabled it substitutes a fixed
  `headless_active_radius` window at the world center for the camera rect. Everything outside that
  window degrades to coarse tiers and can go dormant, so headless benchmarks measure the LOD path
  rather than full-fidelity simulation. Set `lod.enabled` to `false` in `data/config/debug.json`
  for a full-fidelity run.
