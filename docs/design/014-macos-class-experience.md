# 014: A macOS-class experience

Status: programme plan, with M1 and M2 done. Created 6 Nov 2026; M2 7 Nov 2026.

The aim: OrangeOS should feel as finished as macOS: the shell, the
everyday apps, how they connect to the hardware, and that it runs in the
virtual machine software people already use. This plan covers what to build,
in what order, and how each step is proven. It builds on
[010](010-production-desktop-plan.md) (the Aurora desktop plan) and does not
replace its rules: real backends only, no fake controls, a commit per verified
milestone.

We take Apple's *ideas and proportions* as the reference. We do not copy
Apple artwork, fonts, names or trademarks. Our icons stay original SVG, the
font stays Inter.

## 1. Reference measurements

Apple does not publish exact sizes for most of its interface (the Human
Interface Guidelines give rules, not pixel tables), so these were **measured
from AppKit itself** on the development Mac (macOS 15.7, 6 Nov 2026), with a
small Swift program that asks the system for its own sizes:

| Element | macOS 15 (measured) | OrangeOS today | Plan |
|---|---|---|---|
| Menu bar | 24 pt; 37 pt on notched MacBooks (screen 956, visible top 918) | 28 pt | Keep 28 until M2, then 24 |
| Menu bar and menu font | 13 pt | Inter, about 13 pt | Keep |
| Title bar (title only) | 28 pt | **28 pt (M2)** | Done |
| Title bar with toolbar | 52 pt | **52 pt toolbar windows (Files)** | Done |
| Window buttons | 12 pt circles in 14x16 frames, 20 pt apart, first at x 7 (title bar) or 19 (toolbar) | **exact (M2)**, symbols on group hover | Done |
| Body text | 13 pt; small 11 pt; labels 10 pt | 13 pt | Keep |
| Push button | 32 pt tall regular, 27 small, 40 large | **toolkit `ui.pushButton`** | Done |
| Text field / search field | 21 / 22 pt regular | **toolkit `ui.searchField` (Files)** | Done |
| Switch | 42 x 25 pt | n/a | M5 Settings |
| Slider | 28 pt tall | Control Center | M5 |
| Pop-up button | 25 pt | n/a | M5 |
| Table and source-list rows | 24 pt | Files 32 pt | M3 |
| Dock tile | 48 pt default (this Mac: 32) | 44 pt icons | Keep; magnification later |
| Accent | #007AFF (system blue) | theme accent | Keep per theme |
| Window corner radius | about 10 pt (title bar) to 16+ pt (toolbar windows); larger in macOS 26 | **10 plain, 13 toolbar (M2)** | 13, not 16: the shadow's corner masks are cut for 13 |
| Sidebar width | 225–275 pt min, 350–400 max (Apple guidance via the Macintosh checklist) | Files 180 pt | M3 |
| App window minimum | 480–600 x 320–400 pt | **Files 560 x 360, browser 560 x 380, terminal 40 x 10 cells** | Done |

Typography ramp used by macOS (body 13, headline 13 bold, callout 12,
subheadline 11, footnote 10, title 3 15, title 2 17, title 1 22, large title
26). OrangeOS's Inter atlas has 13 and 26 point sizes today (body and large
title); the in-between styles need new atlas sizes and are left for M5.

## 2. What makes macOS feel finished, and what we adopt

| macOS strength | OrangeOS answer | Milestone |
|---|---|---|
| Spotlight finds anything with one shortcut | Spotlight: apps, windows, actions, sums; later files and settings | **M1 done**, files in M3 |
| Cmd+Tab app switcher | Alt+Tab switcher HUD | **M1 done** |
| Settings remembered everywhere | Preferences on the /data disk | **M1 done** (theme) |
| Windows resize, tile and animate | Live resize, edge tiling, short open/minimise motion | **M2 done** |
| One toolkit: same buttons, fields, lists in every app | Shared native toolkit with the measured sizes above | **M2 done** (Files first; more apps in M3 to M5) |
| Finder | Files with writable /data, sidebar, Trash and restore, Quick Look | M3 |
| TextEdit, Preview, Calculator | Text editor with safe save, image viewer, calculator | M4 |
| System Settings | Settings app with a sidebar and real panes | M5 |
| Notification Center | Notifications from apps, with history | M6 |
| Menu bar app menus (File, Edit, View, Window, Help) | Apps publish their menus to Peel | M7 |
| Login window and lock screen | User account, lock on idle | M8 |
| Mission Control and Spaces | Overview with live thumbnails, then desktops | M9 |
| Universal Clipboard, Continuity | Shared clipboard with the Mac through the companion bridge | M10 |
| Activity Monitor | Processes, memory, CPU from the kernel | M11 |
| Gatekeeper, app sandbox, privacy prompts | Signed apps, per-app permission prompts | M12 |

