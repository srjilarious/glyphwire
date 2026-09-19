// Copyright (c) 2026 Jeff DeWall
// SPDX-License-Identifier: GPL-3.0-or-later

// gw-read's own decode/encode for Anki card crops (read/crop.zig).
//
// stb_image and stb_image_write compiled `static`, with only the page
// formats gw-read opens, behind three plainly named entry points. Static
// so they can't collide with the copy zstbi links into glyphwire-host
// (the test runner links both), and separate from zstbi because zstbi
// routes every allocation through one process-global Zig allocator that
// asserts it is initialised exactly once -- the wrong shape for a helper
// that runs once per card. Plain libc malloc here instead.
//
// The headers come from the zstbi package already fetched for the host
// (build.zig adds its `libs/stbi` include path), so nothing is vendored.

#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_ONLY_GIF
#define STBI_NO_STDIO
#include "stb_image.h"

#define STB_IMAGE_WRITE_STATIC
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_WRITE_NO_STDIO
#include "stb_image_write.h"

// Decodes `data` to 8-bit RGB. Null on failure; free with
// gwr_image_free.
unsigned char *gwr_image_decode(const unsigned char *data, int len, int *w, int *h) {
    int channels = 0;
    return stbi_load_from_memory(data, len, w, h, &channels, 3);
}

void gwr_image_free(unsigned char *pixels) {
    stbi_image_free(pixels);
}

// Encodes 8-bit RGB `pixels` as a baseline JPEG, handing the bytes to
// `write` in chunks. Non-zero on success.
int gwr_jpeg_encode(void (*write)(void *ctx, void *data, int size), void *ctx, int w, int h, const unsigned char *pixels, int quality) {
    return stbi_write_jpg_to_func(write, ctx, w, h, 3, pixels, quality);
}
