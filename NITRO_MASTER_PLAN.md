# Project NitroMax: Zero-Breakage Architecture & Rebuild Plan

## 0. Strict AI Agent Guardrails (DO NOT VIOLATE)
1. **DO NOT modify C structs in the kernel module (`linuwu_sense.c`)**: Many 2023–2026 Acer Nitro laptops (Nitro V15, V16, 16, 17) use Acer's `predator_v4` WMI GUID under the hood. Removing `predator_v4` from the C driver will brick those Nitro laptops. Keep the C driver intact; strip Predator exclusively in the Python Daemon and C# GUI.
2. **DO NOT spawn CLI subprocesses (`nvidia-smi`, `sensors`, `rocm-smi`) on a 2-second UI timer**: Spawning processes causes CPU spikes and wakes the NVIDIA dGPU from RTD3 sleep, destroying battery life. Read `/sys/class/hwmon/` and `/proc/stat` directly, and check `/sys/bus/pci/devices/.../power/runtime_status` before querying NVIDIA.
3. **DO NOT cold-start the GUI on Nitro keypress**: Run the GUI as a single-instance resident app (`--background` on login, hiding to memory when closed). Pressing the Nitro key sends an IPC event that brings the pre-rendered window to focus in < 5ms.
4. **ALWAYS restore hardware Auto Fan mode (`0,0`) on daemon exit**: If a custom software fan curve is active and the daemon stops or crashes, the `atexit` / `SIGTERM` handler and systemd `ExecStopPost` MUST write `0,0` to `fan_speed` so the laptop never overheats.

---

## 1. Subsystem 1: Bulletproof Kernel Driver, DKMS & Secure Boot (`scripts/`)

### 1.1 Why Updates & Boot Currently Break (And How We Fix It)
* **Problem**: Compiling into `/lib/modules/$(uname -r)` breaks the moment the Linux kernel updates.
* **Fix**: Register the driver with **DKMS** (`acer-nitro-dkms`), add an unstripped **POST_BUILD MOK signing hook**, and blacklist the conflicting mainline `acer_wmi` module.

### 1.2 File: `/usr/src/acer-nitro-1.0.0/dkms.conf`
```ini
PACKAGE_NAME="acer-nitro"
PACKAGE_VERSION="1.0.0"
CLEAN="make -C src clean"
MAKE[0]="if grep -qi clang /proc/version; then make LLVM=1 CC=clang -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build/src modules; else make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build/src modules; fi"
BUILT_MODULE_NAME[0]="linuwu_sense"
BUILT_MODULE_LOCATION[0]="src/"
DEST_MODULE_LOCATION[0]="/kernel/drivers/platform/x86/"
STRIP[0]="no"
AUTOINSTALL="yes"
POST_BUILD="dkms-sign-module.sh ${kernelver} ${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build/src/linuwu_sense.ko"
```
*(Note: `STRIP[0]="no"` is mandatory so DKMS does not strip the ELF binary after `POST_BUILD` attaches the cryptographic Secure Boot signature).*

### 1.3 File: `/usr/src/acer-nitro-1.0.0/dkms-sign-module.sh`
```bash
#!/bin/bash
set -e
KERNEL_VER="$1"
MODULE_PATH="$2"
KEY_DIR="/var/lib/damx/secureboot"
PRIV_KEY="${KEY_DIR}/DAMX-MOK.priv"
DER_CERT="${KEY_DIR}/DAMX-MOK.der"
SIGN_FILE="/lib/modules/${KERNEL_VER}/build/scripts/sign-file"

# Sign unconditionally if keys exist; signed modules work on both SB-enabled and SB-disabled systems
if [ -x "$SIGN_FILE" ] && [ -f "$PRIV_KEY" ] && [ -f "$DER_CERT" ]; then
    "$SIGN_FILE" sha256 "$PRIV_KEY" "$DER_CERT" "$MODULE_PATH"
fi
```

### 1.4 File: `/etc/modprobe.d/acer-nitro.conf`
```ini
# Prevent mainline acer_wmi from blocking linuwu_sense WMI registration
blacklist acer_wmi
```

