/* W7: the first headless page render (docs/design/012-wpe-webkit-browser.md).
 *
 * The UI process of WPE WebKit on OrangeOS: a web view on the WPE Platform
 * headless display, which has no rendering device, so hardware acceleration
 * is off (recorded patch 0007) and the web process
 * paints with Skia on the CPU into shared memory and no EGL is touched
 * (the recorded patch 0001 keeps the web process from asking for one).
 * WebKit starts its web and network processes from /libexec/wpe-webkit-2.0
 * with posix_spawn. The page is loaded from the disk; JavaScript runs in
 * it; a snapshot of the rendered document is checked and written as a PNG.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wpe/headless/wpe-headless.h>
#include <wpe/webkit.h>

#define PAGE "file:///share/wpe-tests/hello.html"
#define OUTPUT "/tmp/wpe-render.png"

static GMainLoop *loop;
static int result = 1;
static char script_result[128];

static void finish(int code)
{
	result = code;
	g_main_loop_quit(loop);
}

static int write_png(const guint8 *bgra, int width, int height, guint stride)
{
	png_image image;
	memset(&image, 0, sizeof image);
	image.version = PNG_IMAGE_VERSION;
	image.width = (png_uint_32)width;
	image.height = (png_uint_32)height;
	image.format = PNG_FORMAT_BGRA;
	return png_image_write_to_file(&image, OUTPUT, 0, bgra, (png_int_32)stride, NULL) ? 0 : -1;
}

/* The PNG over standard output in base64, between marker lines, so the
 * test harness on the host can keep the rendered page. */
static void send_png(void)
{
	gchar *data = NULL;
	gsize length = 0;
	if (!g_file_get_contents(OUTPUT, &data, &length, NULL))
		return;
	gchar *encoded = g_base64_encode((const guchar *)data, length);
	printf("wpe-render: PNG-BEGIN %zu\n", length);
	for (gsize at = 0, total = strlen(encoded); at < total; at += 96)
		printf("wpe-render: PNG %.96s\n", encoded + at);
	printf("wpe-render: PNG-END\n");
	fflush(stdout);
	g_free(encoded);
	g_free(data);
}

/* Premultiplied BGRA to colour distance from an opaque RGB value. */
static int near(const guint8 *pixel, int r, int g, int b)
{
	return abs(pixel[2] - r) < 24 && abs(pixel[1] - g) < 24 && abs(pixel[0] - b) < 24 && pixel[3] > 240;
}

static void on_snapshot(GObject *object, GAsyncResult *outcome, gpointer data)
{
	(void)data;
	GError *error = NULL;
	WebKitImage *image = webkit_web_view_get_snapshot_finish(WEBKIT_WEB_VIEW(object), outcome, &error);
	if (!image) {
		printf("wpe-render: FAIL snapshot: %s\n", error ? error->message : "none");
		finish(1);
		return;
	}
	int width = webkit_image_get_width(image), height = webkit_image_get_height(image);
	guint stride = webkit_image_get_stride(image);
	GBytes *bytes = webkit_image_as_bytes(image);
	const guint8 *pixels = g_bytes_get_data(bytes, NULL);

	/* The page: an orange background, a white card, dark text and a blue to
	 * green bar. Count what the renderer actually drew. */
	long orange = 0, white = 0, dark = 0, blue = 0, total = (long)width * height;
	for (int y = 0; y < height; y++)
		for (int x = 0; x < width; x++) {
			const guint8 *p = pixels + (gsize)y * stride + (gsize)x * 4;
			orange += near(p, 0xff, 0x8c, 0x00);
			white += near(p, 0xff, 0xff, 0xff);
			dark += p[0] < 80 && p[1] < 80 && p[2] < 80 && p[3] > 240;
			blue += p[0] > 120 && p[2] < 60;
		}
	int saved = write_png(pixels, width, height, stride);
	/* The bytes belong to the image (transfer none). */
	g_object_unref(image);
	if (width < 300 || height < 200 || orange < total / 10 || white < total / 10 || dark < 200 || blue < 200 || saved != 0) {
		printf("wpe-render: FAIL snapshot %dx%d: orange %ld, white %ld, text %ld, bar %ld, png %d\n",
		       width, height, orange, white, dark, blue, saved);
		finish(1);
		return;
	}
	send_png();
	printf("wpe-render: PASS rendered %s at %dx%d on the CPU (orange %ld%%, card %ld%%, %ld text pixels, gradient %ld px); "
	       "page script: \"%s\"; PNG at %s\n",
	       PAGE, width, height, orange * 100 / total, white * 100 / total, dark, blue, script_result, OUTPUT);
	finish(0);
}

