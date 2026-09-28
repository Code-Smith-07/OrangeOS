/* Orange Browser: WPE WebKit in a Peel window (docs/design/012, W8-W10).
 *
 * A tab strip and a toolbar (back, forward, reload, an address field and a
 * load-progress line) above the active tab's web view. Pages render on the
 * CPU and are copied into the window by the Peel backend (peel-platform.c),
 * which keeps each tab's last frame and draws only the active one; a thread
 * waits for Peel's input events and hands them to the main loop, where they
 * become tab and toolbar actions or WPE events.
 *
 * Tabs: the + button or Ctrl+T opens one, the x or Ctrl+W closes one (the
 * last closes the browser), Ctrl+Tab and Ctrl+Shift+Tab move between them,
 * and pages that open a window (target=_blank, window.open) get a new tab.
 *
 * The profile (cookies, local storage, databases) is kept in
 * /data/orange-browser when a data disk is attached, so it survives a
 * reboot (docs/design/013); otherwise, and for the cache, /tmp is used.
 *
 * With no argument the start page opens; an argument is the URL to open.
 * Finished loads, titles and tab changes are logged ("orange-browser: ..."),
 * which the desktop tests read.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <ft2build.h>
#include FT_FREETYPE_H
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wpe/webkit.h>

#include "peel-platform.h"

#define WINDOW_WIDTH 960
#define WINDOW_HEIGHT 640
#define TABBAR 36
#define TOOLBAR 48
#define CONTENT_Y (TABBAR + TOOLBAR)
#define MAX_TABS 6
#define START_PAGE "file:///share/browser/start.html"
#define CONSOLE_FLAG "/etc/orange-browser/console"
#define FONT "/share/fonts/Inter.ttf"
#define PROFILE "/tmp/orange-browser"
#define SAVED_PROFILE "/data/orange-browser"
#define TEST_CERTIFICATE "/share/wpe-tests/allow-tls.pem"

/* libpeel's C interface (userland/libs/libpeel/c_api.zig). */
typedef struct {
	int32_t width, height, scale, stride;
	uint32_t *pixels;
} PeelInfo;
typedef struct {
	uint32_t kind, code, value;
	int32_t x, y;
} PeelEvent;
int orange_peel_open(const char *title, int width, int height, PeelInfo *info);
void orange_peel_commit(int x, int y, int width, int height);
int orange_peel_next_event(PeelEvent *event, int blocking);
void orange_peel_close(void);

enum { BUTTON_BACK, BUTTON_FORWARD, BUTTON_RELOAD, BUTTON_COUNT };

typedef struct {
	WebKitWebView *web_view;
	WPEView *view;
	double progress;
} Tab;

static struct {
	PeelInfo window;
	FT_Library freetype;
	FT_Face face;
	WPEDisplay *display;
	WebKitSettings *settings;
	WebKitNetworkSession *session;
	Tab tabs[MAX_TABS];
	int count, active;
	GMainLoop *loop;
	/* The address field: what is shown, and whether keys go to it. */
	GString *address;
	gboolean editing;
	/* Just focused: the first typed character replaces the whole address. */
	gboolean replace;
	WPEModifiers modifiers;
	guint32 buttons;
} browser;

#define ACTIVE (&browser.tabs[browser.active])

/* ── Drawing (window buffer pixels, logical coordinates) ─────────────────── */

#define INK 0x26313E
#define MUTED 0x8A93A0
#define BAR 0xF2F4F7
#define STRIP 0xDFE4EA
#define FIELD 0xFFFFFF
#define ACCENT 0x1689DB
#define LINE 0xD8DCE2

static void fill(int x, int y, int w, int h, uint32_t color)
{
	const int s = browser.window.scale;
	for (int yy = MAX(y, 0) * s; yy < MIN(y + h, browser.window.height) * s; yy++)
		for (int xx = MAX(x, 0) * s; xx < MIN(x + w, browser.window.width) * s; xx++)
			browser.window.pixels[yy * browser.window.stride + xx] = color;
}

