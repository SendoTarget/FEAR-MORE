# AI timing correction

## Root cause

The LithTech server subtracts one frame time from an object's requested next-update delay. When the delay reaches zero it runs the object and the F.E.A.R. AI immediately schedules a fresh `0.01` second delay; any overshoot from the previous frame is discarded. The result is quantized rather than 100 Hz: at 120 FPS the AI runs at about 60 Hz, at 144 FPS about 72 Hz, and at 240 FPS about 80 Hz.

EchoPatch 4.2.1 corrects the retail binary by requesting an AI update every server frame. The source-owned correction follows the same scheduling principle without importing EchoPatch's retail addresses or hooks.

## Runtime control

`AIUpdateInterval` owns the normal active-AI schedule:

```text
AIUpdateInterval 0
```

Zero or a negative value follows every server frame and is the new default. A positive value requests that many seconds, clamped to the engine's next-frame sentinel. Set the retail value to roll back immediately while profiling:

```text
AIUpdateInterval 0.01
```

The normal scheduler does not replace intentional `UPDATE_NEVER` paths. The sever pipeline is the one explicit exception: it schedules one stock `0.01` second update when an AI becomes severed so its first ragdoll update remains stable, after which the normal frame-synced schedule resumes. The existing GOAP goals, actions, planner relevance checks, authored navigation, squad logic, sensor database rates, and event-driven replanning remain the owners of AI behavior.

## Source-owned profiler

The rebuilt `GameServer` has a focused profiler because the inherited performance-monitor path is disabled in `_FINAL` builds and depends on a separate `performancemon.dll` that is not part of this project. Profiling is off by default and does not alter AI scheduling or decisions.

Enable capture:

```text
AIProfileEnabled 1
```

For automated Release acceptance, pass `+AIProfileEnabled 1` and the desired `+AIUpdateInterval` value on the staged single-player command line. The existing local-only runtime-control bridge forwards those numeric controls to the authoritative in-process server after the world loads; hosted and remote multiplayer clients cannot use it. Automated captures use the fixed `AIProfile.csv` name inside that stage's isolated `UserDirectory`, so each FPS stage remains independent.

Set `AIProfileEnabled 0` or exit cleanly to release the output stream before consuming the file. A developer server console may set `AIProfileFile` before enabling capture to choose another user-directory-relative name; changing it while enabled starts a new file. The first row of a capture has a zero `frame_delta_ms` because there is no preceding captured frame.

Each authoritative server frame produces one CSV row with:

- real and simulation timestamps, real frame-to-frame delta, engine frame delta, and total server work from `PreUpdate` through `PostUpdate`;
- count and inclusive elapsed time for `CAI::Update` calls;
- count and inclusive elapsed time for the global AI manager, sensor manager, goal selection, and navigation owners.

`frame_delta_ms`, `server_frame_ms`, and every profiled subsystem duration use the existing `LTTimeUtils::GetPrecisionTime` monotonic clock. On Win32 that primitive is backed by `QueryPerformanceCounter`; it is independent of simulation time, slow motion, and the retail engine's millisecond-resolution `GetRealTime` value. `real_time_s`, `sim_time_s`, and `engine_frame_dt_ms` remain engine timestamps for correlation. Captures made before the precision-clock correction quantize short work to zero and must be regenerated for CPU attribution.

The subsystem timers are nested: do not add them together. Use `server_frame_ms` for total server-frame cost, `ai_update_ms / ai_update_count` for average object-update cost, and the individual owner columns to locate changes. The profiler deliberately records no goal, awareness, target, weapon, or navigation-result events in this first slice.

Summarize one or more captures without modifying them. The explicit process-level bypass permits the checked-in script on Windows machines whose current shell uses a restricted execution policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '.\tools\runtime\Get-FearAiProfileSummary.ps1' -Path @('local-runtime\fearmore-ai-profile-60\UserDirectory\AIProfile.csv','local-runtime\fearmore-ai-profile-120\UserDirectory\AIProfile.csv','local-runtime\fearmore-ai-profile-144\UserDirectory\AIProfile.csv','local-runtime\fearmore-ai-profile-240\UserDirectory\AIProfile.csv') -WarmupSeconds 5 | Format-Table -AutoSize"
```

The dependency-free summarizer parses numeric fields with invariant culture and returns one reusable PowerShell object per file. It reports stable duration, achieved FPS, FPS and frame-time percentiles, server-frame percentiles, the fraction of stable frames with at least one AI update, and AI/sensor/goal/navigation calls per second. Percentiles use linear interpolation over sorted samples. Zero-length frame intervals are excluded; malformed, negative, incomplete, or too-short captures fail with their file and CSV line.

For an authored combat window, use the stricter read-only acceptance analyzer:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime\Get-FearAiEncounterAcceptance.ps1 `
  -Path .\local-runtime\fearmore-ai-d3d11-120\UserDirectory\AIProfile.csv `
  -WarmupSeconds 45 -EncounterSeconds 30 -TargetFps 120
```

