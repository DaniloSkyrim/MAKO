# Armada, DroidDeck, and native AArch64 support

## Current release status

Native host architecture is a package property. MAKO builds two package lines from the same source:

- **x86_64 packages** (published releases) carry 64-bit and 32-bit Vulkan client payloads for x86_64 hosts.
- **AArch64 tester packages** are compiled natively on arm64 by `.github/workflows/aarch64.yml` or `pnpm --dir plugin run package:local-engine --host-arch aarch64` on an AArch64 machine. They carry one 64-bit AArch64 payload, include the vkBasalt fork compiled from its pinned source commit, and omit Flatpak runtime extensions and the native Remote Play helper. No published release contains an AArch64 Renderer yet.

AArch64 Vulkan clients are 64-bit only: Steam's ARM Proton runs games through wine-arm64, and x86 Linux games running under FEX reach the native loader through FEX's Vulkan thunks. A 32-bit AArch64 payload therefore has no consumer.

| Situation | Current behavior |
| --- | --- |
| Native x86_64 host with an x86_64 package | Installation and activation proceed normally. |
| DroidDeck with an AArch64 package, including Decky running through `droiddeck-fex` | `/usr/local/bin/droiddeck-session` identifies the native AArch64 host even when Python and `uname` report x86_64. Installation, native activation, and AArch64 external-layer identities proceed. |
| Other native AArch64 host with an AArch64 package | The first AArch64 ELF among Decky's process ancestors (or PID 1 when readable) identifies the host. Installation and native activation proceed. |
| Armada, with any package | The root-owned `device-env` marker identifies the host. Installation is disabled, and the wrapper hands games to `armada-game-launch` exactly once without MAKO. |
| AArch64 host with an x86_64 package, or x86_64 host with an AArch64 package | Installation is disabled with a message naming the package to install. The wrapper never exposes the foreign Renderer. |
| Flatpak launch with an AArch64 Renderer | The wrapper prints a one-line notice and continues without MAKO. Flatpak activation RPCs report the host as unsupported. |
| Turnip on Android KGSL (DroidDeck), which cannot export timeline semaphores | Frame Generation synchronizes the game and backend devices through the Renderer's process-local timeline relay instead of an exported timeline. Spatial scaling is unaffected. |
| Native Remote Play with an AArch64 Renderer | The streaming-client override reports that the native x86_64 Steam streaming client is unavailable and changes nothing. |
| Wrapper generated for another Renderer architecture | Its compatibility marker no longer matches, so startup regenerates it from canonical state before parsing profiles or exporting Vulkan settings. |

## Compatibility boundary

```text
package.json bundled_renderer.host_architectures  (exactly one ISA)
        |
        +-- native host detection (Armada marker, DroidDeck marker,
        |   AArch64 process ancestor, PID 1 ELF)
        |       |
        |       +-- matching ISA (not Armada): installation, migrations,
        |       |   ISA-specific Gamescope WSI / MangoHud / Steam overlay identities
        |       |
        |       +-- otherwise: no install, early wrapper passthrough,
        |                      remove persisted MAKO Flatpak activation
        |
        +-- payload share/mako-render/host-architecture record and ELF
        |   e_machine of every native binary must equal the package ISA
        |
        +-- archive architectures: 64/32-bit client payloads (x86_64 only)
```

The package declares its ISA once. `renderer_package.py` validates it, the Renderer payload records it in `share/mako-render/host-architecture`, and installation refuses an archive whose record or ELF machine disagrees, before any file is replaced. Legacy x86_64 archives without the record remain installable.

## External layer identities

`constants.host_layer_identities()` owns the per-ISA names that the wrapper and installation use:

| Layer | x86_64 | AArch64 |
| --- | --- | --- |
| Gamescope WSI | `VK_LAYER_FROG_gamescope_wsi_x86_64`, `VkLayer_FROG_gamescope_wsi.x86_64.json` | `VK_LAYER_FROG_gamescope_wsi_aarch64`, `VkLayer_FROG_gamescope_wsi.aarch64.json` |
| MangoHud | `VK_LAYER_MANGOHUD_overlay_x86_64` and `_x86` | `VK_LAYER_MANGOHUD_overlay_aarch64` (64-bit only) |
| Steam overlay | Filename allowlist for the x86 client manifests | Any user implicit manifest that declares `VK_LAYER_VALVE_steam_overlay_64`, excluding the x86 filenames |

Staging an ISA's layers removes the other ISA's staged copies from the same private directory.

## Safety constraints

`host_environment.py` owns native-host detection for installation, startup, wrapper generation, Flatpak activation, backend status, and the install button. Do not add a second Armada or DroidDeck detector or rely only on `platform.machine()`, which may describe a translated process rather than the host.

The wrapper checks compatibility before setting MAKO, Vulkan, WSI/HDR, diagnostic, profile, or conflict-guard variables. Staging remains deterministic and user-owned rather than crossing a translated `/tmp` boundary.

MAKO must not rewrite FEX's global `Config.json`, install an always-on system layer, or download an opaque AArch64 binary. Every AArch64 binary, including vkBasalt, is compiled from reviewable source on a native arm64 builder.

## Requirements for enabling Armada and publishing AArch64 releases

DroidDeck tester packages are enabled for real-hardware qualification. Armada remains disabled, and no AArch64 package is published, until one release candidate satisfies all of these:

1. Publish the AArch64 Renderer through MAKO's normal release workflow with immutable version and checksum metadata (the build already runs from reviewable source).
2. Prove Vulkan loader activation and clean teardown on the target without global FEX configuration edits or an always-on system layer.
3. On Armada, validate `armada-game-launch`, direct Steam/Proton games, and the explicitly selected Renderer bypass.
4. Run FP32 and FP16 image-quality comparisons, fixed and adaptive scheduling, swapchain recreation, overlays, focus changes, and representative wine-arm64 and FEX-translated games on real hardware.
5. Ship a tested rollback: an unsupported or failed native package must return to the passthrough behavior documented above.

`scripts/collect-aarch64-evidence.sh` gathers read-only host, payload, wrapper, loader, and `mako-cli` GPU self-test evidence from an installed package; its report does not replace the game matrix.

## Code ownership and regression checks

- Native-host detection: `py_modules/mako_plugin/host_environment.py`
- Package ISA metadata: `renderer_package.py`; per-ISA layer identities: `constants.py`
- Package validation, payload ISA checks, and installation status: `installation.py`
- Startup boundary: `plugin.py`
- Wrapper guard, passthrough, and Armada launcher text: `wrapper_generation.py`
- Wrapper regeneration and compatibility migration orchestration: `configuration.py`
- Flatpak activation and old-override cleanup: `flatpak_service.py`
- Renderer payload record and ELF checks: `engine/CMakeLists.txt`, `engine/scripts/package-local.sh`, `engine/scripts/mako-installer`
- Cross-device timeline relay for drivers without exportable timelines: `engine/mako-common/src/vulkan/timeline_semaphore.cpp`, `engine/mako-common/src/vulkan/timeline_relay.cpp`, and the `timeline-relay` CTest
- Deterministic coverage: `tests/test_dual_arch_installation.py`, `tests/test_wrapper_environment.py`, `tests/test_configuration_boundaries.py`, `tests/test_plugin_lifecycle.py`, `tests/test_flatpak_runtime_detection.py`, and the AArch64 CI workflow

Any future AArch64 change must update this document and those boundary tests. Real-hardware evidence is required before a release can describe the Renderer as supported on an AArch64 host.
