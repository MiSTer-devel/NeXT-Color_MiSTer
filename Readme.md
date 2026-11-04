# NeXT-Color core for MiSTer

## General description

A NeXTstation Turbo Color core for MiSTer: a 50 MHz 68040, the Turbo chipset,
12-bit colour at 1120x832, NeXT ROM Rev 3.3 v74. It boots NeXTSTEP 3.3 to the
colour desktop. Work in progress.

| Part | State |
|---|---|
| CPU | 68040 at 50 MHz on a 25 MHz machine bus (the pipelined AP68040), FPU, MMU. BenchPress Dhrystone 243 (25 MHz NeXTstation Color = 100) |
| Memory | 16, 32 (default), 64 or 128 MB in SDRAM, no more than the SDRAM module |
| Video | 1120x832 at 68.4 Hz, 12-bit colour (Bt463 palette, TMC timing) |
| Keyboard and mouse | PS/2 keyboard and mouse as the NeXT keyboard (KMS) |
| SCSI | Two hard disks and a CD-ROM drive (images on the SD card) |
| Floppy | 2.88 MB drive (720K, 1.44M and 2.88M images) |
| Ethernet | On the MiSTer's LAN (optional) |
| Sound out | 16-bit stereo, 44.1 and 22.05 kHz |
| DSP56001 | In the FPGA, 8K words of external RAM (see "Sound and DSP"); untested on hardware |
| Sound in, DSP serial port, printer, ADB | Not present |

* Design decisions: `docs/DECISIONS.md`. Hand-off state: the newest
  `RESUME-*.md`. ROM analysis (the RTL spec):
  `rom-dissassembly/hardware-summary.md`. Hardware references: `RESOURCES.md`.
  Release builds: `releases/`; their notes: `RELEASES.md`.

## Installing

1. **Core**: the rbf in `_Unstable/` (or `_Computer/`) as `NeXT-Color.rbf`.
   Load it directly, not through an `.mgl` file (an MGL load once corrupted the
   remembered disk mount, `config/NeXT-Color.s0`).