static uint32_t blend(uint32_t under, uint32_t over, unsigned alpha)
{
	uint32_t out = 0;
	for (int shift = 0; shift <= 16; shift += 8) {
		unsigned a = (under >> shift) & 255, b = (over >> shift) & 255;
		out |= ((a * (255 - alpha) + b * alpha) / 255) << shift;
	}
	return out;
}

static void rounded(int x, int y, int w, int h, int radius, uint32_t color)
{
	const int s = browser.window.scale, r = radius * s;
	for (int yy = y * s; yy < (y + h) * s; yy++)
		for (int xx = x * s; xx < (x + w) * s; xx++) {
			int dx = MAX(MAX(x * s + r - xx - 1, xx - ((x + w) * s - r)), 0);
			int dy = MAX(MAX(y * s + r - yy - 1, yy - ((y + h) * s - r)), 0);
			if (dx * dx + dy * dy > r * r)
				continue;
			browser.window.pixels[yy * browser.window.stride + xx] = color;
		}
}

/* UTF-8 text with FreeType; returns the advance in logical pixels. Draws
 * nothing when `draw` is false (measuring). Stops at `max_width`. */
static int text(const char *string, int x, int baseline, uint32_t color, int size, gboolean draw, int max_width)
{
	const int s = browser.window.scale;
	FT_Set_Pixel_Sizes(browser.face, 0, size * s);
	int pen = x * s, limit = (x + max_width) * s;
	if (!g_utf8_validate(string, -1, NULL))
		return 0;
	for (const char *c = string; *c; c = g_utf8_next_char(c)) {
		if (FT_Load_Char(browser.face, g_utf8_get_char(c), FT_LOAD_RENDER))
			continue;
		FT_GlyphSlot g = browser.face->glyph;
		if (pen + (int)(g->advance.x >> 6) > limit)
			break;
		if (draw) {
			for (unsigned row = 0; row < g->bitmap.rows; row++)
				for (unsigned column = 0; column < g->bitmap.width; column++) {
					int px = pen + g->bitmap_left + (int)column, py = baseline * s - g->bitmap_top + (int)row;
					unsigned alpha = g->bitmap.buffer[row * (unsigned)g->bitmap.pitch + column];
					if (!alpha || px < 0 || py < 0 || px >= limit || px >= browser.window.width * s || py >= browser.window.height * s)
						continue;
					uint32_t *p = &browser.window.pixels[py * browser.window.stride + px];
					*p = blend(*p, color, alpha);
				}
		}
		pen += (int)(g->advance.x >> 6);
	}
	return (pen - x * s) / s;
}

/* A left or right chevron, or a circular arrow for reload. */
static void icon(int button, int cx, int cy, uint32_t color)
{
	if (button == BUTTON_RELOAD) {
		for (int angle = 40; angle < 330; angle += 4) {
			double a = angle * G_PI / 180;
			fill(cx + (int)(7 * cos(a)), cy - (int)(7 * sin(a)), 2, 2, color);
		}
		fill(cx + 5, cy - 9, 5, 2, color);
		fill(cx + 8, cy - 9, 2, 5, color);
		return;
	}
	int direction = button == BUTTON_BACK ? -1 : 1;
	for (int i = 0; i < 7; i++) {
		fill(cx - direction * 3 + direction * i, cy - 7 + i, 2, 2, color);
		fill(cx - direction * 3 + direction * i, cy + 7 - i, 2, 2, color);
	}
}

/* An x of two diagonal strokes. */
static void cross(int cx, int cy, int half, uint32_t color)
{
	for (int i = -half; i <= half; i++) {
		fill(cx + i, cy + i, 2, 2, color);
		fill(cx + i, cy - i, 2, 2, color);
	}
}

static int button_x(int button)
{
	return 10 + button * 38;
}

