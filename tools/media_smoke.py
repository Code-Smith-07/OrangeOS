#!/usr/bin/env python3
"""GStreamer decodes video and plays sound on OrangeOS (W11).

Build: zig build -Ddesktop-profile -Dwpe-probes
       ORANGE_WPE_PROBES=1 ORANGE_MEDIA_PROBE=1 scripts/mkdisk.sh

gst-probe runs at boot with an Intel HDA card whose output QEMU records:
it checks the playback elements are registered, decodes a VP9 + Opus WebM
clip and an H.264 + AAC MP4 clip (45 frames each), then plays the WebM clip
through autoaudiosink. The recording must hold its 523 Hz tone for about
its three seconds.
"""
import os
import pathlib
import re
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from audio_smoke import runs, windows, WINDOW_MS  # noqa: E402
from desktop_smoke import Guest  # noqa: E402


def main():
    os.environ["ORANGE_WPE_PROBES"] = "1"
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-media-"))
    recording = work / "out.wav"
    g = Guest(extra_args=("-audiodev", f"wav,id=snd0,path={recording},out.frequency=48000",
                          "-device", "intel-hda", "-device", "hda-output,audiodev=snd0"))
    try:
        g.until(lambda: "gst-probe: PASS played" in g.log() or "gst-probe: FAIL" in g.log()
                or "gst-probe: error" in g.log(), "gst-probe finishes", 600)
        log = g.log()
        assert "gst-probe: PASS played" in log, log[-3000:]
        for line in re.findall(r"gst-probe: PASS [^\n]*", log):
            print(line.replace("gst-probe: ", ""), flush=True)
        g.monitor("stop")
    finally:
        g.close()
    tones = [r for r in runs(windows(recording)) if r[0] and r[1] >= 5]
    assert tones, "the recording holds sound"
    longest = max(tones, key=lambda r: r[1])
    assert abs(longest[2] - 523) < 25, f"523 Hz expected, heard {longest[2]} Hz"
    assert longest[1] * WINDOW_MS >= 2500, f"about 3 s of tone, got {longest[1] * WINDOW_MS} ms"
    print(f"PASS the sound card played the clip's tone: {int(longest[2])} Hz for {longest[1] * WINDOW_MS} ms", flush=True)


if __name__ == "__main__":
    main()
