"""Regressions around filesystem safety, interrupted generation and API parity."""

import json
import re
from pathlib import Path
from unittest.mock import patch

from tests.test_engine import TempHome


class LibrarySafety(TempHome):
    def setUp(self):
        super().setUp()
        self.engine = self.engine_module.Engine(idle_unload=0)
        self.addCleanup(self.engine.close)

    def voice(self, name="David"):
        directory = self.engine_module.VOICES_DIR / name
        directory.mkdir(parents=True)
        (directory / "meta.json").write_text(
            json.dumps({"name": name, "reference_text": "Hello"})
        )
        (directory / "reference.wav").write_bytes(b"recording")
        return directory

    def test_traversal_cannot_read_or_rename_a_directory_outside_the_library(self):
        outside = self.tmp / "private"
        outside.mkdir()
        (outside / "reference.wav").write_bytes(b"private recording")
        self.assertIsNone(self.engine.sample("../private"))
        self.assertFalse(self.engine.rename("../private", "stolen"))
        self.assertTrue(outside.exists())

    def test_symlinked_voices_and_recordings_are_not_exposed(self):
        voice = self.voice()
        (self.engine_module.VOICES_DIR / "linked").symlink_to(voice, target_is_directory=True)
        self.assertIsNone(self.engine.sample("linked"))
        self.assertFalse(self.engine.rename("linked", "renamed"))
        self.assertFalse(self.engine.delete("linked"))
        self.assertEqual([entry["name"] for entry in self.engine.voices()], ["David"])
        (voice / "reference.wav").unlink()
        (voice / "reference.wav").symlink_to(voice / "meta.json")
        self.assertIsNone(self.engine.sample("David"))
        self.assertFalse(self.engine.voices()[0]["has_sample"])

    def test_rename_updates_the_profile_and_accepts_an_unchanged_name(self):
        self.voice()
        self.assertTrue(self.engine.rename("David", "Me, reading"))
        metadata = json.loads(
            (self.engine_module.VOICES_DIR / "Me, reading/meta.json").read_text()
        )
        self.assertEqual(metadata["name"], "Me, reading")
        self.assertTrue(self.engine.rename("Me, reading", "Me, reading"))

    def test_malformed_metadata_does_not_break_the_library(self):
        for name, value in (("array", []), ("null", None), ("numeric", {"created_at": 42}),
                            ("missing", {"created_at": None})):
            directory = self.voice(name)
            (directory / "meta.json").write_text(json.dumps(value))
        self.assertEqual(
            {entry["name"] for entry in self.engine.voices()}, {"numeric", "missing"}
        )

    def test_invalid_registration_is_rejected_before_importing_the_encoder(self):
        for name in (".", "..", "../private", "C:\\private", "bad\x00name", "x" * 65):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.engine.register(name, b"audio", "A recording")

    def test_registration_cannot_silently_replace_a_voice(self):
        self.voice()
        with self.assertRaises(FileExistsError):
            self.engine.register("David", b"audio", "A replacement")
        self.assertEqual(self.engine.sample("David"), b"recording")

    def test_missing_model_registration_has_an_actionable_error(self):
        with self.assertRaises(self.engine_module.ModelMissing):
            self.engine.register("David", b"audio", "A recording")

    def test_path_and_control_names_are_rejected_for_speech(self):
        for name in (".", "..", "../private", "bad\nname", "x" * 65, None, []):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.engine.speak_stream("Hello", name)

    def test_invalid_text_and_seed_fail_before_the_generator_is_consumed(self):
        self.voice()
        for text, seed in ((None, 42), ([], 42), ("", 42), (" " * 10_001, 42),
                           ("Hi", None), ("Hi", True), ("Hi", "42"), ("Hi", -1),
                           ("Hi", 1.5), ("Hi", 2**32)):
            with self.subTest(text=str(text)[:20], seed=seed), self.assertRaises(ValueError):
                self.engine.speak_stream(text, "David", seed=seed)

    def test_cache_invalidation_is_literal_for_names_containing_glob_characters(self):
        own = self.engine._cache_path("Hi", "*", 42)
        other = self.engine._cache_path("Hi", "Someone", 42)
        own.write_bytes(b"old")
        other.write_bytes(b"keep")
        self.engine._forget_cached("*")
        self.assertFalse(own.exists())
        self.assertEqual(other.read_bytes(), b"keep")

    def test_long_unicode_names_still_have_short_cache_filenames(self):
        name = "声" * 64
        self.voice(name)
        path = self.engine._cache_path("Hello", name, 42)
        path.write_bytes(b"cached")
        self.assertLess(len(path.name.encode()), 255)

    def test_storage_and_clear_cache_preserve_voices_and_models(self):
        voice = self.voice()
        model = self.engine_module.MODEL_DIR
        model.mkdir()
        (model / "weights").write_bytes(b"weights")
        self.engine._cache_path("Hi", "David", 42).write_bytes(b"cached")
        before = self.engine.storage()
        self.engine.clear_cache()
        after = self.engine.storage()
        self.assertEqual(after["voices"], before["voices"])
        self.assertEqual(after["model"], before["model"])
        self.assertEqual(before["cache"] - after["cache"], len(b"cached"))
        self.assertEqual(
            after["total"], sum(after[key] for key in ("model", "voices", "cache"))
        )
        self.assertTrue(voice.is_dir())

    def test_an_engine_can_stop_its_idle_thread(self):
        engine = self.engine_module.Engine(idle_unload=30)
        self.assertTrue(engine._reaper_thread.is_alive())
        engine.close()
        self.assertFalse(engine._reaper_thread.is_alive())
        self.assertIsNone(self.engine._reaper_thread)


