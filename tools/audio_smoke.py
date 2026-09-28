#!/usr/bin/env python3
"""Sound from a program reaches the sound card (W11 audio path).

Build: zig build -Ddesktop-profile; ORANGE_AUDIO_PROBE=1 scripts/mkdisk.sh

Boots with an Intel HDA card whose output QEMU records to a WAV file, while
audio-probe writes to /dev/audio: 1 s of 660 Hz, a half-second gap in which
it writes nothing, 1 s of 880 Hz. The recording must hold both tones at the
right pitch, silence in the gap (the driver silences what it has played, so
running dry never replays old samples) and silence after the end.
"""
import math
import os
import pathlib
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from desktop_smoke import Guest  # noqa: E402

WINDOW_MS = 10


def windows(path):
    """(rms, zero-crossing frequency) per 10 ms of the left channel."""
    # QEMU leaves the RIFF sizes at 0 when it quits, so read the format
    # from the header and take every byte after it as samples.
    raw = path.read_bytes()
    assert raw[:4] == b"RIFF" and raw[8:12] == b"WAVE" and raw[36:40] == b"data", "a WAV recording"
    channels, rate = struct.unpack_from("<HI", raw, 22)
    width = struct.unpack_from("<H", raw, 34)[0] // 8
    assert width == 2, f"16-bit recording expected, got {width * 8}-bit"
    frames = raw[44:len(raw) - (len(raw) - 44) % (2 * channels)]
    samples = struct.unpack(f"<{len(frames) // 2}h", frames)[::channels]
    step = rate * WINDOW_MS // 1000
    out = []
    for i in range(0, len(samples) - step, step):
        chunk = samples[i:i + step]
        rms = math.sqrt(sum(s * s for s in chunk) / len(chunk))
        crossings = sum(1 for a, b in zip(chunk, chunk[1:]) if (a < 0) != (b < 0))
        out.append((rms, crossings / 2 / (WINDOW_MS / 1000)))
    return out


def runs(stats, loud=1000):
    """Contiguous runs of loud or quiet windows: (loud, count, mean Hz).
    One window resolves only 50 Hz steps; the mean over a run does not."""
    result = []
    for rms, hz in stats:
        is_loud = rms > loud
        if result and result[-1][0] == is_loud:
            result[-1][1].append(hz)
        else:
            result.append((is_loud, [hz]))
    return [(is_loud, len(h), sum(h) / len(h)) for is_loud, h in result]


def main():
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-audio-"))
    recording = work / "out.wav"
    g = Guest(extra_args=("-audiodev", f"wav,id=snd0,path={recording},out.frequency=48000",
                          "-device", "intel-hda", "-device", "hda-output,audiodev=snd0"))
    try:
        g.until(lambda: "audio-probe: PASS" in g.log() or "audio-probe: FAIL" in g.log(), "audio-probe finishes", 120)
        assert "audio-probe: PASS" in g.log(), g.log()[-2000:]
        print("PASS " + g.log().split("audio-probe: PASS ")[1].splitlines()[0], flush=True)
        g.monitor("stop")
    finally:
        g.close()
    sections = [r for r in runs(windows(recording)) if r[1] >= 5]  # ignore blips shorter than 50 ms
    loud = [r for r in sections if r[0]]
    print("sections (loud, ms, Hz): " + ", ".join(f"({int(a)}, {n * WINDOW_MS}, {int(hz)})" for a, n, hz in sections), flush=True)
    assert len(loud) == 2, f"two tones separated by silence, got {sections}"
    (_, first_n, first_hz), (_, second_n, second_hz) = loud
    assert abs(first_hz - 660) < 25 and abs(second_hz - 880) < 25, f"pitches {first_hz}, {second_hz}"
    assert 900 <= first_n * WINDOW_MS <= 1150 and 900 <= second_n * WINDOW_MS <= 1150, "each tone lasts about a second"
    gap = sections[sections.index(loud[0]) + 1]
    assert not gap[0] and gap[1] * WINDOW_MS >= 300, f"a silent gap between the tones, got {gap}"
    # Exactly two tones: nothing replayed after the second (the recording may
    # stop within 50 ms of its end, so no trailing silence is required).
    print(f"PASS the card played 660 Hz for {first_n * WINDOW_MS} ms, silence for {gap[1] * WINDOW_MS} ms, "
          f"880 Hz for {second_n * WINDOW_MS} ms, and nothing after", flush=True)


if __name__ == "__main__":
    main()
