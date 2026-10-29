#!/usr/bin/env python3
"""Deterministic chiptune/synthwave soundtrack and SFX generator for Neon Drift.

    python3 tools/audio/gen_audio.py --write [--only NAME ...]   # render into audio/, refresh manifest
    python3 tools/audio/gen_audio.py --check                     # render to a temp dir, compare sha256
    python3 tools/audio/gen_audio.py --list                      # print the catalog

Standard library only: a tiny synth (pulse 12.5/25/50 %, triangle, saw, LFSR noise), linear
ADSR, one-pole low-pass, feedback echo, a 16th-note step sequencer with arpeggio helpers.
Rendering writes 16-bit 44.1 kHz WAV files to a temporary directory and converts them to OGG
with ``ffmpeg`` (libvorbis, quality 4 ~ 0.4) so only the OGG files and ``audio/manifest.json``
live in git. Every stage is arithmetic on IEEE doubles with fixed seeds, so the same machine
produces byte-identical output; ``--check`` verifies that against the manifest.

Music is loopable: every song is an exact number of bars and note tails wrap around to the
start, so Godot's ``loop`` import plays it seamlessly. Peaks are normalised to -1 dBFS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import shutil
import subprocess
import sys
import tempfile
import wave
from array import array
from dataclasses import dataclass, field, replace
from pathlib import Path
from typing import Callable, Dict, List, Optional, Sequence, Tuple

SAMPLE_RATE = 44100
STEPS_PER_BEAT = 4
BEATS_PER_BAR = 4
STEPS_PER_BAR = STEPS_PER_BEAT * BEATS_PER_BAR
PEAK_DBFS = -1.0
PEAK = 10.0 ** (PEAK_DBFS / 20.0)
INT16_MAX = 32767
OGG_QUALITY = "4"
ROOT = Path(__file__).resolve().parents[2]
AUDIO_DIR = "audio"
MANIFEST_NAME = "manifest.json"
MIDI_A4 = 69
A4_HZ = 440.0
NOISE_SEED = 0x4E44  # "ND"
LFSR_WIDTH_LONG = 15
LFSR_WIDTH_SHORT = 7
REST = -1000

# Waveforms.
PULSE12 = "pulse12"
PULSE25 = "pulse25"
PULSE50 = "pulse50"
TRI = "tri"
SAW = "saw"
NOISE = "noise"  # 15-bit LFSR, white-ish (GBA noise channel)
NOISE_METAL = "noise_metal"  # 7-bit LFSR, periodic/metallic
WHITE = "white"  # seeded random white noise
DUTY: Dict[str, float] = {PULSE12: 0.125, PULSE25: 0.25, PULSE50: 0.5}

NOTE_INDEX: Dict[str, int] = {"c": 0, "d": 2, "e": 4, "f": 5, "g": 7, "a": 9, "b": 11}
NAMES_SHARP = ("c", "c#", "d", "d#", "e", "f", "f#", "g", "g#", "a", "a#", "b")

Samples = array


def zeros(n: int) -> Samples:
    return array("d", bytes(8 * n))


def seconds_to_samples(seconds: float) -> int:
    return int(round(seconds * SAMPLE_RATE))


def note_to_midi(name: str) -> int:
    """``c4`` -> 60, ``f#3``/``gb3`` -> 54. Case-insensitive."""
    text = name.strip().lower()
    if len(text) < 2 or text[0] not in NOTE_INDEX:
        raise ValueError(f"bad note {name!r}")
    semitone = NOTE_INDEX[text[0]]
    rest = text[1:]
    if rest[0] == "#":
        semitone += 1
        rest = rest[1:]
    elif rest[0] == "b":
        semitone -= 1
        rest = rest[1:]
    try:
        octave = int(rest)
    except ValueError as exc:
        raise ValueError(f"bad note {name!r}") from exc
    return (octave + 1) * 12 + semitone


def midi_name(midi: int) -> str:
    return f"{NAMES_SHARP[midi % 12]}{midi // 12 - 1}"


def midi_to_hz(midi: float) -> float:
    return A4_HZ * 2.0 ** ((midi - MIDI_A4) / 12.0)


def note_hz(name: str) -> float:
    return midi_to_hz(note_to_midi(name))


def constant(value: float, n: int) -> List[float]:
    return [value] * n


def sweep(start: float, end: float, n: int) -> List[float]:
    """Exponential frequency sweep over n samples (musically linear)."""
    if n <= 0:
        return []
    if n == 1:
        return [start]
    ratio = end / start
    return [start * ratio ** (i / (n - 1)) for i in range(n)]


def oscillator(
    wave_name: str,
    freqs: Sequence[float],
    phase: float = 0.0,
    seed: int = NOISE_SEED,
) -> Samples:
    """Render len(freqs) samples in [-1, 1]; freqs[i] is the frequency of sample i in Hz.

    For the noise waves freqs is the clock rate of the shift register (44100 = every sample).
    """
    n = len(freqs)
    out = zeros(n)
    if n == 0:
        return out
    inv = 1.0 / SAMPLE_RATE
    ph = phase % 1.0
    if wave_name in DUTY:
        # DC-free pulse: high/low levels weighted by the duty so the mean is zero and |x| <= 1.
        duty = DUTY[wave_name]
        high = (1.0 - duty) / max(duty, 1.0 - duty)
        low = -duty / max(duty, 1.0 - duty)
        for i in range(n):
            out[i] = high if ph < duty else low
            ph += freqs[i] * inv
            if ph >= 1.0:
                ph -= 1.0
    elif wave_name == TRI:
        for i in range(n):
            out[i] = 1.0 - 4.0 * abs(ph - 0.5)
            ph += freqs[i] * inv
            if ph >= 1.0:
                ph -= 1.0
    elif wave_name == SAW:
        for i in range(n):
            out[i] = 2.0 * ph - 1.0
            ph += freqs[i] * inv
            if ph >= 1.0:
                ph -= 1.0
    elif wave_name in (NOISE, NOISE_METAL):
        width = LFSR_WIDTH_LONG if wave_name == NOISE else LFSR_WIDTH_SHORT
        mask = (1 << width) - 1
        reg = (seed & mask) or 1
        top = width - 1
        value = 1.0 if reg & 1 else -1.0
        for i in range(n):
            out[i] = value
            ph += freqs[i] * inv
            while ph >= 1.0:
                ph -= 1.0
                bit = (reg ^ (reg >> 1)) & 1
                reg = (reg >> 1) | (bit << top)
                value = 1.0 if reg & 1 else -1.0
    elif wave_name == WHITE:
        rng = random.Random(seed)
        for i in range(n):
            out[i] = rng.uniform(-1.0, 1.0)
    else:
        raise ValueError(f"unknown wave {wave_name!r}")
    return out


