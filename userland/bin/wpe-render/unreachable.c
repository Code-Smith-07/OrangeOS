/* Handlers WPE WebKit 2.54 references but never builds.
 *
 * WPE generates IPC receivers for GTK's pinch-zoom gesture messages
 * (ViewGestureController, ViewGestureGeometryCollector) without compiling
 * the classes that handle them; as a shared library that goes unnoticed,
 * and no WPE code sends those messages. A static program must resolve the
 * names, so they are defined here to stop loudly if one is ever reached.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <stdio.h>
#include <stdlib.h>

__attribute__((noreturn)) static void unreachable(const char *what)
{
	fprintf(stderr, "wpe: %s reached; it is not part of WPE WebKit's build\n", what);
	abort();
}

#define UNREACHABLE(symbol, what) \
	void symbol##_stub(void) __asm__(#symbol); \
	void symbol##_stub(void) { unreachable(what); }

UNREACHABLE(_ZN6WebKit21ViewGestureController29didHitRenderTreeSizeThresholdEv,
            "ViewGestureController::didHitRenderTreeSizeThreshold")
UNREACHABLE(_ZN6WebKit21ViewGestureController41didCollectGeometryForMagnificationGestureEN7WebCore9FloatRectEb,
            "ViewGestureController::didCollectGeometryForMagnificationGesture")
UNREACHABLE(_ZN6WebKit28ViewGestureGeometryCollector38collectGeometryForMagnificationGestureEv,
            "ViewGestureGeometryCollector::collectGeometryForMagnificationGesture")
UNREACHABLE(_ZN6WebKit28ViewGestureGeometryCollector38setRenderTreeSizeNotificationThresholdEm,
            "ViewGestureGeometryCollector::setRenderTreeSizeNotificationThreshold")
