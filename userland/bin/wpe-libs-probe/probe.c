/* The WPE WebKit stack's base libraries on OrangeOS
 * (docs/design/012-wpe-webkit-browser.md, W3).
 *
 * Each library is cross-built as a static Linux/musl library
 * (tools/wpe/build_deps.py) and exercised the way WebKit uses it: image
 * codecs (PNG, JPEG, WebP), fonts (FreeType rendering, HarfBuzz shaping
 * with ICU Unicode data, fontconfig matching against /etc/fonts and
 * /share/fonts, WOFF2 via brotli), ICU locale services, libxml2/libxslt,
 * SQLite on the tmpfs, libgcrypt (Web Crypto's backend), libtasn1,
 * libxkbcommon, and libepoxy reporting that no EGL exists.
 *
 * SPDX-License-Identifier: MIT OR Apache-2.0
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <brotli/decode.h>
#include <brotli/encode.h>
#include <epoxy/egl.h>
#include <fontconfig/fontconfig.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include <gcrypt.h>
#include <harfbuzz/hb-ft.h>
#include <harfbuzz/hb-icu.h>
#include <harfbuzz/hb.h>
#include <jpeglib.h>
#include <libtasn1.h>
#include <libxml/parser.h>
#include <libxml/xpath.h>
#include <libxslt/transform.h>
#include <libxslt/xsltutils.h>
#include <png.h>
#include <sqlite3.h>
#include <unicode/ubrk.h>
#include <unicode/ucol.h>
#include <unicode/unum.h>
#include <unicode/ustring.h>
#include <webp/decode.h>
#include <webp/demux.h>
#include <webp/encode.h>
#include <xkbcommon/xkbcommon.h>

#define CHECK(condition, what)                                                   \
	do {                                                                         \
		if (!(condition)) {                                                      \
			printf("wpe-libs-probe: FAIL %s (errno %d)\n", (what), errno);       \
			return 1;                                                            \
		}                                                                        \
	} while (0)

#define FONT "/share/fonts/Inter.ttf"
#define MONO_FONT "/share/fonts/JetBrainsMono.ttf"

/* woff2.cpp: TTF -> WOFF2 -> TTF; returns the recovered size or 0. */
size_t woff2_round_trip(const unsigned char *ttf, size_t length, size_t *compressed);

static unsigned char *read_file(const char *path, size_t *length)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	unsigned char *data = malloc((size_t)size);
	if (data && fread(data, 1, (size_t)size, f) != (size_t)size) {
		free(data);
		data = NULL;
	}
	fclose(f);
	*length = (size_t)size;
	return data;
}

/* ── Images ──────────────────────────────────────────────────────────────── */

