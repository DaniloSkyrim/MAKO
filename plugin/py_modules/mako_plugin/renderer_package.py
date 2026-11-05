"""Bundled MAKO Renderer package metadata shared by Decky services.

``package.json`` is the only description of the Renderer archive a MAKO Decky
package ships. Installation validates and installs that archive; wrapper
generation uses the same native host identity to select per-architecture
Vulkan layer names. Both read it here so the two can never disagree.
"""

import json
from pathlib import Path
from typing import TypedDict

from .constants import (
    LEGACY_RENDERER_HOST_ARCHITECTURE,
    SUPPORTED_RENDERER_HOST_ARCHITECTURES,
)


class RendererArchiveMetadata(TypedDict):
    """Validated Renderer payload metadata consumed by installation."""

    name: str
    version: str
    sha256hash: str
    architectures: list[str]
    host_architectures: list[str]


def read_bundled_renderer_metadata(plugin_dir: Path) -> RendererArchiveMetadata:
    """Return the versioned host payload metadata from package.json."""
    manifest_path = plugin_dir / "package.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        if "bundled_renderer" in manifest:
            if "remote_binary" in manifest:
                raise ValueError(
                    "package.json must not define both bundled_renderer and remote_binary"
                )
            binary = manifest["bundled_renderer"]
            metadata_name = "bundled_renderer"
            if not isinstance(binary, dict):
                raise ValueError("bundled_renderer must be an object")
        else:
            binaries = manifest.get("remote_binary")
            if not isinstance(binaries, list) or len(binaries) != 1:
                raise ValueError(
                    "package.json must define bundled_renderer or exactly one "
                    "remote_binary entry"
                )
            binary = binaries[0]
            metadata_name = "remote_binary"
        archive_name = binary.get("name")
        version = binary.get("version")
        checksum = binary.get("sha256hash")
        architectures = binary.get("architectures", ["64", "32"])
        host_architectures = binary.get("host_architectures", ["x86_64"])
        if not isinstance(archive_name, str) or Path(archive_name).name != archive_name:
            raise ValueError(f"{metadata_name} name must be a filename")
        if not isinstance(version, str) or not version:
            raise ValueError(f"{metadata_name} version must be a non-empty string")
        if (
            not isinstance(checksum, str)
            or len(checksum) != 64
            or any(character not in "0123456789abcdefABCDEF" for character in checksum)
        ):
            raise ValueError(
                f"{metadata_name} sha256hash must be a SHA-256 checksum"
            )
        if (
            not isinstance(architectures, list)
            or not architectures
            or any(architecture not in ("64", "32") for architecture in architectures)
            or "64" not in architectures
        ):
            raise ValueError(
                f"{metadata_name} architectures must contain 64 and optional 32"
            )
        if (
            not isinstance(host_architectures, list)
            or len(host_architectures) != 1
            or host_architectures[0] not in SUPPORTED_RENDERER_HOST_ARCHITECTURES
        ):
            # One archive contains one native ISA; its 64/32 entries
            # describe Vulkan client bitness on that host.
            raise ValueError(
                f"{metadata_name} host_architectures must name exactly one "
                "supported native host"
            )
        if host_architectures[0] != "x86_64" and "32" in architectures:
            raise ValueError(
                f"{metadata_name} architectures must be 64-bit only for "
                f"{host_architectures[0]}"
            )
        return {
            "name": archive_name,
            "version": version,
            "sha256hash": checksum,
            "architectures": architectures,
            "host_architectures": host_architectures,
        }
    except (OSError, json.JSONDecodeError, TypeError, ValueError, KeyError) as exc:
        raise OSError(f"Could not read bundled MAKO Renderer metadata from {manifest_path}: {exc}") from exc


def bundled_renderer_host_architecture(plugin_dir: Path) -> str:
    """Return the package's native Renderer ISA, failing closed to x86_64.

    Unreadable metadata keeps the published x86_64 identity, so the wrapper
    guard still bypasses MAKO on any other host.
    """
    try:
        return read_bundled_renderer_metadata(plugin_dir)[
            "host_architectures"
        ][0]
    except OSError:
        return LEGACY_RENDERER_HOST_ARCHITECTURE
