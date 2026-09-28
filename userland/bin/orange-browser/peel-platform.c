/* WPE Platform on Peel: display, view, toplevel and keymap.
 * See peel-platform.h.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include "peel-platform.h"

#include <string.h>

/* ── Keyboard: set-1 scancodes, US layout ─────────────────────────────────── */

/* Keysyms (X11/XKB values) for scancodes 0x00-0x58 without and with Shift.
 * Printable keys use their Latin-1 code point, as XKB keysyms do. */
static const guint16 plain[0x59] = {
	[0x01] = 0xff1b, ['\x02'] = '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', [0x0E] = 0xff08,
	[0x0F] = 0xff09, 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', [0x1C] = 0xff0d,
	[0x1D] = 0xffe3, [0x1E] = 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
	[0x2A] = 0xffe1, [0x2B] = '\\', [0x2C] = 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
	[0x36] = 0xffe2, [0x37] = 0xffaa, [0x38] = 0xffe9, [0x39] = ' ', [0x3A] = 0xffe5,
	[0x3B] = 0xffbe, 0xffbf, 0xffc0, 0xffc1, 0xffc2, 0xffc3, 0xffc4, 0xffc5, 0xffc6, 0xffc7,
	[0x57] = 0xffc8, [0x58] = 0xffc9,
};
static const guint16 shifted[0x59] = {
	[0x02] = '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+',
	[0x10] = 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}',
	[0x1E] = 'A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~',
	[0x2B] = '|', [0x2C] = 'Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?',
};

/* Extended (E0) scancodes: evdev keycode and keysym. */
static const struct { guint8 scancode, evdev; guint16 keysym; } extended_keys[] = {
	{ 0x1C, 96, 0xff8d },  /* KP_Enter */
	{ 0x1D, 97, 0xffe4 },  /* Control_R */
	{ 0x35, 98, 0xffaf },  /* KP_Divide */
	{ 0x38, 100, 0xffea }, /* Alt_R */
	{ 0x47, 102, 0xff50 }, /* Home */
	{ 0x48, 103, 0xff52 }, /* Up */
	{ 0x49, 104, 0xff55 }, /* Page_Up */
	{ 0x4B, 105, 0xff51 }, /* Left */
	{ 0x4D, 106, 0xff53 }, /* Right */
	{ 0x4F, 107, 0xff57 }, /* End */
	{ 0x50, 108, 0xff54 }, /* Down */
	{ 0x51, 109, 0xff56 }, /* Page_Down */
	{ 0x52, 110, 0xff63 }, /* Insert */
	{ 0x53, 111, 0xffff }, /* Delete */
	{ 0x5B, 125, 0xffeb }, /* Super_L */
	{ 0x5C, 126, 0xffec }, /* Super_R */
};

static gboolean is_letter(guint16 keysym)
{
	return keysym >= 'a' && keysym <= 'z';
}

gboolean orange_key_translate(guint scancode, gboolean extended, WPEModifiers modifiers, guint *keycode, guint *keyval)
{
	if (extended) {
		for (gsize i = 0; i < G_N_ELEMENTS(extended_keys); i++) {
			if (extended_keys[i].scancode != scancode)
				continue;
			*keycode = extended_keys[i].evdev + 8;
			*keyval = extended_keys[i].keysym;
			return TRUE;
		}
		return FALSE;
	}
	if (scancode >= G_N_ELEMENTS(plain) || !plain[scancode])
		return FALSE;
	/* For these keys, the set-1 scancode is the evdev keycode. */
	*keycode = scancode + 8;
	gboolean shift = (modifiers & WPE_MODIFIER_KEYBOARD_SHIFT) != 0;
	/* Caps Lock inverts Shift for letters only. */
	if (is_letter(plain[scancode]) && (modifiers & WPE_MODIFIER_KEYBOARD_CAPS_LOCK))
		shift = !shift;
	*keyval = shift && shifted[scancode] ? shifted[scancode] : plain[scancode];
	return TRUE;
}

WPEModifiers orange_key_modifier(guint scancode, gboolean extended)
{
	switch (scancode) {
	case 0x1D:
		return WPE_MODIFIER_KEYBOARD_CONTROL;
	case 0x2A:
	case 0x36:
		return extended ? 0 : WPE_MODIFIER_KEYBOARD_SHIFT;
	case 0x38:
		return WPE_MODIFIER_KEYBOARD_ALT;
	case 0x5B:
	case 0x5C:
		return extended ? WPE_MODIFIER_KEYBOARD_META : 0;
	default:
		return 0;
	}
}