2. **Boot ROM**: `releases/boot0.rom` (NeXT ROM Rev 3.3 v74, the NeXTstation
   Turbo's ROM) in `games/NeXT-Color/` -- the folder name is exactly the core's
   name, with a hyphen. Main loads `boot0.rom`, or `boot.rom` if there is no
   `boot0.rom`, each time the core starts; the OSD's "Load ROM" loads
   another one for that session. Do not copy the mono NeXT core's files into this folder: its
   `boot1.rom` is a 68030 ROM (Rev 2.5), which this core cannot run (see
   Troubleshooting).
3. **Main**: this core needs the `next-color` build of Main_MiSTer
   (`releases/MiSTer`, the build for this release). The NeXT-Color support
   is merged in the official Main (MiSTer-devel/Main_MiSTer #1329); once an
   official Main release includes it, the stock Main works and this step goes
   away. It serves the SCSI
   target responses, the CD-ROM images, the Ethernet bridge and the battery
   clock. A stock Main boots to `NeXT>` but finds no disk ("No SCSI disk").
   Replace `/media/fat/MiSTer` with it (keep the old one, for example as
   `MiSTer.stock`), then `sync` and reboot. It runs the other cores as the
   stock Main does.

   The network needs a Main that reads the network interface from the core
   (`NXTETH02`, Main_MiSTer `support/next/next_enet.cpp`, 2026-10 or later).
   An older Main runs everything else, but the network stays off.

   Check it: load the core, open the OSD, press right, open **About**. The
   MiSTer version must be **v261009** or later. Anything older means the stock Main is
   running.

   A `main=MiSTer_NeXT-Color` line in the core's `MiSTer.ini` section (the
   Main as a second file, used for this core only) also works with
   20261010 and later; the cores before stayed black when loaded that way
   (see Troubleshooting).
4. **Disk**: a NeXTSTEP disk image (`.hda`, `.vhd` or `.img`; rename a `.dd`
   image to `.img`) in the OSD's "Pri. disk (ID 0)" slot. "Boot device" is
   "SCSI disk" by default, so the ROM boots it. Images are written to: work on a
   copy.
5. **Display**: give the core its own 1080p section in `MiSTer.ini` (next
   section).

Shut NeXTSTEP down before loading another core or rebooting the MiSTer
(Log Out -> Power Off, or `halt` as root) and wait until the SD card is quiet:
the disk image is open for writing.

## OSD menu

The menu follows the MiSTer OSD standard
(danifunker/hp9000-715_MiSTer `docs/osd-standard.md`). The top page:

| Entry | What it does |
|---|---|
| Pri. disk (ID 0) / Disk (ID 1) | Hard disk images (`.hda`, `.vhd`, `.img`) for SCSI targets 0 and 1. Target 0 is the boot disk |
| CD-ROM (ID 3) | A disc image (`.iso`, `.cue`/`.bin`, `.chd`) in the CD-ROM drive, SCSI target 3 |
| Floppy | A floppy image (`.img`, `.ima`, `.flp`, `.vfd`, `.fd`) in the floppy drive |
| Load ROM | Load a different boot ROM for this session; the next start loads `boot0.rom` again |
| Memory | 32MB (default), 64MB, 128MB or 16MB. The machine never gets more than the MiSTer's SDRAM module has: 128MB on a 32 MB module runs as 32 MB |
| Network interface | eth0 (default), None, eth1, macvlan or tap0: what the Turbo's Ethernet is wired to (see Network). None is a machine without a cable |
| Machine > | P1: the **Power key** (NeXTSTEP's power-off panel, as F10) and **NMI (monitor)** (the ROM monitor, as F11) |
| Video > | P2: **Aspect ratio** and **Scale**, how the scaler fits the picture (see Display) |
| Input > | P3: **Swap Alt/Win keys** (see Keyboard and mouse) |
| Advanced > | P5: **Boot device** (SCSI disk (default), Prompt = stay at `NeXT>`, Network or Floppy; written to the NVRAM boot command) and **Self test** (On: the ROM tests the machine at power-on; Off: a faster start) |
| Changes pending | Shown while a changed setting is waiting for Apply and reset |
| Apply and reset | Reset the machine with the current settings and close the OSD; the disk mounts stay |

**When settings take effect.** The disks and Input act at once. Everything
else (Memory, Network interface, Video, Advanced) is taken at the next reset:
Apply and reset, the MiSTer's reset button or the next core start. Until then
"Changes pending" shows. The keyboard's reset (Win+Alt+keypad *) restarts
the machine with the settings it is running. The NVRAM is not kept: at
power-on and at each reset it gets a default image with the OSD's boot device.

All disk slots, the CD-ROM and the floppy included, are remembered and
mounted again when the core starts.

**Updating from an older release.** The 2026-10 menu keeps the saved
settings: Memory, Self test, Boot device, Aspect ratio and Scale carry over.
The network is the exception: the old "Ethernet" switch is gone, and
"Network interface" starts at eth0 for everyone, so a core that was
"Disconnected" is now on the LAN. Pick None once to turn it off.

## Display: use 1080p

The NeXT screen is 1120x832. If `MiSTer.ini` does not set a video mode, the MiSTer
takes the display's preferred mode, often 1280x720. It then has to shrink 832
lines into 720, and the ROM monitor's text comes out smeared. Give the core its
own 1080p section instead:

1. Edit `/media/fat/MiSTer.ini` on the SD card, over SSH or with the card in a PC.
   Keep a copy of the original first, for example `cp MiSTer.ini MiSTer.ini.bak`.
2. Add this section at the end of the file. The section name must match the
   core name exactly.

   ```ini
   [NeXT-Color]
   video_mode=8      ; 1920x1080@60
   vscale_mode=3     ; 0.25 steps: 1.25x = 1400x1040
   vfilter_default=No Interpolation.txt
   ```

3. Load the core again, or reboot the MiSTer. The MiSTer reads the core's
   section each time the core loads.

`vscale_mode=3` lets the scaler use quarter steps, so 832 lines become exactly
1040 (5/4): every fourth pixel and line is repeated, a regular pattern, and the
picture fills 96% of the height. `No Interpolation` keeps those edges hard; the
filter can be changed live in the OSD's video processing menu (for example
`Upscaling - SharpBilinear/SharpBilinear_050.txt` for more even stroke weight).
Without the two extra lines, Normal stretches 832 lines to 1080 (1.298x), which
cannot stay crisp.

Then choose the look in the core's OSD, under **Scale**:

| Scale | Result on 1080p |
|---|---|
| V-Integer (default) | 1:1 pixel-perfect 1120x832, centred with borders. The sharpest text; needs no `vscale_mode` line |
| Normal | with `vscale_mode=3`: 1400x1040, an exact 1.25x. Without it: 1454x1080, soft |

On a 1280x1024 monitor V-Integer also shows the picture 1:1 (832 lines fit in
1024); set that monitor's mode in the section instead of `video_mode=8` (the
mode numbers are listed in the MiSTer.ini that ships with MiSTer).

