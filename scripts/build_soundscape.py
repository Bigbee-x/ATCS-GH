#!/usr/bin/env python3
"""Synthesise the visualizer's few sounds to WAV files.

Everything is generated here (no recordings, no samples from anywhere): horn
taps as paired reed tones with a slap echo, night crickets and daytime birds.
There are deliberately no engine or traffic-roar loops: synthesised ones were
heard as a constant fake drone and were removed. The two loops are built with
circular (FFT-domain) filtering, so their ends meet without a click.

    .venv/bin/python3 scripts/build_soundscape.py          # write the files
    .venv/bin/python3 scripts/build_soundscape.py --report # also print levels

Output: visualizer/assets/audio/*.wav (16-bit, 32 kHz). TrafficAudio.gd reads
them directly at startup; a sound whose file is missing stays silent and is
named in the console.
"""
import argparse
import os
import wave

import numpy as np

SR = 32000
OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                   "visualizer", "assets", "audio")


def rng(seed):
    return np.random.default_rng(seed)


def band(f, lo, hi, order=2):
    """Smooth band-pass magnitude between lo and hi Hz."""
    f = np.maximum(f, 1e-3)
    return 1.0 / np.sqrt(1.0 + (lo / f) ** (2 * order)) / np.sqrt(1.0 + (f / hi) ** (2 * order))


def spectral(x, gain_fn):
    """Zero-phase, loop-safe filter: scale the spectrum by gain_fn(frequency)."""
    n = len(x)
    return np.fft.irfft(np.fft.rfft(x) * gain_fn(np.fft.rfftfreq(n, 1.0 / SR)), n)


def noise(n, gain_fn, seed):
    y = spectral(rng(seed).standard_normal(n), gain_fn)
    return y / np.std(y)


def circ(x, impulse):
    """Circular convolution: the tail of the response wraps into the loop start."""
    n = len(x)
    h = np.zeros(n)
    m = min(n, len(impulse))
    h[:m] = impulse[:m]
    return np.fft.irfft(np.fft.rfft(x) * np.fft.rfft(h), n)


def smear(n, decay, seed):
    """Short diffuse impulse response: open-air scatter, not a room."""
    m = int(SR * decay * 5)
    t = np.arange(m) / SR
    ir = rng(seed).standard_normal(m) * np.exp(-t / decay)
    ir[0] = 0.0
    return ir / np.sqrt(np.sum(ir ** 2))


# ── Horns ────────────────────────────────────────────────────────────────────

def horn_note(dur, f_low, f_high, bright, seed):
    """Two reed tones a third apart with a trumpet formant and a pitch scoop."""
    n = int(SR * dur)
    t = np.arange(n) / SR
    r = rng(seed)
    scoop = 1.0 - 0.035 * np.exp(-t / 0.018)
    out = np.zeros(n)
    for f0, gain in ((f_low, 1.0), (f_high, 0.85)):
        phase = 2 * np.pi * np.cumsum(f0 * scoop * (1 + 0.002 * np.sin(2 * np.pi * 5.5 * t))) / SR
        k = 1
        while k * f0 < 6000:
            fk = k * f0
            formant = 1 + bright * np.exp(-((fk - 2600) / 900) ** 2) + 0.6 * np.exp(-((fk - 1200) / 500) ** 2)
            out += gain * formant / k ** 1.05 * np.sin(k * phase + r.uniform(0, 2 * np.pi))
            k += 1
    env = np.clip(np.minimum(t / 0.008, (dur - t) / 0.05), 0, 1)
    return out * env


def horn(pattern, f_low, f_high, bright, seed):
    """`pattern` is alternating on/off seconds. A slap echo sets it outdoors."""
    parts = []
    for i, seconds in enumerate(pattern):
        if i % 2 == 0:
            parts.append(horn_note(seconds, f_low, f_high, bright, seed + i))
        else:
            parts.append(np.zeros(int(SR * seconds)))
    dry = np.concatenate(parts + [np.zeros(int(SR * 0.55))])
    far = spectral(dry, lambda f: 1.0 / np.sqrt(1 + (f / 1500.0) ** 2))
    out = dry.copy()
    for delay, gain in ((0.11, 0.2), (0.24, 0.09), (0.39, 0.04)):
        d = int(SR * delay)
        out[d:] += gain * far[:-d]
    return out


