# Re-audit after P0-P3 and the phase 0 port - 2026-09-15

Branch `feature/phase0-on-p3` at `0e1e7a6`: the P0-P3 checkpoint (`50cd0a7`), the
water fixture fix (`3083a11`) and phase 0 (`0e1e7a6`). The earlier audit was made
against `d98f931`, before P0-P3; this re-checks its findings on the current code,
re-runs the ecology audit and repeats the performance measurements.

## Method

- Code: the 16 earlier AI and ecology findings re-read on the current tree. The
  new defects below marked **verified** were confirmed by reading the cited lines;
  none was reproduced in a running game.
- Ecology: `scripts/dev/ecology_audit.gd` on the default preset.
- Performance: `scripts/dev/headless_benchmark.gd`, large balanced preset, seed 1337.
- Automated suite on this branch: 540 checks, 0 failures.

## Earlier findings on the current code

None of the 16 findings is fully fixed. Most P0-P3 ecology changes were
configuration and gating; the code behind findings 1, 3, 4, 7, 14 and 15 did not
change since `d98f931`.

| # | Finding | Now | Evidence |
| --- | --- | --- | --- |
| 1 | Predator takes an 84-meat bite at the kill and walks away from the carcass | still true | `predator.gd:369-398`, gorge rule `agent_base.gd:612-617`; +100.8 energy clears the breeding threshold of 70, leaving 156 of 240 meat |
| 2 | Breeding pre-empts other actions | partial | predator meal now safe (`predator.gd:58-61`); a partner's birth still clears targets mid-meal (`457-459`); herbivores still leave grass and water to breed (`herbivore.gd:90`); higher-id partner still freezes |
| 3 | Gorge rule lets a fed predator keep hunting | changed, latent | code unchanged (`predator.gd:831-832`); current numbers keep it from triggering |
| 4 | Scavenger outruns the predator that hunts it | still true | sprint 132 vs 128 (`species.json:175`, `:92`) |
| 5 | Individual radial flight, dead panic utility path | partial | escape target now weighs safety, cover and route (`world_state.gd:1501-1617`) with a 12-tick commitment; no neighbour or herd term (`herbivore.gd:262-280`); panic still hard-coded (`herbivore.gd:62-68`) |
| 6 | 2 s threat memory flicker | partial | still 2.0 s; softened by the escape commitment |
| 7 | `join_herd` is really `explore` | still true | regroup only below hunger 12 (`herbivore.gd:299`); inverted proximity term (`herbivore_ai.gd:161`) |
| 8 | Newborns are full adults | still true (live path) | full energy at spawn (`agent_base.gd:104`); juveniles only drawn smaller |
| 9 | Night perception x0.55 | still true | herbivore warning gap 28 units at night vs 82 by day |
| 10 | Absolute rest thresholds | partial | predator has its own 40/60 of 150; herbivore and scavenger still 26/34 |
| 11 | No carrying capacity | changed | births now capped at starting count x multiplier (420 / 48 / 126); grass still hundreds of times beyond consumption |
| 12 | Predator energy budget | changed | kill bite 67% of the bar; failed 14 s chase up to 47% |
| 13 | Dormant predation type I, needs averaged | partial | cohort ages kept during dormant steps; kills still predators x prey without ceiling; needs still averaged |
| 14 | Pair cohesion aims at mate + offspring centroid | still true | `predator.gd:900-913` |
| 15 | Sector grass fallback sends a sector to one cell | still true (fallback only) | `world_state.gd:2560-2611` |
| 16 | No variation, fixed groups, infinite water | still true | offspring inherit `group_id`; drinking never depletes a source |

## New defects

Verified by reading the code:

1. **Predator breeding skips its own cooldown.** The normal entry checks
   `can_reproduce()` (`predator.gd:91`). While the predator is still in state
   `reproduce` after a birth, `_continue_engaged_flow()` calls `_attempt_reproduce()`
   again without that check (`predator.gd:464`); only the candidate mate is checked
   (`predator.gd:738-745`). A parent can pair with another ready predator and
   breed again, rewriting both pairings.
2. **Waking a sector resets every animal's age to the group mean.**
   `_materialize_dormant_records()` sets `age` from `avg_age` unconditionally
   (`world_state.gd:3905`, called from `_wake_sector()`). Juveniles wake as adults
   and elders wake younger, each time the camera moves.