def envelope(gate: int, attack: float, decay: float, sustain: float, release: float) -> Samples:
    """Linear ADSR: gate samples held, then a release tail. Length = gate + release samples."""
    a = seconds_to_samples(attack)
    d = seconds_to_samples(decay)
    r = seconds_to_samples(release)
    out = zeros(gate + r)
    level = 0.0
    for i in range(gate):
        if i < a:
            level = i / a
        elif i < a + d:
            level = 1.0 - (1.0 - sustain) * (i - a) / d
        else:
            level = sustain
        out[i] = level
    for i in range(r):
        out[gate + i] = level * (1.0 - i / r)
    return out


def multiply(samples: Samples, env: Samples) -> Samples:
    n = min(len(samples), len(env))
    out = zeros(n)
    for i in range(n):
        out[i] = samples[i] * env[i]
    return out


def gain(samples: Samples, factor: float) -> Samples:
    out = zeros(len(samples))
    for i, v in enumerate(samples):
        out[i] = v * factor
    return out


def add(*parts: Samples) -> Samples:
    n = max((len(p) for p in parts), default=0)
    out = zeros(n)
    for part in parts:
        for i, v in enumerate(part):
            out[i] += v
    return out


def low_pass(samples: Samples, cutoff: float, wrap: bool = False) -> Samples:
    """One-pole low-pass; cutoff in Hz (0 or less = bypass).

    With wrap the filter is warmed up on one full pass first, so the state at sample 0 equals
    the state after the last sample and a 1 s loop has no click at the seam.
    """
    if cutoff <= 0.0:
        return array("d", samples)
    k = 2.0 * math.pi * cutoff / SAMPLE_RATE
    a = k / (1.0 + k)
    out = zeros(len(samples))
    y = 0.0
    if wrap:
        for x in samples:
            y += a * (x - y)
    for i, x in enumerate(samples):
        y += a * (x - y)
        out[i] = y
    return out


def high_pass(samples: Samples, cutoff: float, wrap: bool = False) -> Samples:
    low = low_pass(samples, cutoff, wrap)
    out = zeros(len(samples))
    for i, x in enumerate(samples):
        out[i] = x - low[i]
    return out


def echo(samples: Samples, delay: int, feedback: float, mix: float, wrap: bool) -> Samples:
    """Feedback delay. With wrap the tail folds into the start so loops stay seamless.

    Without wrap the output grows by 8 delays so the tail rings out.
    """
    n = len(samples)
    if delay <= 0 or n == 0 or mix <= 0.0:
        return array("d", samples)
    if wrap:
        wet = array("d", samples)
        for i in range(2 * n):
            j = i % n
            wet[j] = samples[j] + feedback * wet[(j - delay) % n]
        out = zeros(n)
        for j in range(n):
            out[j] = samples[j] + mix * wet[(j - delay) % n]
        return out
    total = n + delay * 8
    wet = zeros(total)
    out = zeros(total)
    for j in range(total):
        dry = samples[j] if j < n else 0.0
        prev = wet[j - delay] if j >= delay else 0.0
        wet[j] = dry + feedback * prev
        out[j] = dry + mix * prev
    return out


def tremolo(samples: Samples, rate_hz: float, depth: float) -> Samples:
    """Triangle-LFO amplitude modulation; integer cycles per second keep 1 s loops seamless."""
    out = zeros(len(samples))
    for i, v in enumerate(samples):
        ph = (i * rate_hz / SAMPLE_RATE) % 1.0
        lfo = 1.0 - 4.0 * abs(ph - 0.5)
        out[i] = v * (1.0 - depth * 0.5 * (1.0 - lfo))
    return out


def peak_of(*channels: Samples) -> float:
    peak = 0.0
    for channel in channels:
        for v in channel:
            a = abs(v)
            if a > peak:
                peak = a
    return peak


def normalize(channels: Sequence[Samples], peak: float = PEAK) -> List[Samples]:
    current = peak_of(*channels)
    if current <= 0.0:
        return [array("d", c) for c in channels]
    factor = peak / current
    return [gain(c, factor) for c in channels]


def clip(samples: Samples, limit: float = 1.0) -> Samples:
    out = zeros(len(samples))
    for i, v in enumerate(samples):
        out[i] = limit if v > limit else -limit if v < -limit else v
    return out


def to_int16(channels: Sequence[Samples]) -> bytes:
    """Interleave channels into little-endian 16-bit PCM."""
    n = min(len(c) for c in channels)
    count = len(channels)
    pcm = array("h", bytes(2 * n * count))
    for c, channel in enumerate(channels):
        for i in range(n):
            v = channel[i]
            v = 1.0 if v > 1.0 else -1.0 if v < -1.0 else v
            pcm[i * count + c] = int(round(v * INT16_MAX))
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm.tobytes()


# --------------------------------------------------------------------------- instruments


@dataclass(frozen=True)
class Instrument:
    wave: str
    attack: float = 0.004
    decay: float = 0.08
    sustain: float = 0.7
    release: float = 0.06
    cutoff: float = 0.0
    vibrato_depth: float = 0.0  # semitones
    vibrato_rate: float = 5.5
    vibrato_delay: float = 0.1
    detune_cents: float = 0.0  # second oscillator for chorus; 0 = single oscillator
    pitch_sweep: float = 0.0  # semitones, applied over sweep_time
    sweep_time: float = 0.0
    noise_rate: float = SAMPLE_RATE
    volume: float = 1.0


def _freq_curve(inst: Instrument, freq: float, n: int) -> List[float]:
    if inst.wave in (NOISE, NOISE_METAL, WHITE):
        return constant(inst.noise_rate, n)
    sweep_n = seconds_to_samples(inst.sweep_time) if inst.pitch_sweep else 0
    vib_delay = seconds_to_samples(inst.vibrato_delay)
    freqs = constant(freq, n)
    if sweep_n > 0:
        end = freq * 2.0 ** (inst.pitch_sweep / 12.0)
        curve = sweep(freq, end, sweep_n)
        for i in range(min(n, sweep_n)):
            freqs[i] = curve[i]
        for i in range(sweep_n, n):
            freqs[i] = end
    if inst.vibrato_depth > 0.0:
        for i in range(vib_delay, n):
            ph = ((i - vib_delay) * inst.vibrato_rate / SAMPLE_RATE) % 1.0
            lfo = 1.0 - 4.0 * abs(ph - 0.5)
            ramp = min(1.0, (i - vib_delay) / max(1, vib_delay))
            freqs[i] *= 2.0 ** (inst.vibrato_depth * lfo * ramp / 12.0)
    return freqs


def render_note(inst: Instrument, freq: float, gate: int) -> Samples:
    """One note: gate samples held plus the release tail."""
    env = envelope(gate, inst.attack, inst.decay, inst.sustain, inst.release)
    n = len(env)
    freqs = _freq_curve(inst, freq, n)
    signal = oscillator(inst.wave, freqs)
    if inst.detune_cents:
        factor = 2.0 ** (inst.detune_cents / 1200.0)
        second = oscillator(inst.wave, [f * factor for f in freqs], phase=0.37)
        signal = gain(add(signal, second), 0.5)
    signal = low_pass(signal, inst.cutoff)
    return gain(multiply(signal, env), inst.volume)