### Hardware and software together

Apple's advantage is one company owning the chip, the firmware and the OS.
Our version of that, on the user's MacBook, is the **companion bridge**
(docs 010): the guest reads the real Wi-Fi, Bluetooth, battery, brightness
and sound of the Mac, and sends sound out through CoreAudio. Next steps that
make the two feel like one machine:

1. Shared clipboard (copy on the Mac, paste in OrangeOS and back): M10.
2. Real battery and charging state driving low-power behaviour (fewer
   redraws, no animations below 20 percent).
3. Brightness and volume keys on the Mac keyboard acting on the guest's
   on-screen indicators.
4. Time and time zone from the Mac (already read), kept when the bridge is
   down.
5. Files: a shared folder with the Mac (virtio-fs or 9p) shown in the Files
   sidebar.

## 3. Keyboard shortcuts

QEMU on a Mac gives the Command key combinations to the Mac itself
(Cmd+Space opens the Mac's Spotlight, Cmd+Q quits QEMU), so OrangeOS uses
Option (Alt) for its own shell shortcuts:

| Shortcut | Action |
|---|---|
| Option+Space, or the Windows/Command key alone | Spotlight |
| Option+Tab (Shift to go back, arrows to move) | App switcher; release Option to switch |
| F3 | Mission Control (all windows) |
| F4 | Appearance |
| F11 | Show desktop |
| Esc | Close Spotlight, switcher or a panel |

## 4. Milestones and how each is proven

Each milestone ends with: unit tests for its logic, a QEMU test that drives
the real desktop, screenshots kept as evidence, a commit, and a push.

- **M1 Spotlight, switcher, kept preferences (done 6 Nov 2026).**
  `userland/servers/peel/spotlight.zig` (search ranking and a safe
  calculator, 9 unit tests), Peel's Spotlight panel and Alt+Tab HUD,
  `/data/preferences/desktop`. Test: `tools/spotlight_smoke.py` (typing,
  Return, sums, Backspace, menu-bar button, theme by keyword, switcher
  order, theme kept across a reboot).
- **M2 Windows and toolkit (done 7 Nov 2026).** See section 6.
  Test: `tools/windows_smoke.py` (corner and edge resize, the minimum size,
  double-click zoom and restore, tiling at the left edge and pulling the
  window back out, Files' toolbar move and zoom with its grid reflowing,
  minimise and restore motion, Reduce Motion saved and obeyed; `--browser`
  zooms the browser from its tab strip).
- **M3 Files.** Writable `/data/Documents`, new folder, rename, move to
  Trash and restore, sidebar, list and icon views, Quick Look on Space,
  Spotlight finds files.
- **M4 Everyday apps.** Text editor with save and unsaved-change prompts,
  image viewer, calculator app.
- **M5 Settings.** Sidebar app: Appearance, Wallpaper, Display, Sound,
  Network, Bluetooth, Date and Time, Keyboard, About. Each pane real or
  clearly read-only.
- **M6 Notifications.** App-to-Peel message, banners, history panel.
- **M7 App menus.** Apps publish menus; Peel draws and routes them.
- **M8 Login and lock.**
- **M9 Mission Control and desktops.**
- **M10 Shared clipboard with the Mac.**
- **M11 Activity Monitor.**
- **M12 Signed apps and permission prompts.**

## 5. Running in other virtual machine software

OrangeOS is an x86-64 system. The ISO is already a hybrid BIOS and UEFI image
(Limine), and the kernel already falls back from PCIe ECAM to the legacy
0xCF8 port when there is no MCFG table, so it is close to portable.

| Host | Software | Can it run OrangeOS? |
|---|---|---|
| Apple Silicon Mac (this M4) | QEMU (our scripts) | Yes, by emulation (TCG) |
| Apple Silicon Mac | **UTM**, "Emulate", x86_64 | Yes: UTM is QEMU underneath, same speed as ours |
| Apple Silicon Mac | VMware Fusion, Parallels, VirtualBox | No: on Apple Silicon these run Arm guests only |
| Intel or AMD PC | VirtualBox, VMware Workstation/Player, Hyper-V, QEMU/KVM | Should, at full native speed, once V2–V4 pass |

Plan:

- **V1 UTM on this Mac.** A script that builds a ready-to-open UTM bundle
  (q35, the ISO, the system disk, a data disk, HDA sound, e1000 network).
  The user opens it once to confirm.
- **V2 VirtualBox-shaped hardware in QEMU.** Boot under `-M pc` (PIIX3, no
  MCFG, like VirtualBox's default chipset), PS/2 or USB tablet mouse, Intel
  PRO/1000 MT (e1000), ICH6 HDA, AHCI. Fix whatever fails, test it in CI.
- **V3 VMware-shaped hardware.** VMware SVGA framebuffer from the boot
  loader, e1000/e1000e network, AHCI, HDA; add e1000e if needed.
- **V4 Real check.** VirtualBox and VMware on an x86 PC (needs the user or a
  borrowed PC; this Mac cannot run them for x86 guests).

## 6. How M2 works

**Resizing without reallocating.** A window that sets the `resizable` flag
allocates its shared buffer once, at the largest content the screen allows
(Peel says how large in its `display_info` reply; the kernel's 16 MiB cap
per buffer is respected). Rows are always that wide (`stride`), so a new
size never maps new memory. Peel checks the buffer really is that big
(`shm_size`, a new system call) before reading it.

**One configure at a time.** While the user drags an edge, Peel works out
the frame they want (`frame.resized`, with the minimum and the buffer's
capacity) and sends the client a `configure` with that content size. The
client lays itself out, draws everything, and answers `resized`. Only then
does Peel change the frame, against the edges that are held still. A new
configure is sent only after the last one was answered (or after a second
without an answer), so a fast drag never queues work a slow client cannot
keep up with, and a window is never shown stretched or half drawn.

**Toolbar windows.** With `full_size_content` the client draws under the
title area, the way Finder does: Peel draws only the window buttons, at the
measured toolbar position (first button at 19 points, centred in the
client's bar), and rounds all four corners of the client's pixels. Pressing
the client's empty toolbar sends `move_request`; Peel honours it only for
the press it has just delivered to that client, then moves the window or,
on the second click of a double click, zooms it.

**Zoom and tiling.** A double click on a title zooms a resizable window to
the work area (below the menu bar, above the dock, with an 8-point gap)
and back. Dragging a window's title to the left or right screen edge shows
a translucent preview of that half, and releasing tiles it; the menu bar
edge offers the whole work area. Pulling a tiled window away gives it back
its own size, with the pointer keeping its place along the title. Fixed
windows (About, Clock, Welcome) still zoom by scaling, as before.

**Motion.** Windows open by growing from 92 percent and fading in;
minimise shrinks into the app's dock tile and fades out; the dock brings a
window back the same way. 150 ms, eased out (`frame.easeOut`), drawn by
blending the moving window with a copy of what is under it. Appearance has
a **Reduce Motion** switch (the measured 42 x 25 point switch), saved in
`/data/preferences/desktop`; with it on, nothing moves.

**Toolkit.** `ui.Metrics` holds the measured sizes (toolbar 52, toolbar
items 28, push buttons 32/27/40, fields 21/22, switch 42 x 25, rows 24,
radius 6), and `ui.toolbarButton`, `ui.pushButton`, `ui.searchField`,
`ui.segmented` draw the controls the same way in every app. Files uses
them now; the other apps move over as they are rebuilt (M3 to M5).

**Resize pointers.** Hovering a resizable window's edge shows a two-headed
arrow (horizontal, vertical, or diagonal at the corners), original SVG
artwork in the icon atlas.

What M2 does not do yet: live resize of the browser's web page during the
drag happens at the client's pace (WebKit draws the new size a moment
later, white until then); window snapping to other windows; keyboard
shortcuts for tiling (Command combinations stay with the Mac under QEMU).

