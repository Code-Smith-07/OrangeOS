#!/usr/bin/env python3
"""Orange Browser plays video and sound (W11).

Build: zig build -Ddesktop-profile -Dwpe-probes; ORANGE_WPE_PROBES=1 scripts/mkdisk.sh

With an Intel HDA card whose output QEMU records, the browser opens the
HTTPS fixture's media pages:
  /video.html  an H.264 + AAC MP4 in <video>, started by a click (sound
               needs a gesture): it must play to the end in about real
               time, a frame drawn to a canvas must have colour, and the
               recording must hold the clip's 523 Hz tone;
  /mse.html    a VP9 + Opus WebM appended through Media Source Extensions,
               as YouTube streams: it must play to the end.
"""
import os
import pathlib
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
import runtime_smoke  # noqa: E402  (the HTTPS fixture)
import browser_smoke as b  # noqa: E402
from audio_smoke import runs, windows, WINDOW_MS  # noqa: E402
from desktop_smoke import Guest  # noqa: E402


def title(g, prefix):
    found = re.findall(rf'orange-browser: title "({prefix}[^"]*)"', g.log())
    return found[-1] if found else None


def main():
    os.environ["ORANGE_WPE_PROBES"] = "1"
    https = runtime_smoke.https_server()
    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-browser-media-"))
    recording = work / "out.wav"
    g = Guest(extra_args=("-audiodev", f"wav,id=snd0,path={recording},out.frequency=48000",
                          "-device", "intel-hda", "-device", "hda-output,audiodev=snd0"))
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 90)
        g.scale = 2 if "framebuffer: 2560x1600" in g.log() else 1
        time.sleep(1)
        g.click(*b.DOCK_BROWSER)
        g.until(lambda: b.loads(g, "file:///share/browser/start.html") >= 1, "the browser starts", 600)

        g.click(*b.ADDRESS)
        b.typed(g, "10.0.2.2:38459/video.html")
        g.key("ret")
        g.until(lambda: title(g, "video:ready") or title(g, "video:error"), "the video is ready", 180)
        g.click(480, 400)  # the user starts it: sound needs a gesture
        g.until(lambda: (title(g, "video:ended") or title(g, "video:error") or title(g, "video:play ")), "the video plays to its end", 300)
        ended = title(g, "video:ended")
        g.screenshot("21-video")
        assert ended and ended.startswith("video:ended 320x240"), g.log()[-3000:]
        lit = int(re.search(r"lit=(\d+)", ended).group(1))
        wall = int(re.search(r"wall=(\d+)", ended).group(1))
        assert lit > 200, f"a drawn frame has colour ({lit} of 768 pixels lit)"
        assert 2900 <= wall <= 8000, f"the 3 s clip played in about real time from the click, took {wall} ms"
        print(f"PASS <video> MP4 (H.264 + AAC) played: {ended[len('video:'):]}", flush=True)

        g.click(*b.ADDRESS)
        b.typed(g, "10.0.2.2:38459/mse.html")
        g.key("ret")
        g.until(lambda: title(g, "mse:ended") or title(g, "mse:error") or title(g, "mse:unsupported"),
                "the MSE video plays to its end", 300)
        mse = title(g, "mse:ended")
        assert mse and mse.startswith("mse:ended 320x240"), title(g, "mse:")
        print(f"PASS Media Source Extensions WebM (VP9 + Opus) played: {mse[len('mse:'):]}", flush=True)
        g.monitor("stop")
    finally:
        g.close()
        https.shutdown()
    tones = [r for r in runs(windows(recording)) if r[0] and r[1] >= 5]
    assert tones, "the browser's sound reached the card"
    longest = max(tones, key=lambda r: r[1])
    assert abs(longest[2] - 523) < 30 and longest[1] * WINDOW_MS >= 2000, f"the clip's tone, got {longest}"
    print(f"PASS the browser's sound reached the card: {int(longest[2])} Hz for {longest[1] * WINDOW_MS} ms", flush=True)
    print(f"Browser media checks passed; evidence in {g.output}", flush=True)


if __name__ == "__main__":
    main()