### 1.5 File: `/etc/udev/rules.d/99-acer-nitro.rules`
```udev
# Start or notify daemon when acer-wmi platform driver binds
ACTION=="add|bind", SUBSYSTEM=="platform", DRIVER=="acer-wmi", TAG+="systemd", ENV{SYSTEMD_WANTS}+="damx-daemon.service"

# Match I2C-HID ENEK5130 RGB Controller (Bus 0018, Vendor 0CF2, Product 5130)
ACTION=="add", SUBSYSTEM=="hidraw", KERNELS=="*0CF2:5130*", TAG+="systemd", ENV{SYSTEMD_WANTS}+="damx-daemon.service"
```

---

## 2. Subsystem 2: Hardened, Predator-Free Root Daemon (`DAMX-Daemon.py`)

### 2.1 Complete De-Predatorization (User-Space)
* Remove `LaptopType.PREDATOR` from all IPC responses, logs, and API methods. The daemon reports `"NITRO"` exclusively to the GUI.
* **Smart Sysfs Path Resolution (Critical for Nitro V15/V16/16/17)**:
  1. Check `/sys/bus/platform/drivers/acer-wmi/acer-wmi/nitro_sense` first.
  2. Fallback to `/sys/module/linuwu_sense/drivers/platform:acer-wmi/acer-wmi/nitro_sense`.
  3. If a newer Nitro laptop uses the V4 WMI firmware and the kernel driver exposes it as `.../predator_sense`, bind `self.sysfs_base_path` to that directory silently while still setting `self.laptop_type = "NITRO"`. This keeps user-space 100% Nitro-branded while never breaking V4 hardware.
* Replace the `force_predator_model` IPC command with a unified `set_nitro_wmi_generation(gen: "auto" | "legacy" | "v4")` command (which writes `nitro_v4=1` or `predator_v4=1` under the hood if needed by a specific Nitro BIOS).

### 2.2 Security & Stability Fixes
* **Remove `/tmp/damx_restart_attempts` & the 20x rmmod Loop**:
  * Delete `RESTART_COUNTER_FILE = "/tmp/damx_restart_attempts"`.
  * Instead of recursively unloading the module and restarting 20 times, poll for the sysfs path with exponential backoff (`0.1s, 0.2s, 0.5s, 1.0s, 2.0s` — max 5 seconds total) during daemon startup, and trigger `modprobe linuwu_sense` at most once if `/sys/module/linuwu_sense` is missing.
* **Harden Unix Domain Socket (`/run/damx/DAMX.sock` with symlink `/var/run/DAMX.sock`)**:
  * Create group `nitromax` (or fall back to `wheel`/`sudo`/`adm`).
  * Set socket permissions to `0o660` (`root:nitromax`) instead of `0o666`, AND verify caller UID via `SO_PEERCRED` (`sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)`) to reject unauthorized system daemons.
* **Fix IPC Truncation (Newline-Delimited Framing)**:
  * Instead of a single unframed `recv(4096)` pass, read chunks in a loop until `\n` is encountered (or EOF), and append `\n` to all JSON responses. Keep compatibility with legacy unframed single-packet commands.
* **Delete Orphaned Code**:
  * Delete the global `def signal_handler(self, sig, frame):` at the bottom of `DAMX-Daemon.py`.

### 2.3 New Daemon Features: Custom Fan Curve Loop & Sleep/Wake Persistence
* **Daemon-Managed Custom Fan Curve with Hysteresis**:
  * New IPC command: `set_custom_fan_curve(enabled: bool, cpu_points: list, gpu_points: list)`.
  * When enabled, a background daemon thread reads CPU/GPU temps from `/sys/class/hwmon/` every 2 seconds, calculates target fan percentage using linear interpolation with a 3°C hysteresis band (preventing annoying fan revving up and down), and writes `<cpu>,<gpu>` to `fan_speed`.
  * **Safety Failsafe**: Register `atexit` and `SIGTERM`/`SIGINT` handlers to write `0,0` (Hardware Auto) to `fan_speed` whenever the daemon exits.
* **State Persistence Across Reboot & Suspend/Resume (`/var/lib/damx/state.json`)**:
  * Save active thermal profile, fan mode, battery limiter, USB charging level, and last 11-byte ENEK5130 RGB packet to `/var/lib/damx/state.json`.
  * Re-apply saved settings on daemon startup and whenever `/sys/power/wakeup_count` changes or systemd resumes from sleep.

