"""
Mimic's own logic — not the vendored runtime, which is upstream's to test.

Everything here runs without the model downloaded and without ONNX Runtime
installed, so the suite is fast and works in CI. What it covers is the part
Mimic adds: where things live, what a voice library is, and the rule that makes
caching safe.
"""

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))


class TempHome(unittest.TestCase):
    """Each test gets its own ~/.mimic so nothing touches a real install."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mimic-test-"))
        os.environ["MIMIC_HOME"] = str(self.tmp)
        for name in [m for m in sys.modules if m.startswith("core")]:
            del sys.modules[name]
        from core import engine
        self.engine_module = engine
        self.assertTrue(str(self.tmp) in str(engine.HOME))

    def tearDown(self):
        os.environ.pop("MIMIC_HOME", None)
        shutil.rmtree(self.tmp, ignore_errors=True)


class Paths(TempHome):

    def test_state_is_redirectable(self):
        # Which is what lets these tests run at all, and what lets the macOS
        # app keep its data inside its own container.
        engine = self.engine_module
        for path in (engine.MODEL_DIR, engine.VOICES_DIR, engine.CACHE_DIR):
            self.assertTrue(str(path).startswith(str(self.tmp)), path)

    def test_a_missing_model_is_reported_not_assumed(self):
        self.assertFalse(self.engine_module.model_ready())


class VoiceLibrary(TempHome):

    def voice(self, name, text="hello there"):
        """Write a voice profile the way registration would."""
        import json
        directory = self.engine_module.VOICES_DIR / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "meta.json").write_text(json.dumps(
            {"reference_text": text, "created_at": "2026-08-23T12:00:00Z"}))
        return directory

    def test_an_empty_library_is_empty_not_an_error(self):
        self.assertEqual(self.engine_module.Engine(idle_unload=0).voices(), [])

    def test_voices_are_listed_with_their_name(self):
        self.voice("David")
        entries = self.engine_module.Engine(idle_unload=0).voices()
        self.assertEqual([v["name"] for v in entries], ["David"])

    def test_a_directory_without_metadata_is_skipped(self):
        # A half-written registration must not appear as a usable voice.
        (self.engine_module.VOICES_DIR / "broken").mkdir(parents=True)
        self.voice("good")
        self.assertEqual(
            [v["name"] for v in self.engine_module.Engine(idle_unload=0).voices()],
            ["good"])

    def test_rename(self):
        self.voice("before")
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertTrue(engine.rename("before", "after"))
        self.assertEqual([v["name"] for v in engine.voices()], ["after"])

    def test_rename_refuses_to_overwrite(self):
        self.voice("one")
        self.voice("two")
        self.assertFalse(self.engine_module.Engine(idle_unload=0).rename("one", "two"))

    def test_rename_refuses_a_path_as_a_name(self):
        self.voice("one")
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertFalse(engine.rename("one", "../escaped"))
        self.assertFalse((self.tmp / "escaped").exists())

    def test_delete(self):
        self.voice("gone")
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertTrue(engine.delete("gone"))
        self.assertEqual(engine.voices(), [])

    def test_delete_refuses_a_traversing_name(self):
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertFalse(engine.delete("../.."))
        self.assertTrue(self.tmp.exists())

    def test_speaking_with_no_such_voice_is_rejected_before_loading_anything(self):
        engine = self.engine_module.Engine(idle_unload=0)
        with self.assertRaises(ValueError):
            engine.speak("hello", voice="nobody")

    def test_empty_text_is_rejected(self):
        self.voice("David")
        engine = self.engine_module.Engine(idle_unload=0)
        with self.assertRaises(ValueError):
            engine.speak("   ", voice="David")


class Caching(TempHome):
    """
    Synthesis is deterministic for a given seed, which is the whole reason the
    cache is allowed to exist.
    """

    def test_same_text_voice_and_seed_is_one_key(self):
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertEqual(engine._cache_path("hi", "a", 42),
                         engine._cache_path("hi", "a", 42))

    def test_a_different_seed_is_a_different_key(self):
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertNotEqual(engine._cache_path("hi", "a", 42),
                            engine._cache_path("hi", "a", 43))

    def test_a_different_voice_is_a_different_key(self):
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertNotEqual(engine._cache_path("hi", "a", 42),
                            engine._cache_path("hi", "b", 42))

    def test_the_key_is_prefixed_with_the_voice(self):
        # So re-recording or deleting a voice can drop only its own audio.
        engine = self.engine_module.Engine(idle_unload=0)
        self.assertTrue(engine._cache_path("hi", "David", 42).name.startswith("David-"))

    def test_re_registering_a_voice_drops_its_cached_audio(self):
        # The voice changed, so everything previously said in it is now wrong.
        engine = self.engine_module.Engine(idle_unload=0)
        stale = engine._cache_path("hi", "David", 42)
        stale.parent.mkdir(parents=True, exist_ok=True)
        stale.write_bytes(b"old")
        other = engine._cache_path("hi", "Someone", 42)
        other.write_bytes(b"keep")
        engine._forget_cached("David")
        self.assertFalse(stale.exists())
        self.assertTrue(other.exists(), "another voice's audio must survive")


class WavWriting(TempHome):

    def setUp(self):
        super().setUp()
        try:
            import numpy                                       # noqa: F401
        except ImportError:
            self.skipTest("numpy not installed")

    def test_a_wav_is_readable_and_the_right_length(self):
        import io
        import wave

        import numpy as np
        seconds = 0.25
        tone = np.sin(np.linspace(0, 40, int(44100 * seconds))).astype(np.float32)
        data = self.engine_module.to_wav(tone)
        with wave.open(io.BytesIO(data), "rb") as handle:
            self.assertEqual(handle.getnchannels(), 1)
            self.assertEqual(handle.getsampwidth(), 2)
            self.assertEqual(handle.getframerate(), 44100)
            self.assertAlmostEqual(handle.getnframes() / 44100, seconds, places=3)

    def test_samples_outside_the_range_are_clipped_not_wrapped(self):
        # Without the clip these wrap to full-scale noise of the opposite sign.
        import numpy as np
        data = self.engine_module.to_wav(np.array([3.0, -3.0], dtype=np.float32))
        pcm = np.frombuffer(data[44:], dtype="<i2")
        self.assertTrue((pcm > 32000).any() and (pcm < -32000).any())

    def test_the_duration_helper_agrees(self):
        import numpy as np
        data = self.engine_module.to_wav(np.zeros(44100, dtype=np.float32))
        self.assertAlmostEqual(self.engine_module._wav_seconds(data), 1.0, places=3)

    def test_a_corrupt_wav_reports_zero_rather_than_raising(self):
        self.assertEqual(self.engine_module._wav_seconds(b"not a wav"), 0.0)


if __name__ == "__main__":
    unittest.main()


class CachePruning(TempHome):
    """Cached audio is bounded, or a long-lived install grows without limit."""

    def files(self, count, size=1024):
        import time
        self.engine_module.CACHE_DIR.mkdir(parents=True, exist_ok=True)
        made = []
        for n in range(count):
            path = self.engine_module.CACHE_DIR / f"voice-{n:03d}.wav"
            path.write_bytes(b"x" * size)
            # Distinct access times, so "oldest" is well defined.
            os.utime(path, (time.time() - (count - n) * 60,) * 2)
            made.append(path)
        return made

    def test_a_cache_within_budget_is_left_alone(self):
        made = self.files(5)
        self.engine_module._prune_cache(limit_mb=10)
        self.assertTrue(all(p.exists() for p in made))

    def test_the_oldest_go_first(self):
        made = self.files(10, size=200_000)          # ~2 MB total
        self.engine_module._prune_cache(limit_mb=1)  # keep about half
        surviving = [p for p in made if p.exists()]
        self.assertTrue(surviving, "pruning must not empty the cache entirely")
        self.assertLess(len(surviving), len(made))
        # Whatever survived must be newer than whatever did not.
        self.assertTrue(all(p.exists() for p in made[-len(surviving):]))

    def test_pruning_an_absent_cache_is_not_an_error(self):
        import shutil
        shutil.rmtree(self.engine_module.CACHE_DIR, ignore_errors=True)
        self.engine_module._prune_cache()
