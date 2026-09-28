/* A WPE Platform backend for Peel, OrangeOS's compositor (docs/design/012,
 * W8).
 *
 * WPE WebKit draws each frame into a shared-memory buffer and hands it to
 * the view; this backend copies it into the part of the program's Peel
 * window set aside for web content, and turns Peel's input events into WPE
 * events. Rendering stays on the CPU: the display has no rendering device,
 * so WebKit uses shared memory and Skia (recorded patch 0007).
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#pragma once

#include <stdint.h>
#include <wpe/wpe-platform.h>

G_BEGIN_DECLS

/* Where web content goes in the window, in the window buffer's own pixels. */
typedef struct {
	uint32_t *pixels;  /* 0x00RRGGBB */
	int stride;        /* pixels per buffer row */
	int scale;         /* buffer pixels per logical pixel */
	int x, y;          /* logical position of the content area */
	int width, height; /* logical size of the content area */
} OrangeSurface;

#define ORANGE_TYPE_DISPLAY (orange_display_get_type())
G_DECLARE_FINAL_TYPE(OrangeDisplay, orange_display, ORANGE, DISPLAY, WPEDisplay)

#define ORANGE_TYPE_VIEW (orange_view_get_type())
G_DECLARE_FINAL_TYPE(OrangeView, orange_view, ORANGE, VIEW, WPEView)

#define ORANGE_TYPE_TOPLEVEL (orange_toplevel_get_type())
G_DECLARE_FINAL_TYPE(OrangeToplevel, orange_toplevel, ORANGE, TOPLEVEL, WPEToplevel)

#define ORANGE_TYPE_KEYMAP (orange_keymap_get_type())
G_DECLARE_FINAL_TYPE(OrangeKeymap, orange_keymap, ORANGE, KEYMAP, WPEKeymap)

/* The display for content drawn into `surface`; frames are shown by
 * calling `commit` for the changed logical rectangle. */
WPEDisplay *orange_display_new(const OrangeSurface *surface, void (*commit)(int x, int y, int width, int height));

/* Tabs: only the active view is drawn into the window. Each view keeps its
 * last frame, so making a view active shows it at once. */
void orange_view_set_active(WPEView *view, gboolean active);

/* A set-1 scancode (with its E0 flag) as a Linux/XKB key: the XKB keycode
 * (evdev + 8) and the US-layout keysym for the modifiers. FALSE for keys
 * this layout does not know. */
gboolean orange_key_translate(guint scancode, gboolean extended, WPEModifiers modifiers, guint *keycode, guint *keyval);

/* The modifier a key changes, or 0. */
WPEModifiers orange_key_modifier(guint scancode, gboolean extended);

G_END_DECLS
