# Pinned Chromium reference workspace

This is a **macOS arm64 reference build**, not a guest browser or a substitute
for the OrangeOS platform port. `content_shell` is an engine test harness, not
the shipping browser. No browser performance or website support is implied.

`upstream.json` pins Chromium 154.0.8037.58 and depot_tools by full commit hash.
The source's own `DEPS` pins its dependencies; the reference runner checks the
declared Clang package and SDK constants against the manifest without executing
those files. Source pinning is not a completed reproducibility/security audit.

## Explicit steps

From the external project root, run one step at a time:

```sh
python3 tools/browser_reference.py status
python3 tools/browser_reference.py tools
python3 tools/browser_reference.py preflight
python3 tools/browser_reference.py source
python3 tools/browser_reference.py sync
python3 tools/browser_reference.py hooks
python3 tools/browser_reference.py generate
python3 tools/browser_reference.py build
python3 tools/browser_smoke.py
```

`status` is read-only and reports **recorded** results, not fresh qualification.
It also checks the runner lock and reads at most the last 16 KiB of the latest
log to show live action progress. A stale running record is warned about, never
converted to success. A held lock means a runner exists, not that it is making
progress; inspect the log. Build-action totals can change as Siso expands the
graph, so they are not a reliable time-remaining estimate.

For a continuously updating ASCII progress bar in a separate terminal, run:

```sh
python3 tools/browser_progress.py --watch
```

Press Ctrl-C to close only the viewer; compilation continues. Without `--watch`,
the command prints one snapshot. It reads the existing build state and log tails
without changing the build. The overall percentage sums completed actions from
incremental passes, so it is **approximate**: dependency-graph changes and
repeated actions can shift it. The current-pass action count and remaining
actions are shown alongside the estimate. This is not an ETA or evidence that
the Mac test shell, let alone a native OrangeOS browser, has passed its gates.
The other numbered stages enforce ordering. `sync` fetches dependencies without
hooks; `hooks` downloads/prepares the pinned toolchain; `generate` writes GN
configuration; `build` compiles `content_shell` with two local jobs. A successful
build still needs launch/render verification. No step automatically launches a
host browser, changes shell configuration, touches guest images, installs Xcode
or makes a Git commit in the OrangeOS repository.

For additional CPU parallelism, use `python3 tools/browser_reference.py build --jobs 3`.
The runner validates 1–8 workers and records the requested count. This affects
host compilation only, not guest CPU limits. Stop an active build gracefully
and wait for its runner lock to release before changing the worker count;
the same output directory retains completed objects for incremental resume.
Do not run two builders against it. GPU resources do not accelerate these
C/C++/Rust compiler jobs.

The separate `browser_smoke.py` command **does launch** the built Mac Content
Shell after requiring a successful build record at the current manifest pins.
It holds the workspace lock, uses a local file fixture only, saves stdout/stderr
and JSON evidence externally, and enforces a 90-second deadline with cleanup of
its own process group. Its five checks cover JavaScript, DOM manipulation,
CSS flex layout, a canvas pixel readback and an asynchronous timer. Every check,
one unique completion marker, and a zero exit code are required to pass.

This uses upstream `--run-web-tests`, which changes policy including certificate
verification. No user-provided URLs are accepted. **It cannot qualify HTTPS,
sandboxing, general public browsing, visible UI polish, media or OrangeOS**.
Those require separate normal-browser/guest tests. Harness unit tests are not
evidence that the engine fixture itself has run successfully.

The tool stage explicitly initializes depot_tools' Python launcher as well as
vpython. With auto-updates disabled, successfully running `gclient` alone does
not initialize GN's `python-bin/python3` wrapper. Later stages check this too,
allowing an older workspace to recover through `ensure_bootstrap` without
updating its pinned depot_tools commit.

The workspace is `build/browser` on the project's mounted external `/Volumes`
volume. It must be APFS, have no whitespace in its resolved path, and have at
least 100 GiB free before each mutating step (our planning reserve, not an
upstream minimum or a disk quota). The default/internal fallback is refused.
The current runner supports an arm64 Mac with full Xcode only.

Chromium's pinned development SDK minimum is 15; its official build uses 26.5.
The installed 26.2 SDK passes the former, **not official SDK parity**. Only an
actual compile can establish that it works with this source. Do not lower
upstream SDK checks or disable security features to hide a build failure.

## Storage, recovery and evidence

Sources live in `checkout/src`; the output is `checkout/src/out/OrangeReference`.
depot_tools, CIPD caches, vpython environments, XDG caches, gsutil transfer state
and temporary downloads are redirected beneath the workspace. gsutil gets a
credential-free local configuration; personal Boto settings are not imported.
The system Xcode/SDK installation remains
on the Mac; OS-managed swap/system caches are not controlled by this runner.
Large Chromium downloads are opt-in through the explicit `source`/`sync` steps.
The shallow checkout avoids full source history and a second shared Git cache.

Logs and `state.json` record every attempted stage. `source-audit.json` records
the DEPS checksum and declared toolchain. A failed step never counts as passed;
rerunning a step invalidates downstream success records. Stages can be retried
after ordinary network failures. The runner uses a workspace lock to prevent
simultaneous stages, verifies origins/HEADs and refuses tracked modifications
or conflicting generated configuration. It never performs `reset --hard`,
`clean`, force-checkouts, or deletes a failed checkout. An interrupted checkout
that already contains files needs inspection instead of automatic replacement.

Keep these local files ignored: they can be huge and contain host paths. Commit
only the lock manifest, scripts, tests and sanitized qualification summaries.
Changing a pin deliberately requires a new workspace or a reviewed migration;
the runner refuses silently changing an existing workspace's manifest.

Tests (do not fetch/build Chromium):

```sh
python3 -m unittest discover -s tools -p 'test_*.py'
```

## Upstream references

- [Pinned macOS build instructions](https://chromium.googlesource.com/chromium/src/+/a654841425914cbb703a2931e07b70a83aedbafd/docs/mac_build_instructions.md)
- [Apple Silicon build support](https://chromium.googlesource.com/chromium/src/+/a654841425914cbb703a2931e07b70a83aedbafd/docs/mac_arm64.md)
- [Minimum SDK](https://chromium.googlesource.com/chromium/src/+/a654841425914cbb703a2931e07b70a83aedbafd/build/config/mac/mac_sdk_overrides.gni) and [official SDK](https://chromium.googlesource.com/chromium/src/+/a654841425914cbb703a2931e07b70a83aedbafd/build/config/mac/mac_sdk.gni)
- [Pinned Clang package](https://chromium.googlesource.com/chromium/src/+/a654841425914cbb703a2931e07b70a83aedbafd/tools/clang/scripts/update.py)
- [depot_tools auto-update control](https://chromium.googlesource.com/chromium/tools/depot_tools/+/910f54316dac310fadee0c453c4d460c0c446189/update_depot_tools)
- [Bootstrap without updating the checkout](https://chromium.googlesource.com/chromium/tools/depot_tools/+/910f54316dac310fadee0c453c4d460c0c446189/ensure_bootstrap)