static int field_x(void)
{
	return button_x(BUTTON_COUNT) + 6;
}

/* Tab i spans [tab_x(i), tab_x(i) + tab_width()) on the strip. */
static int tab_width(void)
{
	return MIN(220, (browser.window.width - 8 - 44) / MAX(browser.count, 1));
}

static int tab_x(int index)
{
	return 8 + index * tab_width();
}

static int plus_x(void)
{
	return tab_x(browser.count) + 6;
}

static const char *tab_title(const Tab *tab)
{
	const char *title = webkit_web_view_get_title(tab->web_view);
	if (title && *title)
		return title;
	const char *uri = webkit_web_view_get_uri(tab->web_view);
	return uri && *uri ? uri : "New Tab";
}

static void draw_tabs(void)
{
	fill(0, 0, browser.window.width, TABBAR, STRIP);
	const int w = tab_width();
	for (int i = 0; i < browser.count; i++) {
		const int x = tab_x(i);
		const gboolean active = i == browser.active;
		if (active) {
			rounded(x, 6, w - 4, TABBAR, 8, BAR);
		} else if (i + 1 != browser.active) {
			fill(x + w - 4, 12, 1, 18, 0xB9C1CB);
		}
		text(tab_title(&browser.tabs[i]), x + 12, 26, active ? INK : 0x55606D, 13, TRUE, w - 4 - 12 - 26);
		cross(x + w - 4 - 15, 21, 4, active ? INK : MUTED);
	}
	if (browser.count < MAX_TABS) {
		fill(plus_x() + 7, 20, 14, 2, INK);
		fill(plus_x() + 13, 14, 2, 14, INK);
	}
	orange_peel_commit(0, 0, browser.window.width, TABBAR);
}

static void draw_toolbar(void)
{
	WebKitWebView *web_view = ACTIVE->web_view;
	fill(0, TABBAR, browser.window.width, TOOLBAR, BAR);
	fill(0, CONTENT_Y - 1, browser.window.width, 1, LINE);
	gboolean enabled[BUTTON_COUNT] = {
		webkit_web_view_can_go_back(web_view),
		webkit_web_view_can_go_forward(web_view),
		TRUE,
	};
	for (int b = 0; b < BUTTON_COUNT; b++)
		icon(b, button_x(b) + 16, TABBAR + TOOLBAR / 2, enabled[b] ? INK : 0xC4C9D0);

	int fx = field_x(), fw = browser.window.width - fx - 12;
	rounded(fx, TABBAR + 9, fw, 30, 8, browser.editing ? ACCENT : LINE);
	rounded(fx + 1, TABBAR + 10, fw - 2, 28, 7, FIELD);
	const char *shown = browser.address->len ? browser.address->str : "Search or enter an address";
	int advance = text(shown, fx + 12, TABBAR + 29, browser.address->len ? INK : MUTED, 14, TRUE, fw - 24);
	if (browser.editing)
		fill(fx + 12 + advance + 1, TABBAR + 16, 1, 17, ACCENT);
	double progress = ACTIVE->progress;
	if (progress > 0 && progress < 1)
		fill(0, CONTENT_Y - 2, (int)(browser.window.width * progress), 2, ACCENT);
	orange_peel_commit(0, TABBAR, browser.window.width, TOOLBAR);
}

static void commit_content(int x, int y, int w, int h)
{
	orange_peel_commit(x, y, w, h);
}

/* ── Tabs ────────────────────────────────────────────────────────────────── */

static int tab_of(WebKitWebView *web_view)
{
	for (int i = 0; i < browser.count; i++)
		if (browser.tabs[i].web_view == web_view)
			return i;
	return -1;
}

static void show_uri(void)
{
	const char *uri = webkit_web_view_get_uri(ACTIVE->web_view);
	g_string_assign(browser.address, uri ? uri : "");
}