struct _OrangeKeymap {
	WPEKeymap parent;
};

G_DEFINE_FINAL_TYPE(OrangeKeymap, orange_keymap, WPE_TYPE_KEYMAP)

static gboolean keymap_entries_for_keyval(WPEKeymap *keymap, guint keyval, WPEKeymapEntry **entries, guint *n_entries)
{
	(void)keymap;
	GArray *found = g_array_new(FALSE, FALSE, sizeof(WPEKeymapEntry));
	for (guint code = 0; code < G_N_ELEMENTS(plain); code++) {
		if (plain[code] == keyval) {
			WPEKeymapEntry entry = { .keycode = code + 8, .group = 0, .level = 0 };
			g_array_append_val(found, entry);
		}
		if (shifted[code] && shifted[code] == keyval) {
			WPEKeymapEntry entry = { .keycode = code + 8, .group = 0, .level = 1 };
			g_array_append_val(found, entry);
		}
	}
	for (gsize i = 0; i < G_N_ELEMENTS(extended_keys); i++) {
		if (extended_keys[i].keysym == keyval) {
			WPEKeymapEntry entry = { .keycode = extended_keys[i].evdev + 8u, .group = 0, .level = 0 };
			g_array_append_val(found, entry);
		}
	}
	*n_entries = found->len;
	*entries = (WPEKeymapEntry *)g_array_free(found, found->len == 0);
	return *n_entries > 0;
}

static gboolean keymap_translate(WPEKeymap *keymap, guint keycode, WPEModifiers modifiers, int group, guint *keyval,
                                 int *effective_group, int *level, WPEModifiers *consumed)
{
	(void)keymap;
	(void)group;
	if (keycode < 8)
		return FALSE;
	guint evdev = keycode - 8, scancode = evdev, code = 0, value = 0;
	gboolean extended = FALSE;
	for (gsize i = 0; i < G_N_ELEMENTS(extended_keys); i++) {
		if (extended_keys[i].evdev == evdev) {
			scancode = extended_keys[i].scancode;
			extended = TRUE;
		}
	}
	if (!orange_key_translate(scancode, extended, modifiers, &code, &value))
		return FALSE;
	gboolean shifted_level = !extended && scancode < G_N_ELEMENTS(shifted) && shifted[scancode] && value == shifted[scancode];
	if (keyval)
		*keyval = value;
	if (effective_group)
		*effective_group = 0;
	if (level)
		*level = shifted_level ? 1 : 0;
	if (consumed)
		*consumed = shifted_level ? WPE_MODIFIER_KEYBOARD_SHIFT : 0;
	return TRUE;
}

static WPEModifiers keymap_modifiers(WPEKeymap *keymap)
{
	(void)keymap;
	return 0;
}

static void orange_keymap_class_init(OrangeKeymapClass *klass)
{
	WPEKeymapClass *keymap_class = WPE_KEYMAP_CLASS(klass);
	keymap_class->get_entries_for_keyval = keymap_entries_for_keyval;
	keymap_class->translate_keyboard_state = keymap_translate;
	keymap_class->get_modifiers = keymap_modifiers;
}

static void orange_keymap_init(OrangeKeymap *keymap)
{
	(void)keymap;
}

/* ── Display ─────────────────────────────────────────────────────────────── */

struct _OrangeDisplay {
	WPEDisplay parent;
	OrangeSurface surface;
	void (*commit)(int x, int y, int width, int height);
	WPEKeymap *keymap;
};

G_DEFINE_FINAL_TYPE(OrangeDisplay, orange_display, WPE_TYPE_DISPLAY)

static gboolean display_connect(WPEDisplay *display, GError **error)
{
	(void)display;
	(void)error;
	return TRUE;
}

static WPEView *display_create_view(WPEDisplay *display)
{
	return WPE_VIEW(g_object_new(ORANGE_TYPE_VIEW, "display", display, NULL));
}

static WPEToplevel *display_create_toplevel(WPEDisplay *display, guint max_views)
{
	(void)max_views;
	return WPE_TOPLEVEL(g_object_new(ORANGE_TYPE_TOPLEVEL, "display", display, NULL));
}

static WPEKeymap *display_get_keymap(WPEDisplay *display)
{
	OrangeDisplay *self = ORANGE_DISPLAY(display);
	if (!self->keymap)
		self->keymap = WPE_KEYMAP(g_object_new(ORANGE_TYPE_KEYMAP, NULL));
	return self->keymap;
}