It keeps one contiguous simulated window, including any zero-update frames, and fails closed on an early pause, load, death stop, or truncated capture. Its dynamic-population mode requires active AI and sensor work on every simulated frame, one AI-manager call per frame, goal-selection calls matching AI updates, navigation calls at least matching AI updates, and zero AI starvation. Simulation timestamps must advance on every frame, agree with that frame's engine delta within the larger of 0.1 ms or five percent, and keep a cumulative timestamp/engine ratio between 0.995 and 1.005; a frozen, regressing, or discontinuously jumping clock therefore cannot pass on engine deltas alone. `SensorMatchesAIInvariant` remains a diagnostic because an authored population transition can distribute sensor and AI-owner work across adjacent frames; it is not one of the enforced dynamic-population gates. Pass `-ExpectedAiCount` only for a deliberately fixed-population encounter.

`-TargetFps` enables a separate bounded frame-rate gate using `-FpsTolerancePercent`, which defaults to five percent. The result reports the calculated minimum/maximum band, invariant-only `InvariantStatus`, and combined `AcceptanceStatus`; omitting `-TargetFps` preserves invariant-only acceptance for existing analysis callers. This separation prevents a scheduler-correct but materially under- or over-target capture from being reported as a capped-FPS acceptance pass.

## 2026-07-14 capped baseline

Fresh precision-timer captures used the rebuilt Release modules, native D3D9, the engine-only EchoPatch cap, `AIUpdateInterval 0`, and `Worlds\Release\FEAR_SP_Demo`. Five seconds were discarded from each capture. The scene's active-AI population changes as its scripting progresses, so AI calls per second are workload context rather than a normalized cross-cap score.

| Requested cap | Achieved FPS | Stable seconds | Frame P95 / P99 (ms) | Server P95 / P99 (ms) | AI calls/s | AI-update CPU ms/s |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 60 | 60.000 | 41.167 | 16.675 / 16.695 | 0.551 / 1.168 | 240.001 | 1.198 |
| 120 | 119.440 | 56.991 | 8.343 / 8.384 | 0.431 / 0.965 | 427.155 | 1.939 |
| 144 | 143.210 | 37.253 | 6.980 / 7.265 | 0.476 / 1.077 | 442.274 | 1.952 |
| 240 | 182.981 | 27.741 | 6.662 / 7.330 | 0.540 / 1.087 | 583.261 | 2.640 |

The 60, 120, and 144 caps hold closely. The requested 240 cap does not: this run plateaus near 183 FPS while the inclusive AI-update scopes consume only 2.64 milliseconds per second of wall time, and the total authoritative server frame remains 0.540 ms at P95. This rules out the measured AI update loop as the primary limiter in this scene; renderer/client work and presentation pacing remain the next profiling owners. These numbers are a diagnostic baseline, not an encounter-quality acceptance pass.

## 2026-07-16 D3D11 ATC_Roof encounter matrix

The final post-build gate used the rebuilt Release modules, dgVoodoo2 D3D11, engine-only EchoPatch, `AIUpdateInterval 0`, and `Worlds\Release\ATC_Roof`. Each row is one contiguous 30-second simulated window selected after a 20-second wall-clock warmup; zero-update frames would remain visible rather than being cropped away. The 60, 120, and 144 runs used the intended 3440 x 1440 ultrawide gameplay output. The 240-cap row used 640 x 480 strictly to remove the renderer bottleneck and exercise the authoritative scheduler near the requested cap. Every live run continued through rooftop combat until enemies killed the unattended player, including the 144 FPS run whose bounded profiler window begins during the insertion sequence.

| Requested cap | Accepted FPS band | Output | Achieved FPS | Simulation / wall | AI-active frames | Longest starvation | Acceptance |
| ---: | :--- | :--- | ---: | ---: | ---: | ---: | :--- |
| 60 | 57.0-63.0 | 3440 x 1440 | 60.000 | 0.999982 | 100% | 0 frames | PASS |
| 120 | 114.0-126.0 | 3440 x 1440 | 119.909 | 1.000001 | 100% | 0 frames | PASS |
| 144 | 136.8-151.2 | 3440 x 1440 | 143.901 | 1.000006 | 100% | 0 frames | PASS |
| 240 | 228.0-252.0 | 640 x 480 diagnostic | 237.541 | 0.999992 | 100% | 0 frames | PASS |

