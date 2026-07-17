# Controller support

FearMore's rebuilt client has a source-owned SDL3 controller path. It does not enable or copy EchoPatch's GPL game-module controller hooks. SDL is loaded dynamically from the validated `SDL3.dll` beside `FEAR.exe`; if loading or subsystem initialization fails, the client cleans up, retries at a bounded interval, and leaves keyboard and mouse active.

## One-click runtime

`Start-FearMore.ps1` acquires the official SDL 3.4.10 Windows x86 archive when the ignored local package is absent. `FearControllerPackage.psm1` pins the archive, DLL, license, entry set, size, SHA-256, x86 machine type, and PE32 header before any stage mutation. The rebuilt stage owns:

- `SDL3.dll`
- `.fearmore\licenses\SDL3-zlib.txt`

The package is [SDL 3.4.10 for Windows x86](https://github.com/libsdl-org/SDL/releases/tag/release-3.4.10), licensed under the zlib license. The archive and extracted runtime remain ignored local dependencies; the repository does not redistribute them. Schema-9 stage manifests record their exact identities. Reruns reject changed files, partial ownership, or an older manifest that already contains either path.

## Default mapping

SDL button names describe physical positions, so PlayStation and Nintendo face-button legends may differ.

| Input | Gameplay | Menu |
| --- | --- | --- |
| Left stick | Move / strafe | - |
| Right stick | Aim | - |
| South / A | Jump | Confirm |
| East / B | Duck | Back |
| West / X | Activate | - |
| North / Y | Reload | - |
| Right trigger | Fire | - |
| Left trigger | Focus / slow motion | - |
| Right shoulder | Melee | - |
| Left shoulder | Throw grenade | - |
| Left-stick click | Medkit | - |
| Right-stick click | Flashlight | - |
| D-pad up / down | Next weapon / next grenade | Navigate |
| D-pad left / right | Lean left / right | Navigate |
| Back / View | Mission objectives | - |
| Start / Menu | Pause / back | Back |

The controller feeds the existing `CBindMgr` command-state and analog-axis primitives, so callbacks, local-server commands, and multiplayer command semantics retain one path. Keyboard and mouse remain simultaneous. If the same physical device also appears through legacy LTInput/DirectInput, only those legacy gamepad bindings are suppressed while SDL input is active; disconnecting or disabling SDL restores the old controller path.

## In-game options

`Options > Controls > Joystick` remains available even when LTInput finds no legacy joystick. Its modern section owns:

- Controller enabled
- Aim sensitivity (`0.5` to `5.0`)
- Radial stick deadzone (`5%` to `40%`, default `18%`)
- Controller-only invert Y
- Vibration

Settings use the existing `settings.cfg` save path and are editable in game. A fresh Modern launcher profile enables the controller with conservative defaults; Stable, diagnostic, existing, and source-fallback profiles preserve stock/legacy gamepad input until the player opts in. Vibration remains off until the player enables it. Controller pitch compensates for F.E.A.R.'s later `MouseInvertY` transform, keeping mouse and controller inversion independent. Stick aim uses the inherited real-time delta path, not simulation time, so its speed is normalized across refresh rates.

Vibration reuses the two authored ClientFX motor channels. SDL rumble is bounded and expires unless refreshed; the original LTInput vibration call remains for legacy devices.

## Verification and remaining acceptance

Automated checks cover the source lifecycle, SDL export surface, radial deadzone, command mapping, all mapped command IDs fitting the resized command arrays, independent invert-Y truth table, legacy-controller double-input suppression, menu availability without an LTInput joystick, real-time aim scaling, authored rumble bridge, package corruption rejection, x86 PE identity, launcher seeding, stage ownership, and rollback inventory. Debug and Release module builds prove there is no SDL compile-time or link-time dependency.

`Test-FearPhysicalController.ps1` is the hardware-side acceptance probe. It validates the staged SDL identity, relaunches itself through the inbox x86 PowerShell host, opens the same SDL gamepad API used by the rebuilt client, samples every mapped axis and button, reports connection/activity, and can issue a bounded two-motor rumble request. For example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\runtime\Test-FearPhysicalController.ps1 `
  -StageRoot .\local-runtime\fearmore-launcher-modern `
  -SampleSeconds 15 -RumbleMilliseconds 300 -RequireInputActivity
```

Move both sticks and press at least one button during the sample. A successful SDL rumble call proves that the physical driver accepted the request; a person still needs to confirm that both motors were felt.

A physical-controller gameplay pass is still required before calling controller support live-accepted. That pass must cover hotplug/reconnect, menu navigation, every gameplay action, simultaneous keyboard/mouse use, focus loss, vibration opt-in, 60/120/144/240 FPS aim consistency, save/reload, and clean shutdown. Full remapping, controller glyph prompts, gyro, touchpad input, and multiple-controller selection remain explicit follow-up work rather than hidden partial features.