If even V-Integer is not razor sharp, the display itself is rescaling the
1080p signal: set it to "Just Scan", "1:1" or PC mode.

**Aspect ratio** "Original" is 1120:832 (35:26), i.e. square pixels, as on the
NeXT display.

To undo the change, delete the `[NeXT-Color]` section. Other `video_mode` values
are listed in the MiSTer.ini that ships with MiSTer (for example `9` is
1920x1080@50).

The picture goes out over HDMI through the MiSTer scaler. The native signal
has a 61.3 kHz line rate; the analog output has not been tried, has no OSD
menu, and there is no composite or S-Video output (see Building).

## Disks

* **Hard disks**: SCSI targets 0 and 1. With **Boot device** "SCSI disk"
  (the default) the ROM boots NeXTSTEP from target 0 (the NVRAM boot command
  is `sd`); at `NeXT>` type `bsd` (or `b sd`).
* **CD-ROM**: target 3. The drive is always on the SCSI bus, empty or not, so
  NeXTSTEP finds it at boot ("PreviousCD-ROM ... as sd1 at sc0 target 3") and
  a disc mounted in the OSD while NeXTSTEP runs appears in the Workspace
  (tested with NeXT software CDs; NeXT UFS discs mount as `/<volume name>`).
  The mount is remembered, like the disks'.
* **Floppy**: the 82077 and a 2.88 MB drive (remembered too: a writable
  image stays in the drive at the next start). NeXTSTEP attaches it as `fd0`;
  the Workspace's Initialize formats an image at 2.88 MB, and files written
  there land in the image on the SD card. NeXTSTEP 3.3 does not read a DOS
  file system on a 2.88 MB disk (its sectors read correctly).
* The target responses (INQUIRY, READ CAPACITY, ...) come from Main (see
  Installing).

## Network

The OSD's **Network interface** chooses what the Turbo's 7213 Ethernet is
wired to; it takes effect at the next reset (Apply and reset):

| Value | |
|---|---|
| eth0 (default) | The MiSTer's wired eth0, shared with Linux; the guest's own MAC, 00:00:0F:12:34:56, is filtered |
| None | No cable |
| eth1 | A second wired interface, if the MiSTer has one (else off) |
| macvlan | A macvlan interface on eth0 |
| tap0 | A tap interface, for a bridge set up on the Linux side |

This needs a Main that reads the interface from the core (Installing, step
3). NeXTSTEP 3.3 has no DHCP client: its `-AUTOMATIC-` setting is BOOTP,
which most routers do not answer, so give it a static address, for example
as root:

