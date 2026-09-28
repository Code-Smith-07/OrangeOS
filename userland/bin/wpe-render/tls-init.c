/* Start-up for every WPE process on OrangeOS, which links WebKit statically.
 *
 * - Registers glib-networking's OpenSSL TLS backend before main runs: GIO
 *   cannot load it as a module without dlopen (docs/design/012, W5).
 * - Keeps WebKit's compiled-in resources: each GResource bundle registers
 *   itself from a constructor, and nothing else names its object file, so a
 *   static link would otherwise leave it out. Without them, form controls
 *   lose their theme and built-in pages (the PDF viewer) their files.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <gio/gio.h>

void g_io_openssl_load(GIOModule *module);
GResource *WebKitResourcesGResourceBundle_get_resource(void);
GResource *PdfJSGResourceBundle_get_resource(void);
GResource *PdfJSGResourceBundleExtras_get_resource(void);

__attribute__((used)) static GResource *(*const orange_resource_bundles[])(void) = {
	WebKitResourcesGResourceBundle_get_resource,
	PdfJSGResourceBundle_get_resource,
	PdfJSGResourceBundleExtras_get_resource,
};

__attribute__((constructor)) static void orange_register_tls(void)
{
	g_io_openssl_load(NULL);
}
