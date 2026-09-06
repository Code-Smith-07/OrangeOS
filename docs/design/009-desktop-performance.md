# Desktop responsiveness: first optimization pass

September 6, 2026. QEMU q35, x86_64 TCG on an Apple Silicon host, 3 GiB,
two vCPUs, 2560×1600 physical pixels. These are guest composition/presentation
times, not end-to-end input latency or physical-display frame rates.

## Reproducing

```sh
zig build -Ddesktop-profile
./scripts/mkdisk.sh
python3 tools/desktop_perf.py
```

The test boots a disposable snapshot and retains performance.json plus serial
logs. Restore a normal build afterwards; profile logging is off by default.
Do not rebuild a disk currently used by the interactive preview.

## Findings and measurements

The previous compositor repainted scene pixels for every pointer movement.
Frosted surfaces expanded small damage into complete panels. Hover changes
also invalidated both the top menu and dock; combining these with one bounding
rectangle could repaint the entire 1,024,000-point desktop.

| Scenario | Baseline median ms | Optimized median ms |
|---|---:|---:|
| Pointer over client | 6 | 1 |
| Pointer over glass | 567 | 1 |
| Dock hover | 481.5 | 27 |
| Window drag | 181 | 128 |
| Clock-opening phase | 51.5 | 15 |
| Clock-closing phase | 441 | 29.5 |

Each phase includes incidental clock updates and intermediate mouse movements;
the open/close rows are **not application startup/close latency measurements**.
Samples are sparse and emulation is noisy. Pointer-only work no longer paints
any scene pixels; it copies the old/new 20×20-point footprints and draws the
SVG pointer. The glass scenario's p95 remained 80 ms due to other scene work.
Window dragging still had a 435 ms p95 in this run. This is a substantial
pointer/hover improvement, **not yet a smooth 60 Hz compositor**.

Evidence run directories:

- Baseline: orange-daybreak-nzpg3zfr
- Optimized: orange-daybreak-iclwh7ag

Both were retained in the host temporary directory printed by the profiler.
An experimental REP MOVS bulk-copy path was measured and removed because it
did not improve this QEMU configuration.

## Implemented changes

- Keep the back buffer cursor-free; restore the previous cursor footprint
  from the completed scene and draw the new cursor onto the front buffer.
- Invalidate hover-dependent surfaces only; pointer motion alone does not
  refresh an entire title bar or frosted panel.
- Maintain a bounded set of 24 damage rectangles, preserving distant regions.
  Overflow merges conservatively, never discarding damage.
- Expand/merge glass dependencies before rendering. Reconstruct all affected
  scene regions before presenting; glass never samples an old cursor.
- Copy unscaled client rows in bulk; retain the existing rounded-corner and
  zoom paths. Avoid painting opaque backgrounds behind entire client buffers.
- Strip debug information from non-Debug user applications. Debug builds
  retain it. This reduced staged filesystem use from 31,284 to 16,204 KiB
  in the profiled run, reducing executable loading work without removing
  runtime bounds/overflow checks.

## Remaining work

Improve occlusion handling and window-drag rendering, profile
actual host-display and launch latency, and evaluate a supported accelerated
display path. A native ARM port or x86 host avoids cross-architecture TCG costs;
enabling HVF cannot virtualize this x86 guest on an ARM Mac.

The existing desktop smoke suite checks the optimized real framebuffer:
pointer appearance/restoration on glass, no trails, repeated panel stability,
window drag, close/minimize/zoom/restore, app launch and Files/Trash operations.
Native renderer tests cover damage separation/overflow, diffusion, clipping
and reconstruction. This does not prove arbitrary frame-rate or load behavior.

## Input delivery follow-up

The first pass did not establish perceived responsiveness. A second inspection
found two separate problems: relative mouse counts were divided by the Retina
backing scale, and newly ready input work could wait for an idle task's 64 ms
batch quantum. Drawing a cursor in 1 ms did not account for that wait.

Relative motion now uses logical pointer units independent of backing scale.
The kernel combines adjacent same-direction motion without crossing keyboard
events, button transitions, reversals or integer overflow. Peel drains 64 events
and publishes the cursor before further client handling and scene rendering.
The scheduler checks ready work on every idle timer tick; channel wakeups also
request local rescheduling where priority allows. No remote non-atomic scheduler
flags are written and no switch occurs while a wait-list lock is held.

`python3 tools/desktop_input_latency.py` injects 40 movements at 60 Hz per
scenario and observes a serial marker written after guest cursor publication.
It asserts the final coordinate, including reverse travel. This includes queue
and scheduler delay, but **not Cocoa display refresh or physical scanout**.
Coalesced samples are reported explicitly; newest-sample latency alone hides
stalls, so the probe also reports gaps between publications.

Before/after the scheduler change (both already have corrected motion scaling):

| Scenario | Publications before / after | Median newest-sample ms before / after | Longest gap ms before / after |
|---|---:|---:|---:|
| Client motion | 9 / 40 | 12.0 / 3.6 | 84.9 / 19.8 |
| Glass motion | 17 / 40 | 9.4 / 3.2 | 72.2 / 19.0 |
| Dock motion | 11 / 21 | 10.5 / 2.9 | 200.8 / 177.7 |
| Drag motion | 7 / 8 | 12.9 / 7.5 | 199.5 / 161.3 |

Evidence: `orange-daybreak-mg7ozjf9` and `orange-daybreak-r3z5wmpo` under the
host temporary directory. Full desktop regression after this change:
`orange-daybreak-j74aqybd`. Expensive scene work still stalls dragging and dock
hover; this is not a claim of uniformly smooth interaction.

## Exact shell material cache

The menu-bar frost and dock frost/eight-layer shadow now use two bounded
backdrop/result caches (4.8 MB of pixel storage total). Every source pixel and
geometry/material parameter is compared before reuse. A changed backdrop
re-renders the material; partial clips and oversized surfaces fall back to
uncached rendering. The dock shadow participates in damage dependency closure.
Native tests compare cached/uncached pixels exactly, including 2x backing,
changed backdrops and partial clips. No blur, shadow layers, or display
resolution were removed to obtain the speedup.

Final rapid-input run, `orange-daybreak-1mfiy9i4`, with stress threads disabled:

| Scenario | Publications / 40 inputs | Median newest-sample ms | Longest publication gap ms |
|---|---:|---:|---:|
| Client | 40 | 4.2 | 19.9 |
| Glass | 40 | 4.0 | 20.3 |
| Dock | 40 | 3.3 | 25.5 |
| Drag | 6 | 15.5 | 174.6 |
| Reverse motion | 40 | 3.9 | 18.0 |

The probe also records host injection gaps to distinguish delayed injection
from guest work. These runs remain short, host-dependent samples. The drag
result explicitly shows the remaining problem: a large scene render still
blocks input processing, and this cache does not solve window-drag frame rate.
The ordinary pointer/dock paths improved; drag smoothness is not declared done.

Scheduler stress build: `orange-daybreak-rxxh8yh4`, five checks passed, zero
failed (register integrity, preemption, concurrent advancement and switching).
That stress build's timings are not used for the final comparison.
