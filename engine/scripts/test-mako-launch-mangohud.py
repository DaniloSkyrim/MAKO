#!/usr/bin/env python3
"""Exercise the real standalone launcher without loading a graphics driver."""
import concurrent.futures
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

LAUNCHER = Path(__file__).with_name("mako-launch")
# The launcher admits MangoHud manifests for its recorded package architecture
# only when it runs on that same ISA. Exercise the host's own package shape.
HOST_ARCH = "aarch64" if platform.machine() in ("aarch64", "arm64") else "x86_64"
SUFFIXES = {"64": HOST_ARCH, "32": "x86"}
BITS = ("64", "32") if HOST_ARCH == "x86_64" else ("64",)


class MangoHudLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="mako-mangohud-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environment = {
            "PATH": "/usr/bin:/bin", "HOME": str(self.root),
            "XDG_CONFIG_HOME": str(self.root / "config with spaces'"),
            "XDG_CONFIG_DIRS": str(self.root / "config-dirs"),
            "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_DATA_DIRS": str(self.root / "system"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
        }
        self.manifests = self.root / "system/vulkan/implicit_layer.d"
        self.manifests.mkdir(parents=True)
        self.private = self.root / "cache/mako-render/mangohud"
        self.shared = Path(self.environment["XDG_CONFIG_HOME"]) / "mako-render/mangohud.conf"
        self.shared.parent.mkdir(parents=True)
        self.launcher = self.root / "prefix/bin/mako-launch"
        self.launcher.parent.mkdir(parents=True)
        shutil.copy(LAUNCHER, self.launcher)
        self.record = self.root / "prefix/share/mako-render/host-architecture"
        self.record.parent.mkdir(parents=True)
        self.record.write_text(HOST_ARCH + "\n")

    def manifest(self, bits="64", **updates):
        suffix = SUFFIXES[bits]
        library = self.root / ("libMangoHud" + bits + ".so")
        library.write_bytes(b"synthetic library; never loaded")
        layer = {
            "name": "VK_LAYER_MANGOHUD_overlay_" + suffix,
            "type": "GLOBAL", "library_path": str(library),
            "enable_environment": {"MANGOHUD": "1"},
            "disable_environment": {"DISABLE_MANGOHUD": "1"},
        }
        layer.update(updates)
        path = self.manifests / ("MangoHud." + suffix + ".json")
        path.write_text(json.dumps({"file_format_version": "1.0.0", "layer": layer}))
        return path

    def run_launcher(self, *args, **environment):
        return subprocess.run(
            ["bash", str(self.launcher), *args],
            env={**self.environment, **environment},
            text=True, capture_output=True, timeout=10, cwd=self.root,
        )

    def game(self, **environment):
        result = self.run_launcher("/usr/bin/env", **environment)
        self.assertEqual(result.returncode, 0, result.stderr)
        return dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)

    def test_availability_check_is_read_only(self):
        result = self.run_launcher("--check-mangohud")
        self.assertEqual(json.loads(result.stdout), {"available": False})
        self.manifest()
        result = self.run_launcher("--check-mangohud")
        self.assertEqual(json.loads(result.stdout), {"available": True})
        self.assertFalse(self.private.exists())
        self.assertFalse(self.shared.exists())

    def test_native_order_and_configuration_precedence_for_both_architectures(self):
        for bits in BITS:
            with self.subTest(bits=bits):
                for path in self.manifests.iterdir():
                    path.unlink()
                self.manifest(bits)
                self.shared.write_text("fps\nframetime\n")
                for inherited in ("", "/run/gamescope/mangohud.conf", "/custom.conf"):
                    env = self.game(MANGOHUD="1", MANGOHUD_CONFIGFILE=inherited,
                                    MANGOHUD_CONFIG="read_cfg,fps", DISABLE_MANGOHUD="1",
                                    VK_INSTANCE_LAYERS="VK_LAYER_MANGOHUD_overlay_x86:VK_LAYER_TEST:VK_LAYER_MANGOHUD_overlay_" + HOST_ARCH + ":VK_LAYER_MAKO_render")
                    self.assertEqual(env["MANGOHUD_CONFIGFILE"], str(self.shared))
                    self.assertEqual(env["MANGOHUD_CONFIG"], "read_cfg,fps")
                    self.assertEqual(env["MANGOHUD"], "1")
                    self.assertNotIn("DISABLE_MANGOHUD", env)
                    self.assertTrue(env["VK_IMPLICIT_LAYER_PATH"].endswith(":" + str(self.private)))
                    self.assertNotIn(str(self.manifests), env["VK_IMPLICIT_LAYER_PATH"])
                    if bits == "64":
                        self.assertEqual(env["VK_INSTANCE_LAYERS"], "VK_LAYER_MAKO_render:VK_LAYER_MANGOHUD_overlay_" + HOST_ARCH + ":VK_LAYER_TEST")
                    else:
                        self.assertNotIn("MANGOHUD", env["VK_INSTANCE_LAYERS"])
                staged = list(self.private.glob("*.json"))
                self.assertEqual(len(staged), 1)
                self.assertEqual(json.loads(staged[0].read_text())["layer"]["library_arch"], bits)

    def test_missing_or_invalid_shared_file_preserves_inheritance(self):
        self.manifest()
        for kind in ("missing", "directory", "fifo", "dangling"):
            with self.subTest(kind=kind):
                if kind == "directory": self.shared.mkdir()
                elif kind == "fifo": os.mkfifo(self.shared)
                elif kind == "dangling": self.shared.symlink_to(self.root / "absent")
                env = self.game(MANGOHUD="1", MANGOHUD_CONFIGFILE="/previous.conf")
                self.assertEqual(env["MANGOHUD_CONFIGFILE"], "/previous.conf")
                if kind == "directory": self.shared.rmdir()
                elif kind != "missing": self.shared.unlink()

    def test_live_file_changes_and_per_game_override_do_not_regenerate_profiles(self):
        self.manifest()
        self.assertNotIn("MANGOHUD_CONFIGFILE", self.game(MANGOHUD="1"))
        self.shared.write_text("fps\n$(touch should-not-exist)\n")
        self.assertEqual(self.game(MANGOHUD="1")["MANGOHUD_CONFIGFILE"], str(self.shared))
        result = self.run_launcher("env", "MANGOHUD_CONFIGFILE=/game.conf", "/usr/bin/env", MANGOHUD="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("MANGOHUD_CONFIGFILE=/game.conf\n", result.stdout)
        self.assertFalse((self.root / "should-not-exist").exists())
        self.shared.unlink()
        self.assertNotIn("MANGOHUD_CONFIGFILE", self.game(MANGOHUD="1"))

    def test_inactive_unavailable_disabled_and_flatpak_are_isolated(self):
        self.shared.write_text("fps\n")
        for extra in ({}, {"MANGOHUD": "0"}, {"MANGOHUD": "1"},
                      {"MANGOHUD": "1", "DISABLE_MAKO": "1"}):
            with self.subTest(extra=extra):
                env = self.game(MANGOHUD_CONFIGFILE="/inherited", **extra)
                self.assertEqual(env["MANGOHUD_CONFIGFILE"], "/inherited")
                self.assertNotIn("MANGOHUD", env)
                self.assertFalse(self.private.exists())
        self.manifest()
        env = self.game(MANGOHUD="1", FLATPAK_ID="test.app", MANGOHUD_CONFIGFILE="/inherited")
        self.assertNotIn("MANGOHUD", env)
        self.assertEqual(env["MANGOHUD_CONFIGFILE"], "/inherited")
        flatpak = self.root / "flatpak"
        flatpak.write_text("#!/bin/sh\nexec /usr/bin/env\n")
        flatpak.chmod(0o755)
        result = self.run_launcher(str(flatpak), "run", "test.app", MANGOHUD="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("MANGOHUD=1", result.stdout.splitlines())
        self.assertFalse(self.private.exists())
        self.assertEqual(json.loads(self.run_launcher("--check-mangohud", FLATPAK_ID="test.app").stdout), {"available": False})

    def test_invalid_manifest_shapes_and_gates_are_rejected(self):
        for updates in ({"name": "VK_LAYER_TEST"}, {"type": "INSTANCE"},
                        {"library_arch": "32"}, {"enable_environment": {}},
                        {"disable_environment": {"WRONG": "1"}},
                        {"library_path": "/does/not/exist.so"}, {"library_path": ""}):
            with self.subTest(updates=updates):
                self.manifest(**updates)
                self.assertNotIn("MANGOHUD", self.game(MANGOHUD="1"))
                self.assertFalse(self.private.exists())
        path = self.manifest()
        for content in ("[]", "null", "{bad", "x" * 65537,
                        '{"layers":[{"name":"VK_LAYER_TEST"}]}'):
            path.write_text(content)
            self.assertFalse(json.loads(self.run_launcher("--check-mangohud").stdout)["available"])
        path.unlink()
        os.mkfifo(path)
        self.assertFalse(json.loads(self.run_launcher("--check-mangohud").stdout)["available"])

    def test_relative_library_is_resolved_and_foreign_layers_are_not_staged(self):
        (self.manifests / "libMangoHud.so").write_bytes(b"fixture")
        self.manifest(library_path="./libMangoHud.so")
        (self.manifests / "unrelated.json").write_text('{"layer":{"name":"foreign"}}')
        self.game(MANGOHUD="1")
        files = list(self.private.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(json.loads(files[0].read_text())["layer"]["library_path"], str(self.manifests / "libMangoHud.so"))

    def test_invalid_cache_cannot_admit_foreign_layers(self):
        self.manifest()
        self.private.mkdir(parents=True)
        (self.private / "foreign.json").write_text("{}")
        env = self.game(MANGOHUD="1")
        self.assertNotIn("MANGOHUD", env)
        self.assertNotIn(str(self.private), env["VK_IMPLICIT_LAYER_PATH"])
        self.assertEqual((self.private / "foreign.json").read_text(), "{}")

    def test_unmodified_manifests_are_not_rewritten(self):
        self.manifest()
        self.game(MANGOHUD="1")
        path = self.private / ("MangoHud." + HOST_ARCH + ".json")
        before = path.stat().st_mtime_ns
        self.game(MANGOHUD="1")
        self.assertEqual(before, path.stat().st_mtime_ns)

    def test_concurrent_launches_share_a_complete_manifest_directory(self):
        for bits in BITS:
            self.manifest(bits)
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            results = list(pool.map(lambda _: self.game(MANGOHUD="1"), range(12)))
        for result in results:
            self.assertEqual(result.get("MANGOHUD"), "1")
        self.assertEqual(len(list(self.private.iterdir())), len(BITS))

    def test_foreign_architecture_package_never_admits_mangohud(self):
        # A package built for the other ISA (for example an x86_64 payload
        # run through FEX on an ARM host, or the reverse) must not stage a
        # MangoHud manifest for a process ABI it was not built for.
        foreign = "x86_64" if HOST_ARCH == "aarch64" else "aarch64"
        self.record.write_text(foreign + "\n")
        library = self.root / "libMangoHudForeign.so"
        library.write_bytes(b"synthetic library; never loaded")
        (self.manifests / ("MangoHud." + foreign + ".json")).write_text(json.dumps({
            "file_format_version": "1.0.0",
            "layer": {
                "name": "VK_LAYER_MANGOHUD_overlay_" + foreign,
                "type": "GLOBAL", "library_path": str(library),
                "enable_environment": {"MANGOHUD": "1"},
                "disable_environment": {"DISABLE_MANGOHUD": "1"},
            },
        }))
        self.assertEqual(json.loads(self.run_launcher("--check-mangohud").stdout), {"available": False})
        self.assertNotIn("MANGOHUD", self.game(MANGOHUD="1"))
        self.assertFalse(self.private.exists())

    def test_aarch64_package_ignores_x86_manifests(self):
        if HOST_ARCH != "aarch64":
            self.skipTest("requires an AArch64 host")
        self.manifest("64")
        library = self.root / "libMangoHudX86.so"
        library.write_bytes(b"synthetic library; never loaded")
        for suffix, arch in (("x86_64", "64"), ("x86", "32")):
            (self.manifests / ("MangoHud." + suffix + ".json")).write_text(json.dumps({
                "file_format_version": "1.0.0",
                "layer": {
                    "name": "VK_LAYER_MANGOHUD_overlay_" + suffix,
                    "type": "GLOBAL", "library_path": str(library),
                    "library_arch": arch,
                    "enable_environment": {"MANGOHUD": "1"},
                    "disable_environment": {"DISABLE_MANGOHUD": "1"},
                },
            }))
        self.game(MANGOHUD="1")
        self.assertEqual(sorted(path.name for path in self.private.iterdir()), ["MangoHud.aarch64.json"])

    def test_invalid_requests_and_shader_conflict_fail_before_game_exec(self):
        for options in ({"MANGOHUD": "yes"}, {"MANGOHUD": "1", "ENABLE_VKBASALT": "1"}):
            result = self.run_launcher("/usr/bin/env", **options)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