```
ifconfig en0 192.168.1.38 netmask 255.255.255.0 up
```

or permanently with HostManager, or `INETADDR`, `IPNETMASK` and `ROUTER` in
`/etc/hostconfig`.

## Keyboard and mouse

A PS/2 (or USB, through the MiSTer) keyboard and mouse act as the NeXT keyboard
and mouse. The Command keys are the Windows keys and the Alternate keys the
Alt keys; **Swap Alt/Win keys** (Input page, acts at once) swaps them, so the
key next to the space bar is Command, as on a NeXT keyboard. The volume keys
work. F10 is the power key and F11 enters the ROM monitor (NMI); the Machine
page has the same two as buttons. Win+Alt+keypad * resets the machine. At the
login window move the mouse once before typing, the first keys after boot can
be lost.

## Sound and DSP

* **Sound out** plays through the MiSTer's HDMI / analog audio (16-bit
  stereo, 44.1 kHz; 22.05 kHz sounds are doubled as on the real machine;
  the keyboard's volume keys work). There is no sound input (no microphone
  CODEC) and no DSP port (the DSP's serial ports have no connector here).
* **The DSP56001 runs in the FPGA** (`rtl/tc_dsp56k.sv`, `rtl/dsp56k`): the
  Falcon_MiSTer DSP56001 core (apolkosnik/Falcon_MiSTer `rtl/falcon/dsp`,
  checked against Hatari instruction by instruction) with the NeXT's host
  port, DSP DMA (packed and unpacked), SCR2 reset / start mode / memory
  enable, IRQB at a DMA block end and the TXD interrupt.  It runs at the
  machine clock, one instruction cycle per two clocks: 12.5 MIPS at
  25 MHz, a real 25 MHz 56001's rate.  External RAM: the standard 8K
  words (24 KB); no 96 KB expansion.  On hardware (2026-10-23) NeXTSTEP
  boots it, sndplay plays mu-law and ATC-compressed sounds through it, and
  playscore plays a Music Kit score.
* The DSP on the ARM (Previous's interpreter in Main, `next-color`, behind
  `rtl/tc_dsp.sv`) is still in the source: `NEXT_DSP_ARM` in
  `NeXT-Color.qsf` selects it.  `NEXT_NO_DSP` leaves the DSP out.

## Troubleshooting

| What you see | Cause and fix |
|---|---|
| Black screen, no POST, every time the core is loaded from the menu, with `main=` in `MiSTer.ini` | A core before 20261010: update the core. Main restarts once more to switch binaries, and that second core reset made the framework's DDR3 port drop the core's video-memory reads, which left the video memory (and the CPU) waiting forever. Fixed in 20261010 |
| Black screen, no POST (no "Testing system" screen, no disk access) | The core is running a ROM other than Rev 3.3 v74. `games/NeXT-Color/` should hold `boot0.rom` from `releases/` and no other `boot*.rom`: Main also loads `boot1.rom`, `boot2.rom` and `boot3.rom` at start, and cores before 2026-10 took them as the boot ROM, so a `boot1.rom` copied from the mono NeXT core (Rev 2.5, a 68030 ROM) replaced the Turbo ROM. Remove the extra files and load the core again |
| `No SCSI disk`, or `SCSI error` | The stock Main is running. Check OSD -> About shows MiSTer v261009 or later (Installing, step 3) |
| NeXTSTEP panics during boot (for example at the network) | With a core before 2026-10: more memory selected than the MiSTer's SDRAM module has; set Memory to 32 MB. Newer cores never give the machine more than the module |
| No network (the link is up but nothing answers) | Network interface is None, or the Main is too old to read it (Installing, step 3): an older Main leaves the network off |
| A setting changed but nothing happened | Settings outside the disks and Input wait for the next reset ("Changes pending"): use Apply and reset |
| Stops at `NeXT>` | Boot device is "Prompt", or no disk image is mounted in "Pri. disk (ID 0)": mount one and type `bsd`, or set Boot device to "SCSI disk" and Apply and reset |
| Blurry text | Display not set up: give the core a 1080p section in `MiSTer.ini` (Display) |

## Known limitations

* No sound input, no DSP serial port, no printer (its registers only), no
  ADB devices, no second display. The NVRAM is not saved.
* The FPGA is nearly full (about 95% of its logic), so fitter results vary a
  lot between builds: a build is released only when it meets timing, and a
  build that misses timing is only tried with NeXTSTEP shut down.

## Building

* `bash scripts/build_only.sh` (Git bash; `--check` = Analysis & Synthesis
  only). Machine settings in `scripts/local.env` (from `local.env.sample`).
  Quartus 17.0.x. A full build takes about 22 minutes; the result is released
  only if it meets timing (the script says so), otherwise the fitter seed in
  `NeXT-Color.qsf` is changed and the build repeated.
* Main: `bash scripts/build_main_wsl.sh` in WSL (branch `next-color` of
  `../Main_MiSTer`).
* Simulation and unit benches: `verilator/README.md` (`bash scripts/sim_wsl.sh`).

### Build switches in `NeXT-Color.qsf`

The MiSTer framework (`sys/`) and the CPU core have compile-time switches.
`sys/` is the stock framework except for one added switch
(`MISTER_DISABLE_VGA_OSD`, below); keep it when updating `sys/`. This core
sets these:

| Switch | Set | What it does |
|---|---|---|
| `MISTER_DISABLE_ADAPTIVE` | yes (since the first build, from the MacQuadra800 recipe) | Removes the scaler's adaptive scanline filtering, a CRT-style effect of no use on a desktop; saves logic in the HDMI scaler, where timing is tightest |
| `MISTER_DISABLE_ALSA` | yes (since the first build, from the MacQuadra800 recipe) | Removes the path that mixes Linux-side (ALSA) audio into the core's audio output; the NeXT's own sound is not affected |
| `MISTER_DISABLE_YC` | yes (2026-09-27) | Removes the composite / S-Video (Y/C) encoder of the analog output. The NeXT picture has a 61.3 kHz line rate (1120x832 at 68.4 Hz), which no composite or S-Video input can show, so the encoder never had a use here; its logic and multipliers are freed |
| `MISTER_DISABLE_VGA_OSD` | yes (2026-09-27) | No OSD menu on the analog output; HDMI keeps its OSD. Not a stock switch: `sys/sys_top.v` carries it from MacQuadra800_MiSTer's `sys/` (the analog video passes straight through, and the core's OSD-open input reads 0, which this core does not use). Frees ~514 ALMs |
| `NEXT_NO_DSP` | no (on 2026-09-28 .. 2026-10-22) | Leaves the DSP56001 out; its registers read 0 |
| `NEXT_DSP_ARM` | no | The DSP on the ARM (`rtl/tc_dsp.sv` + a Main from `next-color` with the DSP) instead of `rtl/tc_dsp56k.sv` in the FPGA |
| `AP040_EXPERIMENTAL_XSTORE`, `AP040_EXPERIMENTAL_LEA` | yes | 68040 core options, as in the validated MacQuadra800 build: stores that cross a data-cache line, and a faster LEA/PEA address path |

