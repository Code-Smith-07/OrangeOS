/* Registers glib-networking's OpenSSL TLS backend in every WPE process
 * before main runs: OrangeOS links it statically, so GIO cannot load it
 * as a module (docs/design/012, W5).
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <gio/gio.h>

void g_io_openssl_load(GIOModule *module);

__attribute__((constructor)) static void orange_register_tls(void)
{
	g_io_openssl_load(NULL);
}