static int images(void)
{
	enum { W = 24, H = 16 };
	unsigned char rgba[W * H * 4];
	for (int i = 0; i < W * H; i++) {
		rgba[i * 4 + 0] = (unsigned char)(i * 7);
		rgba[i * 4 + 1] = (unsigned char)(i * 3);
		rgba[i * 4 + 2] = (unsigned char)(255 - i);
		rgba[i * 4 + 3] = (unsigned char)(i % 2 ? 255 : 128);
	}

	/* PNG through libpng's simplified API, both directions. */
	png_image image;
	memset(&image, 0, sizeof image);
	image.version = PNG_IMAGE_VERSION;
	image.width = W;
	image.height = H;
	image.format = PNG_FORMAT_RGBA;
	png_alloc_size_t png_size = 0;
	CHECK(png_image_write_to_memory(&image, NULL, &png_size, 0, rgba, 0, NULL) && png_size > 0, "PNG size");
	unsigned char *png = malloc(png_size);
	CHECK(png_image_write_to_memory(&image, png, &png_size, 0, rgba, 0, NULL), "PNG encode");
	png_image back;
	memset(&back, 0, sizeof back);
	back.version = PNG_IMAGE_VERSION;
	CHECK(png_image_begin_read_from_memory(&back, png, png_size), "PNG header");
	back.format = PNG_FORMAT_RGBA;
	unsigned char decoded[W * H * 4];
	CHECK(back.width == W && back.height == H && png_image_finish_read(&back, NULL, decoded, 0, NULL), "PNG decode");
	CHECK(memcmp(decoded, rgba, sizeof rgba) == 0, "PNG round trip");
	free(png);

	/* JPEG: lossy, so compare the size and a smooth area approximately. */
	unsigned char rgb[64 * 64 * 3];
	for (int y = 0; y < 64; y++)
		for (int x = 0; x < 64; x++) {
			rgb[(y * 64 + x) * 3 + 0] = (unsigned char)(x * 4);
			rgb[(y * 64 + x) * 3 + 1] = (unsigned char)(y * 4);
			rgb[(y * 64 + x) * 3 + 2] = 128;
		}
	struct jpeg_compress_struct c;
	struct jpeg_error_mgr c_err;
	c.err = jpeg_std_error(&c_err);
	jpeg_create_compress(&c);
	unsigned char *jpeg = NULL;
	unsigned long jpeg_size = 0;
	jpeg_mem_dest(&c, &jpeg, &jpeg_size);
	c.image_width = 64;
	c.image_height = 64;
	c.input_components = 3;
	c.in_color_space = JCS_RGB;
	jpeg_set_defaults(&c);
	jpeg_set_quality(&c, 90, TRUE);
	jpeg_start_compress(&c, TRUE);
	while (c.next_scanline < 64) {
		JSAMPROW row = &rgb[c.next_scanline * 64 * 3];
		jpeg_write_scanlines(&c, &row, 1);
	}
	jpeg_finish_compress(&c);
	jpeg_destroy_compress(&c);
	CHECK(jpeg_size > 100, "JPEG encode");
	struct jpeg_decompress_struct d;
	struct jpeg_error_mgr d_err;
	d.err = jpeg_std_error(&d_err);
	jpeg_create_decompress(&d);
	jpeg_mem_src(&d, jpeg, jpeg_size);
	CHECK(jpeg_read_header(&d, TRUE) == JPEG_HEADER_OK, "JPEG header");
	jpeg_start_decompress(&d);
	CHECK(d.output_width == 64 && d.output_height == 64 && d.output_components == 3, "JPEG geometry");
	unsigned char out[64 * 64 * 3];
	while (d.output_scanline < 64) {
		JSAMPROW row = &out[d.output_scanline * 64 * 3];
		jpeg_read_scanlines(&d, &row, 1);
	}
	jpeg_finish_decompress(&d);
	jpeg_destroy_decompress(&d);
	free(jpeg);
	int centre = (32 * 64 + 32) * 3;
	CHECK(abs(out[centre] - rgb[centre]) < 12 && abs(out[centre + 1] - rgb[centre + 1]) < 12, "JPEG round trip");

	/* WebP lossless, and the demuxer WebKit uses for animated images. */
	uint8_t *webp = NULL;
	size_t webp_size = WebPEncodeLosslessRGBA(rgba, W, H, W * 4, &webp);
	CHECK(webp_size > 0, "WebP encode");
	WebPData data = { webp, webp_size };
	WebPDemuxer *demux = WebPDemux(&data);
	CHECK(demux && WebPDemuxGetI(demux, WEBP_FF_CANVAS_WIDTH) == W && WebPDemuxGetI(demux, WEBP_FF_FRAME_COUNT) == 1, "WebP demux");
	WebPDemuxDelete(demux);
	int width = 0, height = 0;
	uint8_t *pixels = WebPDecodeRGBA(webp, webp_size, &width, &height);
	CHECK(pixels && width == W && height == H && memcmp(pixels, rgba, sizeof rgba) == 0, "WebP round trip");
	WebPFree(pixels);
	WebPFree(webp);
	return 0;
}

/* ── Fonts ───────────────────────────────────────────────────────────────── */