The 240 diagnostic achieved 99.0% of the requested cap, inside the five-percent acceptance tolerance. A prior 3440 x 1440 D3D11 attempt plateaued near 185 FPS, so it does not prove 240 FPS at ultrawide resolution; 640 x 480 is neither a recommended gameplay setting nor graphics acceptance evidence. Across the four live runs, enemies reacted, fired, moved between authored positions and cover, progressed through the encounter, and killed the unattended player without a freeze or spin. Those observations are manual behavior evidence. The analyzer proves scheduler/owner continuity and pacing, not the semantic correctness of every possible stimulus, goal choice, navigation path, authored encounter, or intermediate frame rate.

### Bidirectional cross-cap save/load

A fresh, dedicated 640 x 480 D3D11 stage created a quick save at 60 FPS during visible live fire. `Quick.sav` and `Save1001.ini` remained byte-for-byte unchanged while the same owned stage was restaged to 240 FPS. Loading that 60 FPS save resumed the fight. Reanalysis with `Get-FearAiEncounterAcceptance.ps1 -WarmupSeconds 1 -EncounterSeconds 30` (the retained post-load capture is too short for the analyzer's five-second default warmup) reproduces a 30.001-second window at 229.427 FPS, a 1.000005 simulation/wall ratio, 100% AI-active frames, zero starvation, and PASS for the dynamic invariants.

The loaded game was then resaved at 240 FPS. The changed `Quick.sav` hash and its companion files survived the restage back to 60 FPS, and loading it again resumed active AI. The reverse 30-second window achieved 60.000 FPS, a 1.000015 simulation/wall ratio, 100% AI-active frames, zero starvation, and PASS. The original 60 FPS source-save window reported the same 60.000 FPS and 1.000015 pacing result. The unattended player died about 35 seconds after the reverse load, which is consistent with live enemy activity rather than a failed load.

The developer god-mode toggle is not a reliable cross-load survival oracle: the player object serializes its god-mode state while the client cheat manager's active toggle is transient, so issuing the toggle again after load can turn protection off. Cross-cap acceptance therefore uses resumed combat, preserved save hashes, and the authoritative profiler rather than player survival alone.

## Related correctness fixes

- The flame-pot sensor now initializes its entry timestamp and waits for the intended two-second grace period before invalidating an AI position. Its old comparison was immediately true. Loading an old save restarts the grace period without adding fields to the sensor's save layout.
- A severed AI receives that one stock `0.01` second update delay before the normal frame-synced schedule resumes, matching EchoPatch's protection against an unstable initial ragdoll update.
- `CAISensorMgr::Save` now writes the existing processed-stimulus count followed by each actual `EnumAIStimulusID`. The inherited loop wrote the list size once per element even though `Load` consumes stimulus IDs. This restores serializer symmetry without changing the wire layout or adding a save-version field; older malformed saves remain readable, while new saves preserve the intended IDs.

`Test-AiTimingSource.ps1` protects the frame-synced default and positive-interval rollback, intentional `UPDATE_NEVER` path, AI update order, sever wakeup, profiler owners and wiring, processed-stimulus serializer symmetry, and flame-pot compatibility without launching the game. `Test-FearAiEncounterAcceptance.ps1` protects the encounter analyzer's bounded crop, fixed and dynamic population rules, starvation visibility, owner invariants, target-FPS pass plus below/above-band rejection, frozen/jumped simulation-timestamp rejection, percentiles, malformed/short-capture rejection, and read-only input contract using synthetic profiles.

## Runtime acceptance pass

The post-build ATC_Roof D3D11 matrix now covers representative supported caps at 60, 120, 144, and a true near-240 diagnostic, plus the earlier bidirectional 60-to-240 and 240-to-60 quick-save restoration. It is not a literal proof of every possible frame rate or every campaign encounter. The source and synthetic verification scripts cover scheduler, ownership, serialization, and analyzer invariants.

Two narrower follow-ups remain outside that completed matrix:

1. Repeat the encounter at `AIUpdateInterval 0.01` as the retail-scheduling control.
2. Exercise flame-pot navigation from a new game and a restored save; confirm the AI remains in the link for roughly two seconds before position invalidation.

The remaining risk is CPU cost from frame-synced state and navigation bookkeeping at very high frame rates. If profiling shows unacceptable cost, tune a measured positive interval rather than replacing or simplifying the planner.
