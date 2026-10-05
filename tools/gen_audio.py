#!/usr/bin/env python3
"""Procedural audio source for Cloud Courtyard (云上庭).

Every sound effect and music loop the game ships in ``audio/`` is synthesised
here from scratch with numpy/scipy: no recorded samples, no third-party assets,
so the soundscape is fully reproducible and free of licensing questions.

The palette follows the game's Monument Valley-inspired art direction -- calm,
airy, pastel.  Bells are additive glass/kalimba tones on the C major pentatonic
scale (one per box push, so a run of pushes plays a melody), stone sounds are
soft filtered noise, and most things sit in a gentle synthetic reverb.

Usage::

    python3 tools/gen_audio.py                  # regenerate everything
    python3 tools/gen_audio.py --only push win  # regenerate selected sounds

Output conventions
------------------
* One-shot SFX: 16-bit PCM WAV, 44.1 kHz, mono (``win`` / ``target_on`` are
  stereo), DC-free, short fades at both ends, peak-normalised to -1 dBFS.
  Playback level is set per sound in the engine (see ``Sound.target_db``).
* Loop (``ambient_pad``): stereo, peak -3 dBFS, *periodic by construction* --
  circular reverb, events wrapped modulo the loop length, oscillators
  quantised to a whole number of cycles per loop -- so the last sample flows
  straight into the first.  (An earlier noise-based waterfall loop was removed:
  broadband noise read as wind / a broken microphone under the music.)
  - ``ambient_pad.wav``: 16-bit PCM at 22.05 kHz with a ``smpl`` loop chunk.
    The pad is so smooth and dark that the Vorbis encoder's error on the
    stream's last block becomes an audible click at the loop point.  Its
    spectrum is already 65-80 dB below its peak band above 5 kHz, so 22.05 kHz
    loses nothing audible and halves the size of 44.1 kHz PCM.
* All randomness is seeded from each sound's name, so runs are bit-identical.

After writing, the script re-reads every file and prints a verification
report: format, levels, bell pitch accuracy and loop-seam continuity.
"""

from __future__ import annotations

import argparse
import functools
import os
import shutil
import struct
import subprocess
import sys
import warnings
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import numpy as np
from scipy import signal
from scipy.io import wavfile

SR = 44_100
OUT_DIR = Path(__file__).resolve().parent.parent / "audio"
FFMPEG = os.environ.get("FFMPEG") or shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"

SFX_PEAK_DB = -1.0
LOOP_PEAK_DB = -3.0
OGG_QUALITY = 8      # ffmpeg native Vorbis "-q:a" (VBR)
VORBIS_BLOCK = 256   # loop lengths are multiples of this so the decoded Ogg is sample-exact
LOOP_POSTROLL = 64   # frames of loop-start copied after a WAV loop's end (see write_wav)

TAU = 2.0 * np.pi

# --------------------------------------------------------------------------
# Pitch
# --------------------------------------------------------------------------

_SEMITONES_FROM_A = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}

# The ten bells, bell_00 .. bell_09: C major pentatonic over two octaves.
BELL_NOTES = ("C5", "D5", "E5", "G5", "A5", "C6", "D6", "E6", "G6", "A6")


def note(name: str) -> float:
    """Equal-tempered frequency (A4 = 440 Hz) of a name like 'C5', 'F#3' or 'Bb4'."""
    letter, accidental, octave = name[0], name[1:-1], int(name[-1])
    semis = _SEMITONES_FROM_A[letter] + {"": 0, "#": 1, "b": -1}[accidental]
    return 440.0 * 2.0 ** ((semis + 12 * (octave - 4)) / 12)


def detune(freq: float, cents: float) -> float:
    return freq * 2.0 ** (cents / 1200)


# --------------------------------------------------------------------------
# Time and envelopes
# --------------------------------------------------------------------------

def samples(seconds: float) -> int:
    return int(round(seconds * SR))


def time_axis(seconds: float) -> np.ndarray:
    return np.arange(samples(seconds)) / SR


def loop_samples(seconds: float) -> int:
    """Loop length rounded to a whole number of Vorbis blocks."""
    return int(round(seconds * SR / VORBIS_BLOCK)) * VORBIS_BLOCK


def ramp(t, start: float, end: float):
    """Raised-cosine step: 0 before `start`, 1 after `end`, smooth in between."""
    x = np.clip((np.asarray(t) - start) / max(end - start, 1e-9), 0.0, 1.0)
    return 0.5 - 0.5 * np.cos(np.pi * x)


def decay(t, t60: float):
    """Exponential decay that reaches -60 dB after `t60` seconds."""
    return 10.0 ** (-3.0 * np.asarray(t) / t60)


def strike(t, attack: float, t60: float):
    """Percussive envelope: short raised-cosine attack, then exponential decay."""
    return ramp(t, 0.0, attack) * decay(t, t60)


def fade(x: np.ndarray, fade_in: float, fade_out: float) -> np.ndarray:
    """Raised-cosine fade-in/out at the ends of a mono (n,) or stereo (n, 2) signal."""
    t = np.arange(len(x)) / SR
    env = ramp(t, 0.0, fade_in) * (1.0 - ramp(t, t[-1] - fade_out, t[-1]))
    return x * (env[:, None] if x.ndim == 2 else env)


# --------------------------------------------------------------------------
# Oscillators, noise and filters
# --------------------------------------------------------------------------

def sine_sweep(freq: np.ndarray, phase: float = 0.0) -> np.ndarray:
    """Sine whose instantaneous frequency (Hz) follows the array `freq`."""
    return np.sin(phase + TAU * np.cumsum(freq) / SR)


def modal(t: np.ndarray, modes) -> np.ndarray:
    """Tiny modal resonator: sum of decaying sines given as (freq, amp, t60)."""
    return sum(amp * np.sin(TAU * f * t) * decay(t, t60) for f, amp, t60 in modes)