static int fonts(void)
{
	FT_Library ft;
	CHECK(FT_Init_FreeType(&ft) == 0, "FreeType init");
	FT_Face face;
	CHECK(FT_New_Face(ft, FONT, 0, &face) == 0, "FreeType open " FONT);
	CHECK(strcmp(face->family_name, "Inter") == 0, "font family name");
	CHECK(FT_Set_Pixel_Sizes(face, 0, 32) == 0, "FreeType size");
	CHECK(FT_Load_Char(face, 'A', FT_LOAD_RENDER) == 0, "FreeType render");
	FT_Bitmap *bitmap = &face->glyph->bitmap;
	int inked = 0;
	for (unsigned y = 0; y < bitmap->rows; y++)
		for (unsigned x = 0; x < bitmap->width; x++)
			inked += bitmap->buffer[y * (unsigned)bitmap->pitch + x] > 128;
	CHECK(bitmap->width > 10 && bitmap->rows > 15 && inked > 60, "rendered glyph coverage");

	/* HarfBuzz shaping through FreeType, with ICU's Unicode data. */
	hb_font_t *font = hb_ft_font_create_referenced(face);
	hb_buffer_t *buffer = hb_buffer_create();
	hb_buffer_set_unicode_funcs(buffer, hb_icu_get_unicode_funcs());
	hb_buffer_add_utf8(buffer, "Orange OS", -1, 0, -1);
	hb_buffer_guess_segment_properties(buffer);
	CHECK(hb_buffer_get_direction(buffer) == HB_DIRECTION_LTR && hb_buffer_get_script(buffer) == HB_SCRIPT_LATIN, "Latin segment");
	hb_shape(font, buffer, NULL, 0);
	unsigned count = 0;
	hb_glyph_info_t *glyphs = hb_buffer_get_glyph_infos(buffer, &count);
	hb_glyph_position_t *positions = hb_buffer_get_glyph_positions(buffer, &count);
	int advance = 0;
	for (unsigned i = 0; i < count; i++)
		advance += positions[i].x_advance;
	CHECK(count == 9 && glyphs[0].codepoint != 0 && advance > 0, "HarfBuzz shaping");
	hb_buffer_reset(buffer);
	hb_buffer_set_unicode_funcs(buffer, hb_icu_get_unicode_funcs());
	hb_buffer_add_utf8(buffer, "\xd9\x85\xd8\xb1\xd8\xad\xd8\xa8\xd8\xa7", -1, 0, -1);
	hb_buffer_guess_segment_properties(buffer);
	CHECK(hb_buffer_get_direction(buffer) == HB_DIRECTION_RTL && hb_buffer_get_script(buffer) == HB_SCRIPT_ARABIC, "Arabic detected as right-to-left");
	hb_buffer_destroy(buffer);
	hb_font_destroy(font);
	FT_Done_FreeType(ft);

	/* fontconfig with the configuration staged on the disk. */
	FcConfig *config = FcInitLoadConfigAndFonts();
	CHECK(config != NULL, "fontconfig configuration");
	FcPattern *pattern = FcNameParse((const FcChar8 *)"monospace");
	FcConfigSubstitute(config, pattern, FcMatchPattern);
	FcDefaultSubstitute(pattern);
	FcResult result;
	FcPattern *match = FcFontMatch(config, pattern, &result);
	FcChar8 *file = NULL;
	CHECK(match && FcPatternGetString(match, FC_FILE, 0, &file) == FcResultMatch, "fontconfig match");
	CHECK(strcmp((const char *)file, MONO_FONT) == 0 || strcmp((const char *)file, FONT) == 0, "fontconfig finds /share/fonts");
	FcPatternDestroy(match);
	FcPatternDestroy(pattern);
	FcObjectSet *objects = FcObjectSetBuild(FC_FAMILY, FC_FILE, NULL);
	FcPattern *any = FcPatternCreate();
	FcFontSet *all = FcFontList(config, any, objects);
	CHECK(all && all->nfont >= 2, "fontconfig lists the installed fonts");
	FcFontSetDestroy(all);
	FcPatternDestroy(any);
	FcObjectSetDestroy(objects);
	FcConfigDestroy(config);

	/* WOFF2, the web-font format, round trip through brotli. */
	size_t ttf_size = 0, compressed = 0;
	unsigned char *ttf = read_file(MONO_FONT, &ttf_size);
	CHECK(ttf != NULL, "read " MONO_FONT);
	size_t recovered = woff2_round_trip(ttf, ttf_size, &compressed);
	CHECK(compressed > 0 && compressed < ttf_size && recovered > ttf_size / 2, "WOFF2 round trip");
	free(ttf);
	return 0;
}

/* ── Unicode and locales (ICU) ───────────────────────────────────────────── */