# --------------------------------------------------------------------------- drums


def _drum_kick() -> Samples:
    n = seconds_to_samples(0.22)
    body = multiply(oscillator(TRI, sweep(170.0, 42.0, n)), envelope(n, 0.001, 0.2, 0.0, 0.01))
    click_n = seconds_to_samples(0.012)
    click = multiply(
        oscillator(NOISE, constant(SAMPLE_RATE, click_n)), envelope(click_n, 0.0, 0.012, 0.0, 0.0)
    )
    return add(body, gain(click, 0.35))


def _drum_snare() -> Samples:
    n = seconds_to_samples(0.18)
    tone = multiply(oscillator(TRI, sweep(220.0, 150.0, n)), envelope(n, 0.001, 0.09, 0.0, 0.01))
    hiss = multiply(
        high_pass(oscillator(NOISE, constant(SAMPLE_RATE, n)), 1800.0),
        envelope(n, 0.001, 0.16, 0.0, 0.01),
    )
    return add(gain(tone, 0.6), gain(hiss, 0.9))


def _drum_hat(open_hat: bool) -> Samples:
    n = seconds_to_samples(0.16 if open_hat else 0.035)
    hiss = high_pass(oscillator(NOISE_METAL, constant(SAMPLE_RATE, n), seed=0x5A), 6500.0)
    return gain(multiply(hiss, envelope(n, 0.0005, n / SAMPLE_RATE, 0.0, 0.005)), 0.7)


def _drum_tom(freq: float) -> Samples:
    n = seconds_to_samples(0.28)
    body = multiply(oscillator(TRI, sweep(freq * 1.4, freq, n)), envelope(n, 0.001, 0.26, 0.0, 0.01))
    skin_n = seconds_to_samples(0.02)
    skin = multiply(
        oscillator(NOISE, constant(SAMPLE_RATE, skin_n)), envelope(skin_n, 0.0, 0.02, 0.0, 0.0)
    )
    return add(body, gain(skin, 0.25))


def _drum_clap() -> Samples:
    burst_n = seconds_to_samples(0.012)
    spacing = seconds_to_samples(0.011)
    tail_n = seconds_to_samples(0.2)
    noise = high_pass(
        oscillator(NOISE, constant(SAMPLE_RATE, tail_n + spacing * 3), seed=0x77), 1200.0
    )
    out = zeros(len(noise))
    for k in range(3):
        start = k * spacing
        for i in range(burst_n):
            out[start + i] += noise[start + i] * (1.0 - i / burst_n)
    tail = multiply(noise, envelope(len(noise), 0.0, 0.2, 0.0, 0.0))
    for i in range(len(out)):
        out[i] = out[i] * 0.8 + tail[i] * 0.5
    return out


def _drum_crash() -> Samples:
    n = seconds_to_samples(0.9)
    hiss = high_pass(oscillator(NOISE_METAL, constant(SAMPLE_RATE, n), seed=0x3C), 4000.0)
    return gain(multiply(hiss, envelope(n, 0.002, 0.9, 0.0, 0.0)), 0.6)


KIT: Dict[str, Callable[[], Samples]] = {
    "K": _drum_kick,
    "S": _drum_snare,
    "H": lambda: _drum_hat(False),
    "O": lambda: _drum_hat(True),
    "T1": lambda: _drum_tom(220.0),
    "T2": lambda: _drum_tom(150.0),
    "T3": lambda: _drum_tom(100.0),
    "C": _drum_clap,
    "R": _drum_crash,
}
DRUMS = Instrument(wave="drums")
SOFT_HIT = 0.5


# --------------------------------------------------------------------------- sequencer


@dataclass(frozen=True)
class Event:
    step: int
    length: int  # steps
    notes: Tuple[str, ...]  # note names, or kit symbols for drum tracks
    velocity: float = 1.0


def parse_pattern(pattern: str, steps: int) -> List[Event]:
    """Token DSL: ``name[+name...][:steps][@velocity]``; ``.`` rests. Must fill exactly ``steps``."""
    events: List[Event] = []
    position = 0
    for token in pattern.split():
        velocity = 1.0
        if "@" in token:
            token, vel_text = token.split("@", 1)
            velocity = float(vel_text)
        length = 1
        if ":" in token:
            token, len_text = token.split(":", 1)
            length = int(len_text)
        if length <= 0:
            raise ValueError(f"bad length in token {token!r}")
        if token != ".":
            events.append(Event(position, length, tuple(token.split("+")), velocity))
        position += length
    if position != steps:
        raise ValueError(f"pattern has {position} steps, expected {steps}")
    return events


def drum_pattern(bars: Sequence[str], symbol: str) -> str:
    """One char per step: ``x`` hit, ``o`` soft hit, ``.`` rest. Returns token DSL text."""
    tokens: List[str] = []
    for bar in bars:
        if len(bar) != STEPS_PER_BAR:
            raise ValueError(f"drum bar {bar!r} must have {STEPS_PER_BAR} chars")
        for char in bar:
            if char == "x":
                tokens.append(symbol)
            elif char == "o":
                tokens.append(f"{symbol}@{SOFT_HIT}")
            else:
                tokens.append(".")
    return " ".join(tokens)


