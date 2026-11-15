# Running OrangeOS in a virtual machine

OrangeOS is a system for Intel and AMD processors (x86-64). This page says
where it runs today, with the exact settings, and what is not there yet.

## What you need

Run `zig build && ./scripts/mkdisk.sh`, then `./scripts/export-vm.sh`. It
writes three files to `build/vm/`:

| File | What it is |
|---|---|
| `orange.iso` | The boot disc. Boots with BIOS and with UEFI. |
| `system.vmdk` | The system disk (read-only in use). |
| `data.vmdk` | The data disk: Documents, settings, your password. |

## Which computer can run it

| Your computer | Program | Works? |
|---|---|---|
| Apple Silicon Mac (M1 to M4) | QEMU (`scripts/run-desktop.sh`) | Yes. It emulates an Intel processor, so it is slower than a real PC. |
| Apple Silicon Mac | UTM, with "Emulate" and x86_64 | Yes (UTM uses QEMU). |
| Apple Silicon Mac | VirtualBox, VMware Fusion, Parallels | No. On these Macs they only run Arm systems. |
| Intel or AMD PC, or Intel Mac | VirtualBox, VMware, QEMU/KVM | Expected to, at full speed: see below. |

"Expected to" is exact: every device these programs give a virtual machine
is tested here by making QEMU look like them (`tools/vm_shapes_smoke.py`:
eight machines, all boot to the desktop with a disk and a network address).
The programs themselves have not been run, because that needs an Intel or
AMD computer. If one misbehaves, the log from its serial port says where.

## Settings

Use these for a new machine, type **Other / Unknown (64-bit)**:

| Setting | Value |
|---|---|
| Memory | 3 GB or more |
| Processors | 2 |
| Firmware | BIOS (the default). UEFI also boots. |
| Optical drive | `orange.iso`, first in the boot order |
| Disk 1 | `system.vmdk`, on a SATA (AHCI), IDE or NVMe controller |
| Disk 2 | `data.vmdk`, on a SATA (AHCI), IDE or NVMe controller |
| Network | NAT, card "Intel PRO/1000" (any of MT Desktop, MT Server, T Server) or e1000e |
| Pointing device | **PS/2 mouse** (not USB tablet) |
| Video memory | 16 MB or more for the sharp 2560x1600 picture; with less OrangeOS uses 1024x768 |
| Sound | Intel HD Audio |

### VirtualBox

1. New machine, type Other, version Other/Unknown (64-bit), 3072 MB, 2 CPUs.
2. Storage: put `orange.iso` in the optical drive. Attach `system.vmdk` and
   `data.vmdk` to the IDE controller that is already there, or to a SATA
   controller you add: both work.
3. System: pointing device **PS/2 Mouse**.
4. Display: video memory 16 MB or more. For the 2560x1600 picture also run
   `VBoxManage setextradata "<name>" CustomVideoMode1 2560x1600x32`.
5. Network: NAT, adapter type Intel PRO/1000 MT Desktop. Audio: Intel HD Audio.

### VMware Workstation, Player or Fusion (on Intel)

1. New machine, guest "Other 64-bit", 3 GB, 2 processors.
2. Use existing disks: `system.vmdk`, then `data.vmdk`, as **SATA**, IDE or
   NVMe (not SCSI: OrangeOS has no SCSI driver yet). CD/DVD: `orange.iso`.
3. Network: NAT. The card VMware picks (e1000 or e1000e) works.

### UTM on an Apple Silicon Mac

1. Create a machine, choose **Emulate**, Other, architecture x86_64,
   system "Standard PC (Q35)", 3072 MB, 2 cores.
2. Boot image `orange.iso`. Add `system.vmdk` and `data.vmdk` as IDE or
   SATA drives. Network card: Intel e1000. Sound: Intel HD Audio.

## What works in every one of them

The desktop and all the apps, the disk, the network (DHCP, DNS, HTTPS, the
browser), sound (Intel HD Audio), and the keyboard and mouse.

## What is different outside our own launcher

- **Mac hardware in the menu bar** (Wi-Fi, Bluetooth, battery, brightness,
  volume) comes from the OrangeOS Companion, which only
  `scripts/run-desktop.sh` starts. Elsewhere those show "?", honestly.
- **The data disk is optional.** OrangeOS finds it by its own signature on
  whichever controller it is attached to. Without it everything still
  runs; nothing is kept across restarts and there is no lock screen.

## Not there yet

| Missing | Effect |
|---|---|
| USB keyboard and mouse (xHCI HID) | Use a PS/2 mouse in the VM. On most real laptops the built-in keyboard is PS/2, but USB keyboards and many touchpads do not work. |
| SCSI controllers (LSI Logic, BusLogic, VMware PVSCSI) | Choose SATA, IDE or NVMe. |
| VirtIO disk and network, VMXNET3, Hyper-V | Choose SATA and an Intel card. Hyper-V is not supported. |
| Realtek, Broadcom and wireless network cards | No network on most real PCs yet. |
| A battery driver (ACPI) | No battery reading on a real laptop. |
| An installer | The system runs from the disc and the system disk; nothing copies it onto a PC's own drive yet. |

So OrangeOS runs in virtual machines today, and on a real PC it can start
when the PC has a SATA or NVMe disk and a PS/2 keyboard, but it is not yet a
system to install on any laptop. That takes the drivers in this table,
in roughly this order: USB input, more network cards, an installer.