static int icu(void)
{
	UErrorCode status = U_ZERO_ERROR;
	UChar source[32], upper[32];
	u_uastrcpy(source, "istanbul");
	int32_t n = u_strToUpper(upper, 32, source, -1, "tr", &status);
	CHECK(U_SUCCESS(status) && n == 8 && upper[0] == 0x0130, "Turkish upper-casing");

	UChar text[64];
	u_uastrcpy(text, "The quick brown fox.");
	UBreakIterator *words = ubrk_open(UBRK_WORD, "en", text, -1, &status);
	CHECK(U_SUCCESS(status), "word break iterator (ICU data)");
	int word_count = 0;
	for (int32_t at = ubrk_first(words); at != UBRK_DONE; at = ubrk_next(words))
		if (ubrk_getRuleStatus(words) >= UBRK_WORD_LETTER)
			word_count++;
	ubrk_close(words);
	CHECK(word_count == 4, "word boundaries");

	UCollator *collator = ucol_open("de", &status);
	CHECK(U_SUCCESS(status), "collator");
	UChar a[8], b[8];
	u_uastrcpy(a, "apfel");
	u_uastrcpy(b, "Birne");
	CHECK(ucol_strcoll(collator, a, -1, b, -1) == UCOL_LESS, "locale collation");
	ucol_close(collator);

	UNumberFormat *format = unum_open(UNUM_DECIMAL, NULL, 0, "de_DE", NULL, &status);
	UChar formatted[32];
	unum_formatDouble(format, 1234567.5, formatted, 32, NULL, &status);
	unum_close(format);
	char utf8[32];
	u_austrcpy(utf8, formatted);
	CHECK(U_SUCCESS(status) && strcmp(utf8, "1.234.567,5") == 0, "German number format");
	return 0;
}

/* ── XML ─────────────────────────────────────────────────────────────────── */

static int xml(void)
{
	const char *doc_text = "<fruits><fruit colour='orange'>orange</fruit><fruit colour='yellow'>lemon</fruit>"
	                       "<fruit colour='orange'>mandarin</fruit></fruits>";
	xmlDocPtr doc = xmlReadMemory(doc_text, (int)strlen(doc_text), "fruits.xml", NULL, 0);
	CHECK(doc != NULL, "libxml2 parse");
	xmlXPathContextPtr xpath = xmlXPathNewContext(doc);
	xmlXPathObjectPtr found = xmlXPathEvalExpression((const xmlChar *)"//fruit[@colour='orange']", xpath);
	CHECK(found && found->nodesetval && found->nodesetval->nodeNr == 2, "XPath");
	xmlXPathFreeObject(found);
	xmlXPathFreeContext(xpath);

	const char *sheet_text =
		"<xsl:stylesheet version='1.0' xmlns:xsl='http://www.w3.org/1999/XSL/Transform'>"
		"<xsl:output method='text'/>"
		"<xsl:template match='/'><xsl:for-each select='//fruit'><xsl:value-of select='.'/>;</xsl:for-each></xsl:template>"
		"</xsl:stylesheet>";
	xmlDocPtr sheet_doc = xmlReadMemory(sheet_text, (int)strlen(sheet_text), "sheet.xsl", NULL, 0);
	xsltStylesheetPtr sheet = xsltParseStylesheetDoc(sheet_doc);
	CHECK(sheet != NULL, "XSLT stylesheet");
	xmlDocPtr result = xsltApplyStylesheet(sheet, doc, NULL);
	xmlChar *output = NULL;
	int length = 0;
	CHECK(result && xsltSaveResultToString(&output, &length, result, sheet) == 0, "XSLT transform");
	CHECK(output && strcmp((const char *)output, "orange;lemon;mandarin;") == 0, "XSLT output");
	xmlFree(output);
	xmlFreeDoc(result);
	xsltFreeStylesheet(sheet);
	xmlFreeDoc(doc);
	return 0;
}

/* ── SQLite ──────────────────────────────────────────────────────────────── */