3. **Dormant predators hunt from a different hunger floor.** The dormant goal uses
   `graze_hunger_floor` 12 (`world_state.gd:3161`, `:3208`); live predators use
   `feed_hunger_floor` 28. `simulation_tests.gd:697` calls 12 the feed floor and pins
   the mismatch.
4. **Breeding creates energy.** State `reproduce` recovers energy like resting
   (`agent_base.gd:278`), and a newborn starts at full energy (`agent_base.gd:104`)
   while its parents pay only `birth_energy_cost`.
5. **Founders age in lockstep.** `_stagger_initial_agent()` varies hunger and thirst
   but not age (`world_state.gd:1904-1911`), so the whole starting population
   reaches `old_age_start` together.

Reported by the code review and not independently verified: the birth cap ignores
map size; dormant deaths remove the oldest records first; dormant kills leave no
carcass for scavengers; the last-seen search calls `local_path` outside the path
budget; scavenger hunger is too slow for one to starve within its lifespan.

## Ecology

`ecology_audit.gd`, default preset (large map, balanced mix), seed 3.

### One year with LOD

480 simulated seconds, stopped on duration, exit code 0.

| Species | Start | End of year | Minimum | Maximum | Birth cap |
| --- | ---: | ---: | ---: | ---: | ---: |
| herbivore | 240 | 418 | 240 | 420 | 420 |
| predator | 24 | 48 | 24 | 48 | 48 |
| scavenger | 72 | 126 | 72 | 126 | 126 |

Population history, one row per simulated minute:

| Time, s | Herbivore | Predator | Scavenger | Grass biomass | Carcass meat |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 240 | 24 | 72 | 6.84 M | 4947 |
| 60 | 285 | 34 | 77 | 9.10 M | 967 |
| 120 | 327 | 34 | 88 | 9.10 M | 125 |
| 180 | 376 | 35 | 119 | 9.10 M | 387 |
| 240 | 420 | 37 | 126 | 9.09 M | 308 |
| 300 | 420 | 38 | 126 | 9.09 M | 589 |
| 360 | 420 | 39 | 126 | 9.08 M | 2303 |
| 420 | 420 | 42 | 126 | 9.08 M | 996 |
| 480 | 418 | 48 | 126 | 9.09 M | 1861 |

Births and deaths over the year:

| Species | Births | Deaths | Starvation | Thirst | Predation | Old age |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| herbivore | 213 | 35 | 11 | 1 | 23 (7 dormant) | 0 |
| predator | 25 | 1 | 1 | 0 | 0 | 0 |
| scavenger | 77 | 23 | 0 | 12 (11 dormant) | 11 (1 dormant) | 0 |

Hunting: 82 hunts started, 56 attack attempts, 34 kills, 58 failed hunts (30 misses,
27 on low energy, 1 lost sight), 11 last-seen searches with 3 reacquisitions.
Carcasses: 40 spawned, 37 expired.

What this shows:

- **The birth cap is the only population control.** Herbivores and scavengers reach
  their cap at about 240 s and stay on it; predators reach theirs at the end of the
  year. No predator-prey oscillation appears, because every loss below the cap is
  refilled by a birth.
- **Food does not limit anyone.** Grass biomass rises from 6.84 M to 9.10 M in the
  first minute and then stays flat while 420 herbivores graze.
- **Predation is marginal.** 34 kills in a year for up to 48 predators is fewer
  than one kill per predator. Only one predator died, although predators logged
  2,211 animal-seconds at starvation risk.
- **Carcasses mostly rot.** 37 of 40 expired, which is consistent with the scavenger
  niche not being food-limited.
- **Dormant scavengers die of thirst.** 11 of the 12 scavenger thirst deaths happened
  in sleeping sectors. The full-fidelity run below checks whether this is a
  dormant-path divergence.

### One year without LOD

Same seed, same 480 seconds, every animal at full fidelity. The end state matches
the LOD run; what happens along the way does not.

| One year, seed 3 | Without LOD | With LOD |
| --- | ---: | ---: |
| Final herbivore / predator / scavenger | 419 / 48 / 126 | 418 / 48 / 126 |
| Herbivore births | 289 | 213 |
| Herbivore deaths | 110 | 35 |
| of which thirst | 41 | 1 |
| of which starvation | 34 | 11 |
| of which predation | 35 | 23 |
| Scavenger deaths by thirst | 0 | 12 (11 dormant) |
| Herbivore starvation risk, animal-seconds | 1,963 | 351 |
| Scavenger starvation risk, animal-seconds | 3,292 | 0 |
| Kills | 40 | 34 |
| Carcasses spawned / expired | 121 / 141 | 40 / 37 |