And leaves these off:

| Switch | Why not |
|---|---|
| `MISTER_DOWNSCALE_NN` | Nearest-neighbour instead of filtered downscaling. Saves scaler logic but makes text unreadable on a 720p output (832 lines onto 720); no effect at 1080p |
| `MISTER_SMALL_VBUF` | A 1 MB scaler buffer per frame: too small for 1120x832 |
| `MISTER_FB`, `MISTER_FB_PALETTE` | A Linux framebuffer on top of the core: not used |
| `MISTER_DEBUG_NOHDMI` | Removes HDMI: debug only |
| `MISTER_DUAL_SDRAM` | Pin layout for dual-SDRAM I/O boards |

The notes below come from the MiSTer template and describe the standard core layout. `<core_name>` is `NeXT-Color`.

## Source structure

### Legend:
* `<core_name>` - you have to use the same name where you see this in this manual. Basically it's your core name.

### Standard MiSTer core should have following folders:
* `sys` - the framework. Basically it's prohibited to change any files in this folder. Framework updates may erase any customization in this folder. All MiSTer cores have to include sys folder as is from this core.
* `rtl` - the actual source of core. It's up to the developer how to organize the inner structure of this folder. Exception is pll folder/files (see below).
* `releases` - the folder where rbf files should be placed. format of each rbf is: <core_name>_YYYYMMDD.rbf (YYYYMMDD is date code of release).