def arpeggio(chord: Sequence[str], order: Sequence[int], steps: int) -> str:
    """Cycle ``order`` over ``chord`` for ``steps`` 16ths; index >= len(chord) climbs octaves."""
    tokens: List[str] = []
    for i in range(steps):
        k = order[i % len(order)]
        base = chord[k % len(chord)]
        midi = note_to_midi(base) + 12 * (k // len(chord))
        tokens.append(midi_name(midi))
    return " ".join(tokens)


def bass_line(root: str, rhythm: Sequence[Tuple[int, int]]) -> str:
    """``rhythm`` = (interval in semitones, steps); an interval of REST means a rest."""
    base = note_to_midi(root)
    tokens: List[str] = []
    for interval, steps in rhythm:
        if interval == REST:
            tokens.append(f".:{steps}")
        else:
            tokens.append(f"{midi_name(base + interval)}:{steps}")
    return " ".join(tokens)


def repeat(pattern: str, times: int) -> str:
    return " ".join([pattern] * times)


@dataclass
class Track:
    instrument: Instrument
    pattern: str
    volume: float = 1.0
    pan: float = 0.0
    gate: float = 0.9  # fraction of the step length actually held
    echo_steps: float = 0.0
    echo_feedback: float = 0.35
    echo_mix: float = 0.3


@dataclass
class Song:
    name: str
    bpm: float
    bars: int
    tracks: List[Track] = field(default_factory=list)
    loop: bool = True
    tail_seconds: float = 0.0


def samples_per_step(bpm: float) -> float:
    return SAMPLE_RATE * 60.0 / bpm / STEPS_PER_BEAT


def song_samples(song: Song) -> int:
    steps = song.bars * STEPS_PER_BAR
    n = int(round(steps * samples_per_step(song.bpm)))
    if not song.loop:
        n += seconds_to_samples(song.tail_seconds)
    return n


def mix_into(dest: Samples, src: Samples, start: int, factor: float, wrap: bool) -> None:
    n = len(dest)
    for i, v in enumerate(src):
        j = start + i
        if j >= n:
            if not wrap:
                return
            j %= n
        dest[j] += v * factor


def render_track(track: Track, song: Song, n: int) -> Samples:
    steps = song.bars * STEPS_PER_BAR
    sps = samples_per_step(song.bpm)
    buffer = zeros(n)
    cache: Dict[Tuple[str, int], Samples] = {}
    is_kit = track.instrument.wave == DRUMS.wave
    for event in parse_pattern(track.pattern, steps):
        start = int(round(event.step * sps))
        gate = max(1, int(round(event.length * sps * track.gate)))
        for name in event.notes:
            key = (name, gate)
            if key not in cache:
                if is_kit:
                    cache[key] = KIT[name]()
                else:
                    cache[key] = render_note(track.instrument, note_hz(name), gate)
            mix_into(buffer, cache[key], start, event.velocity, song.loop)
    if track.echo_steps > 0.0:
        buffer = echo(
            buffer,
            int(round(track.echo_steps * sps)),
            track.echo_feedback,
            track.echo_mix,
            song.loop,
        )
        if len(buffer) > n:
            buffer = array("d", buffer[:n])
    return buffer


def render_song(song: Song) -> Tuple[Samples, Samples]:
    """Stereo mix, normalised to PEAK. Length = song_samples(song)."""
    n = song_samples(song)
    left = zeros(n)
    right = zeros(n)
    for track in song.tracks:
        mono = render_track(track, song, n)
        lg = math.sqrt((1.0 - track.pan) / 2.0) * track.volume
        rg = math.sqrt((1.0 + track.pan) / 2.0) * track.volume
        for i, v in enumerate(mono):
            left[i] += v * lg
            right[i] += v * rg
    normalised = normalize([left, right])
    return normalised[0], normalised[1]


# --------------------------------------------------------------------------- music

PAD_TRI = Instrument(
    TRI, attack=0.5, decay=0.3, sustain=0.8, release=0.7, cutoff=2200.0, detune_cents=7.0
)
PAD_SAW = Instrument(
    SAW, attack=0.08, decay=0.2, sustain=0.75, release=0.3, cutoff=1400.0, detune_cents=9.0
)
BASS_SOFT = Instrument(PULSE50, attack=0.005, decay=0.15, sustain=0.6, release=0.08, cutoff=500.0)
BASS_PUMP = Instrument(PULSE50, attack=0.002, decay=0.09, sustain=0.5, release=0.04, cutoff=1100.0)
BASS_SAW = Instrument(SAW, attack=0.003, decay=0.12, sustain=0.55, release=0.05, cutoff=700.0)
ARP = Instrument(PULSE25, attack=0.002, decay=0.1, sustain=0.3, release=0.05, cutoff=5000.0)
LEAD_DREAM = Instrument(
    PULSE12,
    attack=0.02,
    decay=0.2,
    sustain=0.7,
    release=0.25,
    cutoff=4500.0,
    vibrato_depth=0.25,
    vibrato_delay=0.18,
)
LEAD_DRIVE = Instrument(
    PULSE25,
    attack=0.004,
    decay=0.12,
    sustain=0.65,
    release=0.12,
    cutoff=6000.0,
    vibrato_depth=0.2,
    vibrato_delay=0.12,
)
LEAD_NIGHT = Instrument(
    PULSE50,
    attack=0.01,
    decay=0.2,
    sustain=0.6,
    release=0.2,
    cutoff=3500.0,
    vibrato_depth=0.3,
    vibrato_delay=0.15,
)
FANFARE = Instrument(
    PULSE50, attack=0.003, decay=0.15, sustain=0.6, release=0.35, cutoff=5000.0, detune_cents=5.0
)

ARP_UP_DOWN = (0, 1, 2, 3, 4, 5, 6, 7, 8, 7, 6, 5, 4, 3, 2, 1)
ARP_ROLL = (0, 2, 1, 3, 2, 4, 3, 5, 4, 6, 5, 7, 6, 5, 4, 3)


def menu_theme() -> Song:
    """Dreamy synthwave, 100 BPM, 16 bars: I-vi-IV-V (C-Am-F-G), two bars per chord."""
    chords = [
        ("c4", "e4", "g4", "b4"),
        ("a3", "c4", "e4", "g4"),
        ("f3", "a3", "c4", "e4"),
        ("g3", "b3", "d4", "f#4"),
    ]
    roots = ["c2", "a1", "f1", "g1"]
    pad = " ".join(f"{'+'.join(chord)}:32" for chord in chords)
    arps = " ".join(arpeggio(chord, ARP_UP_DOWN, 32) for chord in chords)
    rhythm = [(0, 6), (0, 2), (0, 4), (7, 4), (0, 6), (0, 2), (12, 2), (0, 2), (7, 2), (0, 2)]
    bass = " ".join(bass_line(root, rhythm) for root in roots)
    lead = " ".join(
        [
            ".:128",
            "e5:6 g5:2 a5:4 g5:4 e5:8 d5:4 c5:4",
            "a4:6 c5:2 e5:4 d5:4 c5:8 .:8",
            "f5:6 e5:2 d5:4 c5:4 a4:8 c5:4 d5:4",
            "e5:6 d5:2 b4:4 d5:4 g5:12 .:4",
        ]
    )
    kick = ["x.......x......."] * 16
    snare = ["....o.......o..."] * 16
    hats = ["..x...x...x...x."] * 16
    return Song(
        "menu_theme",
        100.0,
        16,
        [
            Track(PAD_TRI, repeat(pad, 2), volume=0.34, gate=1.0),
            Track(
                ARP,
                repeat(arps, 2),
                volume=0.22,
                pan=0.25,
                gate=0.6,
                echo_steps=3.0,
                echo_feedback=0.45,
                echo_mix=0.35,
            ),
            Track(BASS_SOFT, repeat(bass, 2), volume=0.5, gate=0.85),
            Track(
                LEAD_DREAM,
                lead,
                volume=0.3,
                pan=-0.15,
                gate=0.92,
                echo_steps=6.0,
                echo_feedback=0.4,
                echo_mix=0.3,
            ),
            Track(DRUMS, drum_pattern(kick, "K"), volume=0.55),
            Track(DRUMS, drum_pattern(snare, "S"), volume=0.35),
            Track(DRUMS, drum_pattern(hats, "H"), volume=0.25, pan=0.3),
        ],
    )


def race_a() -> Song:
    """Driving synthwave, 128 BPM, 24 bars: Am-F-C-G, pumping octave bass, lead from bar 9."""
    chords = [
        ("a3", "c4", "e4", "g4"),
        ("f3", "a3", "c4", "e4"),
        ("c4", "e4", "g4", "b4"),
        ("g3", "b3", "d4", "f#4"),
    ]
    roots = ["a1", "f1", "c2", "g1"]
    pad = " ".join(f"{'+'.join(chord)}:16" for chord in chords)
    bass = " ".join(bass_line(root, [(0, 2), (12, 2)] * 4) for root in roots)
    arps = " ".join(arpeggio(chord, ARP_ROLL, 16) for chord in chords)
    phrase_a = [
        "a4:2 .:2 a4:2 c5:2 e5:4 d5:2 c5:2",
        "c5:2 .:2 c5:2 d5:2 f5:4 e5:4",
        "e5:4 g5:2 e5:2 c5:4 d5:4",
        "b4:4 d5:4 g4:6 .:2",
        "a4:2 .:2 a4:2 c5:2 e5:4 g5:2 a5:2",
        "f5:4 e5:2 c5:2 d5:4 c5:4",
        "e5:6 d5:2 c5:4 b4:4",
        "a4:12 .:4",
    ]
    phrase_b = [
        "e5:2 e5:2 e5:2 d5:2 c5:4 a4:4",
        "f5:2 f5:2 f5:2 e5:2 d5:4 c5:4",
        "g5:4 e5:2 c5:2 g5:4 e5:4",
        "d5:2 b4:2 d5:2 g5:2 b5:8",
        "a5:2 .:2 g5:2 e5:2 d5:4 c5:4",
        "f5:2 .:2 e5:2 c5:2 d5:4 a4:4",
        "e5:4 g5:4 c6:8",
        "b5:6 g5:2 e5:4 d5:4",
    ]
    lead = " ".join([".:128"] + phrase_a + phrase_b)
    kick = ["x...x...x...x..."] * 24
    snare = ["....x.......x..."] * 23 + ["....x.......x.xx"]
    hats = ["x.x.x.x.x.x.x.x."] * 24
    open_hats = ["..x...x...x...x."] * 24
    return Song(
        "race_a",
        128.0,
        24,
        [
            Track(BASS_PUMP, repeat(bass, 6), volume=0.55, gate=0.75),
            Track(PAD_SAW, repeat(pad, 6), volume=0.2, gate=0.98),
            Track(
                ARP,
                repeat(arps, 6),
                volume=0.2,
                pan=0.3,
                gate=0.5,
                echo_steps=3.0,
                echo_feedback=0.4,
                echo_mix=0.3,
            ),
            Track(
                LEAD_DRIVE,
                lead,
                volume=0.34,
                pan=-0.1,
                gate=0.9,
                echo_steps=6.0,
                echo_feedback=0.35,
                echo_mix=0.28,
            ),
            Track(DRUMS, drum_pattern(kick, "K"), volume=0.7),
            Track(DRUMS, drum_pattern(snare, "S"), volume=0.5),
            Track(DRUMS, drum_pattern(hats, "H"), volume=0.22, pan=0.35),
            Track(DRUMS, drum_pattern(open_hats, "O"), volume=0.2, pan=-0.3),
        ],
    )


def race_b() -> Song:
    """Night/desert, 140 BPM, 28 bars: Dm-Bb-C-A7, saw bass, arpeggio lead, toms."""
    chords = [
        ("d4", "f4", "a4", "c5"),
        ("a#3", "d4", "f4", "a4"),
        ("c4", "e4", "g4", "d5"),
        ("a3", "c#4", "e4", "g4"),
    ]
    roots = ["d2", "a#1", "c2", "a1"]
    pad = " ".join(f"{'+'.join(chord)}:16" for chord in chords)
    rhythm = [(0, 3), (0, 1), (0, 2), (0, 2), (12, 2), (0, 2), (10, 2), (12, 2)]
    bass = " ".join(bass_line(root, rhythm) for root in roots)
    arps = " ".join(arpeggio(chord, ARP_UP_DOWN, 16) for chord in chords)
    phrase_a = [
        "d5:8 f5:4 e5:4",
        "d5:8 .:4 c5:4",
        "e5:8 g5:4 e5:4",
        "c#5:12 .:4",
        "a5:4 g5:4 f5:4 e5:4",
        "f5:8 d5:8",
        "e5:4 c5:4 g5:8",
        "a5:4 e5:4 c#5:8",
    ]
    phrase_b = [
        "d6:4 c6:4 a5:4 f5:4",
        "d5:8 f5:4 a5:4",
        "g5:4 e5:4 c5:8",
        "e5:6 c#5:2 a4:8",
        "f5:4 a5:4 d6:8",
        "f5:4 d5:4 a#4:8",
        "c6:4 g5:4 e5:4 c5:4",
        "a5:12 .:4",
    ]
    lead = " ".join([".:192"] + phrase_a + phrase_b)
    kick = ["x...x...x...x..."] * 28
    snare = ["....x.......x..."] * 28
    hats = ["x.x.x.x.x.x.x.x."] * 28
    groove_tom = ["..o.......o....."] * 28
    fill_high = ["................"] * 3 + ["........x.x....."]
    fill_mid = ["................"] * 3 + ["..........x.x..."]
    fill_low = ["................"] * 3 + ["............x.xx"]
    return Song(
        "race_b",
        140.0,
        28,
        [
            Track(BASS_SAW, repeat(bass, 7), volume=0.5, gate=0.8),
            Track(PAD_TRI, repeat(pad, 7), volume=0.22, gate=1.0),
            Track(
                ARP,
                repeat(arps, 7),
                volume=0.3,
                pan=0.25,
                gate=0.55,
                echo_steps=3.0,
                echo_feedback=0.45,
                echo_mix=0.35,
            ),
            Track(
                LEAD_NIGHT,
                lead,
                volume=0.3,
                pan=-0.15,
                gate=0.92,
                echo_steps=4.0,
                echo_feedback=0.35,
                echo_mix=0.3,
            ),
            Track(DRUMS, drum_pattern(kick, "K"), volume=0.7),
            Track(DRUMS, drum_pattern(snare, "S"), volume=0.45),
            Track(DRUMS, drum_pattern(hats, "H"), volume=0.2, pan=0.35),
            Track(DRUMS, drum_pattern(groove_tom, "T3"), volume=0.5, pan=-0.2),
            Track(DRUMS, drum_pattern(fill_high * 7, "T1"), volume=0.5, pan=0.3),
            Track(DRUMS, drum_pattern(fill_mid * 7, "T2"), volume=0.5),
            Track(DRUMS, drum_pattern(fill_low * 7, "T3"), volume=0.55, pan=-0.3),
        ],
    )


def results_jingle() -> Song:
    """One-shot fanfare, 120 BPM, 3 bars = 6 s including the ring-out."""
    lead = " ".join(["c5:2 e5:2 g5:2 c6:4 .:2 g5:2 c6:2", "e6:2 d6:2 c6:12", ".:16"])
    harmony = " ".join(["e4:2 g4:2 c5:2 e5:4 .:2 e5:2 e5:2", "g5:2 g5:2 e5:12", ".:16"])
    pad = "c4+e4+g4:8 f4+a4+c5:8 g3+b3+d4+f4:8 c4+e4+g4+c5:16 .:8"
    bass = "c2:8 f2:8 g2:8 c2:14 .:10"
    kick = ["x.......x.......", "x...............", "................"]
    snare = ["oooooooooooooooo", "....x...........", "................"]
    crash = ["................", "x...............", "................"]
    return Song(
        "results_jingle",
        120.0,
        3,
        [
            Track(
                FANFARE,
                lead,
                volume=0.4,
                pan=-0.1,
                gate=0.9,
                echo_steps=4.0,
                echo_feedback=0.4,
                echo_mix=0.3,
            ),
            Track(replace(FANFARE, wave=PULSE25), harmony, volume=0.25, pan=0.2, gate=0.9),
            Track(PAD_SAW, pad, volume=0.22, gate=1.0),
            Track(BASS_SOFT, bass, volume=0.5, gate=0.95),
            Track(DRUMS, drum_pattern(kick, "K"), volume=0.6),
            Track(DRUMS, drum_pattern(snare, "S"), volume=0.4),
            Track(DRUMS, drum_pattern(crash, "R"), volume=0.5),
        ],
        loop=False,
    )


# --------------------------------------------------------------------------- sfx

Adsr = Tuple[float, float, float, float]


def _tone(wave_name: str, freqs: Sequence[float], adsr: Adsr, cutoff: float = 0.0) -> Samples:
    env = envelope(len(freqs), *adsr)
    signal = oscillator(wave_name, list(freqs) + constant(freqs[-1], len(env) - len(freqs)))
    return multiply(low_pass(signal, cutoff), env)


def _noise(
    seconds: float,
    adsr: Adsr,
    cutoff: float = 0.0,
    rate: float = SAMPLE_RATE,
    seed: int = NOISE_SEED,
    wave_name: str = NOISE,
) -> Samples:
    n = seconds_to_samples(seconds)
    env = envelope(n, *adsr)
    signal = oscillator(wave_name, constant(rate, len(env)), seed=seed)
    return multiply(low_pass(signal, cutoff), env)


def _blip(notes: Sequence[str], each: float, wave_name: str = PULSE25, release: float = 0.05) -> Samples:
    out = zeros(0)
    n = seconds_to_samples(each)
    for k, name in enumerate(notes):
        part = _tone(wave_name, constant(note_hz(name), n), (0.002, each * 0.5, 0.6, release))
        padded = zeros(k * n + len(part))
        for i, v in enumerate(part):
            padded[k * n + i] = v
        out = add(out, padded)
    return out


def _mono(signal: Samples) -> List[Samples]:
    return normalize([clip(signal)])


def sfx_engine_loop() -> List[Samples]:
    n = SAMPLE_RATE  # exactly 1 s: 56 Hz, 28 Hz and the 4 Hz LFO complete whole cycles
    low = low_pass(oscillator(PULSE25, constant(56.0, n)), 300.0, wrap=True)
    sub = oscillator(TRI, constant(28.0, n))
    rumble = low_pass(oscillator(WHITE, constant(SAMPLE_RATE, n), seed=NOISE_SEED), 400.0, True)
    mix = add(gain(low, 0.6), gain(sub, 0.5), gain(rumble, 0.5))
    return _mono(tremolo(mix, 4.0, 0.25))


def sfx_nitro_ignite() -> List[Samples]:
    n = seconds_to_samples(0.45)
    whoosh = _noise(0.45, (0.005, 0.4, 0.0, 0.05), cutoff=3000.0, seed=0x11)
    rise = _tone(PULSE25, sweep(180.0, 1100.0, n), (0.005, 0.35, 0.1, 0.05), cutoff=4000.0)
    return _mono(add(gain(whoosh, 0.8), gain(rise, 0.5)))


def sfx_nitro_loop() -> List[Samples]:
    n = SAMPLE_RATE
    hiss = high_pass(oscillator(WHITE, constant(SAMPLE_RATE, n), seed=0x22), 1500.0, True)
    whine = oscillator(PULSE12, constant(880.0, n))
    mix = add(gain(hiss, 0.7), gain(low_pass(whine, 2500.0, wrap=True), 0.15))
    return _mono(tremolo(mix, 6.0, 0.3))


def sfx_thruster_jump() -> List[Samples]:
    n = seconds_to_samples(0.4)
    rise = _tone(PULSE50, sweep(150.0, 1400.0, n), (0.003, 0.3, 0.2, 0.08), cutoff=5000.0)
    burst = _noise(0.25, (0.002, 0.22, 0.0, 0.03), cutoff=2500.0, seed=0x33)
    return _mono(add(gain(rise, 0.6), gain(burst, 0.6)))


def sfx_landing() -> List[Samples]:
    n = seconds_to_samples(0.2)
    thump = _tone(TRI, sweep(130.0, 40.0, n), (0.001, 0.18, 0.0, 0.03))
    dust = _noise(0.12, (0.001, 0.1, 0.0, 0.02), cutoff=1200.0, seed=0x44)
    return _mono(add(thump, gain(dust, 0.5)))


def sfx_hard_landing() -> List[Samples]:
    n = seconds_to_samples(0.4)
    thump = _tone(TRI, sweep(160.0, 30.0, n), (0.001, 0.35, 0.0, 0.05))
    crunch = _noise(0.3, (0.001, 0.25, 0.0, 0.05), cutoff=2000.0, seed=0x55)
    metal = _noise(0.2, (0.001, 0.15, 0.0, 0.05), rate=9000.0, seed=0x56, wave_name=NOISE_METAL)
    return _mono(clip(gain(add(thump, gain(crunch, 0.7), gain(metal, 0.3)), 1.6)))


def sfx_crush() -> List[Samples]:
    n = seconds_to_samples(0.55)
    thud = _tone(TRI, sweep(120.0, 35.0, n), (0.001, 0.45, 0.0, 0.05))
    scream = _tone(PULSE25, sweep(900.0, 120.0, n), (0.002, 0.4, 0.1, 0.1), cutoff=3000.0)
    crunch = _noise(0.5, (0.001, 0.4, 0.0, 0.05), rate=12000.0, seed=0x66, wave_name=NOISE_METAL)
    return _mono(clip(gain(add(thud, gain(scream, 0.45), gain(crunch, 0.6)), 1.5)))


def sfx_bump() -> List[Samples]:
    n = seconds_to_samples(0.12)
    thud = _tone(TRI, sweep(200.0, 70.0, n), (0.001, 0.1, 0.0, 0.02))
    click = _noise(0.05, (0.0005, 0.04, 0.0, 0.01), cutoff=3500.0, seed=0x77)
    return _mono(add(thud, gain(click, 0.6)))


def sfx_scenery_hit() -> List[Samples]:
    n = seconds_to_samples(0.3)
    crash = _noise(0.3, (0.001, 0.28, 0.0, 0.04), cutoff=4500.0, seed=0x88)
    thud = _tone(PULSE50, sweep(260.0, 60.0, n), (0.001, 0.2, 0.0, 0.05), cutoff=1500.0)
    return _mono(add(gain(crash, 0.8), gain(thud, 0.5)))


def sfx_offroad_loop() -> List[Samples]:
    n = SAMPLE_RATE
    rng = random.Random(0x99)
    gravel = low_pass(oscillator(WHITE, constant(SAMPLE_RATE, n), seed=0x9A), 900.0, wrap=True)
    flicker = zeros(n)
    level = 0.5
    grain = SAMPLE_RATE // 100  # 10 ms grains, 100 per second so the loop point is a grain edge
    for i in range(n):
        if i % grain == 0:
            level = 0.35 + 0.65 * rng.random()
        flicker[i] = gravel[i] * level
    return _mono(tremolo(flicker, 8.0, 0.2))


def sfx_countdown_beep() -> List[Samples]:
    n = seconds_to_samples(0.14)
    return _mono(_tone(PULSE50, constant(note_hz("a5"), n), (0.002, 0.05, 0.7, 0.03)))


def sfx_go() -> List[Samples]:
    n = seconds_to_samples(0.5)
    tone = _tone(PULSE50, constant(note_hz("a6"), n), (0.002, 0.1, 0.7, 0.12))
    shimmer = _tone(PULSE25, constant(note_hz("e7"), n), (0.002, 0.1, 0.5, 0.12))
    return _mono(add(tone, gain(shimmer, 0.4)))


def sfx_lap() -> List[Samples]:
    return _mono(_blip(["e6", "a6"], 0.12, PULSE25, release=0.15))


def sfx_finish() -> List[Samples]:
    return _mono(_blip(["c6", "e6", "g6", "c7"], 0.11, PULSE50, release=0.5))


def sfx_menu_move() -> List[Samples]:
    n = seconds_to_samples(0.05)
    return _mono(_tone(PULSE25, constant(1000.0, n), (0.001, 0.03, 0.5, 0.02)))


def sfx_menu_confirm() -> List[Samples]:
    return _mono(_blip(["c6", "g6"], 0.08, PULSE25, release=0.08))


def sfx_menu_cancel() -> List[Samples]:
    return _mono(_blip(["g5", "c5"], 0.08, PULSE25, release=0.08))


def sfx_buy() -> List[Samples]:
    return _mono(_blip(["b5", "e6"], 0.09, PULSE50, release=0.35))


def sfx_error() -> List[Samples]:
    buzz = _tone(PULSE12, constant(110.0, seconds_to_samples(0.09)), (0.001, 0.05, 0.7, 0.02))
    offset = seconds_to_samples(0.13)
    second = zeros(offset + len(buzz))
    for i, v in enumerate(buzz):
        second[offset + i] = v
    return _mono(add(buzz, second))


# --------------------------------------------------------------------------- catalog


@dataclass(frozen=True)
class Entry:
    name: str
    role: str  # "music" | "sfx"
    loop: bool
    bpm: float
    render: Callable[[], List[Samples]]

    @property
    def path(self) -> str:
        return f"{AUDIO_DIR}/{self.role}/{self.name}.ogg"


def _song_entry(builder: Callable[[], Song]) -> Entry:
    song = builder()
    return Entry(song.name, "music", song.loop, song.bpm, lambda: list(render_song(builder())))


def _sfx_entry(name: str, render: Callable[[], List[Samples]], loop: bool = False) -> Entry:
    return Entry(name, "sfx", loop, 0.0, render)


CATALOG: List[Entry] = [
    _song_entry(menu_theme),
    _song_entry(race_a),
    _song_entry(race_b),
    _song_entry(results_jingle),
    _sfx_entry("engine_loop", sfx_engine_loop, loop=True),
    _sfx_entry("nitro_ignite", sfx_nitro_ignite),
    _sfx_entry("nitro_loop", sfx_nitro_loop, loop=True),
    _sfx_entry("thruster_jump", sfx_thruster_jump),
    _sfx_entry("landing", sfx_landing),
    _sfx_entry("hard_landing", sfx_hard_landing),
    _sfx_entry("crush", sfx_crush),
    _sfx_entry("bump", sfx_bump),
    _sfx_entry("scenery_hit", sfx_scenery_hit),
    _sfx_entry("offroad_loop", sfx_offroad_loop, loop=True),
    _sfx_entry("countdown_beep", sfx_countdown_beep),
    _sfx_entry("go", sfx_go),
    _sfx_entry("lap", sfx_lap),
    _sfx_entry("finish", sfx_finish),
    _sfx_entry("menu_move", sfx_menu_move),
    _sfx_entry("menu_confirm", sfx_menu_confirm),
    _sfx_entry("menu_cancel", sfx_menu_cancel),
    _sfx_entry("buy", sfx_buy),
    _sfx_entry("error", sfx_error),
]
CATALOG_BY_NAME: Dict[str, Entry] = {entry.name: entry for entry in CATALOG}


# --------------------------------------------------------------------------- files


def write_wav(path: Path, channels: Sequence[Samples]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(len(channels))
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(to_int16(channels))


def ffmpeg_binary() -> Optional[str]:
    return shutil.which("ffmpeg")


def encode_ogg(wav_path: Path, ogg_path: Path) -> None:
    """ffmpeg libvorbis with bitexact flags so the container is reproducible."""
    binary = ffmpeg_binary()
    if binary is None:
        raise RuntimeError("ffmpeg not found in PATH")
    ogg_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        binary,
        "-hide_banner",
        "-loglevel",
        "error",
        "-nostdin",
        "-y",
        "-i",
        str(wav_path),
        "-map_metadata",
        "-1",
        "-fflags",
        "+bitexact",
        "-flags",
        "+bitexact",
        "-c:a",
        "libvorbis",
        "-q:a",
        OGG_QUALITY,
        str(ogg_path),
    ]
    subprocess.run(command, check=True)


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def render_entry(entry: Entry, out_root: Path, wav_dir: Path) -> Dict[str, object]:
    channels = entry.render()
    seconds = len(channels[0]) / SAMPLE_RATE
    wav_path = wav_dir / f"{entry.name}.wav"
    write_wav(wav_path, channels)
    ogg_path = out_root / entry.path
    encode_ogg(wav_path, ogg_path)
    return {
        "name": entry.name,
        "path": entry.path,
        "role": entry.role,
        "loop": entry.loop,
        "bpm": entry.bpm,
        "seconds": round(seconds, 4),
        "channels": len(channels),
        "pcm_sha256": sha256_of(wav_path),
        "sha256": sha256_of(ogg_path),
    }


def load_manifest(root: Path) -> Dict[str, object]:
    path = root / AUDIO_DIR / MANIFEST_NAME
    if not path.is_file():
        return {"files": []}
    return json.loads(path.read_text(encoding="utf-8"))


def manifest_files(manifest: Dict[str, object]) -> List[Dict[str, object]]:
    files = manifest.get("files", [])
    return list(files) if isinstance(files, list) else []


def save_manifest(root: Path, files: List[Dict[str, object]]) -> None:
    path = root / AUDIO_DIR / MANIFEST_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "generator": "tools/audio/gen_audio.py",
        "sample_rate": SAMPLE_RATE,
        "peak_dbfs": PEAK_DBFS,
        "files": sorted(files, key=lambda f: (str(f["role"]), str(f["name"]))),
    }
    path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def selected_entries(only: Optional[Sequence[str]]) -> List[Entry]:
    if not only:
        return list(CATALOG)
    missing = [name for name in only if name not in CATALOG_BY_NAME]
    if missing:
        raise SystemExit(f"unknown entries: {', '.join(missing)}")
    return [CATALOG_BY_NAME[name] for name in only]