def band(lo: float | None = None, hi: float | None = None, order: int = 2, tilt: float = 0.0):
    """Magnitude response for `shaped_noise`: Butterworth-like edges and a 1/f^tilt
    power slope (tilt 1 = pink, 2 = brown)."""
    def gain(f):
        g = f ** (-tilt / 2.0)
        if lo:
            g = g / np.sqrt(1.0 + (lo / f) ** (2 * order))
        if hi:
            g = g / np.sqrt(1.0 + (f / hi) ** (2 * order))
        return g
    return gain


def shaped_noise(rng: np.random.Generator, n: int, gain) -> np.ndarray:
    """Unit-RMS Gaussian noise whose magnitude spectrum follows `gain(freqs)`.

    Built in the frequency domain, so it is exactly periodic over `n` samples --
    which is what makes it directly usable inside seamless loops.
    """
    f = np.maximum(np.fft.rfftfreq(n, 1.0 / SR), 1.0)
    spectrum = (rng.standard_normal(f.size) + 1j * rng.standard_normal(f.size)) * gain(f)
    spectrum[0] = 0.0
    x = np.fft.irfft(spectrum, n)
    return x / (np.sqrt(np.mean(x ** 2)) + 1e-12)


def butter(x: np.ndarray, kind: str, freq, order: int = 2) -> np.ndarray:
    """Causal Butterworth filter ('lowpass' / 'highpass' / 'bandpass') along time."""
    sos = signal.butter(order, freq, btype=kind, fs=SR, output="sos")
    return signal.sosfilt(sos, x, axis=0)


def svf(x: np.ndarray, cutoff, q: float = 0.7, mode: str = "bandpass") -> np.ndarray:
    """State-variable filter (topology-preserving form) with a per-sample cutoff.

    Used for sweeps (whooshes, puffs) where a static IIR would not do.  The
    band-pass output is normalised to unity gain at the centre frequency.
    """
    g = np.tan(np.pi * np.clip(np.broadcast_to(cutoff, x.shape), 20.0, 0.45 * SR) / SR)
    k = 1.0 / q
    a1 = 1.0 / (1.0 + g * (g + k))
    a2 = g * a1
    a3 = g * a2
    band_out = mode == "bandpass"
    ic1 = ic2 = 0.0
    out = []
    for xi, b1, b2, b3 in zip(x.tolist(), a1.tolist(), a2.tolist(), a3.tolist()):
        v3 = xi - ic2
        v1 = b1 * ic1 + b2 * v3
        v2 = ic2 + b2 * ic1 + b3 * v3
        ic1 = 2.0 * v1 - ic1
        ic2 = 2.0 * v2 - ic2
        out.append(k * v1 if band_out else v2)
    return np.array(out)


# --------------------------------------------------------------------------
# Stereo, mixing and reverb
# --------------------------------------------------------------------------

def pan(x: np.ndarray, position) -> np.ndarray:
    """Constant-power pan of a mono signal; position -1 (left) .. 1 (right),
    either a scalar or one value per sample."""
    theta = (np.clip(position, -1.0, 1.0) + 1.0) * np.pi / 4
    return np.stack([x * np.cos(theta), x * np.sin(theta)], axis=-1)


def mix_into(buf: np.ndarray, x: np.ndarray, start: int, wrap: bool = False) -> None:
    """Add `x` into `buf` at sample `start`; overflow is cut off, or wrapped
    around to the beginning when building a loop."""
    idx = start + np.arange(len(x))
    if wrap:
        buf[idx % len(buf)] += x
    else:
        keep = idx < len(buf)
        buf[idx[keep]] += x[keep]


def make_ir(rng: np.random.Generator, seconds: float, t60: float, cutoff: float = 5000.0,
            channels: int = 1, predelay: float = 0.012, onset: float = 0.03) -> np.ndarray:
    """Synthetic room impulse response, shape (n, channels): exponentially
    decaying low-passed noise that fades in over `onset` seconds, one
    independent tail per channel (that decorrelation is what gives stereo
    width), unit energy."""
    t = time_axis(seconds)
    gap = np.zeros(samples(predelay))
    tails = [np.concatenate([gap, butter(rng.standard_normal(t.size), "lowpass", cutoff)
                             * decay(t, t60) * ramp(t, 0.0, onset)])
             for _ in range(channels)]
    ir = np.stack(tails, axis=-1)
    return ir / np.sqrt(np.sum(ir ** 2, axis=0))


def reverb(x: np.ndarray, ir: np.ndarray, wet: float, length: int) -> np.ndarray:
    """(1 - wet) * dry + wet * reverb, trimmed or padded to `length` samples.

    The reverberated signal is scaled to the dry signal's energy first, so
    `wet` means the same thing for every sound -- and for every note: a noise
    IR's gain at a single pitch is random, which would otherwise make some
    bells louder than others.  A mono input through a stereo IR comes out stereo.
    """
    x2 = x[:, None] if x.ndim == 1 else x
    channels = max(x2.shape[1], ir.shape[1])
    x2 = np.broadcast_to(x2, (len(x2), channels))
    ir2 = np.broadcast_to(ir, (len(ir), channels))
    tail = signal.fftconvolve(x2, ir2, axes=0)
    tail *= np.sqrt(np.sum(x2 ** 2) / np.sum(tail ** 2))
    out = np.zeros((max(length, len(tail)), channels))
    out[:len(x2)] += (1.0 - wet) * x2
    out[:len(tail)] += wet * tail
    out = out[:length]
    return out[:, 0] if channels == 1 else out


def circular_reverb(x: np.ndarray, ir: np.ndarray) -> np.ndarray:
    """Reverb (wet only) for loops: circular convolution, so the tail of the end
    of the loop rings on into its beginning."""
    n = len(x)
    return np.fft.irfft(np.fft.rfft(x, axis=0) * np.fft.rfft(ir, n, axis=0), n, axis=0)


