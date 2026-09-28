/* gst-probe: GStreamer on OrangeOS, before WebKit uses it (W11).
 *
 * 1. The elements WebKit's playback needs are registered (static plugins
 *    from gst-orange, no registry).
 * 2. Two clips decode completely: VP9 + Opus in WebM, H.264 + AAC in MP4
 *    (320x240, 15 fps, 3 s, 523 Hz tone), as fast as possible; the frame
 *    count and speed are reported.
 * 3. The WebM clip plays through autoaudiosink, which must pick
 *    orangeaudiosink; tools/media_smoke.py records the sound card and checks
 *    the tone.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <gst/gst.h>
#include <stdio.h>
#include <string.h>

#define MEDIA "file:///share/wpe-tests/media/"

static const char *required[] = {
	"orangeaudiosink", "autoaudiosink", "playbin", "decodebin", "appsink", "appsrc",
	"matroskademux", "qtdemux", "h264parse", "vp9parse", "avdec_h264", "avdec_vp9",
	"avdec_aac", "avdec_opus", "opusparse", "aacparse", "scaletempo", "deinterlace", "fakevideosink", "audioconvert", "audioresample", "videoconvert", "videoscale", NULL,
};

static guint frames;

static void on_frame(GstElement *sink, GstBuffer *buffer, GstPad *pad, gpointer data)
{
	(void)sink;
	(void)buffer;
	(void)pad;
	(void)data;
	frames++;
}

/* Run to the end; FALSE (and the message) on error or after `seconds`. */
static gboolean run(GstElement *pipeline, int seconds)
{
	GstBus *bus = gst_element_get_bus(pipeline);
	gst_element_set_state(pipeline, GST_STATE_PLAYING);
	GstMessage *message = gst_bus_timed_pop_filtered(bus, (GstClockTime)seconds * GST_SECOND,
	                                                 GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
	gboolean ok = message && GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS;
	if (!message) {
		printf("gst-probe: timed out after %d s\n", seconds);
	} else if (!ok) {
		GError *error = NULL;
		gchar *debug = NULL;
		gst_message_parse_error(message, &error, &debug);
		printf("gst-probe: error from %s: %s (%s)\n", GST_OBJECT_NAME(message->src), error->message, debug ? debug : "");
		g_clear_error(&error);
		g_free(debug);
	}
	if (message)
		gst_message_unref(message);
	gst_element_set_state(pipeline, GST_STATE_NULL);
	gst_object_unref(bus);
	return ok;
}

static gboolean decode(const char *name)
{
	GstElement *playbin = gst_element_factory_make("playbin", NULL);
	GstElement *video = gst_element_factory_make("fakesink", NULL);
	GstElement *audio = gst_element_factory_make("fakesink", NULL);
	g_object_set(video, "sync", FALSE, "signal-handoffs", TRUE, NULL);
	g_object_set(audio, "sync", FALSE, NULL);
	g_signal_connect(video, "handoff", G_CALLBACK(on_frame), NULL);
	char *uri = g_strconcat(MEDIA, name, NULL);
	g_object_set(playbin, "uri", uri, "video-sink", video, "audio-sink", audio, NULL);
	g_free(uri);
	frames = 0;
	gint64 start = g_get_monotonic_time();
	gboolean ok = run(playbin, 120);
	gint64 ms = (g_get_monotonic_time() - start) / 1000;
	gst_object_unref(playbin);
	if (!ok || frames != 45) {
		printf("gst-probe: FAIL decoding %s: %u of 45 frames\n", name, frames);
		return FALSE;
	}
	printf("gst-probe: PASS decoded %s: 45 frames and its audio in %lld ms (%.1f fps)\n", name, (long long)ms,
	       45000.0 / (double)(ms ? ms : 1));
	return TRUE;
}

int main(int argc, char **argv)
{
	gst_init(&argc, &argv);
	for (const char **e = required; *e; e++) {
		GstElementFactory *factory = gst_element_factory_find(*e);
		if (!factory) {
			printf("gst-probe: FAIL element %s is not registered\n", *e);
			return 1;
		}
		gst_object_unref(factory);
	}
	printf("gst-probe: PASS %zu elements registered\n", sizeof required / sizeof *required - 1);

	if (!decode("clip-vp9-opus.webm") || !decode("clip-h264-aac.mp4"))
		return 1;

	/* Played in real time; the sound goes to the card. */
	GstElement *playbin = gst_element_factory_make("playbin", NULL);
	GstElement *video = gst_element_factory_make("fakesink", NULL);
	GstElement *audio = gst_element_factory_make("autoaudiosink", NULL);
	g_object_set(playbin, "uri", MEDIA "clip-vp9-opus.webm", "video-sink", video, "audio-sink", audio, NULL);
	printf("gst-probe: playing\n");
	fflush(stdout);
	gint64 start = g_get_monotonic_time();
	if (!run(playbin, 60)) {
		printf("gst-probe: FAIL playing clip-vp9-opus.webm\n");
		return 1;
	}
	printf("gst-probe: PASS played clip-vp9-opus.webm in %lld ms\n", (long long)(g_get_monotonic_time() - start) / 1000);
	gst_object_unref(playbin);
	return 0;
}