IMPORT_SUFFIX = ".import"
PARAMS_HEADER = "[params]"


def import_params(entry: Entry, seconds: float) -> Dict[str, str]:
    """Godot ``.ogg.import`` [params] values for an entry: loop flag, and BPM data for music."""
    music_loop = entry.role == "music" and entry.loop
    return {
        "loop": "true" if entry.loop else "false",
        "loop_offset": "0",
        "bpm": f"{entry.bpm:.1f}" if music_loop else "0",
        "beat_count": str(int(round(seconds * entry.bpm / 60.0))) if music_loop else "0",
        "bar_beats": str(BEATS_PER_BAR),
    }


def update_import_file(root: Path, entry: Entry, seconds: float) -> bool:
    """Rewrite the [params] of ``<entry>.ogg.import`` so Godot keeps the loop flag on re-import.

    Returns False when Godot has not generated the file yet (run ``--headless --import`` first).
    """
    path = root / (entry.path + IMPORT_SUFFIX)
    if not path.is_file():
        return False
    values = import_params(entry, seconds)
    out: List[str] = []
    seen: set = set()
    in_params = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("["):
            in_params = line.strip() == PARAMS_HEADER
        key = line.split("=", 1)[0].strip() if in_params and "=" in line else ""
        if key in values:
            line = f"{key}={values[key]}"
            seen.add(key)
        out.append(line)
    if not in_params:
        out.append("")
        out.append(PARAMS_HEADER)
        out.append("")
    for key, value in values.items():
        if key not in seen:
            out.append(f"{key}={value}")
    path.write_text("\n".join(out) + "\n", encoding="utf-8")
    return True