static void log_tabs(void)
{
	printf("orange-browser: tabs %d active %d %s\n", browser.count, browser.active + 1,
	       webkit_web_view_get_uri(ACTIVE->web_view) ? webkit_web_view_get_uri(ACTIVE->web_view) : "");
	fflush(stdout);
}

static void activate(int index)
{
	for (int i = 0; i < browser.count; i++) {
		if (i == index)
			continue;
		orange_view_set_active(browser.tabs[i].view, FALSE);
		wpe_view_focus_out(browser.tabs[i].view);
	}
	browser.active = index;
	browser.editing = FALSE;
	orange_view_set_active(ACTIVE->view, TRUE);
	wpe_view_focus_in(ACTIVE->view);
	show_uri();
	draw_tabs();
	draw_toolbar();
	log_tabs();
}

/* What the user typed, as a URL: kept when it has a scheme, https:// for
 * something that looks like a host name. There is no search engine. */
static char *address_to_url(const char *typed)
{
	while (*typed == ' ')
		typed++;
	if (strstr(typed, "://") || g_str_has_prefix(typed, "about:") || g_str_has_prefix(typed, "file:"))
		return g_strdup(typed);
	return g_strconcat("https://", typed, NULL);
}

static void on_uri(GObject *object, GParamSpec *spec, gpointer data)
{
	(void)spec;
	(void)data;
	if (tab_of(WEBKIT_WEB_VIEW(object)) != browser.active)
		return;
	if (!browser.editing)
		show_uri();
	draw_toolbar();
}

static void on_title(GObject *object, GParamSpec *spec, gpointer data)
{
	(void)spec;
	(void)data;
	const char *title = webkit_web_view_get_title(WEBKIT_WEB_VIEW(object));
	printf("orange-browser: title \"%s\"\n", title ? title : "");
	fflush(stdout);
	draw_tabs();
}

static void on_progress(GObject *object, GParamSpec *spec, gpointer data)
{
	(void)spec;
	(void)data;
	int index = tab_of(WEBKIT_WEB_VIEW(object));
	if (index < 0)
		return;
	browser.tabs[index].progress = webkit_web_view_get_estimated_load_progress(WEBKIT_WEB_VIEW(object));
	if (index == browser.active)
		draw_toolbar();
}

static void on_load(WebKitWebView *view, WebKitLoadEvent event, gpointer data)
{
	(void)data;
	if (event != WEBKIT_LOAD_FINISHED)
		return;
	const char *title = webkit_web_view_get_title(view);
	printf("orange-browser: loaded %s title=\"%s\"\n", webkit_web_view_get_uri(view), title ? title : "");
	fflush(stdout);
	draw_tabs();
	if (tab_of(view) == browser.active)
		draw_toolbar();
}

static gboolean on_failed(WebKitWebView *view, WebKitLoadEvent event, char *uri, GError *error, gpointer data)
{
	(void)view;
	(void)event;
	(void)data;
	printf("orange-browser: failed %s: %s\n", uri, error->message);
	fflush(stdout);
	return FALSE; /* WebKit shows its error page */
}

static void close_tab(int index);
static WebKitWebView *on_create(WebKitWebView *web_view, WebKitNavigationAction *action, gpointer data);

static void on_close(WebKitWebView *web_view, gpointer data)
{
	(void)data;
	int index = tab_of(web_view);
	if (index >= 0)
		close_tab(index);
}

static void add_tab(WebKitWebView *web_view)
{
	Tab *tab = &browser.tabs[browser.count++];
	tab->web_view = web_view;
	tab->view = webkit_web_view_get_wpe_view(web_view);
	tab->progress = 0;
	g_signal_connect(web_view, "notify::uri", G_CALLBACK(on_uri), NULL);
	g_signal_connect(web_view, "notify::title", G_CALLBACK(on_title), NULL);
	g_signal_connect(web_view, "notify::estimated-load-progress", G_CALLBACK(on_progress), NULL);
	g_signal_connect(web_view, "load-changed", G_CALLBACK(on_load), NULL);
	g_signal_connect(web_view, "load-failed", G_CALLBACK(on_failed), NULL);
	g_signal_connect(web_view, "create", G_CALLBACK(on_create), NULL);
	g_signal_connect(web_view, "close", G_CALLBACK(on_close), NULL);
}