/* No EGL and no DRM device: WebKit renders into shared memory. */
static gpointer display_get_egl_display(WPEDisplay *display, GError **error)
{
	(void)display;
	g_set_error_literal(error, WPE_EGL_ERROR, WPE_EGL_ERROR_NOT_AVAILABLE, "OrangeOS has no EGL");
	return NULL;
}

static WPEDRMDevice *display_get_drm_device(WPEDisplay *display)
{
	(void)display;
	return NULL;
}

static void display_dispose(GObject *object)
{
	g_clear_object(&ORANGE_DISPLAY(object)->keymap);
	G_OBJECT_CLASS(orange_display_parent_class)->dispose(object);
}

static void orange_display_class_init(OrangeDisplayClass *klass)
{
	G_OBJECT_CLASS(klass)->dispose = display_dispose;
	WPEDisplayClass *display_class = WPE_DISPLAY_CLASS(klass);
	display_class->connect = display_connect;
	display_class->create_view = display_create_view;
	display_class->create_toplevel = display_create_toplevel;
	display_class->get_keymap = display_get_keymap;
	display_class->get_egl_display = display_get_egl_display;
	display_class->get_drm_device = display_get_drm_device;
}

static void orange_display_init(OrangeDisplay *display)
{
	(void)display;
}

WPEDisplay *orange_display_new(const OrangeSurface *surface, void (*commit)(int x, int y, int width, int height))
{
	OrangeDisplay *display = g_object_new(ORANGE_TYPE_DISPLAY, NULL);
	display->surface = *surface;
	display->commit = commit;
	return WPE_DISPLAY(display);
}

/* ── Toplevel ────────────────────────────────────────────────────────────── */

struct _OrangeToplevel {
	WPEToplevel parent;
};

G_DEFINE_FINAL_TYPE(OrangeToplevel, orange_toplevel, WPE_TYPE_TOPLEVEL)

static void toplevel_constructed(GObject *object)
{
	G_OBJECT_CLASS(orange_toplevel_parent_class)->constructed(object);
	WPEToplevel *toplevel = WPE_TOPLEVEL(object);
	OrangeDisplay *display = ORANGE_DISPLAY(wpe_toplevel_get_display(toplevel));
	/* Peel windows keep their size; the content area is the toplevel. */
	wpe_toplevel_resized(toplevel, display->surface.width, display->surface.height);
	wpe_toplevel_scale_changed(toplevel, display->surface.scale);
	wpe_toplevel_state_changed(toplevel, WPE_TOPLEVEL_STATE_ACTIVE);
}

static gboolean toplevel_resize(WPEToplevel *toplevel, int width, int height)
{
	(void)toplevel;
	(void)width;
	(void)height;
	return FALSE;
}

static void orange_toplevel_class_init(OrangeToplevelClass *klass)
{
	G_OBJECT_CLASS(klass)->constructed = toplevel_constructed;
	WPE_TOPLEVEL_CLASS(klass)->resize = toplevel_resize;
}

static void orange_toplevel_init(OrangeToplevel *toplevel)
{
	(void)toplevel;
}

/* ── View ────────────────────────────────────────────────────────────────── */

struct _OrangeView {
	WPEView parent;
	WPEBuffer *shown;
	gboolean active;
	/* The last frame, in buffer pixels (0x00RRGGBB). */
	uint32_t *frame;
	int frame_width, frame_height;
};

G_DEFINE_FINAL_TYPE(OrangeView, orange_view, WPE_TYPE_VIEW)

static void view_toplevel_changed(WPEView *view, GParamSpec *spec, gpointer data)
{
	(void)spec;
	(void)data;
	WPEToplevel *toplevel = wpe_view_get_toplevel(view);
	if (!toplevel) {
		wpe_view_unmap(view);
		return;
	}
	int width = 0, height = 0;
	wpe_toplevel_get_size(toplevel, &width, &height);
	if (width && height)
		wpe_view_resized(view, width, height);
	wpe_view_map(view);
}

static void view_constructed(GObject *object)
{
	G_OBJECT_CLASS(orange_view_parent_class)->constructed(object);
	g_signal_connect(object, "notify::toplevel", G_CALLBACK(view_toplevel_changed), NULL);
}

/* The frame is copied out at once, so it can go back to WebKit as soon as
 * the main loop runs again (not from inside render_buffer). */