def import_loop_flag(root: Path, entry: Entry) -> Optional[bool]:
    """The ``loop`` value in the committed .import file, or None when the file is missing."""
    path = root / (entry.path + IMPORT_SUFFIX)
    if not path.is_file():
        return None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("loop="):
            return line.split("=", 1)[1].strip() == "true"
    return False


def update_imports(root: Path, only: Optional[Sequence[str]]) -> int:
    listed = {str(f["name"]): f for f in manifest_files(load_manifest(root))}
    missing = 0
    for entry in selected_entries(only):
        info = listed.get(entry.name)
        seconds = float(str(info["seconds"])) if info else 0.0
        if update_import_file(root, entry, seconds):
            print(f"import {entry.path}{IMPORT_SUFFIX}  loop={str(entry.loop).lower()}")
        else:
            print(f"skip   {entry.path}{IMPORT_SUFFIX}: not generated yet")
            missing += 1
    return 1 if missing else 0


def write(root: Path, only: Optional[Sequence[str]], keep_wav: Optional[Path]) -> int:
    entries = selected_entries(only)
    previous = {str(f["name"]): f for f in manifest_files(load_manifest(root))}
    with tempfile.TemporaryDirectory(prefix="neondrift-audio-") as tmp:
        wav_dir = keep_wav or Path(tmp)
        for entry in entries:
            info = render_entry(entry, root, wav_dir)
            previous[entry.name] = info
            update_import_file(root, entry, float(str(info["seconds"])))
            print(f"wrote  {info['path']}  {info['seconds']:.2f}s  {str(info['sha256'])[:12]}")
    save_manifest(root, list(previous.values()))
    return 0


