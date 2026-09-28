/* GLib 2.88 on OrangeOS: the first library of the WPE WebKit stack
 * (docs/design/012-wpe-webkit-browser.md, W1).
 *
 * GLib, GObject and GIO are cross-built as static Linux/musl libraries
 * (tools/wpe/build_deps.py) and linked against OrangeOS's musl. This checks
 * the parts WebKit leans on: strings, Unicode, regular expressions (PCRE2),
 * GVariant and checksums; threads, mutexes, condition variables, queues and
 * a thread pool (futexes underneath); the main loop with timeouts, idle
 * sources, a file-descriptor source and cross-thread wakeups (eventfd);
 * GObject types, properties and signals marshalled through libffi; GIO
 * files, directory listing, streams and zlib conversion; and g_spawn
 * through posix_spawn.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <errno.h>
#include <fcntl.h>
#include <gio/gio.h>
#include <glib-unix.h>
#include <glib.h>
#include <glib-object.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("glib-probe: FAIL %s (errno %d)\n", (what), errno);           \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define CHECK_ERROR(error, what)                                                 \
	do {                                                                         \
		if ((error) != NULL) {                                                   \
			printf("glib-probe: FAIL %s: %s\n", (what), (error)->message);       \
			return 1;                                                            \
		}                                                                        \
	} while (0)

/* ── Core utilities ──────────────────────────────────────────────────────── */

