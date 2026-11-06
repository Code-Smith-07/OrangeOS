# 014: A macOS-class experience

Status: programme plan, with M1 done. Created 6 Nov 2026.

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
| Title bar (title only) | 28 pt | 38 pt | M2: 28 pt plain, 52 pt with toolbar |
| Title bar with toolbar | 52 pt | n/a | M2 |
| Window buttons | 12 pt circles in 14x16 frames, 20 pt apart, first at x 7 (title bar) or 19 (toolbar) | similar | M2: match exactly |
| Body text | 13 pt; small 11 pt; labels 10 pt | 13 pt | Keep |
| Push button | 32 pt tall regular, 27 small, 40 large | per app | M2 toolkit |
| Text field / search field | 21 / 22 pt regular | per app | M2 toolkit |
| Switch | 42 x 25 pt | n/a | M5 Settings |
| Slider | 28 pt tall | Control Center | M5 |
| Pop-up button | 25 pt | n/a | M5 |
| Table and source-list rows | 24 pt | Files 32 pt | M3 |
| Dock tile | 48 pt default (this Mac: 32) | 44 pt icons | Keep; magnification later |
| Accent | #007AFF (system blue) | theme accent | Keep per theme |
| Window corner radius | about 10 pt (title bar) to 16+ pt (toolbar windows); larger in macOS 26 | 16 pt | M2: 10 plain, 16 toolbar |
| Sidebar width | 225–275 pt min, 350–400 max (Apple guidance via the Macintosh checklist) | Files 180 pt | M3 |
| App window minimum | 480–600 x 320–400 pt | fixed sizes | M2 resize |

Typography ramp used by macOS (body 13, headline 13 bold, callout 12,
subheadline 11, footnote 10, title 3 15, title 2 17, title 1 22, large title
26) becomes OrangeOS's named text styles in M2.

## 2. What makes macOS feel finished, and what we adopt

| macOS strength | OrangeOS answer | Milestone |
|---|---|---|
| Spotlight finds anything with one shortcut | Spotlight: apps, windows, actions, sums; later files and settings | **M1 done**, files in M3 |
| Cmd+Tab app switcher | Alt+Tab switcher HUD | **M1 done** |
| Settings remembered everywhere | Preferences on the /data disk | **M1 done** (theme) |
| Windows resize, tile and animate | Live resize, edge tiling, short open/minimise motion | M2 |
| One toolkit: same buttons, fields, lists in every app | Shared native toolkit with the measured sizes above | M2 |
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
- **M2 Windows and toolkit.** Protocol op for a new window size; apps
  re-lay out; drag edges and corners; double-click title to zoom; tile to
  half screen at the edges; 150 ms open and minimise motion (none with
  Reduce Motion); measured title bar, buttons and radii; shared controls.
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