static void on_script(GObject *object, GAsyncResult *outcome, gpointer data)
{
	(void)data;
	GError *error = NULL;
	JSCValue *value = webkit_web_view_evaluate_javascript_finish(WEBKIT_WEB_VIEW(object), outcome, &error);
	if (!value) {
		printf("wpe-render: FAIL evaluate JavaScript: %s\n", error ? error->message : "none");
		finish(1);
		return;
	}
	char *text = jsc_value_to_string(value);
	g_strlcpy(script_result, text, sizeof script_result);
	g_free(text);
	g_object_unref(value);
	if (strcmp(script_result, "Orange OS 42|14+28+42") != 0) {
		printf("wpe-render: FAIL page state \"%s\"\n", script_result);
		finish(1);
		return;
	}
	webkit_web_view_get_snapshot(WEBKIT_WEB_VIEW(object), WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT, WEBKIT_SNAPSHOT_OPTIONS_NONE,
	                             NULL, on_snapshot, NULL);
}

static void on_load(WebKitWebView *view, WebKitLoadEvent event, gpointer data)
{
	(void)data;
	if (event != WEBKIT_LOAD_FINISHED)
		return;
	/* The page's own script changed its title and a paragraph; report them,
	 * or, when they are missing, what the document is instead. */
	const char *script =
		"(() => { const line = document.getElementById('line');"
		" if (!line) return 'no page content: url=' + document.URL + ' state=' + document.readyState +"
		" ' html=' + document.documentElement.outerHTML.slice(0, 160);"
		" return document.title + '|' + line.textContent.split('ran: ')[1].replace('.', ''); })()";
	webkit_web_view_evaluate_javascript(view, script, -1, NULL, NULL, NULL, on_script, NULL);
}

static gboolean on_failed(WebKitWebView *view, WebKitLoadEvent event, char *uri, GError *error, gpointer data)
{
	(void)view;
	(void)event;
	(void)data;
	printf("wpe-render: FAIL loading %s: %s\n", uri, error->message);
	finish(1);
	return TRUE;
}

static gboolean on_timeout(gpointer data)
{
	(void)data;
	printf("wpe-render: FAIL timed out\n");
	finish(1);
	return G_SOURCE_REMOVE;
}

int main(void)
{
	/* Software rendering, and nothing written to the read-only disk. */
	g_setenv("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1", TRUE);
	g_setenv("HOME", "/tmp/wpe-home", TRUE);
	g_setenv("XDG_CACHE_HOME", "/tmp/wpe-home/cache", TRUE);
	g_setenv("XDG_DATA_HOME", "/tmp/wpe-home/data", TRUE);
	g_setenv("XDG_RUNTIME_DIR", "/tmp/wpe-home/run", TRUE);
	g_mkdir_with_parents("/tmp/wpe-home/run", 0700);

	GError *error = NULL;
	WPEDisplay *display = wpe_display_headless_new();
	if (!wpe_display_connect(display, &error)) {
		printf("wpe-render: FAIL headless display: %s\n", error ? error->message : "none");
		return 1;
	}
	wpe_display_set_primary(display);

	/* Hardware acceleration and compositing are off because the headless
	 * display has no rendering device (patch 0007); WPE's API has no
	 * policy call for it. */
	WebKitSettings *settings = webkit_settings_new();
	webkit_settings_set_enable_webgl(settings, FALSE);
	WebKitNetworkSession *session = webkit_network_session_new_ephemeral();
	WebKitWebView *view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", display, "settings", settings,
	                                   "network-session", session, NULL);
	g_signal_connect(view, "load-changed", G_CALLBACK(on_load), NULL);
	g_signal_connect(view, "load-failed", G_CALLBACK(on_failed), NULL);

	loop = g_main_loop_new(NULL, FALSE);
	g_timeout_add_seconds(240, on_timeout, NULL);
	webkit_web_view_load_uri(view, PAGE);
	g_main_loop_run(loop);
	return result;
}