### Other standard files:
* `<core_name>.qpf`- quartus project file. Copy it as is and then modify the line `PROJECT_REVISION = "<core_name>"` according to your core name.
* `<core_name>.qsf` - quartus settings file. In most cases you don't need to modify anything inside (although you may wont to adjust some settings in quartus - this is fine, but keep changes minimal). You also need to watch this file before you make a commit. Quartus in some conditions may "spit" all settings from different files into this file so it will become large. If you see this, then simply revert it to original file.
* `<core_name>.srf` - optional file to disable some warnings which are safe to disable and make message list more clean, so you will have less chance to miss some important warnings. You are free to modify it.
* `<core_name>.sdc` - optional file for constraints in case if core require some special constraints. You are free to modify it.
* `<core_name>.sv` - glue logic between framework and core. This is where you adapt core specific signals to framework.
* `files.qip` - list of all core files. You need to edit it manually to add/remove files. Quartus will use this file but can't edit it. If you add files in Quartus IDE, then they will be added to `<core_name>.qsf` which is recommended manually move them to `files.qip`.
* `clean.bat` - windows batch file to clean the whole project from temporary files. In most cases you don't need to modify it.
* `.gitignore` - list of files should be ignored by git, so temporary files wont be included in commits.
* `jtag.cdf` - it will be produced when you compile the core. By clicking it in Quartus IDE, you will launch programmer where you can send the core to MiSTer over USB blaster cable (see manual for DE10-nano how to connect it). This file normally is not present on cleaned project and not included in commits.

### PLL:
Framework implies use of at least one PLL in the core. Framework doesn't contain this PLL but requires it to be placed in `rtl` folder, so `pll` folder and `pll.v`, `pll.qip` files must be present, however PLL settings are up to the core.

### Verilog Macros

The framework switches this core sets, and why, are listed under Building. The full list:

Macro                    |   Effect
-------------------------|---------------------------------
MISTER_DEBUG_NOHDMI      | Disable HDMI-related modules. Speeds up compilation but only analogue/direct video is available
MISTER_DUAL_SDRAM        | Changes configuration of FPGA pins to work with dual SDRAM I/O boards
MISTER_FB                | Allows to use framebuffer from the core
MISTER_SMALL_VBUF        | Sets a smaller video buffer for the ASCAL
MISTER_DOWNSCALE_NN      | Ascal's downscale mode
MISTER_DISABLE_ADAPTIVE  | Disables adaptive scan lines
MISTER_DISABLE_YC        | Disables the Y/C (composite / S-Video) output
MISTER_DISABLE_ALSA      | Disables mixing Linux (ALSA) audio into the core's audio output
MISTER_DISABLE_VGA_OSD   | No OSD on the analog output (added to this core's sys/, from MacQuadra800_MiSTer)
MISTER_FB_PALETTE        | Framebuffer palette


# Quartus version
Cores must be developed in **Quartus v17.0.x**. It's recommended to have updates, so it will be **v17.0.2**. Newer versions won't give any benefits to FPGA used in MiSTer, however they will introduce incompatibilities in project settings and it will make harder to maintain the core and collaborate with others. **So please stick to good old 17.0.x version.** You may use either Lite or Standard license.