/* A new tab that loads `uri` and becomes active; NULL when full. */
static WebKitWebView *open_tab(const char *uri)
{
	if (browser.count == MAX_TABS)
		return NULL;
	WebKitWebView *web_view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "display", browser.display, "settings", browser.settings,
	                                       "network-session", browser.session, NULL);
	add_tab(web_view);
	activate(browser.count - 1);
	if (uri) {
		char *url = address_to_url(uri);
		webkit_web_view_load_uri(web_view, url);
		g_free(url);
	}
	return web_view;
}

/* A page opens a window: it becomes a tab sharing the opener's web
 * process, which WebKit then loads. */
static WebKitWebView *on_create(WebKitWebView *web_view, WebKitNavigationAction *action, gpointer data)
{
	(void)action;
	(void)data;
	if (browser.count == MAX_TABS)
		return NULL;
	WebKitWebView *created = g_object_new(WEBKIT_TYPE_WEB_VIEW, "related-view", web_view, "display", browser.display,
	                                      "settings", browser.settings, NULL);
	add_tab(g_object_ref(created));
	activate(browser.count - 1);
	return created;
}

static void close_tab(int index)
{
	Tab closing = browser.tabs[index];
	memmove(&browser.tabs[index], &browser.tabs[index + 1], sizeof(Tab) * (size_t)(browser.count - index - 1));
	browser.count--;
	g_signal_handlers_disconnect_by_data(closing.web_view, NULL);
	orange_view_set_active(closing.view, FALSE);
	g_object_unref(closing.web_view);
	if (browser.count == 0) {
		printf("orange-browser: last tab closed\n");
		fflush(stdout);
		g_main_loop_quit(browser.loop);
		return;
	}
	int next = browser.active;
	if (index < browser.active || next >= browser.count)
		next = MAX(next - 1, 0);
	activate(MIN(next, browser.count - 1));
}

static void navigate(void)
{
	char *url = address_to_url(browser.address->str);
	webkit_web_view_load_uri(ACTIVE->web_view, url);
	g_free(url);
	browser.editing = FALSE;
	wpe_view_focus_in(ACTIVE->view);
	show_uri();
	draw_toolbar();
}

static void edit_address(gboolean clear)
{
	browser.editing = TRUE;
	browser.replace = !clear;
	if (clear)
		g_string_truncate(browser.address, 0);
	wpe_view_focus_out(ACTIVE->view);
	draw_toolbar();
}

/* ── Input ───────────────────────────────────────────────────────────────── */

static guint32 now_ms(void)
{
	return (guint32)(g_get_monotonic_time() / 1000);
}

static void address_key(guint keyval)
{
	switch (keyval) {
	case 0xff0d: /* Return */
	case 0xff8d:
		navigate();
		return;
	case 0xff1b: /* Escape: back to the page, address restored */
		browser.editing = FALSE;
		show_uri();
		wpe_view_focus_in(ACTIVE->view);
		break;
	case 0xff08: /* BackSpace */
		if (browser.address->len)
			g_string_truncate(browser.address, browser.address->len - 1);
		break;
	default:
		if (keyval >= 0x20 && keyval < 0x7f && !(browser.modifiers & (WPE_MODIFIER_KEYBOARD_CONTROL | WPE_MODIFIER_KEYBOARD_ALT))) {
			if (browser.replace)
				g_string_truncate(browser.address, 0);
			g_string_append_c(browser.address, (char)keyval);
		}
		break;
	}
	browser.replace = FALSE;
	draw_toolbar();
}

