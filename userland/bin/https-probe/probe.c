/* HTTPS on OrangeOS: libsoup 3 over GIO's TLS, provided by glib-networking
 * with OpenSSL (docs/design/012-wpe-webkit-browser.md, W5 and B9).
 *
 * The host runs an HTTPS server at 10.0.2.2:38459 with a certificate from
 * a throwaway test CA (tools/wpe/test_certs.sh; the CA certificate is on
 * the disk at /share/wpe-tests/test-ca.pem). This checks that the OpenSSL
 * backend registers without dlopen; that a GET succeeds when that CA is
 * trusted; that the same GET is refused against the system trust store
 * (/etc/ssl/cert.pem, Mozilla's roots), which shows certificates really are
 * verified; and that the system trust store loads.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <gio/gio.h>
#include <libsoup/soup.h>
#include <stdio.h>
#include <string.h>

/* glib-networking's static OpenSSL module (libgioopenssl.a). */
void g_io_openssl_load(GIOModule *module);

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("https-probe: FAIL %s\n", (what));                            \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define URL "https://10.0.2.2:38459/orange"
#define EXPECTED "orange over https\n"

static GBytes *get(SoupSession *session, guint *status, GError **error)
{
	SoupMessage *message = soup_message_new("GET", URL);
	GBytes *body = soup_session_send_and_read(session, message, NULL, error);
	*status = soup_message_get_status(message);
	g_object_unref(message);
	return body;
}

int main(void)
{
	g_io_openssl_load(NULL);
	GTlsBackend *backend = g_tls_backend_get_default();
	CHECK(backend && g_tls_backend_supports_tls(backend), "a TLS backend is registered");
	CHECK(strcmp(G_OBJECT_TYPE_NAME(backend), "GTlsBackendOpenssl") == 0, "the backend is OpenSSL");

	GError *error = NULL;
	GTlsDatabase *system = g_tls_backend_get_default_database(backend);
	CHECK(system != NULL, "system trust store (/etc/ssl/cert.pem)");
	GTlsDatabase *roots = g_tls_file_database_new("/etc/ssl/cert.pem", &error);
	CHECK(roots != NULL && error == NULL, "Mozilla roots parse");
	g_object_unref(roots);

	/* Trusting the test CA: the request succeeds. */
	GTlsDatabase *test_ca = g_tls_file_database_new("/share/wpe-tests/test-ca.pem", &error);
	CHECK(test_ca != NULL, "test CA loads");
	SoupSession *session = soup_session_new_with_options("tls-database", test_ca, "timeout", 20, NULL);
	guint status = 0;
	GBytes *body = get(session, &status, &error);
	if (!body || error) {
		printf("https-probe: FAIL GET with the test CA: %s\n", error ? error->message : "no body");
		return 1;
	}
	gsize length = 0;
	const char *data = g_bytes_get_data(body, &length);
	CHECK(status == 200 && length == strlen(EXPECTED) && memcmp(data, EXPECTED, length) == 0, "response body");
	g_bytes_unref(body);
	/* A second request reuses the connection. */
	body = get(session, &status, &error);
	CHECK(body && !error && status == 200, "second request");
	g_bytes_unref(body);
	g_object_unref(session);

	/* Against the Mozilla roots, the test CA is unknown: refused. */
	session = soup_session_new_with_options("tls-database", system, "timeout", 20, NULL);
	body = get(session, &status, &error);
	CHECK(body == NULL && error != NULL && g_error_matches(error, G_TLS_ERROR, G_TLS_ERROR_BAD_CERTIFICATE),
	      "an unknown CA is refused");
	g_clear_error(&error);
	g_object_unref(session);
	g_object_unref(test_ca);

	printf("https-probe: PASS OpenSSL TLS backend, libsoup GET over TLS with keep-alive, "
	       "certificate verification (unknown CA refused), Mozilla trust store\n");
	return 0;
}