What this shows:

- **Sleeping sectors hide herbivore mortality.** With LOD the year has a third of the
  herbivore deaths, almost no thirst deaths and a sixth of the starvation risk.
- **Sleeping sectors kill scavengers that full fidelity keeps alive.** Every
  scavenger thirst death in the LOD run happened or began in a dormant sector; the
  full-fidelity run has none.
- **The birth cap masks both.** Final counts agree because both runs sit on the same
  cap; any population-level check that compares only end counts will pass.

### Three years with LOD

1,440 simulated seconds, stopped on duration, exit code 0.

| Time, s | Herbivore | Predator | Scavenger | Predators at starvation risk | Grass biomass |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 240 | 24 | 72 | 0 | 6.84 M |
| 240 | 420 | 36 | 126 | 2 | 9.09 M |
| 480 | 420 | 45 | 126 | 4 | 9.09 M |
| 720 | 420 | 48 | 126 | 7 | 9.09 M |
| 960 | 420 | 43 | 124 | 1 | 9.09 M |
| 1080 | 420 | 48 | 117 | 1 | 9.10 M |
| 1200 | 396 | 48 | 126 | 23 | 9.10 M |
| 1260 | 405 | 48 | 125 | 23 | 9.10 M |
| 1320 | 420 | 48 | 126 | 23 | 9.09 M |
| 1440 | 420 | 46 | 126 | 20 | 9.10 M |

| Species | Births | Deaths | Starvation | Thirst | Predation | Old age |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| herbivore | 625 | 445 | 19 | 61 (35 dormant) | 90 (18 dormant) | 275 (226 dormant) |
| predator | 42 | 20 | 8 (5 dormant) | 2 | 0 | 10 |
| scavenger | 220 | 166 | 0 | 85 (55 dormant) | 60 (4 dormant) | 21 (1 dormant) |

Hunting over three years: 327 hunts started, 150 kills, 241 failed hunts (133 on low
energy, 105 misses, 2 timeouts), 30 last-seen searches with 25 reacquisitions.
Carcasses: 287 spawned, 188 expired.

What this shows:

- **Three years look like one flat line.** Herbivores sit on the 420 cap from 240 s to
  the end, except one dip.
- **The dip is the founders dying together.** 275 herbivore old-age deaths, 226 of
  them dormant, cluster where the starting cohort passes `old_age_start` 1000 s and
  `max_age` 1200 s. The herd drops to 396 at 1200 s and is back on the cap two
  minutes later.
- **Predation stays marginal.** 150 kills in three years for 46-48 predators is about
  one kill per predator per year. More than half of the failed hunts ended on low
  energy.
- **Predators starve slowly without dying.** From 1200 s, 20-23 of 48 predators are at
  starvation risk, yet only 8 predators starved in three years.
- **Grass never matters.** Biomass stays at 9.1 M for the whole run.

## Performance

The first attempt ran on a heavily loaded machine and produced no valid numbers. The
machine later went quiet (load average 3.6-8.5 on 8 cores), and the measurements
below come from that window. The machine was still not idle, so treat them as
indicative rather than as release gates.

### The loaded attempt, kept as an example of CPU starvation

- **Machine state.** MacBook Air M2 (fanless, 16 GB), shared with other sessions: a
  Gradle build, a TypeScript build and a macOS virtual machine. Load average ran
  between 13 and 120, and `kernel_task` held 112-118% CPU, which on a fanless Mac
  usually means thermal throttling. `pmset -g therm` recorded no warning, so
  throttling is likely rather than confirmed.
- **Result.** LOD on: capacity 0.118x, tick p95 1,737 ms, worst tick 12.8 s. That tick
  ran 9 full agent ticks and almost no path or grass work, so its time was spent
  waiting for a CPU. The same benchmark later took 13 s instead of 468 s.

### Headless benchmark on the quieter machine

`headless_benchmark.gd`, large balanced preset, seed 1337, 90 warmup and 600 measured
ticks, this branch.