/* Browser shortcuts; TRUE when the key was one. */
static gboolean shortcut(guint keyval)
{
	if (!(browser.modifiers & WPE_MODIFIER_KEYBOARD_CONTROL))
		return FALSE;
	switch (keyval) {
	case 'l':
	case 'L':
		edit_address(TRUE);
		return TRUE;
	case 't':
	case 'T':
		if (open_tab(START_PAGE))
			edit_address(TRUE);
		return TRUE;
	case 'w':
	case 'W':
		close_tab(browser.active);
		return TRUE;
	case 0xff09: /* Tab */
	case 0xfe20: /* ISO_Left_Tab (Shift+Tab) */
		if (browser.count > 1) {
			int step = (browser.modifiers & WPE_MODIFIER_KEYBOARD_SHIFT) || keyval == 0xfe20 ? browser.count - 1 : 1;
			activate((browser.active + step) % browser.count);
		}
		return TRUE;
	default:
		return FALSE;
	}
}

static void handle_key(const PeelEvent *e)
{
	gboolean pressed = e->value & 1, extended = (e->value & 2) != 0;
	WPEModifiers modifier = orange_key_modifier(e->code, extended);
	if (modifier) {
		browser.modifiers = pressed ? browser.modifiers | modifier : browser.modifiers & ~modifier;
	} else if (e->code == 0x3A && !extended && pressed) {
		browser.modifiers ^= WPE_MODIFIER_KEYBOARD_CAPS_LOCK;
	}
	guint keycode = 0, keyval = 0;
	if (!orange_key_translate(e->code, extended, browser.modifiers, &keycode, &keyval))
		return;
	if (pressed && !modifier && shortcut(keyval))
		return;
	if (browser.editing) {
		if (pressed && !modifier)
			address_key(keyval);
		return;
	}
	WPEEvent *event = wpe_event_keyboard_new(pressed ? WPE_EVENT_KEYBOARD_KEY_DOWN : WPE_EVENT_KEYBOARD_KEY_UP, ACTIVE->view,
	                                         WPE_INPUT_SOURCE_KEYBOARD, now_ms(), browser.modifiers, keycode, keyval);
	wpe_view_event(ACTIVE->view, event);
	wpe_event_unref(event);
}

static void tabbar_click(int x, int y)
{
	(void)y;
	const int w = tab_width();
	for (int i = 0; i < browser.count; i++) {
		if (x < tab_x(i) || x >= tab_x(i) + w - 4)
			continue;
		if (x >= tab_x(i) + w - 4 - 26)
			close_tab(i);
		else if (i != browser.active)
			activate(i);
		return;
	}
	if (browser.count < MAX_TABS && x >= plus_x() && x < plus_x() + 28 && open_tab(START_PAGE))
		edit_address(TRUE);
}

static void toolbar_click(int x, int y)
{
	(void)y;
	WebKitWebView *web_view = ACTIVE->web_view;
	for (int b = 0; b < BUTTON_COUNT; b++) {
		if (x < button_x(b) || x >= button_x(b) + 32)
			continue;
		if (b == BUTTON_BACK)
			webkit_web_view_go_back(web_view);
		else if (b == BUTTON_FORWARD)
			webkit_web_view_go_forward(web_view);
		else
			webkit_web_view_reload(web_view);
		return;
	}
	if (x >= field_x())
		edit_address(FALSE);
}

/* Peel reports held buttons (1 left, 2 right, 4 middle); WPE numbers them
 * 1 left, 2 middle, 3 right. */
static const struct { guint32 mask; guint button; WPEModifiers modifier; } mouse_buttons[] = {
	{ 1, 1, WPE_MODIFIER_POINTER_BUTTON1 },
	{ 4, 2, WPE_MODIFIER_POINTER_BUTTON2 },
	{ 2, 3, WPE_MODIFIER_POINTER_BUTTON3 },
};