---

## 3. Subsystem 3: Safe Hotkey & Instant Window Toggle (`nitro-key-detection.sh` + IPC)
* **Eliminate `source /etc/damx/nitro_key.conf`**:
  * Replace `source` with strict regex extraction:
    ```bash
    KEYCODE=$(grep -E '^(KEYCODE|NITRO_KEY)=[0-9]+$' /etc/damx/nitro_key.conf 2>/dev/null | cut -d= -f2)
    : "${KEYCODE:=425}"
    ```
* **Instant IPC Toggle Instead of Slow Process Spawn**:
  * When keycode 425 (value 1 key press) is detected by `evtest`, send `{"command": "nitro_key_pressed"}\n` to `/var/run/DAMX.sock` using `socat` or a clean Python one-liner.
  * Only spawn a new GUI process via `sudo -u` if no GUI client is currently connected to the daemon.

---

## 4. Subsystem 4: Next-Gen Nitro GUI (`DivAcerManagerMax/` $\rightarrow$ `NitroSenseMax`)

### 4.1 De-Predatorization & Visual Overhaul
* Remove all Predator strings, logos, and the "Force Predator Model" button in `InternalsManager.axaml` / `.axaml.cs`.
* **Aesthetic Upgrade**: Apply a sleek Nitro Obsidian & Crimson/Neon theme (`#0B0C10` deep background, `#141720` glassmorphic cards with 1px `#252A38` borders, `#FF1E42` Nitro Crimson primary accent, `#00F0FF` Cyber Cyan telemetry accent).

### 4.2 Fix All C# Bugs (`DAMXClient.cs` & `InternalsManager.axaml.cs`)
* `InternalsManager.axaml.cs`: Add `await` to every `_mainWindow._client.SendCommandAsync(...)` call and mark event handlers `async void` with proper `try/catch` error notifications.
* `DAMXClient.cs`: Replace fixed 4096-byte buffer read with `StreamReader.ReadLineAsync()` (or a `MemoryStream` loop) so large JSON payloads never truncate.

### 4.3 Fix Telemetry Lag & Battery Drain (`Dashboard.axaml.cs`)
* **CPU Temp & Usage**: Cache the discovered `/sys/class/hwmon/hwmon*/temp*_input` path on startup instead of scanning directories every 2 seconds. Read `/proc/stat` directly in memory.
* **RTD3-Safe GPU Telemetry**:
  * Locate the NVIDIA PCI device in `/sys/bus/pci/devices/` (vendor `0x10de`).
  * Before calling `nvidia-smi`, read `power/runtime_status`.
  * If `runtime_status` is `"suspended"`, **DO NOT run `nvidia-smi`**! Display "Sleeping (Eco)" and 0°C in the UI.
  * Only query `nvidia-smi` when `runtime_status` is `"active"`, and use a persistent `nvidia-smi --loop=2 --query-gpu=temperature.gpu,utilization.gpu --format=csv,noheader,nounits` background stream instead of spawning a new process every 2 seconds.

### 4.4 Instant <5ms Launch (Resident Mode) & New Innovative Features
* **Single-Instance Resident Mode (`MainWindow.axaml.cs` & `Program.cs`)**:
  * Support `--background` CLI flag (used by `~/.config/autostart/nitromax.desktop`).
  * Override `Window.OnClosing`: when the user clicks X, cancel window destruction, pause the 2-second UI telemetry timer (dropping CPU usage to 0.0%), and call `this.Hide()`.
  * Listen for the `nitro_key_pressed` broadcast from `DAMXClient` (or POSIX `SIGUSR1` signal): if hidden, resume the telemetry timer and call `this.Show(); this.WindowState = WindowState.Normal; this.Activate();` (takes < 5ms); if already focused, toggle the compact Nitro OSD HUD or minimize.
* **Interactive Fan Curve Editor Tab**:
  * Add a visual 4-point draggable curve editor (40°C, 60°C, 75°C, 90°C) in the Fan Control section that sends `set_custom_fan_curve` to the daemon.
