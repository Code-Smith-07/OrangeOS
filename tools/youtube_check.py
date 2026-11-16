#!/usr/bin/env python3
"""Play a YouTube video in Orange Browser and measure it.

Build: zig build -Ddesktop-profile -Dwpe-probes
       ORANGE_WPE_PROBES=1 ORANGE_BROWSER_CONSOLE=1 \
       ORANGE_BROWSER_INSPECT=tools/browser-inspect/youtube.js scripts/mkdisk.sh

A report, not a pass/fail test: it needs the internet and YouTube changes.
It opens the watch page of one video, starts it with a click on the player,
lets it play, and reports:

  * picture: frames that reached the screen per second (the browser counts
    them on debug images), and whether the picture kept changing;
  * sound: QEMU records the sound card; the share of the time with sound
    and the number of gaps (a gap is a stall you would hear);
  * the player's own complaints in the log (dropped frames, buffering).

Options: --seconds N (default 60), --cpus N, --threads multi|single,
--video ID (default Big Buck Bunny), --click X,Y (where the player is).
"""
import argparse
import os
import pathlib
import re
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--cpus", type=int, default=0)
    ap.add_argument("--threads", choices=("multi", "single"), default="single")
    ap.add_argument("--tb-size", type=int, default=0)
    ap.add_argument("--video", default="aqz-KE-bpKQ")
    ap.add_argument("--quality", default="", help="ask the player for small, medium, large or hd720")
    ap.add_argument("--settle", type=int, default=15, help="seconds to wait before clicking the player")
    ap.add_argument("--click", type=lambda v: tuple(int(n) for n in v.split(",")), default=(330, 300))
    args = ap.parse_args()
    if args.cpus:
        os.environ["ORANGE_VM_CPUS"] = str(args.cpus)
    os.environ["ORANGE_WPE_PROBES"] = "1"
    from desktop_smoke import Guest
    import browser_smoke as b
    from audio_smoke import windows, WINDOW_MS

    work = pathlib.Path(tempfile.mkdtemp(prefix="orange-youtube-"))
    recording = work / "out.wav"
    accel = "tcg"
    if args.threads == "multi":
        accel += ",thread=multi"
    if args.tb_size:
        accel += f",tb-size={args.tb_size}"
    # A data disk kept between runs: the browser stores its cookies there,
    # as on the real system, so YouTube's cookie question is answered once.
    data = pathlib.Path(__file__).resolve().parents[1] / "build/test-youtube-data.img"
    if not data.exists():
        import subprocess
        subprocess.run([sys.executable, str(data.parents[1] / "tools/mkdata.py"), str(data), "--size-mib", "64"], check=True)
    g = Guest(extra_args=("-accel", accel, "-audiodev", f"wav,id=snd0,path={recording},out.frequency=48000",
                          "-device", "intel-hda", "-device", "hda-output,audiodev=snd0",
                          "-drive", f"id=data0,file={data},format=raw,if=none", "-device", "ide-hd,drive=data0,bus=ahci.1"))
    keys = {".": "dot", ":": "shift-semicolon", "/": "slash", "-": "minus", "_": "shift-minus", "?": "shift-slash", "=": "equal", "&": "shift-7", "#": "shift-3"}

    def typed(text):
        for ch in text:
            g.key("shift-" + ch.lower() if ch.isupper() else keys.get(ch, ch))

    frames = []
    try:
        g.until(lambda: '"Welcome"' in g.log() and "squeeze: window" in g.log(), "boot to desktop", 120)
        g.scale = 2
        time.sleep(1)
        g.click(*b.DOCK_BROWSER)
        g.until(lambda: "orange-browser: loaded file:///share/browser/start.html" in g.log(), "the browser starts", 600)
        time.sleep(2)
        # The watch page itself: YouTube refuses its embedded player when it
        # is opened directly rather than from inside another page.
        url = f"www.youtube.com/watch?v={args.video}"
        if args.quality:
            url += f"#oq={args.quality}"

        import json

        def stats():
            """Ask the page (F12 runs tools/browser-inspect/youtube.js)."""
            before = g.log().count("YTSTAT ")
            g.key("f12")
            deadline = time.time() + 15
            while time.time() < deadline and g.log().count("YTSTAT ") == before:
                time.sleep(0.5)
            found = re.findall(r"YTSTAT (\{.*?\})(?:\n|$)", g.log())
            try:
                return json.loads(found[-1]) if len(found) > before else {}
            except ValueError:
                return {}
        g.click(*b.ADDRESS)
        typed(url)
        mark = len(g.log())
        g.key("ret")
        g.until(lambda: re.search(r"orange-browser: (loaded|failed) \S*youtube", g.log()[mark:]), "YouTube's player loads", 300)
        assert "orange-browser: failed" not in g.log()[mark:], "the player page failed to load"
        # YouTube asks its cookie question (in Europe) up to a minute after
        # the page loads, and holds the video until it is answered. The
        # inspection script answers "Reject all"; the answer is then kept in
        # the cookies on the test's data disk.
        time.sleep(max(args.settle, 55))
        first = stats()
        if first.get("consent"):
            print("the cookie question was asked: answered Reject all", flush=True)
            time.sleep(25)
            first = stats()
        g.screenshot("yt-0-ready")
        if first.get("paused"):
            g.key("k")  # YouTube's own play key; a key press also allows sound
            print("the video was paused: pressed k to play", flush=True)
            time.sleep(12)
            first = stats()
        if first.get("muted") or first.get("pmuted"):
            g.key("m")
            print("the video started muted: pressed m to unmute", flush=True)
            time.sleep(2)
            first = stats()
        print(f"player at start: {first}", flush=True)
        started = time.time()
        mark = len(g.log())
        stills = []
        while time.time() - started < args.seconds:
            time.sleep(5)
            stills.append(g.region(300, 250, 360, 200))
        last = stats()
        print(f"player at end:   {last}", flush=True)
        g.screenshot("yt-1-playing")
        log = g.log()[mark:]
        frames = [int(n) for n in re.findall(r"orange-browser: frames (\d+) in 5 s", log)]
        changed = sum(1 for a, c in zip(stills, stills[1:]) if a != c)
        qos = len(re.findall(r"(?i)dropping frame|lateness|A lot of buffers are being dropped", log))
        buffering = len(re.findall(r"(?i)buffering|underrun|stall", log))
        crashed = "[app fault]" in log or "KERNEL PANIC" in g.log()
        g.monitor("stop")
    finally:
        g.close()

    print()
    print(f"Machine: {os.environ.get('ORANGE_VM_CPUS', 'default')} CPUs, TCG threads {args.threads}" + (f", tb-size {args.tb_size} MB" if args.tb_size else ""))
    if frames:
        # The first sample includes the start of playback.
        steady = frames[1:] or frames
        print(f"Picture: {sum(steady) / len(steady) / 5:.1f} frames a second on average "
              f"(lowest {min(steady) / 5:.1f}, highest {max(steady) / 5:.1f}) over {len(frames) * 5} s")
    else:
        print("Picture: the browser reported no frames (is this a debug image? ORANGE_BROWSER_CONSOLE=1)")
    print(f"Picture kept changing in {changed} of {max(1, len(stills) - 1)} five-second checks")
    if first.get("total") is not None and last.get("total") is not None and last.get("t", 0) > first.get("t", 0):
        wall = (last["t"] - first["t"]) / 1000
        decoded = last["total"] - first["total"]
        dropped = (last.get("dropped") or 0) - (first.get("dropped") or 0)
        played = last["time"] - first["time"]
        print(f"Video: {last.get('w')}x{last.get('h')} stream ({last.get('quality')}), shown at {last.get('shown')} points, screen scale {last.get('dpr')}")
        print(f"Video: {played:.1f} s of film played in {wall:.1f} s ({played / wall * 100:.0f}% of real time)")
        print(f"Video: {(decoded - dropped) / wall:.1f} frames a second shown, {dropped / wall:.1f} a second dropped ({dropped} of {decoded} dropped)")
        print(f"Video: muted {last.get('muted')}, volume {last.get('volume')}")
    if recording.exists() and recording.stat().st_size > 1000:
        stats = windows(recording)
        loud = [rms > 200 for rms, _ in stats]
        if any(loud):
            first, last = loud.index(True), len(loud) - 1 - loud[::-1].index(True)
            playing = loud[first:last + 1]
            gaps, run = [], 0
            for is_loud in playing:
                if is_loud:
                    if run * WINDOW_MS >= 150:
                        gaps.append(run * WINDOW_MS)
                    run = 0
                else:
                    run += 1
            print(f"Sound: heard for {sum(playing) * WINDOW_MS / 1000:.1f} s of {len(playing) * WINDOW_MS / 1000:.1f} s; "
                  f"{len(gaps)} silent gaps of 150 ms or more" + (f" (longest {max(gaps)} ms, total {sum(gaps) / 1000:.1f} s)" if gaps else ""))
        else:
            print("Sound: nothing reached the sound card")
    else:
        print("Sound: no recording")
    print(f"Player log: {qos} dropped-frame or lateness messages, {buffering} buffering messages" + (", A PROCESS CRASHED" if crashed else ""))
    print(f"Evidence: {g.output} and {recording}")


if __name__ == "__main__":
    main()