static void handle_mouse(const PeelEvent *e)
{
	guint32 changed = e->code ^ browser.buttons, pressed = changed & e->code;
	browser.buttons = e->code;
	if (e->y < TABBAR) {
		if (pressed & 1)
			tabbar_click(e->x, e->y);
		return;
	}
	if (e->y < CONTENT_Y) {
		if (pressed & 1)
			toolbar_click(e->x, e->y);
		return;
	}
	WPEView *view = ACTIVE->view;
	double x = e->x, y = e->y - CONTENT_Y;
	WPEModifiers held = browser.modifiers;
	for (gsize i = 0; i < G_N_ELEMENTS(mouse_buttons); i++)
		if (e->code & mouse_buttons[i].mask)
			held |= mouse_buttons[i].modifier;
	if (pressed && browser.editing) {
		browser.editing = FALSE;
		show_uri();
		draw_toolbar();
	}
	if (pressed)
		wpe_view_focus_in(view);
	WPEEvent *move = wpe_event_pointer_move_new(WPE_EVENT_POINTER_MOVE, view, WPE_INPUT_SOURCE_MOUSE, now_ms(), held, x, y, 0, 0);
	wpe_view_event(view, move);
	wpe_event_unref(move);
	for (gsize i = 0; i < G_N_ELEMENTS(mouse_buttons); i++) {
		if (!(changed & mouse_buttons[i].mask))
			continue;
		gboolean down = (e->code & mouse_buttons[i].mask) != 0;
		WPEEvent *button = wpe_event_pointer_button_new(down ? WPE_EVENT_POINTER_DOWN : WPE_EVENT_POINTER_UP, view,
		                                                WPE_INPUT_SOURCE_MOUSE, now_ms(), held, mouse_buttons[i].button, x, y,
		                                                down ? 1 : 0);
		wpe_view_event(view, button);
		wpe_event_unref(button);
	}
}

/* Wheel steps (a signed byte, positive towards the user) as WPE scroll
 * steps, which count the other way, as WPE's own DRM backend passes them. */
static void handle_wheel(const PeelEvent *e)
{
	if (e->y < CONTENT_Y)
		return;
	int steps = (int8_t)e->code;
	WPEEvent *scroll = wpe_event_scroll_new(ACTIVE->view, WPE_INPUT_SOURCE_MOUSE, now_ms(), browser.modifiers, 0, -steps,
	                                        FALSE, FALSE, e->x, e->y - CONTENT_Y);
	wpe_view_event(ACTIVE->view, scroll);
	wpe_event_unref(scroll);
}

static gboolean dispatch(gpointer data)
{
	PeelEvent *e = data;
	if (e->kind == 1)
		handle_key(e);
	else if (e->kind == 2)
		handle_mouse(e);
	else if (e->kind == 4)
		handle_wheel(e);
	else if (e->kind == 3)
		g_main_loop_quit(browser.loop);
	return G_SOURCE_REMOVE;
}

/* Waits on Peel's port, which GLib cannot poll, and queues each event. */
static gpointer input_thread(gpointer data)
{
	(void)data;
	for (;;) {
		PeelEvent *e = g_new(PeelEvent, 1);
		if (orange_peel_next_event(e, 1) != 1) {
			g_free(e);
			return NULL;
		}
		g_main_context_invoke_full(NULL, G_PRIORITY_DEFAULT, dispatch, e, g_free);
	}
}