* **Nitro OSD Overlay (`NitroOsdWindow.axaml`)**:
  * A borderless, non-activating, top-right transparent HUD pill (`280x70px`, `Topmost="True"`) that slides in for 1.8 seconds showing current Thermal Profile, CPU/GPU Temp, and Fan RPM whenever the Thermal Profile changes or the Nitro key is double-pressed.

---

## 5. End-to-End System Flowchart

```
[Kernel Update: apt / pacman / dnf]
│
▼
[DKMS Auto-Build (acer-nitro 1.0.0)] ──► Checks /proc/version for Clang (LLVM=1)
│
▼
[POST_BUILD: dkms-sign-module.sh]    ──► Signs linuwu_sense.ko with MOK (STRIP="no")
│
▼
[Boot: udev 99-acer-nitro.rules]     ──► Starts damx-daemon.service when WMI/HID binds
│
▼
[Root Daemon: DAMX-Daemon.py]        ──► Restores /var/lib/damx/state.json (RGB + Fans)
│                                    ──► Opens /var/run/DAMX.sock (0o660, framed JSON)
▼
[User Login: NitroSenseMax --background]
│                                    ──► Stays hidden in memory (0% CPU when hidden)
▼
[User Presses Physical Nitro Key]    ──► Instant IPC wake -> Window appears in < 5ms!
```

---

## 6. Phased Implementation Steps for AI Execution

### Step 1: Fix Kernel Updates, DKMS & Secure Boot
1. Consolidate remote setup scripts: keep `scripts/remoteSetup.sh` (v1.0.0 with sha256 + release API) and remove legacy duplicates.
2. Create `scripts/dkms.conf` and `scripts/dkms-sign-module.sh` with `STRIP[0]="no"` and Clang/LLVM auto-detection.
3. Create `scripts/acer-nitro.modprobe.conf` (`blacklist acer_wmi`).
4. Create `scripts/99-acer-nitro.rules` for udev binding.
5. Update `scripts/local-setup.sh` to install via DKMS (`/usr/src/acer-nitro-1.0.0`), register MOK signing, install modprobe blacklist, and configure udev rules. Verify with `bash -n`.

### Step 2: Harden & De-Predatorize the Root Daemon
1. Smart sysfs path detection: always set `laptop_type = NITRO`; probe `nitro_sense` first, fall back silently to `predator_sense` for WMI v4 Nitro models.
2. Remove `/tmp/damx_restart_attempts` and the 20x loop; use a 5s exponential backoff startup poll.
3. Remove orphaned global `signal_handler`.
4. Secure `/var/run/DAMX.sock` with `0o660` + group + `SO_PEERCRED`.
5. Frame JSON IPC with newline delimiters to prevent 4KB truncation.
6. Implement `/var/lib/damx/state.json` persistence across boot and sleep/resume.
7. Implement `set_custom_fan_curve` with 3°C hysteresis and failsafe reset to `0,0` on exit.
8. Implement `nitro_key_pressed` IPC command/event.

### Step 3: Fix Hotkey Script & C# IPC / Async Bugs
1. In `scripts/nitro-key-detection.sh`, replace `source` with strict regex extraction of `KEYCODE`.
2. Check if GUI process is already running for target user; send `nitro_key_pressed` IPC / `SIGUSR1` to wake it instantly instead of slow process spawning.
3. In `DAMXClient.cs`, use dynamic buffer/stream reader to eliminate 4096-byte truncation.
4. In `InternalsManager.axaml` and `.cs`, rebrand WMI parameters strictly for Nitro and await all `SendCommandAsync` calls.

### Step 4: RTD3-Safe Telemetry, Instant-Wake Resident Mode & Cyber-Nitro UI
1. In `Dashboard.axaml.cs`, check NVIDIA PCI `runtime_status` before calling `nvidia-smi` to prevent dGPU battery drain.
2. In `Program.cs` and `MainWindow.axaml.cs`, implement `--background` resident mode, hide on close (pause timer), and instant unhide (<5ms) on `nitro_key_pressed` or `SIGUSR1`.
3. Add interactive 4-point custom fan curve UI editor.
4. Refine dark obsidian & crimson theme, enable `<PublishReadyToRun>true</PublishReadyToRun>` in `.csproj`.
