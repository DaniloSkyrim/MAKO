"""Native-host detection shared by Renderer and Flatpak safety boundaries."""

from dataclasses import dataclass
import os
import platform
from pathlib import Path
from typing import Any, Optional

from .constants import ARMADA_DEVICE_ENV, DROIDDECK_SESSION_MARKER

# Bound the ancestor walk; a real launch chain is a handful of processes deep.
_MAX_ANCESTOR_DEPTH = 32


@dataclass(frozen=True)
class HostEnvironment:
    """Describe the plugin process and the native host beneath translation."""

    process_architecture: str
    native_architecture: str
    armada: bool
    droiddeck: bool = False

    @property
    def translated(self) -> bool:
        return self.process_architecture != self.native_architecture


def normalize_host_architecture(machine: str) -> str:
    """Return the canonical architecture spelling used by package metadata."""
    normalized = machine.strip().lower()
    if normalized in {"amd64", "x86_64"}:
        return "x86_64"
    if normalized in {"arm64", "aarch64"}:
        return "aarch64"
    return normalized or "unknown"


def _elf_host_architecture(executable: Path) -> Optional[str]:
    """Read only the ELF identity needed to identify a native host process."""
    with executable.open("rb") as host_executable:
        elf_header = host_executable.read(20)
    if elf_header[:4] != b"\x7fELF" or elf_header[5] not in (1, 2):
        return None
    byte_order = "little" if elf_header[5] == 1 else "big"
    return {
        62: "x86_64",
        183: "aarch64",
    }.get(int.from_bytes(elf_header[18:20], byte_order))


def _parent_pid(proc_root: Path, pid: int) -> Optional[int]:
    """Read one process's parent from procfs without trusting its name."""
    try:
        status = (proc_root / str(pid) / "status").read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    for line in status.splitlines():
        if line.startswith("PPid:"):
            try:
                parent = int(line.split(":", 1)[1].strip())
            except ValueError:
                return None
            return parent if parent > 0 else None
    return None


def _native_process_candidates(
        proc_root: Path,
        native_process: Optional[Path],
) -> list[Path]:
    """Return PID 1 and this process's ancestors, nearest native first.

    FEX reports the guest ISA through ``platform.machine()`` and its own
    ``/proc/self/exe`` emulation, but the emulator and its native launcher
    remain ordinary AArch64 ancestors. PID 1 is often unreadable inside a
    proot or container, so the parent chain is the portable fallback.
    """
    if native_process is not None:
        return [native_process]
    candidates = [proc_root / "1" / "exe"]
    seen = {1}
    pid = _parent_pid(proc_root, os.getpid())
    while pid is not None and pid not in seen and len(seen) < _MAX_ANCESTOR_DEPTH:
        seen.add(pid)
        candidates.append(proc_root / str(pid) / "exe")
        pid = _parent_pid(proc_root, pid)
    return candidates


def detect_host_environment(
        logger: Optional[Any] = None,
        *,
        process_machine: Optional[str] = None,
        armada_marker: Optional[Path] = None,
        droiddeck_marker: Optional[Path] = None,
        native_process: Optional[Path] = None,
        proc_root: Path = Path("/proc"),
) -> HostEnvironment:
    """Detect the native ISA even when Decky's Python process runs in FEX.

    Armada's root-owned device marker and DroidDeck's session helper are
    authoritative platform signals. Otherwise any AArch64 ELF among PID 1 and
    this process's ancestors proves an AArch64 host, because an x86_64 host
    cannot run AArch64 code natively; an ordinary native process falls back
    to ``platform.machine()``.
    """
    process_architecture = normalize_host_architecture(
        process_machine if process_machine is not None else platform.machine()
    )
    armada_path = ARMADA_DEVICE_ENV if armada_marker is None else armada_marker
    droiddeck_path = (
        DROIDDECK_SESSION_MARKER if droiddeck_marker is None else droiddeck_marker
    )

    if armada_path.is_file():
        if logger:
            logger.info("Detected native AArch64 Armada host through device-env")
        return HostEnvironment(
            process_architecture=process_architecture,
            native_architecture="aarch64",
            armada=True,
        )

    if droiddeck_path.is_file():
        if logger:
            logger.info(
                "Detected native AArch64 DroidDeck host (plugin process: %s)",
                process_architecture,
            )
        return HostEnvironment(
            process_architecture=process_architecture,
            native_architecture="aarch64",
            armada=False,
            droiddeck=True,
        )

    native_architecture = process_architecture
    for candidate in _native_process_candidates(proc_root, native_process):
        try:
            detected = _elf_host_architecture(candidate)
        except OSError as error:
            if logger:
                logger.debug(
                    "Could not inspect %s for the native host architecture: %s",
                    candidate,
                    error,
                )
            continue
        if detected is None:
            continue
        if detected == "aarch64" or candidate == native_process:
            native_architecture = detected
            if logger and detected != process_architecture:
                logger.info(
                    "Detected native %s host through %s (plugin process: %s)",
                    detected,
                    candidate,
                    process_architecture,
                )
            break
        if candidate.parent.name == "1":
            native_architecture = detected

    return HostEnvironment(
        process_architecture=process_architecture,
        native_architecture=native_architecture,
        armada=False,
    )


def detect_power_source(root: Path = Path("/sys/class/power_supply")) -> str:
    """Match the independently deployed Renderer's system-supply policy."""
    def read(path: Path) -> str:
        try:
            return path.read_text(encoding="utf-8").strip()
        except OSError:
            return ""

    try:
        entries = list(root.iterdir())
    except OSError:
        return ""
    if len(entries) > 64:
        return ""
    battery = supply = incomplete = False
    for path in entries:
        if read(path / "scope") == "Device":
            continue
        kind = read(path / "type")
        if kind == "Battery":
            battery |= read(path / "present") != "0"
        elif kind in {"Mains", "USB", "USB_C", "USB_PD", "USB_DCP", "USB_CDP", "USB_ACA", "Wireless"}:
            supply = True
            online = read(path / "online")
            if online == "1":
                return "docked"
            incomplete |= online != "0"
        elif not kind:
            incomplete = True
    return "handheld" if battery and supply and not incomplete else ""
