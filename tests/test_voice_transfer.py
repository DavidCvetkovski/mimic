"""Portable files roundtrip without overwriting another profile."""

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(importlib.util.find_spec("numpy"), "voice transfer requires numpy")
class VoiceTransferTests(unittest.TestCase):
    def test_roundtrip_and_conflict(self):
        from core.voice_transfer import export_voice, import_voice

        fixture = (
            Path(__file__).resolve().parents[1] / "MimicKit/Tests/Fixtures/cloud-truth.json"
        )
        archive = json.loads(fixture.read_text())["archive"]
        data = json.dumps(archive).encode()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            name = import_voice(root, data)
            self.assertEqual(name, archive["name"])
            self.assertEqual(
                json.loads(export_voice(root, name))["files"]["codes.npy"],
                archive["files"]["codes.npy"],
            )
            with self.assertRaises(FileExistsError):
                import_voice(root, data)
            with self.assertRaises(ValueError):
                import_voice(root, data, name="../outside")
            bad = dict(archive, files=dict(archive["files"], **{"../extra": "YWJj"}))
            with self.assertRaises(ValueError):
                import_voice(root, json.dumps(bad).encode())