# --------------------------------------------------------------------------
# Instruments
# --------------------------------------------------------------------------

# Glass bell / kalimba partials: (frequency ratio, amplitude, decay-time scale).
# Slightly stretched ratios give the bell colour; upper partials die out much
# faster than the fundamental, so the tone settles into a pure, warm sine.
BELL_PARTIALS = (
    (1.000, 1.000, 1.00),
    (2.003, 0.300, 0.45),
    (3.011, 0.110, 0.28),
    (4.170, 0.060, 0.17),
    (5.430, 0.035, 0.11),
)


def bell(freq: float, seconds: float, t60: float = 2.2, brightness: float = 1.0,
         attack: float = 0.004, rng: np.random.Generator | None = None) -> np.ndarray:
    """Additive glass-bell / kalimba tone (mono, dry).

    `t60` is the fundamental's ring time at C5; higher notes ring a little
    shorter, as real tines do.  `brightness` < 1 darkens the upper partials.
    Passing `rng` adds a faint mallet tick to the attack.
    """
    t = time_axis(seconds)
    t60 *= (note("C5") / freq) ** 0.35
    out = np.zeros_like(t)
    for ratio, amp, decay_scale in BELL_PARTIALS:
        f = freq * ratio
        if f > 0.4 * SR:
            continue
        gain = amp * brightness ** (ratio - 1.0) / np.sqrt(1.0 + (f / 5000.0) ** 4)
        out += gain * np.sin(TAU * f * t) * decay(t, t60 * decay_scale)
    # A quieter copy of the fundamental, 1.2 cents sharp: a slow, warm shimmer.
    out += 0.25 * np.sin(TAU * detune(freq, 1.2) * t) * decay(t, t60)
    if rng is not None:
        out += 0.012 * shaped_noise(rng, t.size, band(400, 3000)) * strike(t, 0.001, 0.015)
    return out * ramp(t, 0.0, attack)