int main(int argc, char **argv)
{
	/* Software rendering; website data on the data disk when there is one. */
	g_setenv("WEBKIT_SKIA_ENABLE_CPU_RENDERING", "1", TRUE);
	const char *data_dir = access("/data", W_OK) == 0 && g_mkdir_with_parents(SAVED_PROFILE, 0700) == 0 ? SAVED_PROFILE : PROFILE "/data";
	g_setenv("HOME", PROFILE, TRUE);
	g_setenv("XDG_CACHE_HOME", PROFILE "/cache", TRUE);
	g_setenv("XDG_DATA_HOME", data_dir, TRUE);
	g_setenv("XDG_RUNTIME_DIR", PROFILE "/run", TRUE);
	g_mkdir_with_parents(PROFILE "/run", 0700);
	/* Where video downloads are buffered (WebKit's default, /var/tmp, is on
	 * the read-only root). */
	g_setenv("WPE_SHELL_MEDIA_DISK_CACHE_PATH", PROFILE "/media", TRUE);
	g_mkdir_with_parents(PROFILE "/media", 0700);
	printf("orange-browser: website data in %s\n", data_dir);

	if (orange_peel_open("Orange Browser", WINDOW_WIDTH, WINDOW_HEIGHT, &browser.window) != 0) {
		fprintf(stderr, "orange-browser: no display\n");
		return 1;
	}
	if (FT_Init_FreeType(&browser.freetype) || FT_New_Face(browser.freetype, FONT, 0, &browser.face)) {
		fprintf(stderr, "orange-browser: cannot load %s\n", FONT);
		return 1;
	}
	browser.address = g_string_new(NULL);
	fill(0, 0, browser.window.width, browser.window.height, 0xFFFFFF);
	orange_peel_commit(0, 0, browser.window.width, browser.window.height);

	OrangeSurface surface = {
		.pixels = browser.window.pixels, .stride = browser.window.stride, .scale = browser.window.scale,
		.x = 0, .y = CONTENT_Y, .width = browser.window.width, .height = browser.window.height - CONTENT_Y,
	};
	browser.display = orange_display_new(&surface, commit_content);
	GError *error = NULL;
	if (!wpe_display_connect(browser.display, &error)) {
		fprintf(stderr, "orange-browser: display: %s\n", error->message);
		return 1;
	}
	wpe_display_set_primary(browser.display);

	browser.settings = webkit_settings_new();
	webkit_settings_set_enable_webgl(browser.settings, FALSE);
	/* Debug images (ORANGE_BROWSER_CONSOLE=1 scripts/mkdisk.sh): page
	 * console messages go to standard output, which is the serial log. */
	if (access(CONSOLE_FLAG, F_OK) == 0) {
		webkit_settings_set_enable_write_console_messages_to_stdout(browser.settings, TRUE);
		/* GStreamer's warnings and errors, in the web process too. */
		g_setenv("GST_DEBUG", "3", FALSE);
	}
	printf("orange-browser: user agent \"%s\"\n", webkit_settings_get_user_agent(browser.settings));
	browser.session = webkit_network_session_new(data_dir, PROFILE "/cache");
	/* Cookies in SQLite beside the rest of the website data. */
	char *cookies = g_build_filename(data_dir, "cookies.sqlite", NULL);
	webkit_cookie_manager_set_persistent_storage(webkit_network_session_get_cookie_manager(browser.session), cookies,
	                                             WEBKIT_COOKIE_PERSISTENT_STORAGE_SQLITE);
	g_free(cookies);
	/* Test images only: trust the host fixture's certificate for its
	 * address (tools/browser_smoke.py). Nothing else is exempted, and
	 * ordinary images have no such file. */
	GTlsCertificate *allowed = g_tls_certificate_new_from_file(TEST_CERTIFICATE, NULL);
	if (allowed) {
		webkit_network_session_allow_tls_certificate_for_host(browser.session, allowed, "10.0.2.2");
		printf("orange-browser: test certificate allowed for 10.0.2.2\n");
		g_object_unref(allowed);
	}

	const char *first = argc > 1 ? argv[1] : START_PAGE;
	open_tab(first);
	g_string_assign(browser.address, first);
	draw_toolbar();

	browser.loop = g_main_loop_new(NULL, FALSE);
	g_thread_unref(g_thread_new("peel-input", input_thread, NULL));
	g_main_loop_run(browser.loop);
	orange_peel_close();
	return 0;
}