def horns():
    return {
        "horn_car_tap": horn([0.15], 410, 505, 1.2, 201),
        "horn_car_double": horn([0.11, 0.08, 0.19], 410, 505, 1.2, 202),
        "horn_taxi_pips": horn([0.08, 0.07, 0.08, 0.07, 0.12], 470, 590, 1.4, 204),
        "horn_trotro_double": horn([0.14, 0.09, 0.3], 325, 410, 0.8, 205),
    }


# ── Beds and ambience ────────────────────────────────────────────────────────

def crickets(dur=8.0, seed=31):
    """Field crickets: three-pulse chirps from several insects, each its own pitch."""
    n = int(SR * dur)
    t = np.arange(n) / SR
    r = rng(seed)
    out = np.zeros(n)
    for _ in range(7):
        carrier = round(r.uniform(3900, 5300) * dur) / dur
        period = dur / round(dur / r.uniform(0.42, 0.75))
        tt = (t - r.uniform(0, period)) % period
        env = np.zeros(n)
        for pulse in range(3):
            env += np.exp(-((tt - (0.02 + pulse * 0.034)) / 0.008) ** 2)
        out += r.uniform(0.25, 1.0) * env * np.sin(2 * np.pi * carrier * t)
    return out + 0.04 * noise(n, lambda f: band(f, 2500, 9000, 1), seed + 1)


def birds(dur=16.0, seed=53):
    """Sparse daytime phrases: short whistled sweeps, a few birds at a distance."""
    n = int(SR * dur)
    r = rng(seed)
    out = np.zeros(n)
    for _ in range(12):
        start = r.uniform(0, dur)
        base = r.uniform(2300, 4800)
        level = r.uniform(0.2, 1.0)
        for _note in range(int(r.integers(2, 6))):
            length = r.uniform(0.05, 0.13)
            m = int(length * SR)
            tt = np.arange(m) / m
            fa = base * r.uniform(0.85, 1.25)
            fb = fa * r.uniform(0.8, 1.3)
            phase = 2 * np.pi * np.cumsum(fa + (fb - fa) * tt ** r.uniform(0.6, 1.6)) / SR
            note = (np.sin(phase) + 0.25 * np.sin(2 * phase)) * np.hanning(m) * level
            out[(int(start * SR) + np.arange(m)) % n] += note
            start += length + r.uniform(0.02, 0.09)
    out = out + 0.5 * circ(out, smear(n, 0.09, seed + 1))
    return spectral(out, lambda f: band(f, 1500, 8000, 1))


# ── Output ───────────────────────────────────────────────────────────────────

def write(name, data, peak_db):
    data = np.asarray(data, dtype=np.float64)
    data = data - np.mean(data, axis=0)
    data = data / np.max(np.abs(data)) * 10 ** (peak_db / 20.0)
    pcm = np.round(data * 32767.0).astype("<i2")
    path = os.path.join(OUT, name + ".wav")
    with wave.open(path, "wb") as f:
        f.setnchannels(1 if data.ndim == 1 else data.shape[1])
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())
    return data


def report(name, data, loop):
    mono = data if data.ndim == 1 else data.mean(axis=1)
    rms = np.sqrt(np.mean(mono ** 2))
    spec = np.abs(np.fft.rfft(mono)) ** 2
    freqs = np.fft.rfftfreq(len(mono), 1.0 / SR)
    centroid = np.sum(freqs * spec) / np.sum(spec)
    seam = ""
    if loop:
        # A clean loop joins with a step no bigger than the largest step inside it.
        step = abs(mono[0] - mono[-1])
        largest = np.max(np.abs(np.diff(mono)))
        seam = "seam %.4f vs largest inner step %.4f %s" % (step, largest, "ok" if step <= largest else "CLICK")
    print("%-20s %5.2fs peak %6.1f dBFS rms %6.1f dBFS centroid %5.0f Hz %s" % (
        name, len(mono) / SR, 20 * np.log10(np.max(np.abs(data))), 20 * np.log10(rms), centroid, seam))


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--report", action="store_true", help="print level, spectrum and loop-seam figures")
    args = parser.parse_args()
    os.makedirs(OUT, exist_ok=True)
    loops = {"night_crickets": crickets(), "day_birds": birds()}
    shots = horns()
    for name, data in loops.items():
        out = write(name, data, -3.0)
        if args.report:
            report(name, out, True)
    for name, data in shots.items():
        out = write(name, data, -2.0)
        if args.report:
            report(name, out, False)
    print("Wrote %d files to %s" % (len(loops) + len(shots), OUT))


if __name__ == "__main__":
    main()