def soft_saw_partials(freq: float, cutoff: float = 900.0, rolloff: float = 1.4):
    """(harmonic, amplitude) pairs of a band-limited sawtooth that is already
    heavily low-passed -- the warm raw material of the pads."""
    partials = []
    for h in range(1, int(4000 // freq) + 1):
        amp = h ** -rolloff / np.sqrt(1.0 + (h * freq / cutoff) ** 4)
        if amp > 0.003:
            partials.append((h, amp))
    return partials


def soft_saw(freq: float, t: np.ndarray, rng: np.random.Generator) -> np.ndarray:
    """Warm pad oscillator (random harmonic phases keep the crest factor low)."""
    return sum(amp * np.sin(TAU * h * freq * t + rng.uniform(0, TAU))
               for h, amp in soft_saw_partials(freq))


def periodic_soft_saw(freq: float, n: int, rng: np.random.Generator, where: np.ndarray):
    """Soft saw that completes a whole number of cycles in `n` samples, so it is
    exactly periodic over a loop (the frequency moves by < 1 / loop length Hz,
    i.e. < 0.2 cents for a 64 s loop).  Evaluated only at indices `where`.
    Returns (fundamental, upper harmonics) so a slow "filter" can scale the latter."""
    cycles = max(1, int(round(freq * n / SR)))
    fundamental = np.zeros(where.size)
    upper = np.zeros(where.size)
    for h, amp in soft_saw_partials(freq):
        # Integer phase arithmetic keeps the wrap exact even after millions of samples.
        wave = amp * np.sin(TAU * ((h * cycles * where) % n) / n + rng.uniform(0, TAU))
        if h == 1:
            fundamental += wave
        else:
            upper += wave
    return fundamental, upper


# --------------------------------------------------------------------------
# Sound builders -- each returns float samples, mono (n,) or stereo (n, 2)
# --------------------------------------------------------------------------

@functools.lru_cache(maxsize=None)
def bell_room() -> np.ndarray:
    """One shared room for all ten bells, so the melody sounds like one instrument.
    Pre-delay and a slow onset keep the reverb from piling onto the attack."""
    rng = np.random.default_rng(zlib.crc32(b"bell_room"))
    return make_ir(rng, 1.8, 1.7, cutoff=4500, predelay=0.025, onset=0.12)


def build_bell(note_name: str, rng: np.random.Generator) -> np.ndarray:
    dry = bell(note(note_name), 2.5, t60=2.2, rng=rng)
    return fade(reverb(dry, bell_room(), wet=0.22, length=dry.size), 0.0, 0.35)


def build_step(rng: np.random.Generator) -> np.ndarray:
    t = time_axis(0.075)
    tick = shaped_noise(rng, t.size, band(700, 2600)) * strike(t, 0.0015, 0.035)
    thump = sine_sweep(65.0 + 25.0 * decay(t, 0.05)) * strike(t, 0.002, 0.06)
    return fade(0.55 * tick + 0.45 * thump, 0.0, 0.015)


def build_push(rng: np.random.Generator) -> np.ndarray:
    dur = 0.32
    t = time_axis(dur)
    body = shaped_noise(rng, t.size, band(120, 900, tilt=2.0))       # brown-ish rumble
    grit = shaped_noise(rng, t.size, band(500, 1400, tilt=1.0))      # finer friction
    grains = np.clip(1.0 + 0.35 * shaped_noise(rng, t.size, band(hi=45.0, order=1)), 0.2, None)
    env = ramp(t, 0.0, 0.025) * (1.0 - ramp(t, 0.15, dur))
    return (body + 0.22 * grit * grains) * grains * env


def build_bump(rng: np.random.Generator) -> np.ndarray:
    t = time_axis(0.25)
    phase = TAU * np.cumsum(72.0 + 48.0 * decay(t, 0.12)) / SR      # 120 Hz -> 72 Hz
    # Second/third harmonics keep the thud audible on small speakers.
    body = (np.sin(phase) + 0.35 * np.sin(2 * phase) + 0.12 * np.sin(3 * phase)) \
        * strike(t, 0.003, 0.2)
    click = shaped_noise(rng, t.size, band(200, 1800)) * strike(t, 0.0008, 0.018)
    return fade(body + 0.18 * click, 0.0, 0.03)


def build_target_on(rng: np.random.Generator) -> np.ndarray:
    dur = 2.8
    out = np.zeros((samples(dur), 2))
    # G5 / D6 / G6, gently strummed; each note is a detuned pair spread in stereo.
    for name, position, delay in (("G5", -0.35, 0.0), ("D6", 0.35, 0.025), ("G6", 0.0, 0.05)):
        for cents, spread in ((-5.0, -0.3), (5.0, 0.3)):
            tone = bell(detune(note(name), cents), dur - delay, t60=2.8, rng=rng)
            mix_into(out, 0.5 * pan(tone, position + spread), samples(delay))
    # Sparkle: a few tiny, quick high pings scattered over the first ~0.6 s.
    for _ in range(7):
        ping = bell(note(rng.choice(["G6", "A6", "C7", "D7", "E7", "G7"])), 0.6,
                    t60=0.5, brightness=0.5)
        mix_into(out, 0.1 * rng.uniform(0.5, 1.0) * pan(ping, rng.uniform(-0.8, 0.8)),
                 samples(rng.uniform(0.04, 0.6)))
    out = reverb(out, make_ir(rng, 2.4, 2.2, cutoff=6000, channels=2), wet=0.3, length=len(out))
    return fade(out, 0.0, 0.5)


def build_target_off(rng: np.random.Generator) -> np.ndarray:
    dur = 1.2
    out = np.zeros(samples(dur))
    for name, start, amp in (("A5", 0.0, 1.0), ("E5", 0.17, 0.85)):
        tone = bell(note(name), dur - start, t60=0.9, brightness=0.35, attack=0.008)
        mix_into(out, amp * tone, samples(start))
    out = butter(out, "lowpass", 2500)                                 # muted
    out = reverb(out, make_ir(rng, 1.0, 0.9, cutoff=3500), wet=0.2, length=len(out))
    return fade(out, 0.0, 0.25)


def build_undo(rng: np.random.Generator) -> np.ndarray:
    # A short forward whoosh (falling band-pass + reverb tail) played backwards:
    # it swells and rises, then stops softly where the original attack was.
    t = time_axis(0.3)
    burst = shaped_noise(rng, t.size, band(300, 6000, tilt=1.0)) * strike(t, 0.012, 0.18)
    cutoff = 700.0 * (2600.0 / 700.0) ** (1.0 - ramp(t, 0.0, 0.18))
    whoosh = svf(burst, cutoff, q=1.2)
    whoosh = reverb(whoosh, make_ir(rng, 0.25, 0.22), wet=0.35, length=t.size)
    return fade(whoosh[::-1], 0.03, 0.006)


def build_win(rng: np.random.Generator) -> np.ndarray:
    dur = 4.5
    t = time_axis(dur)
    out = np.zeros((t.size, 2))
    # Ascending pentatonic arpeggio over ~1.6 s, travelling left to right.
    arpeggio = ("C5", "E5", "G5", "A5", "C6", "D6", "E6", "G6")
    for i, name in enumerate(arpeggio):
        start = 0.2 * i + rng.uniform(-0.008, 0.008) * (i > 0)
        tone = bell(note(name), dur - start, t60=2.4, rng=rng)
        position = -0.6 + 1.2 * i / (len(arpeggio) - 1)
        mix_into(out, (0.55 + 0.05 * i) * pan(tone, position), samples(start))
    # Resolving C(add9) chord that rings to the end.
    chord_at = 1.75
    for name, position in (("C4", 0.0), ("G5", -0.4), ("C6", 0.4), ("D6", -0.2), ("E6", 0.2)):
        tone = bell(note(name), dur - chord_at, t60=3.5, brightness=0.8)
        mix_into(out, 0.45 * pan(tone, position), samples(chord_at))
    # Warm pad swelling underneath: detuned soft saws, peaking with the chord.
    swell = ramp(t, 0.0, 2.0) * (1.0 - ramp(t, 2.6, dur))
    for name in ("C3", "G3", "E4", "D5"):
        for cents, position in ((-6.0, -0.5), (6.0, 0.5)):
            out += 0.12 * pan(soft_saw(detune(note(name), cents), t, rng) * swell, position)
    out = reverb(out, make_ir(rng, 2.8, 2.6, cutoff=6000, channels=2), wet=0.3, length=t.size)
    return fade(out, 0.0, 0.8)


def build_intro(rng: np.random.Generator) -> np.ndarray:
    dur = 2.5
    t = time_axis(dur)
    # Airy rising whoosh (band-pass sweeping up 250 Hz -> 2.4 kHz) ...
    air = shaped_noise(rng, t.size, band(150, 7000, tilt=1.0))
    sweep = 250.0 * (2400.0 / 250.0) ** ramp(t, 0.0, 1.25)
    whoosh = svf(air, sweep, q=1.4) * ramp(t, 0.0, 1.0) ** 1.5 * (1.0 - ramp(t, 0.95, 1.7))
    # ... that blends into a single low bell.
    low_bell = np.zeros(t.size)
    mix_into(low_bell, bell(note("C4"), dur - 0.95, t60=3.0, rng=rng), samples(0.95))
    out = reverb(0.5 * whoosh + low_bell, make_ir(rng, 2.2, 2.0), wet=0.3, length=t.size)
    return fade(out, 0.0, 0.5)


def build_ui_hover(rng: np.random.Generator) -> np.ndarray:
    t = time_axis(0.04)
    return modal(t, [(2350, 1.0, 0.03), (3610, 0.25, 0.015)]) * ramp(t, 0.0, 0.0015)


def build_ui_click(rng: np.random.Generator) -> np.ndarray:
    t = time_axis(0.09)
    body = modal(t, [(540, 0.6, 0.06), (1230, 1.0, 0.045), (2870, 0.3, 0.02)])
    tick = shaped_noise(rng, t.size, band(1500, 5000)) * strike(t, 0.0005, 0.006)
    return fade((body + 0.15 * tick) * ramp(t, 0.0, 0.0008), 0.0, 0.02)


def build_editor_place(rng: np.random.Generator) -> np.ndarray:
    # Wooden "tok": a resonant body around 310 Hz plus two higher wood modes.
    t = time_axis(0.12)
    body = modal(t, [(310, 1.0, 0.10), (800, 0.4, 0.05), (1730, 0.12, 0.025)])
    tick = shaped_noise(rng, t.size, band(1000, 3000)) * strike(t, 0.0005, 0.008)
    return fade((body + 0.12 * tick) * ramp(t, 0.0, 0.001), 0.0, 0.025)


def build_editor_erase(rng: np.random.Generator) -> np.ndarray:
    # Soft "puff": pink noise through a low-pass sweeping down 5 kHz -> 350 Hz.
    t = time_axis(0.15)
    noise = shaped_noise(rng, t.size, band(100, 8000, tilt=1.0))
    cutoff = 350.0 * (5000.0 / 350.0) ** (1.0 - ramp(t, 0.0, 0.12))
    return fade(svf(noise, cutoff, q=0.6, mode="lowpass") * strike(t, 0.006, 0.16), 0.0, 0.03)


# Ambient pad: four voice-led chords, 16 s each; common tones simply keep sounding.
PAD_PROGRESSION = (
    ("Cmaj9", ("C3", "G3", "D4", "E4", "B4")),
    ("Am9", ("A2", "G3", "C4", "E4", "B4")),
    ("Fmaj7(#11)", ("F2", "A3", "C4", "E4", "B4")),
    ("G6sus", ("G2", "A3", "C4", "E4", "D5")),
)
PENTATONIC = ("C", "D", "E", "G", "A")


def build_ambient_pad(rng: np.random.Generator) -> np.ndarray:
    n = loop_samples(64.0)
    loop_len = n / SR
    t = np.arange(n) / SR
    slot = loop_len / len(PAD_PROGRESSION)
    xfade = 6.0

    # Chord envelopes: raised-cosine crossfades centred on the slot boundaries,
    # computed modulo the loop length, so G6sus -> Cmaj9 across the loop point
    # is an ordinary crossfade.  A note shared by consecutive chords gets
    # envelopes that sum to 1, i.e. it is simply held.
    note_env: dict[str, np.ndarray] = {}
    for i, (_, chord) in enumerate(PAD_PROGRESSION):
        u = (t - i * slot + xfade / 2) % loop_len
        env = ramp(u, 0.0, xfade) * (1.0 - ramp(u, slot, slot + xfade))
        for name in chord:
            note_env[name] = note_env.get(name, 0.0) + env

    # Voices: the bass note of each chord is a single soft oscillator in the
    # centre; every upper note is a +/-3 cent pair spread left/right (each side
    # mostly hears one copy, so the pair widens the image instead of pulsing).
    # Two slow "filter" sweeps per loop and a gentle per-note stereo drift;
    # every LFO completes a whole number of cycles over the loop.
    bass_notes = {chord[0] for _, chord in PAD_PROGRESSION}
    brightness = 0.7 + 0.3 * np.cos(TAU * 2 * t / loop_len)
    pad = np.zeros((n, 2))
    for name, env in note_env.items():
        active = np.flatnonzero(env > 1e-6)
        freq = note(name)
        if name in bass_notes:
            level, copies = 0.55, ((0.0, 0.0),)
        else:
            level, copies = (freq / note("C4")) ** -0.25, ((-3.0, -0.75), (3.0, 0.75))
        drift = 0.2 * np.sin(TAU * rng.integers(1, 3) * t[active] / loop_len + rng.uniform(0, TAU))
        for cents, position in copies:
            fundamental, upper = periodic_soft_saw(detune(freq, cents), n, rng, active)
            voice = env[active] * level * (fundamental + brightness[active] * upper)
            pad[active] += pan(voice, position + drift)

    # Sparse bells, one every 6-10 s, drawn from pentatonic notes of the current chord.
    bells = np.zeros((n, 2))
    count = 8
    previous = None
    for i in range(count):
        start = (i + 0.5) * loop_len / count + rng.uniform(-1.0, 1.0)
        chord = PAD_PROGRESSION[int(start // slot) % len(PAD_PROGRESSION)][1]
        pitch_classes = {name[:-1] for name in chord}
        choices = [f"{pc}{octave}" for octave in (5, 6) for pc in PENTATONIC
                   if pc in pitch_classes and f"{pc}{octave}" not in ("G6", "A6", previous)]
        previous = str(rng.choice(choices))
        tone = bell(note(previous), 6.0, t60=3.2, brightness=0.75, attack=0.006)
        mix_into(bells, rng.uniform(0.6, 1.0) * pan(tone, rng.uniform(-0.6, 0.6)),
                 samples(start), wrap=True)

    pad /= np.sqrt(np.mean(pad ** 2))
    bells *= 1.6
    ir = make_ir(rng, 5.0, 4.0, cutoff=4500, channels=2, predelay=0.02)
    return 0.8 * pad + 0.6 * bells + 0.45 * circular_reverb(0.5 * pad + bells, ir)


# --------------------------------------------------------------------------
# The sound table
# --------------------------------------------------------------------------

@dataclass(frozen=True)
class Sound:
    name: str
    build: Callable[[np.random.Generator], np.ndarray]
    description: str
    # Intended in-game loudness: A-weighted RMS of the loudest 300 ms, in dBFS.
    # The report turns this into a suggested AudioStreamPlayer.volume_db.
    target_db: float
    loop: bool = False
    codec: str = "wav"           # "wav" (16-bit PCM) or "ogg" (Vorbis)
    rate: int = SR               # output sample rate (synthesis always runs at SR)


SOUNDS: list[Sound] = [
    *(Sound(f"bell_{i:02d}", functools.partial(build_bell, name),
            f"glass/kalimba bell {name}, one per box push", -20.0)
      for i, name in enumerate(BELL_NOTES)),
    Sound("step", build_step, "very soft footstep tick on stone", -35.0),
    Sound("push", build_push, "heavy stone block sliding on stone", -29.0),
    Sound("bump", build_bump, "soft low thud when a move is blocked", -37.0),
    Sound("target_on", build_target_on, "box locks onto a target: shimmering G chord", -19.0),
    Sound("target_off", build_target_off, "box leaves a target: muted A5 -> E5", -22.0),
    Sound("undo", build_undo, "gentle reverse swoosh", -30.0),
    Sound("win", build_win, "level complete: arpeggio over a pad swell", -17.0),
    Sound("intro", build_intro, "level build-in: rising air into a low bell", -22.0),
    Sound("ui_hover", build_ui_hover, "tiny high tick on button hover", -35.0),
    Sound("ui_click", build_ui_click, "soft wood/glass click", -31.0),
    Sound("editor_place", build_editor_place, "editor: wooden 'tok' when placing", -30.0),
    Sound("editor_erase", build_editor_erase, "editor: soft 'puff' when erasing", -29.0),
    Sound("ambient_pad", build_ambient_pad,
          "64 s ambient bed: Cmaj9 - Am9 - Fmaj7(#11) - G6sus pad + sparse bells", -31.0,
          loop=True, rate=22_050),
]


# --------------------------------------------------------------------------
# Mastering and file output
# --------------------------------------------------------------------------

def normalize(x: np.ndarray, peak_db: float) -> np.ndarray:
    return x * (10.0 ** (peak_db / 20) / np.max(np.abs(x)))


def finish_sfx(x: np.ndarray) -> np.ndarray:
    x = butter(x, "highpass", 20.0)     # remove DC and sub-sonic drift
    x = fade(x, 0.002, 0.005)           # guarantee click-free ends
    # A short file keeps a tiny mean after the high-pass; take it out with a
    # Hann-shaped correction so the ends stay exactly at zero.
    hann = np.hanning(len(x))
    hann = hann[:, None] if x.ndim == 2 else hann
    x = x - x.mean(axis=0) * hann / hann.mean()
    return normalize(x, SFX_PEAK_DB)


def finish_loop(x: np.ndarray, rate: int) -> np.ndarray:
    # No fades and no causal filtering here: either would break the seam.
    x = x - x.mean(axis=0)
    if rate != SR:
        # FFT resampling treats the signal as periodic, so the loop stays seamless.
        x = signal.resample(x, len(x) * rate // SR, axis=0)
    return normalize(x, LOOP_PEAK_DB)


def write_wav(path: Path, x: np.ndarray, rate: int = SR, loop: bool = False) -> None:
    """16-bit PCM WAV.

    With `loop`, a RIFF 'smpl' chunk marks frames [0, len(x)) as one forward
    loop -- Godot's WAV importer picks it up ("Detect From WAV") and uses the
    stored end as an exclusive bound.  A few frames of post-roll (a copy of the
    loop's start) follow, so interpolation that reads past the loop end still
    sees the true continuation.  A reader that takes the end as inclusive, as
    the RIFF spec says, merely repeats one sample.
    """
    frames = len(x)
    if loop:
        x = np.concatenate([x, x[:LOOP_POSTROLL]])
    pcm = np.clip(np.round(x * 32767), -32768, 32767).astype("<i2")
    channels = 1 if pcm.ndim == 1 else pcm.shape[1]
    fmt = struct.pack("<HHIIHH", 1, channels, rate, rate * 2 * channels, 2 * channels, 16)
    chunks = [(b"fmt ", fmt)]
    if loop:
        # 9 header fields (sample period in ns, MIDI unity note 60, one loop),
        # then the loop: id, type 0 = forward, start, end, fraction, play count 0 = forever.
        smpl = struct.pack("<9I", 0, 0, 1_000_000_000 // rate, 60, 0, 0, 0, 1, 0)
        smpl += struct.pack("<6I", 0, 0, 0, frames, 0, 0)
        chunks.append((b"smpl", smpl))
    chunks.append((b"data", pcm.tobytes()))
    body = b"WAVE" + b"".join(cid + struct.pack("<I", len(data)) + data for cid, data in chunks)
    path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)


def write_ogg(path: Path, x: np.ndarray, rate: int = SR) -> None:
    """Encode float samples to Ogg Vorbis through ffmpeg (bit-exact, no metadata)."""
    channels = 1 if x.ndim == 1 else x.shape[1]
    cmd = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
           "-f", "f32le", "-ar", str(rate), "-ac", str(channels), "-i", "pipe:0",
           "-c:a", "vorbis", "-strict", "-2", "-q:a", str(OGG_QUALITY),
           "-fflags", "+bitexact", "-flags:a", "+bitexact", "-map_metadata", "-1",
           str(path)]
    subprocess.run(cmd, input=x.astype("<f4").tobytes(), check=True)


def write_sound(sound: Sound, x: np.ndarray) -> Path:
    path = OUT_DIR / f"{sound.name}.{sound.codec}"
    if sound.codec == "ogg":
        try:
            write_ogg(path, x, sound.rate)
        except (OSError, subprocess.CalledProcessError) as err:
            print(f"warning: Vorbis encoding failed ({err}); writing {sound.name}.wav instead",
                  file=sys.stderr)
            path = path.with_suffix(".wav")
    if path.suffix == ".wav":
        write_wav(path, x, sound.rate, loop=sound.loop)
    # Remove an output left over from a different format (but never Godot's .import files).
    for stale in (path.with_suffix(".wav"), path.with_suffix(".ogg")):
        if stale != path and stale.exists():
            stale.unlink()
    return path


# --------------------------------------------------------------------------
# Verification
# --------------------------------------------------------------------------

def read_audio(path: Path) -> tuple[int, np.ndarray]:
    """Read a written file back as float (n, channels).  Ogg files are decoded
    to 32-bit float by ffmpeg, so codec overshoot above 0 dBFS stays visible."""
    if path.suffix == ".wav":
        with warnings.catch_warnings():          # scipy skips the 'smpl' chunk with a warning
            warnings.simplefilter("ignore", wavfile.WavFileWarning)
            sr, data = wavfile.read(path)
        data = data.astype(np.float64) / 32768.0
    else:
        header = path.read_bytes()[:256]
        i = header.index(b"\x01vorbis")
        channels, sr = header[i + 11], int.from_bytes(header[i + 12:i + 16], "little")
        raw = subprocess.run([FFMPEG, "-hide_banner", "-loglevel", "error", "-i", str(path),
                              "-f", "f32le", "-ac", str(channels), "pipe:1"],
                             capture_output=True, check=True).stdout
        data = np.frombuffer(raw, dtype="<f4").astype(np.float64).reshape(-1, channels)
    return sr, data if data.ndim == 2 else data[:, None]


def wav_loop_end(path: Path) -> int:
    """Loop end stored in a WAV file's 'smpl' chunk."""
    data = path.read_bytes()
    i = data.index(b"smpl") + 8                   # skip chunk id and size
    return struct.unpack_from("<I", data, i + 36 + 12)[0]


def db(x: float) -> float:
    return 20.0 * np.log10(max(x, 1e-12))


def a_weighted_loudness(x: np.ndarray, sr: int, window: float = 0.3) -> float:
    """A-weighted RMS (dBFS) of the loudest `window` seconds, channels averaged."""
    f = np.fft.rfftfreq(len(x), 1.0 / sr)
    f2 = f ** 2
    weight = (12194.0 ** 2 * f2 ** 2) / ((f2 + 20.6 ** 2) * (f2 + 12194.0 ** 2)
                                         * np.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2)))
    weight *= 10.0 ** (2.0 / 20)                                       # 0 dB at 1 kHz
    weighted = np.fft.irfft(np.fft.rfft(x, axis=0) * weight[:, None], len(x), axis=0)
    power = np.mean(weighted ** 2, axis=1)
    w = min(int(window * sr), len(power))
    sliding = np.convolve(power, np.ones(w) / w, mode="valid")
    return 10.0 * np.log10(max(sliding.max(), 1e-24))


def dominant_frequency(x: np.ndarray, sr: int, start: float = 0.0,
                       end: float | None = None) -> float:
    """Strongest spectral peak (Hz) of the mono mix, with parabolic interpolation."""
    mono = x.mean(axis=1)[int(start * sr):int(end * sr) if end else None]
    nfft = 1 << max(18, int(np.ceil(np.log2(len(mono)))))               # zero-padded
    spectrum = np.abs(np.fft.rfft(mono * np.hanning(len(mono)), nfft))
    spectrum[:int(20.0 * nfft / sr) + 1] = 0.0                          # ignore < 20 Hz
    k = int(np.argmax(spectrum))
    a, b, c = np.log(spectrum[k - 1:k + 2] + 1e-20)
    return (k + 0.5 * (a - c) / (a - 2 * b + c)) * sr / nfft


def seam_report(x: np.ndarray, sr: int) -> dict[str, float]:
    """How audible is the wrap from the last sample back to the first?"""
    steps = np.abs(np.diff(x, axis=0)).max(axis=1)
    jump = np.abs(x[0] - x[-1]).max()
    w = int(0.05 * sr)
    rms_step = db(np.sqrt(np.mean(x[:w] ** 2))) - db(np.sqrt(np.mean(x[-w:] ** 2)))
    # A click shows up as a burst above 8 kHz in the 10 ms around the junction.
    rolled = np.roll(x, len(x) // 2, axis=0)            # junction now in the middle
    hf = signal.sosfiltfilt(signal.butter(4, 8000, "highpass", fs=sr, output="sos"),
                            rolled, axis=0)
    win = int(0.01 * sr)
    frames = np.mean(hf[:len(hf) // win * win].reshape(-1, win, hf.shape[1]) ** 2, axis=(1, 2))
    mid = len(x) // 2
    junction = np.mean(hf[mid - win // 2:mid + win // 2] ** 2)
    return {"jump": jump,
            "jump_pct": 100.0 * np.mean(steps < jump),      # rank among all sample steps
            "p999_step": np.percentile(steps, 99.9),
            "rms_step_db": rms_step,
            "hf_vs_median_db": 10.0 * np.log10(junction / np.median(frames)),
            "hf_vs_rms_db": 10.0 * np.log10(junction / np.mean(x ** 2))}


def third_octave_deviation(reference: np.ndarray, decoded: np.ndarray, sr: int) -> float:
    """Largest 1/3-octave level difference (dB, 50 Hz-16 kHz, bands within
    40 dB of the loudest) between the pre-encode signal and the decoded Ogg --
    a sanity check that the codec kept the spectrum intact.  Bands further down
    hold only codec noise floor, which says nothing about quality."""
    f, p_ref = signal.welch(reference.mean(axis=1), sr, nperseg=8192)
    _, p_dec = signal.welch(decoded.mean(axis=1), sr, nperseg=8192)
    centres = 1000.0 * 2.0 ** (np.arange(-14, 13) / 3)
    levels = []
    for fc in centres:
        sel = (f >= fc * 2 ** (-1 / 6)) & (f < fc * 2 ** (1 / 6))
        levels.append((10 * np.log10(p_ref[sel].sum() + 1e-30), 10 * np.log10(p_dec[sel].sum() + 1e-30)))
    loudest = max(ref for ref, _ in levels)
    return max(abs(dec - ref) for ref, dec in levels if ref > loudest - 40.0)


def verify(results: list[tuple[Sound, Path, np.ndarray]]) -> bool:
    ok = True
    print("\nfile                   dur(s)     sr ch  peak dBFS  RMS dBFS  loud dBA"
          "  size KB  dominant Hz  suggested volume_db")
    total = 0
    played = {}                                   # what the engine will actually play
    for sound, path, source in results:
        sr, x = read_audio(path)
        problems = []
        if sound.loop and path.suffix == ".wav":
            end = wav_loop_end(path)
            if not np.array_equal(x[end:], x[:len(x) - end]):
                problems.append("post-roll does not repeat the loop start")
            x = x[:end]
        played[sound.name] = (sr, x)
        size = path.stat().st_size
        total += size
        loud = a_weighted_loudness(x, sr)
        print(f"{path.name:<22} {len(x) / sr:6.3f} {sr:6d} {x.shape[1]:2d} {db(np.abs(x).max()):10.2f}"
              f" {db(np.sqrt(np.mean(x ** 2))):9.2f} {loud:9.2f} {size / 1024:8.1f}"
              f" {dominant_frequency(x, sr):12.1f} {round(2 * (sound.target_db - loud)) / 2:+20.1f}")
        if not np.all(np.isfinite(x)):
            problems.append("non-finite samples")
        if np.abs(x).max() >= 0.999:
            problems.append("clipping")
        if not sound.loop and (np.abs(x[0]).max() > 1e-3 or np.abs(x[-1]).max() > 1e-3):
            problems.append("ends are not silent")
        if np.abs(x.mean(axis=0)).max() > 2e-3:
            problems.append("DC offset")
        if sound.loop and len(x) != len(source):
            problems.append(f"loop length {len(x)} != {len(source)}")
        for problem in problems:
            print(f"  !! {path.name}: {problem}")
        ok &= not problems
    print(f"total size of the files above: {total / 1024 / 1024:.2f} MiB ({total / 1e6:.2f} MB)")

    bells = [s for s, _, _ in results if s.name.startswith("bell_")]
    if bells:
        print("\nbell pitch check (dominant frequency, 0.05-1.05 s):")
        for sound in bells:
            name = BELL_NOTES[int(sound.name[-2:])]
            found = dominant_frequency(played[sound.name][1], SR, 0.05, 1.05)
            error = 100.0 * (found / note(name) - 1.0)
            ok &= abs(error) < 1.0
            print(f"  {sound.name}  {name:<3} target {note(name):8.2f} Hz"
                  f"  found {found:8.2f} Hz  error {error:+.3f}%")

    loops = [(s, p, src) for s, p, src in results if s.loop]
    if loops:
        print("\nloop seam check (wrap from last sample to first):")
        for sound, path, source in loops:
            sr, x = played[sound.name]
            if path.suffix == ".ogg":
                checks = (("source", source), ("decoded", x))
            else:
                full = read_audio(path)[1]
                checks = (("Godot", x), ("RIFF spec", full[:len(x) + 1]))   # end exclusive / inclusive
            for label, y in checks:
                r = seam_report(y, sr)
                print(f"  {path.name:<16} {label:<9}  |x[0]-x[-1]| {r['jump']:.4f}"
                      f" ({r['jump_pct']:.2f}th pct of all steps; 99.9th pct = {r['p999_step']:.4f})"
                      f"  50 ms RMS step {r['rms_step_db']:+.2f} dB"
                      f"  >8 kHz at junction: {r['hf_vs_median_db']:+.1f} dB vs median,"
                      f" {r['hf_vs_rms_db']:+.1f} dB vs loop RMS")
                ok &= (r["jump"] <= 1.5 * r["p999_step"] and abs(r["rms_step_db"]) < 1.5
                       and (r["hf_vs_median_db"] < 6.0 or r["hf_vs_rms_db"] < -50.0))
            if path.suffix == ".ogg":
                print(f"  {path.name:<16} codec 1/3-octave deviation (50 Hz-16 kHz):"
                      f" {third_octave_deviation(source, x, sr):.2f} dB")
    print("\nall checks passed" if ok else "\nSOME CHECKS FAILED")
    return ok


# --------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--only", nargs="+", metavar="NAME",
                        help="regenerate only these sounds (e.g. bell_03 push)")
    args = parser.parse_args(argv)

    selected = [s for s in SOUNDS if not args.only or s.name in args.only]
    unknown = set(args.only or ()) - {s.name for s in SOUNDS}
    if unknown:
        parser.error(f"unknown sound(s): {', '.join(sorted(unknown))}")

    OUT_DIR.mkdir(exist_ok=True)
    results = []
    for sound in selected:
        rng = np.random.default_rng(zlib.crc32(sound.name.encode()))
        x = sound.build(rng)
        x = finish_loop(x, sound.rate) if sound.loop else finish_sfx(x)
        path = write_sound(sound, x)
        print(f"wrote {path.relative_to(OUT_DIR.parent)}  -- {sound.description}")
        results.append((sound, path, x if x.ndim == 2 else x[:, None]))
    return 0 if verify(results) else 1


if __name__ == "__main__":
    sys.exit(main())