static gboolean view_release(gpointer data)
{
	OrangeView *self = ORANGE_VIEW(data);
	if (self->shown) {
		wpe_view_buffer_rendered(WPE_VIEW(self), self->shown);
		wpe_view_buffer_released(WPE_VIEW(self), self->shown);
		g_clear_object(&self->shown);
	}
	g_object_unref(self);
	return G_SOURCE_REMOVE;
}

/* The view's last frame into the window's content area, or white. */
static void view_show_frame(OrangeView *self)
{
	OrangeDisplay *display = ORANGE_DISPLAY(wpe_view_get_display(WPE_VIEW(self)));
	const OrangeSurface *s = &display->surface;
	const int width = s->width * s->scale, height = s->height * s->scale;
	for (int row = 0; row < height; row++) {
		uint32_t *to = s->pixels + (gsize)(s->y * s->scale + row) * s->stride + s->x * s->scale;
		int copied = 0;
		if (self->frame && row < self->frame_height) {
			copied = MIN(width, self->frame_width);
			memcpy(to, self->frame + (gsize)row * self->frame_width, (gsize)copied * 4);
		}
		for (int column = copied; column < width; column++)
			to[column] = 0xFFFFFF;
	}
	display->commit(s->x, s->y, s->width, s->height);
}

void orange_view_set_active(WPEView *view, gboolean active)
{
	OrangeView *self = ORANGE_VIEW(view);
	self->active = active;
	/* Hidden views are throttled by WebKit (timers, animation frames). */
	wpe_view_set_visible(view, active);
	if (active)
		view_show_frame(self);
}

static gboolean view_render_buffer(WPEView *view, WPEBuffer *buffer, const WPERectangle *damage, guint n_damage,
                                   GError **error)
{
	(void)damage;
	(void)n_damage;
	if (!WPE_IS_BUFFER_SHM(buffer)) {
		g_set_error_literal(error, WPE_VIEW_ERROR, WPE_VIEW_ERROR_RENDER_FAILED, "only shared-memory buffers");
		return FALSE;
	}
	OrangeDisplay *display = ORANGE_DISPLAY(wpe_view_get_display(view));
	const OrangeSurface *s = &display->surface;
	WPEBufferSHM *shm = WPE_BUFFER_SHM(buffer);
	gsize length = 0;
	const guint8 *data = g_bytes_get_data(wpe_buffer_shm_get_data(shm), &length);
	guint source_stride = wpe_buffer_shm_get_stride(shm);
	int source_width = wpe_buffer_get_width(buffer), source_height = wpe_buffer_get_height(buffer);
	int width = MIN(source_width, s->width * s->scale), height = MIN(source_height, s->height * s->scale);
	OrangeView *self = ORANGE_VIEW(view);
	if (self->frame_width != width || self->frame_height != height) {
		g_free(self->frame);
		self->frame = g_new0(uint32_t, (gsize)width * height);
		self->frame_width = width;
		self->frame_height = height;
	}
	for (int row = 0; row < height && (gsize)(row + 1) * source_stride <= length; row++) {
		/* ARGB8888 in memory order B, G, R, A: the same 32-bit value Peel
		 * reads as 0x00RRGGBB once alpha is ignored. */
		memcpy(self->frame + (gsize)row * width, data + (gsize)row * source_stride, (gsize)width * 4);
	}
	if (self->active)
		view_show_frame(self);

	if (self->shown) {
		wpe_view_buffer_rendered(view, self->shown);
		wpe_view_buffer_released(view, self->shown);
		g_clear_object(&self->shown);
	}
	self->shown = g_object_ref(buffer);
	g_idle_add(view_release, g_object_ref(self));
	return TRUE;
}

static void view_dispose(GObject *object)
{
	g_clear_object(&ORANGE_VIEW(object)->shown);
	g_clear_pointer(&ORANGE_VIEW(object)->frame, g_free);
	G_OBJECT_CLASS(orange_view_parent_class)->dispose(object);
}

static void orange_view_class_init(OrangeViewClass *klass)
{
	G_OBJECT_CLASS(klass)->constructed = view_constructed;
	G_OBJECT_CLASS(klass)->dispose = view_dispose;
	WPE_VIEW_CLASS(klass)->render_buffer = view_render_buffer;
}

static void orange_view_init(OrangeView *view)
{
	(void)view; /* inactive until the program shows it */
}