static int database(void)
{
	const char *path = "/tmp/wpe-libs-probe.db";
	unlink(path);
	sqlite3 *db = NULL;
	CHECK(sqlite3_open(path, &db) == SQLITE_OK, "SQLite open");
	char *message = NULL;
	int rc = sqlite3_exec(db,
	                      "CREATE TABLE fruit(id INTEGER PRIMARY KEY, name TEXT, weight REAL);"
	                      "BEGIN;"
	                      "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 1000)"
	                      " INSERT INTO fruit(name, weight) SELECT 'orange ' || i, i * 0.5 FROM n;"
	                      "COMMIT;",
	                      NULL, NULL, &message);
	if (rc != SQLITE_OK) {
		printf("wpe-libs-probe: FAIL SQLite write: %s (extended code %d)\n", message ? message : sqlite3_errmsg(db), sqlite3_extended_errcode(db));
		return 1;
	}
	sqlite3_stmt *query;
	CHECK(sqlite3_prepare_v2(db, "SELECT count(*), sum(weight) FROM fruit WHERE name LIKE 'orange%'", -1, &query, NULL) == SQLITE_OK, "SQLite prepare");
	CHECK(sqlite3_step(query) == SQLITE_ROW, "SQLite step");
	CHECK(sqlite3_column_int(query, 0) == 1000 && sqlite3_column_double(query, 1) == 250250.0, "SQLite results");
	sqlite3_finalize(query);
	sqlite3_close(db);

	/* Reopen: the data was really written to the file. */
	CHECK(sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK, "SQLite reopen");
	CHECK(sqlite3_prepare_v2(db, "SELECT name FROM fruit WHERE id = 777", -1, &query, NULL) == SQLITE_OK, "SQLite reopen query");
	CHECK(sqlite3_step(query) == SQLITE_ROW && strcmp((const char *)sqlite3_column_text(query, 0), "orange 777") == 0, "SQLite persisted row");
	sqlite3_finalize(query);
	sqlite3_close(db);
	unlink(path);
	return 0;
}

/* ── Cryptography and ASN.1 ──────────────────────────────────────────────── */

static int crypto(void)
{
	CHECK(gcry_check_version(GCRYPT_VERSION) != NULL, "libgcrypt version");
	gcry_control(GCRYCTL_INITIALIZATION_FINISHED, 0);

	unsigned char digest[32];
	gcry_md_hash_buffer(GCRY_MD_SHA256, digest, "abc", 3);
	static const unsigned char abc[4] = { 0xba, 0x78, 0x16, 0xbf };
	CHECK(memcmp(digest, abc, 4) == 0, "libgcrypt SHA-256");

	/* AES-256-GCM: encrypt, decrypt, and reject a tampered tag. */
	unsigned char key[32], iv[12], plain[64], sealed[64], opened[64], tag[16];
	gcry_randomize(key, sizeof key, GCRY_STRONG_RANDOM);
	gcry_create_nonce(iv, sizeof iv);
	memset(plain, 'o', sizeof plain);
	gcry_cipher_hd_t cipher;
	CHECK(gcry_cipher_open(&cipher, GCRY_CIPHER_AES256, GCRY_CIPHER_MODE_GCM, 0) == 0, "AES-GCM open");
	gcry_cipher_setkey(cipher, key, sizeof key);
	gcry_cipher_setiv(cipher, iv, sizeof iv);
	CHECK(gcry_cipher_encrypt(cipher, sealed, sizeof sealed, plain, sizeof plain) == 0, "AES-GCM encrypt");
	gcry_cipher_gettag(cipher, tag, sizeof tag);
	gcry_cipher_reset(cipher);
	gcry_cipher_setiv(cipher, iv, sizeof iv);
	gcry_cipher_decrypt(cipher, opened, sizeof opened, sealed, sizeof sealed);
	CHECK(gcry_cipher_checktag(cipher, tag, sizeof tag) == 0 && memcmp(opened, plain, sizeof plain) == 0, "AES-GCM decrypt");
	tag[0] ^= 1;
	gcry_cipher_reset(cipher);
	gcry_cipher_setiv(cipher, iv, sizeof iv);
	gcry_cipher_decrypt(cipher, opened, sizeof opened, sealed, sizeof sealed);
	CHECK(gcry_cipher_checktag(cipher, tag, sizeof tag) != 0, "AES-GCM rejects a bad tag");
	gcry_cipher_close(cipher);

	/* libtasn1: DER encoding of an INTEGER, and back. */
	/* libtasn1's simple DER helpers take string types: an OCTET STRING. */
	const unsigned char value[6] = "orange";
	unsigned char header[16];
	unsigned header_length = sizeof header;
	CHECK(asn1_encode_simple_der(ASN1_ETYPE_OCTET_STRING, value, sizeof value, header, &header_length) == ASN1_SUCCESS, "ASN.1 header");
	CHECK(header_length == 2 && header[0] == 0x04 && header[1] == sizeof value, "ASN.1 tag and length");
	unsigned char full[18];
	memcpy(full, header, header_length);
	memcpy(full + header_length, value, sizeof value);
	const unsigned char *inner = NULL;
	unsigned inner_length = 0;
	CHECK(asn1_decode_simple_der(ASN1_ETYPE_OCTET_STRING, full, header_length + sizeof value, &inner, &inner_length) == ASN1_SUCCESS, "ASN.1 decode");
	CHECK(inner_length == sizeof value && memcmp(inner, value, sizeof value) == 0, "ASN.1 round trip");
	return 0;
}