| Mode | Capacity | Tick p50 | Tick p95 | Tick p99 | Worst tick |
| --- | ---: | ---: | ---: | ---: | ---: |
| LOD, overview | 4.24x | 12.4 ms | 22.3 ms | 25.5 ms | 32.9 ms |
| full fidelity | 0.91x | 58.9 ms | 78.8 ms | 91.6 ms | 105.9 ms |

The LOD run beats the 2.58x recorded in the P2 report of 2026-09-12. Its global path
queue peaked at 6 and ended at 0; the local queue stayed at 0. The full-fidelity run
is still just under real time on the default map, with agent ticks taking 55 ms of a
59 ms tick.

CPU time from the ecology runs agrees on the ratio: 1.66 CPU-seconds per simulated
second with LOD and 3.90 without, about 2.4x apart. Those runs overlapped the loaded
period, so their absolute values overstate the cost.

### Windowed worker: phase 0 port against the P0-P3 checkpoint

`visual_audit.gd`, large balanced preset, speed 1x, seed 1337, 180 warmup and 720
measured frames per view. Three runs per build, alternating port and checkpoint.

| View | Metric | Port (3 runs) | Checkpoint `50cd0a7` (3 runs) |
| --- | --- | --- | --- |
| herd | measured speed | 0.96 / 0.90 / 0.79x | 0.50 / 0.71 / 0.73x |
| herd | dropped simulation | 0.69 / 1.03 / 1.51 s | 3.52 / 1.98 / 1.67 s |
| herd | tick p50 | 48 / 51 / 54 ms | 83 / 57 / 60 ms |
| pan | measured speed | 1.01 / 1.02 / 1.06x | 0.94 / 0.82 / 1.01x |
| pan | dropped simulation | 0 / 0 / 0 s | 0.91 / 1.40 / 0.26 s |
| overview | tick p50 | 9 / 9 / 10 ms | 20 / 22 / 20 ms |
| overview | worker cycle p50 | 18 / 17 / 20 ms | 31 / 33 / 30 ms |

What this shows:

- **The port is faster in all three views.** It keeps up in pan and overview and
  loses about half as much simulation time with the camera on a herd.
- **The clearest signal is the overview tick,** consistently about half on the port
  with little spread. Phase 0 barely touched `world.step()`, so the likely cause is
  the persistent worker thread staying warm instead of a new thread per tick. That
  mechanism is a hypothesis and was not checked.
- **The herd view still runs below real time on both builds.**

Limits of this comparison:

- The window did not render: every saved screenshot is fully transparent, so frame
  times exclude drawing.
- The machine carried load average 4.4-7.6 during these runs.
- The two builds do not simulate identical worlds, because the port keeps the dormant
  path off the shared random stream.

To measure release gates on an idle machine: `scripts/dev/run_p0_matrix.sh` for the
full matrix and `scripts/dev/worker_soak.gd` for the 30-minute worker soak.

## Behaviour audit

`scripts/dev/p2_behavior_audit.gd`, seed 2201: passed, with the same numbers as the
P2 report. The escape target raised the nearest-predator distance from 71.55 to
147.51 units and broke both lines of sight; the lost-sight fixture recorded one
search start, one expiry and one failure.

## Conclusions

Ranked by how much they hurt believability:

1. **A global birth cap is the only population control.** Populations sit on the cap
   for most of three years, show no predator-prey cycles, and grass never limits
   anything. Replace the cap with limits that come from food and habitat.
2. **Dormant sectors diverge from full fidelity in both directions.** They hide two
   thirds of herbivore deaths and almost all thirst deaths, kill scavengers by thirst,
   reset ages on wake and hunt from a different hunger floor. Add a test that runs
   the same seed with and without LOD and compares deaths by cause, not only end
   counts.
3. **The predator economy does not work.** About one kill per predator per year, most
   failed hunts end on low energy, carcasses mostly rot, and starving predators do
   not die.
4. **The founding cohort ages in lockstep,** producing a single mass die-off at
   1000-1200 s.
5. **Breeding defects:** the predator cooldown bypass, energy recovered while
   breeding, and full-energy newborns.
6. **Flight, herding and night** are unchanged from the earlier audit apart from the
   P2 escape target.
7. **The herd view is still below real time.** On a quieter machine the port ran the
   herd view at 0.79-0.96x, ahead of the checkpoint's 0.50-0.73x, and headless LOD
   has 4.24x headroom. The full P0 matrix and the 30-minute worker soak still need an
   idle machine before release.
