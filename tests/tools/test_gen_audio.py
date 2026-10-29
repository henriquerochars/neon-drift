"""Unit tests for tools/audio/gen_audio.py: synth lengths, sequencer sample counts, CLI round trip.

    python3 -m unittest discover -s tests/tools
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parents[2]
GENERATOR = ROOT / "tools" / "audio" / "gen_audio.py"
REQUIRED_MUSIC = {"menu_theme", "race_a", "race_b", "results_jingle"}
REQUIRED_SFX = {
    "engine_loop",
    "nitro_ignite",
    "nitro_loop",
    "thruster_jump",
    "landing",
    "hard_landing",
    "crush",
    "bump",
    "scenery_hit",
    "offroad_loop",
    "countdown_beep",
    "go",
    "lap",
    "finish",
    "menu_move",
    "menu_confirm",
    "menu_cancel",
    "buy",
    "error",
}
MANIFEST_KEYS = {"name", "path", "role", "loop", "bpm", "seconds", "sha256"}


def load_generator() -> ModuleType:
    spec = importlib.util.spec_from_file_location("gen_audio", GENERATOR)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


gen = load_generator()


class SynthTests(unittest.TestCase):
    def test_oscillators_render_requested_length_in_range(self) -> None:
        waves = (gen.PULSE12, gen.PULSE25, gen.PULSE50, gen.TRI, gen.SAW, gen.NOISE, gen.NOISE_METAL, gen.WHITE)
        for wave in waves:
            with self.subTest(wave=wave):
                out = gen.oscillator(wave, gen.constant(440.0, 1000))
                self.assertEqual(len(out), 1000)
                self.assertTrue(all(-1.0 <= v <= 1.0 for v in out))
        self.assertEqual(len(gen.oscillator(gen.TRI, [])), 0)

    def test_pulse_duty_cycles(self) -> None:
        for wave, duty in ((gen.PULSE12, 0.125), (gen.PULSE25, 0.25), (gen.PULSE50, 0.5)):
            out = gen.oscillator(wave, gen.constant(100.0, gen.SAMPLE_RATE))
            high = sum(1 for v in out if v > 0.0) / gen.SAMPLE_RATE
            self.assertAlmostEqual(high, duty, delta=0.01)

    def test_envelope_length_is_gate_plus_release(self) -> None:
        env = gen.envelope(1000, 0.0, 0.0, 1.0, 0.01)
        self.assertEqual(len(env), 1000 + 441)
        self.assertEqual(env[0], 1.0)
        self.assertEqual(env[999], 1.0)
        self.assertLess(env[-1], 0.01)
        shaped = gen.envelope(gen.SAMPLE_RATE, 0.1, 0.1, 0.5, 0.0)
        self.assertAlmostEqual(shaped[4410], 1.0, places=3)
        self.assertAlmostEqual(shaped[-1], 0.5)

    def test_sweep_endpoints(self) -> None:
        curve = gen.sweep(100.0, 400.0, 5)
        self.assertEqual(len(curve), 5)
        self.assertAlmostEqual(curve[0], 100.0)
        self.assertAlmostEqual(curve[-1], 400.0)
        self.assertAlmostEqual(curve[2], 200.0)
        self.assertEqual(gen.sweep(1.0, 2.0, 0), [])

    def test_note_names(self) -> None:
        self.assertEqual(gen.note_to_midi("c4"), 60)
        self.assertEqual(gen.note_to_midi("A4"), 69)
        self.assertEqual(gen.note_to_midi("f#3"), 54)
        self.assertEqual(gen.note_to_midi("gb3"), 54)
        self.assertAlmostEqual(gen.note_hz("a4"), 440.0)
        self.assertEqual(gen.midi_name(61), "c#4")
        with self.assertRaises(ValueError):
            gen.note_to_midi("h2")

    def test_low_pass_attenuates_and_keeps_length(self) -> None:
        signal = gen.oscillator(gen.PULSE50, gen.constant(8000.0, 4410))
        filtered = gen.low_pass(signal, 200.0)
        self.assertEqual(len(filtered), 4410)
        self.assertLess(gen.peak_of(filtered), 0.3)
        self.assertEqual(list(gen.low_pass(signal, 0.0)), list(signal))

    def test_echo_lengths(self) -> None:
        signal = gen.zeros(1000)
        signal[0] = 1.0
        wrapped = gen.echo(signal, 100, 0.5, 1.0, True)
        self.assertEqual(len(wrapped), 1000)
        self.assertAlmostEqual(wrapped[100], 1.0, delta=0.01)
        self.assertAlmostEqual(wrapped[200], 0.5, delta=0.01)
        self.assertGreater(wrapped[0], 0.0)
        tail = gen.echo(signal, 100, 0.5, 1.0, False)
        self.assertEqual(len(tail), 1000 + 800)
        self.assertAlmostEqual(tail[1000], 0.5 ** 9)

    def test_normalize_hits_peak(self) -> None:
        signal = gen.gain(gen.oscillator(gen.SAW, gen.constant(220.0, 2000)), 0.1)
        loud = gen.normalize([signal])[0]
        self.assertAlmostEqual(gen.peak_of(loud), gen.PEAK, places=9)
        self.assertLess(gen.PEAK, 1.0)

    def test_render_is_deterministic(self) -> None:
        first = gen.sfx_bump()[0]
        second = gen.sfx_bump()[0]
        self.assertEqual(first.tobytes(), second.tobytes())

    def test_int16_interleaving(self) -> None:
        left = gen.zeros(3)
        right = gen.zeros(3)
        left[0] = 1.0
        right[1] = -1.0
        data = gen.to_int16([left, right])
        self.assertEqual(len(data), 12)
        self.assertEqual(data[0:2], b"\xff\x7f")
        self.assertEqual(data[6:8], b"\x01\x80")


class SequencerTests(unittest.TestCase):
    def test_parse_pattern_tokens(self) -> None:
        events = gen.parse_pattern("c4:4 .:4 e4+g4:8@0.5", 16)
        self.assertEqual(len(events), 2)
        self.assertEqual((events[0].step, events[0].length, events[0].notes), (0, 4, ("c4",)))
        self.assertEqual((events[1].step, events[1].length, events[1].notes), (8, 8, ("e4", "g4")))
        self.assertEqual(events[1].velocity, 0.5)
        with self.assertRaises(ValueError):
            gen.parse_pattern("c4:4", 16)

    def test_drum_pattern_and_arpeggio_helpers(self) -> None:
        tokens = gen.drum_pattern(["x...o..........."], "K").split()
        self.assertEqual(len(tokens), 16)
        self.assertEqual(tokens[0], "K")
        self.assertEqual(tokens[4], "K@0.5")
        self.assertEqual(gen.arpeggio(["c4", "e4", "g4"], (0, 1, 2, 3), 4), "c4 e4 g4 c5")
        self.assertEqual(gen.bass_line("a1", [(0, 2), (12, 2), (gen.REST, 4)]), "a1:2 a2:2 .:4")
        with self.assertRaises(ValueError):
            gen.drum_pattern(["x..."], "K")

    def test_song_sample_counts_follow_bpm_and_bars(self) -> None:
        song = gen.Song("t", 120.0, 2, [gen.Track(gen.BASS_SOFT, "c2:16 .:16")])
        self.assertEqual(gen.song_samples(song), 176400)
        left, right = gen.render_song(song)
        self.assertEqual(len(left), 176400)
        self.assertEqual(len(right), 176400)
        self.assertAlmostEqual(gen.peak_of(left, right), gen.PEAK, places=9)
        self.assertEqual(gen.song_samples(gen.Song("odd", 128.0, 1)), round(16 * 44100 * 60 / 128 / 4))

    def test_loop_wraps_note_tails(self) -> None:
        song = gen.Song("t", 240.0, 1, [gen.Track(gen.BASS_SOFT, ".:15 c2:1", gate=1.0)])
        mono = gen.render_track(song.tracks[0], song, gen.song_samples(song))
        self.assertNotEqual(mono[0], 0.0)
        one_shot = gen.Song("o", 240.0, 1, [gen.Track(gen.BASS_SOFT, ".:15 c2:1", gate=1.0)], loop=False)
        mono = gen.render_track(one_shot.tracks[0], one_shot, gen.song_samples(one_shot))
        self.assertEqual(mono[0], 0.0)

    def test_music_catalog_is_exact_bars(self) -> None:
        expected = {"menu_theme": 38.4, "race_a": 45.0, "race_b": 48.0, "results_jingle": 6.0}
        for builder in (gen.menu_theme, gen.race_a, gen.race_b, gen.results_jingle):
            song = builder()
            self.assertAlmostEqual(gen.song_samples(song) / gen.SAMPLE_RATE, expected[song.name], places=4)
            steps = song.bars * gen.STEPS_PER_BAR
            for track in song.tracks:
                gen.parse_pattern(track.pattern, steps)


class CatalogTests(unittest.TestCase):
    def test_catalog_names_and_roles(self) -> None:
        names = {entry.name for entry in gen.CATALOG}
        self.assertEqual(names, REQUIRED_MUSIC | REQUIRED_SFX)
        for entry in gen.CATALOG:
            self.assertEqual(entry.role, "music" if entry.name in REQUIRED_MUSIC else "sfx")
            self.assertEqual(entry.path, f"audio/{entry.role}/{entry.name}.ogg")
        loops = {entry.name for entry in gen.CATALOG if entry.loop}
        self.assertEqual(loops, {"menu_theme", "race_a", "race_b", "engine_loop", "nitro_loop", "offroad_loop"})

    def test_sfx_loops_are_exactly_one_second(self) -> None:
        for name in ("engine_loop", "nitro_loop", "offroad_loop"):
            channels = gen.CATALOG_BY_NAME[name].render()
            self.assertEqual(len(channels), 1)
            self.assertEqual(len(channels[0]), gen.SAMPLE_RATE)
            self.assertAlmostEqual(gen.peak_of(channels[0]), gen.PEAK, places=9)

    def test_import_params(self) -> None:
        music = gen.CATALOG_BY_NAME["race_a"]
        self.assertEqual(gen.import_params(music, 45.0)["loop"], "true")
        self.assertEqual(gen.import_params(music, 45.0)["bpm"], "128.0")
        self.assertEqual(gen.import_params(music, 45.0)["beat_count"], "96")
        sfx = gen.CATALOG_BY_NAME["bump"]
        self.assertEqual(gen.import_params(sfx, 0.14)["loop"], "false")
        self.assertEqual(gen.import_params(sfx, 0.14)["bpm"], "0")


@unittest.skipIf(shutil.which("ffmpeg") is None, "ffmpeg not in PATH")
class CliRoundTripTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="nd-audio-test-")
        self.root = Path(self.tmp.name)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def _run(self, *args: str) -> int:
        with contextlib.redirect_stdout(io.StringIO()):
            return gen.main(list(args))

    def test_write_then_check_passes_and_detects_drift(self) -> None:
        only = ["--only", "menu_move", "countdown_beep"]
        self.assertEqual(self._run("--write", "--root", str(self.root), *only), 0)
        manifest = json.loads((self.root / "audio" / "manifest.json").read_text(encoding="utf-8"))
        files = {entry["name"]: entry for entry in manifest["files"]}
        self.assertEqual(set(files), {"menu_move", "countdown_beep"})
        for entry in files.values():
            self.assertTrue(MANIFEST_KEYS <= set(entry))
            self.assertTrue((self.root / entry["path"]).is_file())
        self.assertEqual(self._run("--check", "--root", str(self.root), *only), 0)
        ogg = self.root / files["menu_move"]["path"]
        ogg.write_bytes(ogg.read_bytes() + b"\0")
        self.assertEqual(self._run("--check", "--root", str(self.root), *only), 1)

    def test_import_file_rewrite(self) -> None:
        entry = gen.CATALOG_BY_NAME["race_b"]
        path = self.root / (entry.path + gen.IMPORT_SUFFIX)
        path.parent.mkdir(parents=True)
        path.write_text("[remap]\n\nimporter=\"oggvorbisstr\"\n\n[params]\n\nloop=false\nbpm=0\n", encoding="utf-8")
        self.assertTrue(gen.update_import_file(self.root, entry, 48.0))
        text = path.read_text(encoding="utf-8")
        self.assertIn("loop=true\n", text)
        self.assertIn("bpm=140.0\n", text)
        self.assertIn("beat_count=112\n", text)
        self.assertIn("bar_beats=4\n", text)
        self.assertTrue(gen.import_loop_flag(self.root, entry))
        self.assertFalse(gen.update_import_file(self.root, gen.CATALOG_BY_NAME["bump"], 0.1))


if __name__ == "__main__":
    unittest.main()
