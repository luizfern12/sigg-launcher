# ivi-homescreen: window hide/show

Branch under review: `sigg-hide-v2` in `/run/media/luizfern12/512GB/SDKs/ivi-homescreen`,
based on upstream `9c6dac86df39961851c1d188c554afe7f6617754`.

## Status

Legend: **built** = the target was compiled; **unit-tested** = `ctest` run and
passing locally; **run on target** = executed on the Raspberry Pi 4 / labwc.
"not run" means exactly that — nothing below is claimed on hardware.

| Step | x86_64 debug built | x86_64 unit-tested | aarch64 release built | run on target |
| --- | --- | --- | --- | --- |
| Setup (baseline at 9c6dac86) | yes (39/39 ctest) | yes | yes | no |
| Step 1a reason bitmask (`51cd2c16`) | yes | yes (40/40, new `suspend_reasons` test) | yes | **not run** |
| Step 1b `IsVsyncParked`/`CanParkVsync` (`40b330e9`) | yes | yes (40/40) | yes | **not run** |
| Step 1c `hide`/`show` channel (`baa42561`) | yes | yes (40/40) | yes | **not run** |
| Step 1.5 `diag:` hide probe (`775400db`, dropped before export) | yes | yes (40/40, probe inert without env) | yes | **not run** |
| Step 2 present gate | not started | — | — | — |
| Step 3 foreign-toplevel minimize | not started | — | — | — |
| Step 4 drain | not started | — | — | — |
| Step 5 watchdog interaction | not started | — | — | — |
| Step 6 lifecycle messages | not started | — | — | — |
| Step 7 Dart side (sigg_launcher) | n/a (Dart) | yes (`window_service_test.dart`, 8 cases) | n/a | **not run** |
| Step 8 diagnostics | not started | — | — | — |

### Not verified, and why

- Everything about hide/show is **not run on target**. The Pi was not driven
  this session; x86_64 and aarch64 builds plus host unit tests are the only
  evidence.
- `WaylandEglBackend::CanParkVsync()`/`IsVsyncParked()` are not unit-tested:
  constructing the backend requires a Wayland display, EGL and a
  `WaylandVsyncProvider`.
- `FlutterView::Hide()`/`Show()` and the `sigg_launcher/window` channel are not
  unit-tested: `FlutterView` needs a display and a running engine. The policy
  they delegate to (`ivi::SuspendReasons`) is unit-tested, including the
  "notification only on parked<->unparked transitions" gate.
- Only the Wayland EGL backend overrides the new capability queries. The DRM,
  software, headless and Wayland Vulkan backends keep the default `false`, so a
  hide request on those reports `not-parked`. Step 1's scope was Wayland EGL.
- Step 1 does not yet guarantee that no frame already rasterizing can commit
  after hide; that is Step 2's present gate.

## Build setup (exact commands used)

Both build trees already existed with their options cached; these are the
configure commands actually run, and they preserve the existing cache:

x86_64 debug (unit tests + watchdog, Wayland EGL):

```
cd /run/media/luizfern12/512GB/SDKs/ivi-homescreen
cmake -S . -B build -GNinja
ninja -C build -j$(nproc)
ctest --test-dir build --output-on-failure -j$(nproc)
```

Effective cached options in `build/CMakeCache.txt`:
`CMAKE_BUILD_TYPE=Debug`, `BUILD_UNIT_TESTS=ON`, `BUILD_WATCHDOG=ON`,
`BUILD_BACKEND_WAYLAND_EGL=ON`, compiler `/usr/bin/c++`.

aarch64 release, inside the `ivi-build` container (`/src` is a bind mount of the
repo):

```
docker exec ivi-build bash -lc 'cd /src && cmake -S . -B build-aarch64 -GNinja'
docker exec ivi-build bash -lc 'cd /src && ninja -C build-aarch64 homescreen -j$(nproc)'
```

Effective cached options in `build-aarch64/CMakeCache.txt`:
`CMAKE_BUILD_TYPE=Release`, `BUILD_UNIT_TESTS=OFF`, `BUILD_WATCHDOG=ON`,
`BUILD_BACKEND_WAYLAND_EGL=ON`.

## Step 1 design notes

- `ivi::SuspendReasons` (`shell/view/suspend_reasons.h`) is a bitmask:
  `kOutputDisconnected` (what `Suspend()`/`Resume()` set) and `kAppHidden`
  (what `Hide()`/`Show()` set). The view is parked while any bit is set.
- `FlutterView::SetReason()` is the only place that parks: it calls
  `Backend::SetVsyncParked()` and posts the platform-view notification only when
  the parked state flips, so repeated output events and a second reason stay
  silent. `ApplyOnDisconnect()` is untouched.
- `Hide()` asks `Backend::CanParkVsync()` first and returns `false` without
  changing state when the backend cannot stop frames (no `wp_presentation`, or
  `IVI_WL_VSYNC=0`). The channel turns that into
  `PlatformException("not-parked")`.
- `Show()` clears the reason and, if nothing else holds the view parked, posts
  `FlutterEngineScheduleFrame` so the surface repaints. Show() while not
  app-hidden is a no-op (no spurious frame).
- Channel: `sigg_launcher/window`, methods `hide`/`show`, result
  `{parked: bool}`. Same names as the GTK runner.