/* ── Compression ─────────────────────────────────────────────────────────── */

static int compression(void)
{
	char input[4096];
	for (size_t i = 0; i < sizeof input; i++)
		input[i] = "OrangeOS brotli "[i % 16];
	uint8_t packed[4096];
	size_t packed_size = sizeof packed;
	CHECK(BrotliEncoderCompress(BROTLI_DEFAULT_QUALITY, BROTLI_DEFAULT_WINDOW, BROTLI_MODE_TEXT, sizeof input,
	                            (const uint8_t *)input, &packed_size, packed),
	      "brotli compress");
	uint8_t unpacked[4096];
	size_t unpacked_size = sizeof unpacked;
	CHECK(BrotliDecoderDecompress(packed_size, packed, &unpacked_size, unpacked) == BROTLI_DECODER_RESULT_SUCCESS,
	      "brotli decompress");
	CHECK(packed_size < 100 && unpacked_size == sizeof input && memcmp(unpacked, input, sizeof input) == 0, "brotli round trip");
	return 0;
}

/* ── Keyboard (xkbcommon) ────────────────────────────────────────────────── */

static const char keymap_text[] =
	"xkb_keymap {\n"
	" xkb_keycodes \"orange\" { minimum = 8; maximum = 255; <AC01> = 38; <LFSH> = 50; };\n"
	" xkb_types \"orange\" {\n"
	"  virtual_modifiers NumLock;\n"
	"  type \"ONE_LEVEL\" { modifiers = none; level_name[Level1] = \"Any\"; };\n"
	"  type \"ALPHABETIC\" { modifiers = Shift+Lock; map[Shift] = Level2; map[Lock] = Level2;\n"
	"    level_name[Level1] = \"Base\"; level_name[Level2] = \"Caps\"; };\n"
	" };\n"
	" xkb_compat \"orange\" { interpret Shift_L { action = SetMods(modifiers = Shift); }; };\n"
	" xkb_symbols \"orange\" {\n"
	"  key <AC01> { type = \"ALPHABETIC\", [ a, A ] };\n"
	"  key <LFSH> { type = \"ONE_LEVEL\", [ Shift_L ] };\n"
	"  modifier_map Shift { <LFSH> };\n"
	" };\n"
	"};\n";

static int keyboard(void)
{
	struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_DEFAULT_INCLUDES | XKB_CONTEXT_NO_ENVIRONMENT_NAMES);
	CHECK(context != NULL, "xkb context");
	struct xkb_keymap *keymap = xkb_keymap_new_from_string(context, keymap_text, XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
	CHECK(keymap != NULL, "xkb keymap compile");
	struct xkb_state *state = xkb_state_new(keymap);
	CHECK(xkb_state_key_get_one_sym(state, 38) == XKB_KEY_a, "unshifted key");
	xkb_state_update_key(state, 50, XKB_KEY_DOWN);
	CHECK(xkb_state_key_get_one_sym(state, 38) == XKB_KEY_A, "shifted key");
	char name[16];
	xkb_keysym_get_name(XKB_KEY_A, name, sizeof name);
	CHECK(strcmp(name, "A") == 0, "keysym name");
	xkb_state_unref(state);
	xkb_keymap_unref(keymap);
	xkb_context_unref(context);
	return 0;
}

/* ── Graphics API loader ─────────────────────────────────────────────────── */

static int graphics(void)
{
	/* OrangeOS has no EGL. epoxy looks for it with dlopen, which static
	 * musl refuses, and must report its absence rather than abort. */
	CHECK(!epoxy_has_egl(), "epoxy reports that no EGL is available");
	return 0;
}

int main(void)
{
	if (images() || fonts() || icu() || xml() || database() || crypto() || compression() || keyboard() || graphics())
		return 1;
	printf("wpe-libs-probe: PASS PNG, JPEG, WebP, FreeType, HarfBuzz+ICU, fontconfig, WOFF2, ICU locales, "
	       "libxml2, libxslt, SQLite on tmpfs, libgcrypt AES-GCM, libtasn1, brotli, xkbcommon, no EGL\n");
	return 0;
}
