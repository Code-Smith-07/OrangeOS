// Run in a YouTube watch page by F12 on debug images (see browser.c,
// run_inspector, and tools/youtube_check.py). Each run prints one line of
// facts about the player. A quality can be asked for in the address:
// ...watch?v=ID#oq=medium  (small 240p, medium 360p, large 480p, hd720).
(function () {
  var v = document.querySelector('video');
  var p = document.getElementById('movie_player');
  var want = (location.hash.match(/oq=([a-z0-9]+)/) || [])[1];
  var out = { t: Math.round(performance.now()) };
  // In Europe YouTube first asks about cookies. Answer "Reject all" (the
  // privacy-preserving choice) by pressing its own button.
  var buttons = document.querySelectorAll('ytd-consent-bump-v2-lightbox button, ytd-consent-bump-v2-lightbox [role="button"], ytd-consent-bump-v2-lightbox ytd-button-renderer');
  for (var i = 0; i < buttons.length; i++) {
    if (/^Reject all/.test((buttons[i].textContent || '').trim()) && buttons[i].getBoundingClientRect().width > 0) {
      var inner = buttons[i].querySelector('button') || buttons[i];
      // Once is enough: the button stays in the page, hidden, afterwards.
      if (window.__consentClicked) break;
      window.__consentClicked = out.t;
      inner.click();
      console.log('YTSTAT ' + JSON.stringify({ t: out.t, consent: 'rejected' }));
      return;
    }
  }
  if (p && p.focus) p.focus();
  if (p && want && !window.__oqDone) {
    window.__oqDone = 1;
    try { p.setPlaybackQualityRange(want, want); out.asked = want; } catch (e) { out.askError = String(e); }
  }
  if (v) {
    var q = v.getVideoPlaybackQuality ? v.getVideoPlaybackQuality() : {};
    out.w = v.videoWidth; out.h = v.videoHeight;
    out.shown = Math.round(v.getBoundingClientRect().width) + 'x' + Math.round(v.getBoundingClientRect().height);
    out.time = Math.round(v.currentTime * 1000) / 1000;
    out.paused = v.paused; out.muted = v.muted; out.volume = v.volume;
    out.ready = v.readyState; out.rate = v.playbackRate;
    out.total = q.totalVideoFrames; out.dropped = q.droppedVideoFrames;
    out.dpr = devicePixelRatio;
  } else out.video = 'none';
  if (p && p.getPlaybackQuality) {
    out.quality = p.getPlaybackQuality();
    try { out.levels = p.getAvailableQualityLevels().join(','); } catch (e) {}
    try {
      var s = p.getStatsForNerds && p.getStatsForNerds();
      if (s) { out.codecs = s.codecs; out.res = s.resolution; out.frames = s.dropped_frames || s.frames; }
    } catch (e) {}
    try { out.pmuted = p.isMuted(); out.pvol = p.getVolume(); } catch (e) {}
  }
  console.log('YTSTAT ' + JSON.stringify(out));
})();
