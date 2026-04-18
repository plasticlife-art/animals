# Feature Backlog

## Ecosystem Simulation

- Seasons that change grass regrowth, water availability, reproduction, and mortality
- Dynamic weather modifiers such as drought, rain, heat, and cold waves
- Additional biome interactions, including temporary flooding and recovering drought zones
- Water sources that shrink, refill, or migrate over time
- Local habitat degradation from overgrazing and recovery after pressure drops

## Animal Behavior

- Additional species roles: heavy grazers, fast herd animals, pack predators, scavengers
- Juvenile-specific behavior and parent protection logic
- Dominance hierarchies and role-based herd behavior
- Better long-term memory for safe routes, risky zones, and productive feeding grounds
- Cooperative hunting and flanking behavior for predators
- Stress / panic systems that affect regrouping, reproduction, and energy recovery

## Evolution and Population Dynamics

- Genetic traits inherited across generations
- Trait mutation and natural selection tracking
- Lineage and ancestry visualization in the inspector
- Trait-level telemetry across multiple seeds
- Population bottleneck and extinction-risk detection

## UX and Tooling

- Scenario editor for water, terrain, obstacles, and spawn presets
- Runtime balance editor without restarting the scene
- Timeline bookmarks and quick jump to important events
- Replay snapshots of key ecosystem transitions
- Cause explorer for population crashes and prey/predator imbalance
- Better export browser inside the debug UI

## Analytics

- Batch runner for multi-seed experiments
- Preset experiment suites such as drought, predator surge, low-water map
- Comparative summary reports across runs
- More charts for carcasses, biomass by biome, blocked movement pressure, and LOD distribution
- Automated anomaly detection for boom/bust cycles and near-extinction events

## Performance

- Group-level LOD as a follow-up to the current individual LOD
- Async or chunked initialization for very large worlds
- Pathfinding budget controls and path cache diagnostics
- Separate light, standard, and stress presets for profiling
- In-engine profiler panel summarizing AI, navigation, and resource step cost

## Engineering

- Save/load of full world state
- Deterministic replay from seed plus input log
- Automated regression tests for world invariants and telemetry schema
- Golden run comparisons for headless experiments
- Config validation and schema checks at startup