static int core(void)
{
	GString *s = g_string_new("orange");
	g_string_append_printf(s, "-%d-%.2f", 42, 3.14159);
	CHECK(strcmp(s->str, "orange-42-3.14") == 0, "GString printf");
	g_string_free(s, TRUE);

	GHashTable *table = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
	for (int i = 0; i < 1000; i++)
		g_hash_table_insert(table, g_strdup_printf("key%d", i), GINT_TO_POINTER(i + 1));
	CHECK(g_hash_table_size(table) == 1000, "hash table size");
	CHECK(GPOINTER_TO_INT(g_hash_table_lookup(table, "key777")) == 778, "hash table lookup");
	g_hash_table_destroy(table);

	gchar *upper = g_utf8_strup("stra\xc3\x9f" "e \xc3\xa9t\xc3\xa9", -1);
	CHECK(strcmp(upper, "STRASSE \xc3\x89T\xc3\x89") == 0, "Unicode case mapping");
	g_free(upper);
	CHECK(g_utf8_validate("\xe0\xb0\x86\xe0\xb0\xb0\xe0\xb1\x86\xe0\xb0\x82\xe0\xb0\x9c\xe0\xb1\x8d", -1, NULL), "UTF-8 validation");
	CHECK(!g_utf8_validate("\xc3\x28", -1, NULL), "UTF-8 rejection");

	GError *error = NULL;
	GRegex *regex = g_regex_new("(\\w+)@(\\w+)\\.org", G_REGEX_DEFAULT, G_REGEX_MATCH_DEFAULT, &error);
	CHECK_ERROR(error, "GRegex compile");
	GMatchInfo *match = NULL;
	CHECK(g_regex_match(regex, "mail orange@example.org today", 0, &match), "GRegex match");
	gchar *user = g_match_info_fetch(match, 1), *domain = g_match_info_fetch(match, 2);
	CHECK(strcmp(user, "orange") == 0 && strcmp(domain, "example") == 0, "GRegex groups");
	g_free(user);
	g_free(domain);
	g_match_info_free(match);
	gchar *replaced = g_regex_replace(regex, "a@b.org, c@d.org", -1, 0, "\\2:\\1", 0, &error);
	CHECK_ERROR(error, "GRegex replace");
	CHECK(strcmp(replaced, "b:a, d:c") == 0, "GRegex replace result");
	g_free(replaced);
	g_regex_unref(regex);

	GVariant *variant = g_variant_parse(NULL, "{'answer': <42>, 'name': <'orange'>}", NULL, NULL, &error);
	CHECK_ERROR(error, "GVariant parse");
	gint32 answer = 0;
	CHECK(g_variant_lookup(variant, "answer", "i", &answer) && answer == 42, "GVariant lookup");
	GBytes *wire = g_variant_get_data_as_bytes(variant);
	GVariant *copy = g_variant_new_from_bytes(G_VARIANT_TYPE("a{sv}"), wire, TRUE);
	CHECK(g_variant_equal(variant, copy), "GVariant serialisation");
	g_variant_unref(copy);
	g_bytes_unref(wire);
	g_variant_unref(variant);

	gchar *sha = g_compute_checksum_for_string(G_CHECKSUM_SHA256, "abc", -1);
	CHECK(strcmp(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad") == 0, "SHA-256");
	g_free(sha);

	gchar *encoded = g_base64_encode((const guchar *)"OrangeOS", 8);
	CHECK(strcmp(encoded, "T3JhbmdlT1M=") == 0, "base64");
	g_free(encoded);

	GDateTime *now = g_date_time_new_now_utc();
	CHECK(now != NULL && g_date_time_get_year(now) >= 2026, "GDateTime from the real-time clock");
	g_date_time_unref(now);
	return 0;
}

/* ── Threads ─────────────────────────────────────────────────────────────── */

static GMutex counter_lock;
static int counter;

static gpointer add_many(gpointer data)
{
	(void)data;
	for (int i = 0; i < 20000; i++) {
		g_mutex_lock(&counter_lock);
		counter++;
		g_mutex_unlock(&counter_lock);
	}
	return GINT_TO_POINTER(7);
}

static gpointer produce(gpointer data)
{
	GAsyncQueue *queue = data;
	for (int i = 1; i <= 2000; i++)
		g_async_queue_push(queue, GINT_TO_POINTER(i));
	return NULL;
}

static GMutex pool_lock;
static GCond pool_done;
static int pool_finished;

static void pool_task(gpointer data, gpointer user)
{
	(void)user;
	g_usleep(2000);
	g_mutex_lock(&pool_lock);
	pool_finished += GPOINTER_TO_INT(data);
	g_cond_signal(&pool_done);
	g_mutex_unlock(&pool_lock);
}

static int threads(void)
{
	GThread *workers[4];
	for (int i = 0; i < 4; i++)
		workers[i] = g_thread_new("adder", add_many, NULL);
	for (int i = 0; i < 4; i++)
		CHECK(GPOINTER_TO_INT(g_thread_join(workers[i])) == 7, "thread return value");
	CHECK(counter == 80000, "mutex-protected counter");

	GAsyncQueue *queue = g_async_queue_new();
	GThread *producer = g_thread_new("producer", produce, queue);
	long sum = 0;
	for (int i = 0; i < 2000; i++)
		sum += GPOINTER_TO_INT(g_async_queue_pop(queue));
	g_thread_join(producer);
	CHECK(sum == 2000L * 2001 / 2, "async queue");
	CHECK(g_async_queue_timeout_pop(queue, 10000) == NULL, "async queue timeout");
	g_async_queue_unref(queue);

	GError *error = NULL;
	GThreadPool *pool = g_thread_pool_new(pool_task, NULL, 4, FALSE, &error);
	CHECK_ERROR(error, "thread pool");
	for (int i = 1; i <= 16; i++)
		g_thread_pool_push(pool, GINT_TO_POINTER(i), NULL);
	g_mutex_lock(&pool_lock);
	gint64 deadline = g_get_monotonic_time() + 10 * G_TIME_SPAN_SECOND;
	while (pool_finished != 16 * 17 / 2)
		if (!g_cond_wait_until(&pool_done, &pool_lock, deadline))
			break;
	g_mutex_unlock(&pool_lock);
	CHECK(pool_finished == 16 * 17 / 2, "thread pool tasks");
	g_thread_pool_free(pool, FALSE, TRUE);
	return 0;
}

/* ── Main loop ───────────────────────────────────────────────────────────── */

static GMainLoop *loop;
static int timeouts, idles, fd_reads, invoked;
static int wake_pipe[2];

static gboolean on_timeout(gpointer data)
{
	(void)data;
	return ++timeouts < 3 ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

static gboolean on_idle(gpointer data)
{
	(void)data;
	idles++;
	return G_SOURCE_REMOVE;
}

static gboolean on_readable(gint fd, GIOCondition condition, gpointer data)
{
	(void)data;
	char byte;
	if ((condition & G_IO_IN) && read(fd, &byte, 1) == 1 && byte == 'w')
		fd_reads++;
	return G_SOURCE_REMOVE;
}

static gboolean on_invoke(gpointer data)
{
	(void)data;
	invoked++;
	g_main_loop_quit(loop);
	return G_SOURCE_REMOVE;
}

/* Writes to the pipe, then — once the loop has seen it — asks the loop's
 * thread to quit, which wakes a loop sleeping in poll(). */
static gpointer poke_loop(gpointer data)
{
	GMainContext *context = data;
	g_usleep(60000);
	if (write(wake_pipe[1], "w", 1) != 1)
		return NULL;
	g_usleep(60000);
	g_main_context_invoke(context, on_invoke, NULL);
	return NULL;
}

static int main_loop(void)
{
	GError *error = NULL;
	CHECK(g_unix_open_pipe(wake_pipe, O_CLOEXEC, &error), "g_unix_open_pipe");
	GMainContext *context = g_main_context_default();
	loop = g_main_loop_new(context, FALSE);
	g_timeout_add(20, on_timeout, NULL);
	g_idle_add(on_idle, NULL);
	g_unix_fd_add(wake_pipe[0], G_IO_IN, on_readable, NULL);
	gint64 start = g_get_monotonic_time();
	GThread *poker = g_thread_new("poker", poke_loop, context);
	g_main_loop_run(loop);
	gint64 elapsed = g_get_monotonic_time() - start;
	g_thread_join(poker);
	g_main_loop_unref(loop);
	close(wake_pipe[0]);
	close(wake_pipe[1]);
	CHECK(timeouts == 3, "repeating timeout source");
	CHECK(idles == 1, "idle source");
	CHECK(fd_reads == 1, "file-descriptor source");
	CHECK(invoked == 1, "cross-thread invoke");
	CHECK(elapsed >= 100000 && elapsed < 5 * G_USEC_PER_SEC, "main loop timing");
	return 0;
}

/* ── GObject ─────────────────────────────────────────────────────────────── */

#define ORANGE_TYPE_COUNTER (orange_counter_get_type())
G_DECLARE_FINAL_TYPE(OrangeCounter, orange_counter, ORANGE, COUNTER, GObject)

struct _OrangeCounter {
	GObject parent;
	int count;
};

enum { PROP_COUNT = 1 };
static guint changed_signal;
static int finalized;

G_DEFINE_TYPE(OrangeCounter, orange_counter, G_TYPE_OBJECT)

static void orange_counter_set_property(GObject *object, guint id, const GValue *value, GParamSpec *spec)
{
	OrangeCounter *self = ORANGE_COUNTER(object);
	if (id != PROP_COUNT) {
		G_OBJECT_WARN_INVALID_PROPERTY_ID(object, id, spec);
		return;
	}
	self->count = g_value_get_int(value);
	/* A NULL marshaller makes GObject use its generic one, which calls
	 * the handler through libffi. */
	g_signal_emit(self, changed_signal, 0, self->count, "set");
}

static void orange_counter_get_property(GObject *object, guint id, GValue *value, GParamSpec *spec)
{
	if (id != PROP_COUNT) {
		G_OBJECT_WARN_INVALID_PROPERTY_ID(object, id, spec);
		return;
	}
	g_value_set_int(value, ORANGE_COUNTER(object)->count);
}

static void orange_counter_finalize(GObject *object)
{
	finalized++;
	G_OBJECT_CLASS(orange_counter_parent_class)->finalize(object);
}

static void orange_counter_class_init(OrangeCounterClass *klass)
{
	GObjectClass *object_class = G_OBJECT_CLASS(klass);
	object_class->set_property = orange_counter_set_property;
	object_class->get_property = orange_counter_get_property;
	object_class->finalize = orange_counter_finalize;
	g_object_class_install_property(object_class, PROP_COUNT,
	                                g_param_spec_int("count", NULL, NULL, 0, 1000, 0, G_PARAM_READWRITE | G_PARAM_STATIC_STRINGS));
	changed_signal = g_signal_new("changed", ORANGE_TYPE_COUNTER, G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
	                              G_TYPE_NONE, 2, G_TYPE_INT, G_TYPE_STRING);
}

static void orange_counter_init(OrangeCounter *self)
{
	self->count = 0;
}

static int signal_total, notifications;

static void on_changed(OrangeCounter *counter, int value, const char *how, gpointer data)
{
	(void)counter;
	if (strcmp(how, "set") == 0)
		signal_total += value * GPOINTER_TO_INT(data);
}

static void on_notify(GObject *object, GParamSpec *spec, gpointer data)
{
	(void)object;
	(void)data;
	if (strcmp(spec->name, "count") == 0)
		notifications++;
}

static int objects(void)
{
	OrangeCounter *counter = g_object_new(ORANGE_TYPE_COUNTER, NULL);
	CHECK(G_TYPE_CHECK_INSTANCE_TYPE(counter, G_TYPE_OBJECT), "type hierarchy");
	CHECK(strcmp(G_OBJECT_TYPE_NAME(counter), "OrangeCounter") == 0, "type name");
	g_signal_connect(counter, "changed", G_CALLBACK(on_changed), GINT_TO_POINTER(10));
	g_signal_connect(counter, "notify::count", G_CALLBACK(on_notify), NULL);
	g_object_set(counter, "count", 5, NULL);
	g_object_set(counter, "count", 7, NULL);
	int count = 0;
	g_object_get(counter, "count", &count, NULL);
	CHECK(count == 7, "property round trip");
	CHECK(signal_total == 120, "signal with arguments through libffi");
	CHECK(notifications == 2, "property notification");
	g_object_unref(counter);
	CHECK(finalized == 1, "finalize on last unref");
	return 0;
}

/* ── GIO ─────────────────────────────────────────────────────────────────── */

static int files(void)
{
	GError *error = NULL;
	const char *path = "/tmp/glib-probe.txt";
	const char *text = "line one\nline two\nline three\n";
	CHECK(g_file_set_contents(path, text, -1, &error), "g_file_set_contents");
	CHECK_ERROR(error, "g_file_set_contents");

	GFile *file = g_file_new_for_path(path);
	char *loaded = NULL;
	gsize length = 0;
	CHECK(g_file_load_contents(file, NULL, &loaded, &length, NULL, &error), "GFile load");
	CHECK(length == strlen(text) && memcmp(loaded, text, length) == 0, "GFile contents");
	g_free(loaded);

	GFileInfo *info = g_file_query_info(file, G_FILE_ATTRIBUTE_STANDARD_SIZE "," G_FILE_ATTRIBUTE_STANDARD_TYPE,
	                                    G_FILE_QUERY_INFO_NONE, NULL, &error);
	CHECK_ERROR(error, "GFile query info");
	CHECK(g_file_info_get_size(info) == (goffset)strlen(text), "GFile size");
	CHECK(g_file_info_get_file_type(info) == G_FILE_TYPE_REGULAR, "GFile type");
	g_object_unref(info);

	GFile *tmp = g_file_new_for_path("/tmp");
	GFileEnumerator *listing = g_file_enumerate_children(tmp, G_FILE_ATTRIBUTE_STANDARD_NAME, G_FILE_QUERY_INFO_NONE, NULL, &error);
	CHECK_ERROR(error, "GFile enumerate");
	gboolean seen = FALSE;
	GFileInfo *entry;
	while ((entry = g_file_enumerator_next_file(listing, NULL, &error)) != NULL) {
		if (strcmp(g_file_info_get_name(entry), "glib-probe.txt") == 0)
			seen = TRUE;
		g_object_unref(entry);
	}
	CHECK_ERROR(error, "GFile enumerate next");
	CHECK(seen, "directory listing");
	g_object_unref(listing);
	g_object_unref(tmp);

	GFileInputStream *input = g_file_read(file, NULL, &error);
	CHECK_ERROR(error, "GFile read");
	GDataInputStream *lines = g_data_input_stream_new(G_INPUT_STREAM(input));
	int line_count = 0;
	char *line;
	while ((line = g_data_input_stream_read_line(lines, NULL, NULL, &error)) != NULL) {
		line_count++;
		g_free(line);
	}
	CHECK_ERROR(error, "GDataInputStream");
	CHECK(line_count == 3, "line reader");
	g_object_unref(lines);
	g_object_unref(input);

	CHECK(g_file_delete(file, NULL, &error), "GFile delete");
	CHECK(!g_file_query_exists(file, NULL), "deleted file is gone");
	g_object_unref(file);

	/* zlib through GIO's converters, round trip. */
	GString *original = g_string_new(NULL);
	for (int i = 0; i < 2000; i++)
		g_string_append_printf(original, "OrangeOS %d ", i % 17);
	GZlibCompressor *compressor = g_zlib_compressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP, 6);
	GInputStream *plain = g_memory_input_stream_new_from_data(original->str, original->len, NULL);
	GInputStream *squeezed = g_converter_input_stream_new(plain, G_CONVERTER(compressor));
	GOutputStream *gz = g_memory_output_stream_new_resizable();
	g_output_stream_splice(gz, squeezed, G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET, NULL, &error);
	CHECK_ERROR(error, "gzip compress");
	gsize gz_size = g_memory_output_stream_get_data_size(G_MEMORY_OUTPUT_STREAM(gz));
	CHECK(gz_size > 0 && gz_size < original->len / 4, "gzip shrinks repetitive text");

	GZlibDecompressor *decompressor = g_zlib_decompressor_new(G_ZLIB_COMPRESSOR_FORMAT_GZIP);
	GInputStream *packed = g_memory_input_stream_new_from_data(g_memory_output_stream_get_data(G_MEMORY_OUTPUT_STREAM(gz)), gz_size, NULL);
	GInputStream *expanded = g_converter_input_stream_new(packed, G_CONVERTER(decompressor));
	GOutputStream *back = g_memory_output_stream_new_resizable();
	g_output_stream_splice(back, expanded, G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET, NULL, &error);
	CHECK_ERROR(error, "gzip decompress");
	CHECK(g_memory_output_stream_get_data_size(G_MEMORY_OUTPUT_STREAM(back)) == original->len &&
	          memcmp(g_memory_output_stream_get_data(G_MEMORY_OUTPUT_STREAM(back)), original->str, original->len) == 0,
	      "gzip round trip");
	g_object_unref(back);
	g_object_unref(expanded);
	g_object_unref(packed);
	g_object_unref(decompressor);
	g_object_unref(gz);
	g_object_unref(squeezed);
	g_object_unref(plain);
	g_object_unref(compressor);
	g_string_free(original, TRUE);
	return 0;
}

/* ── Processes ───────────────────────────────────────────────────────────── */

static int processes(void)
{
	/* LEAVE_DESCRIPTORS_OPEN keeps GLib on its posix_spawn path; OrangeOS
	 * has no fork(), which GLib's other path needs. */
	char *argv[] = { "/bin/spawn-child", "echo", "from glib", NULL };
	char *out = NULL;
	int status = -1;
	GError *error = NULL;
	CHECK(g_spawn_sync(NULL, argv, NULL, G_SPAWN_LEAVE_DESCRIPTORS_OPEN | G_SPAWN_STDERR_TO_DEV_NULL, NULL, NULL,
	                   &out, NULL, &status, &error),
	      "g_spawn_sync");
	CHECK_ERROR(error, "g_spawn_sync");
	CHECK(g_spawn_check_wait_status(status, &error), "child exit status");
	if (!g_str_has_prefix(out, "argc=3\n[/bin/spawn-child]\n[echo]\n[from glib]\n")) {
		gchar *shown = g_strescape(out, NULL);
		printf("glib-probe: FAIL child output through a pipe: \"%s\"\n", shown);
		g_free(shown);
		return 1;
	}
	g_free(out);
	return 0;
}

int main(void)
{
	if (core() || threads() || main_loop() || objects() || files() || processes())
		return 1;
	printf("glib-probe: PASS GLib %u.%u.%u strings, Unicode, PCRE2 regex, GVariant, SHA-256, threads, "
	       "async queue, thread pool, main loop sources and wakeups, GObject signals via libffi, "
	       "GIO files and streams, zlib, g_spawn\n",
	       glib_major_version, glib_minor_version, glib_micro_version);
	return 0;
}