def check(root: Path, only: Optional[Sequence[str]]) -> int:
    listed = {str(f["name"]): f for f in manifest_files(load_manifest(root))}
    entries = selected_entries(only)
    failures = 0
    with tempfile.TemporaryDirectory(prefix="neondrift-audio-check-") as tmp:
        tmp_root = Path(tmp)
        for entry in entries:
            expected = listed.get(entry.name)
            if expected is None:
                print(f"MISSING {entry.name}: not in manifest")
                failures += 1
                continue
            committed = root / entry.path
            if not committed.is_file():
                print(f"MISSING {entry.path}")
                failures += 1
                continue
            if sha256_of(committed) != expected["sha256"]:
                print(f"DRIFT   {entry.path}: file does not match manifest")
                failures += 1
                continue
            loop_flag = import_loop_flag(root, entry)
            if loop_flag is not None and loop_flag != entry.loop:
                print(f"DRIFT   {entry.path}{IMPORT_SUFFIX}: loop={str(loop_flag).lower()}")
                failures += 1
                continue
            info = render_entry(entry, tmp_root, tmp_root / "wav")
            if info["sha256"] != expected["sha256"]:
                same_pcm = info["pcm_sha256"] == expected.get("pcm_sha256")
                detail = "encoder differs" if same_pcm else "pcm differs"
                print(f"DRIFT   {entry.path}: regenerated output differs ({detail})")
                failures += 1
            else:
                print(f"ok      {entry.path}")
    extra = set(listed) - set(CATALOG_BY_NAME)
    if extra and not only:
        print(f"EXTRA   manifest lists unknown entries: {', '.join(sorted(extra))}")
        failures += 1
    return 1 if failures else 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="render into <root>/audio, update manifest")
    mode.add_argument("--check", action="store_true", help="regenerate to a temp dir and compare")
    mode.add_argument("--imports", action="store_true", help="only rewrite the .ogg.import params")
    mode.add_argument("--list", action="store_true", help="print the catalog")
    parser.add_argument("--only", nargs="*", default=None, help="entry names to render")
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root (default: here)")
    parser.add_argument("--keep-wav", type=Path, default=None, help="also keep WAV files here")
    args = parser.parse_args(argv)
    if args.list:
        for entry in CATALOG:
            loop = "loop" if entry.loop else "one-shot"
            print(f"{entry.role:5} {entry.name:16} {loop}")
        return 0
    if args.imports:
        return update_imports(args.root, args.only)
    if ffmpeg_binary() is None:
        print("ffmpeg not found in PATH", file=sys.stderr)
        return 2
    if args.write:
        return write(args.root, args.only, args.keep_wav)
    return check(args.root, args.only)


if __name__ == "__main__":
    sys.exit(main())
