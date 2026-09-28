/* GStreamer for OrangeOS programs, which link it statically (docs/design/012,
 * W11).
 *
 * - gst_init_static_plugins(): GStreamer core is built with
 *   GST_FULL_STATIC_COMPILATION, so gst_init() calls this to register the
 *   plugins linked into the program; there is no plugin loading or
 *   registry cache.
 * - orangeaudiosink: an audio sink writing 48 kHz, 16-bit stereo PCM to
 *   /dev/audio (drivers/audio/hda.zig). Its rank puts it first for
 *   autoaudiosink, which WebKit uses. Its delay is what the device reports
 *   as queued (fstat), so audio and video stay in step.
 *
 * tools/wpe/build_deps.py gst-orange builds this into
 * libgstreamer-full-1.0.a, with the pkg-config file WebKit's
 * USE_GSTREAMER_FULL looks for.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <errno.h>
#include <fcntl.h>
#include <gst/audio/gstaudiosink.h>
#include <gst/gst.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DEVICE "/dev/audio"

/* ── orangeaudiosink ──────────────────────────────────────────────────── */

typedef struct {
	GstAudioSink parent;
	int fd;
	guint frame_bytes;
} OrangeAudioSink;

typedef struct {
	GstAudioSinkClass parent_class;
} OrangeAudioSinkClass;

GType orange_audio_sink_get_type(void);
G_DEFINE_TYPE(OrangeAudioSink, orange_audio_sink, GST_TYPE_AUDIO_SINK)

#define SINK(obj) ((OrangeAudioSink *)(obj))

static GstStaticPadTemplate sink_template = GST_STATIC_PAD_TEMPLATE(
	"sink", GST_PAD_SINK, GST_PAD_ALWAYS,
	GST_STATIC_CAPS("audio/x-raw, format = (string) S16LE, layout = (string) interleaved, "
	                "rate = (int) 48000, channels = (int) 2, channel-mask = (bitmask) 0x3"));

static gboolean sink_open(GstAudioSink *base)
{
	OrangeAudioSink *self = SINK(base);
	self->fd = open(DEVICE, O_WRONLY | O_CLOEXEC);
	if (self->fd < 0) {
		GST_ELEMENT_ERROR(base, RESOURCE, OPEN_WRITE, ("Could not open %s", DEVICE), ("%s", strerror(errno)));
		return FALSE;
	}
	return TRUE;
}

static gboolean sink_prepare(GstAudioSink *base, GstAudioRingBufferSpec *spec)
{
	SINK(base)->frame_bytes = GST_AUDIO_INFO_BPF(&spec->info);
	/* About 10 ms segments, 200 ms of ring in GStreamer. */
	spec->segsize = 480 * SINK(base)->frame_bytes;
	spec->segtotal = 20;
	return TRUE;
}

static gboolean sink_unprepare(GstAudioSink *base)
{
	(void)base;
	return TRUE;
}

static gboolean sink_close(GstAudioSink *base)
{
	OrangeAudioSink *self = SINK(base);
	if (self->fd >= 0)
		close(self->fd);
	self->fd = -1;
	return TRUE;
}

static gint sink_write(GstAudioSink *base, gpointer data, guint length)
{
	OrangeAudioSink *self = SINK(base);
	guint done = 0;
	while (done < length) {
		ssize_t n = write(self->fd, (const char *)data + done, length - done);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			GST_ELEMENT_ERROR(base, RESOURCE, WRITE, ("Could not write to %s", DEVICE), ("%s", strerror(errno)));
			return -1;
		}
		done += (guint)n;
	}
	return (gint)done;
}

/* Frames written to the device but not yet played. */
static guint sink_delay(GstAudioSink *base)
{
	OrangeAudioSink *self = SINK(base);
	struct stat status;
	if (self->fd < 0 || !self->frame_bytes || fstat(self->fd, &status) != 0)
		return 0;
	return (guint)(status.st_size / self->frame_bytes);
}

static void sink_reset(GstAudioSink *base)
{
	(void)base; /* what is queued in the device plays out (a third of a second at most) */
}

static void orange_audio_sink_class_init(OrangeAudioSinkClass *klass)
{
	GstElementClass *element = GST_ELEMENT_CLASS(klass);
	GstAudioSinkClass *audio = GST_AUDIO_SINK_CLASS(klass);
	gst_element_class_set_static_metadata(element, "OrangeOS audio sink", "Sink/Audio",
	                                      "Plays audio through /dev/audio", "OrangeOS");
	gst_element_class_add_static_pad_template(element, &sink_template);
	audio->open = sink_open;
	audio->prepare = sink_prepare;
	audio->unprepare = sink_unprepare;
	audio->close = sink_close;
	audio->write = sink_write;
	audio->delay = sink_delay;
	audio->reset = sink_reset;
}

static void orange_audio_sink_init(OrangeAudioSink *self)
{
	self->fd = -1;
}

/* ── Static plugins ───────────────────────────────────────────────────── */

#define PLUGINS(X)                                                                        \
	X(coreelements) X(app) X(playback) X(typefindfunctions) X(audioconvert) X(audioresample) \
	X(videoconvertscale) X(volume) X(audiotestsrc) X(videotestsrc) X(rawparse) X(autodetect) \
	X(isomp4) X(matroska) X(audioparsers) X(id3demux) X(wavparse) X(videoparsersbad) X(opusparse)    \
	X(audiofx) X(deinterlace) X(debugutilsbad) X(libav)

#define DECLARE(name) GST_PLUGIN_STATIC_DECLARE(name);
PLUGINS(DECLARE)

void gst_init_static_plugins(void);

void gst_init_static_plugins(void)
{
#define REGISTER(name) GST_PLUGIN_STATIC_REGISTER(name);
	PLUGINS(REGISTER)
	gst_element_register(NULL, "orangeaudiosink", GST_RANK_PRIMARY + 10, orange_audio_sink_get_type());
}