class SynthesisReliability(TempHome):
    def setUp(self):
        super().setUp()
        try:
            import numpy as np
        except ImportError:
            self.skipTest("numpy not installed")
        self.np = np
        self.engine = self.engine_module.Engine(idle_unload=0)
        self.addCleanup(self.engine.close)
        voice = self.engine_module.VOICES_DIR / "David"
        voice.mkdir()
        (voice / "meta.json").write_text('{"reference_text":"Hi"}')
        self.calls = []
        calls = self.calls

        class Runtime:
            def synthesize(self, **kwargs):
                calls.append(kwargs)
                return np.full(441, len(calls) / 100, dtype=np.float32), None

        self.engine._runtime = Runtime()
        self.passage = (
            "This is the beginning. "
            + "A long sentence with many words, " * 8
            + "This is the end."
        )

    def test_stream_and_wav_share_ordered_complete_audio_and_cache(self):
        events = list(self.engine.speak_stream(self.passage, "David"))
        chunks = [event["samples"] for event in events if not event["done"]]
        expected = self.engine_module.to_wav(self.np.concatenate(chunks))
        self.assertEqual(events[-1]["wav"], expected)
        self.assertEqual(" ".join(call["text"] for call in self.calls), self.passage.strip())
        count = len(self.calls)
        data, seconds, cached = self.engine.speak(self.passage, "David")
        self.assertEqual(data, expected)
        self.assertTrue(cached)
        self.assertGreater(seconds, 0)
        self.assertEqual(len(self.calls), count)

    def test_non_streaming_also_splits_a_long_passage(self):
        self.engine.speak(self.passage, "David")
        self.assertGreater(len(self.calls), 1)
        self.assertEqual(" ".join(call["text"] for call in self.calls), self.passage.strip())

    def test_cache_keys_include_all_generation_settings(self):
        self.engine.speak("Hello", "David")
        for settings in (
            {"temperature": 0.8},
            {"top_p": 0.5},
            {"top_k": 10},
            {"max_new_tokens": 512},
        ):
            with self.subTest(settings=settings):
                _, _, cached = self.engine.speak("Hello", "David", **settings)
                self.assertFalse(cached)
        self.assertEqual(len(self.calls), 5)

    def test_corrupt_and_truncated_wavs_are_rebuilt(self):
        cached = self.engine._cache_path("Hello", "David", 42)
        wav = self.engine_module.to_wav(self.np.zeros(441))
        for data in (b"broken", b"RIFF", wav[:-2]):
            cached.write_bytes(data)
            _, _, hit = self.engine.speak("Hello", "David")
            self.assertFalse(hit)
        self.assertEqual(len(self.calls), 3)

    def test_closing_an_interrupted_stream_does_not_cache_a_partial_passage(self):
        stream = self.engine.speak_stream(self.passage, "David")
        next(stream)
        stream.close()
        self.assertEqual(list(self.engine_module.CACHE_DIR.glob("*.wav")), [])
        self.engine.speak("Still usable", "David")

    def test_changing_the_voice_between_chunks_stops_generation(self):
        stream = self.engine.speak_stream(self.passage, "David")
        next(stream)
        self.assertTrue(self.engine.delete("David"))
        with self.assertRaisesRegex(ValueError, "voice changed"):
            next(stream)
        self.assertEqual(list(self.engine_module.CACHE_DIR.glob("*.wav")), [])

    def test_clear_cache_during_generation_does_not_repopulate_it(self):
        stream = self.engine.speak_stream(self.passage, "David")
        next(stream)
        self.engine.clear_cache()
        self.assertTrue(list(stream)[-1]["done"])
        self.assertEqual(list(self.engine_module.CACHE_DIR.glob("*.wav")), [])

    def test_cache_write_failure_does_not_lose_generated_audio(self):
        with patch.object(
            self.engine_module, "_atomic_write", side_effect=OSError("disk full")
        ):
            data, seconds, cached = self.engine.speak("Hello", "David")
        self.assertGreater(len(data), 44)
        self.assertGreater(seconds, 0)
        self.assertFalse(cached)

    def test_sentence_seeds_wrap_without_exceeding_the_accepted_range(self):
        self.engine.speak(self.passage, "David", seed=0xFFFFFFFF)
        self.assertEqual(self.calls[0]["seed"], 0xFFFFFFFF)
        self.assertEqual(self.calls[1]["seed"], 0)


class SharedPresets(TempHome):
    def test_api_presets_exactly_match_the_native_library(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "MimicKit/Sources/MimicKit/Preset.swift").read_text()
        quoted = r'"(?:[^"\\]|\\.)*"'
        pattern = (
            rf"Preset\(label:\s*({quoted}),\s*source:\s*({quoted}),"
            rf"\s*text:\s*((?:{quoted}\s*\+?\s*)+)\)"
        )
        native = [
            {"label": json.loads(label), "source": json.loads(origin),
             "text": "".join(json.loads(part) for part in re.findall(quoted, fragments))}
            for label, origin, fragments in re.findall(pattern, source)
        ]
        self.assertEqual(len(native), source.count("Preset(label:"))
        self.assertGreater(len(native), 0)
        self.assertEqual(json.loads((root / "core/presets.json").read_text()), native)
