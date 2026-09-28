// WOFF2 for the W3 library probe (probe.c): compress a TrueType font to
// WOFF2 and back, as WebKit does when a page uses a WOFF2 web font.
//
// SPDX-License-Identifier: MIT OR Apache-2.0
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <string>
#include <woff2/decode.h>
#include <woff2/encode.h>
#include <woff2/output.h>

extern "C" size_t woff2_round_trip(const unsigned char *ttf, size_t length, size_t *compressed)
{
	size_t capacity = woff2::MaxWOFF2CompressedSize(ttf, length);
	std::string woff(capacity, '\0');
	size_t woff_size = capacity;
	if (!woff2::ConvertTTFToWOFF2(ttf, length, reinterpret_cast<uint8_t *>(&woff[0]), &woff_size))
		return 0;
	*compressed = woff_size;
	const auto *data = reinterpret_cast<const uint8_t *>(woff.data());
	std::string recovered(std::min(woff2::ComputeWOFF2FinalSize(data, woff_size), woff2::kDefaultMaxSize), '\0');
	woff2::WOFF2StringOut out(&recovered);
	if (!woff2::ConvertWOFF2ToTTF(data, woff_size, &out))
		return 0;
	return out.Size();
}
