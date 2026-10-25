# NITRO RULES (Strict Engineering Guardrails)

- **RULE 1**: Never delete or rename C structs (`predator_v4`, etc.) inside the kernel driver C source (`linuwu_sense.c`), because 2023–2026 Acer Nitro laptops (Nitro V15, V16, 16, 17) use the V4 WMI GUID in hardware. Strip Predator ONLY in user-space (Python daemon and C# GUI).
- **RULE 2**: Never truncate existing functions or classes when editing `DAMX-Daemon.py` or C# files. Always use targeted edits and preserve all ENEK5130 HID ioctl and sysfs read/write methods.
- **RULE 3**: Never run `nvidia-smi` when the NVIDIA GPU PCI `power/runtime_status` is `suspended`.
- **RULE 4**: Always restore hardware auto-fan mode (`0,0`) if the daemon exits or stops.
