package main

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
shared_previews_persist_validate_and_reuse_without_decoding_originals :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.VIDEO})) {return}
	defer sdl.Quit()
	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !testing.expect(
		t,
		sdl.CreateWindowAndRenderer("cache test", 320, 200, {.HIDDEN}, &window, &renderer),
	) {return}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	root, err := os.make_directory_temp("/tmp", "stuff-shared-previews-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create cache fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/photo %%色.png", root)
	defer delete(path)
	cache_root := fmt.aprintf("%s/thumbnails", root)
	defer delete(cache_root)
	preview_test_image(t, path, false)
	testing.expect_value(t, preview_cache_root("", "/tmp/home"), "/tmp/home/.cache/thumbnails")
	uri, name := preview_cache_key(path)
	defer delete(uri); defer delete(name)
	testing.expect(t, strings.has_suffix(uri, "/photo%20%25%E8%89%B2.png"))
	gold_uri, gold_name := preview_cache_key("/home/jens/photos/me.png")
	defer delete(gold_uri); defer delete(gold_name)
	testing.expect_value(t, gold_name, "c6ee772d9e49320e97ec29a7eb5b1697.png")
	reserved_uri, reserved_name := preview_cache_key("/tmp/a!$&'()*+,:=@; %.png")
	defer delete(reserved_uri); defer delete(reserved_name)
	testing.expect_value(t, reserved_uri, "file:///tmp/a!$&'()*+,:=@%3B%20%25.png")
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.icons = true
	s := preview_start(1, cache_root)
	if !testing.expect(t, s != nil) {return}
	defer preview_destroy(s)
	b.previews = s
	g := geometry(960, 640, 1.5, icons = true)
	preview_prepare(s, &b, g)
	texture := preview_test_wait(t, s, renderer, path)
	testing.expect_value(t, texture.w, i32(144))
	testing.expect_value(t, texture.h, i32(72))
	file := fmt.aprintf("%s/large/%s", cache_root, name)
	defer delete(file)
	data, read_err := os.read_entire_file(file, context.allocator)
	if read_err != nil {testing.fail_now(t, "thumbnail was not persisted")}
	defer delete(data)
	stat, valid := preview_source_stat(path)
	testing.expect(t, valid && preview_cache_valid(data, uri, stat, THUMBNAIL_PIXELS))
	cache_stat, cached := preview_source_stat(file)
	testing.expect(t, cached && transmute(u32)cache_stat.mode & 0o777 == 0o600)
	changed := stat
	changed.mtime.time_nsec = changed.mtime.time_nsec ~ 1
	testing.expect(
		t,
		!preview_cache_valid(data, uri, changed, THUMBNAIL_PIXELS),
		"detect same-second source changes",
	)
	data[len(data) - 1] = data[len(data) - 1] ~ 1
	testing.expect(
		t,
		!preview_cache_valid(data, uri, stat, THUMBNAIL_PIXELS),
		"reject a damaged PNG",
	)
	data[len(data) - 1] = data[len(data) - 1] ~ 1

	// Reserve all decoder memory. A disk hit must still finish immediately.
	preview_forget(s, path)
	sync.mutex_lock(&s.mutex)
	s.active_pixels = PREVIEW_PIXEL_LIMIT
	sync.mutex_unlock(&s.mutex)
	preview_prepare(s, &b, g)
	texture = preview_test_wait(t, s, renderer, path)
	testing.expect_value(t, preview_test_pixel(t, renderer, texture, 5, 5), [4]u8{255, 0, 0, 255})

	// Simulate another application's shared entry: no stuff-specific metadata.
	external_png := make([dynamic]u8)
	defer delete(external_png)
	append(&external_png, ..data[:8])
	for offset := 8; offset + 12 <= len(data); {
		length := int(endian.unchecked_get_u32be(data[offset:]))
		end := offset + 12 + length
		kind := string(data[offset + 4:offset + 8])
		if kind != "tEXt" || !strings.has_prefix(string(data[offset + 8:end - 4]), "X-Stuff::") {
			append(&external_png, ..data[offset:end])
		}
		offset = end
	}
	testing.expect(t, os.write_entire_file(file, external_png[:]) == nil)
	preview_forget(s, path)
	preview_prepare(s, &b, g)
	texture = preview_test_wait(t, s, renderer, path)
	testing.expect_value(t, texture.w, i32(144))
	testing.expect_value(t, preview_test_pixel(t, renderer, texture, 5, 5), [4]u8{255, 0, 0, 255})

	// A cache-file symlink must not redirect reads to an otherwise valid PNG.
	testing.expect(t, os.remove(file) == nil)
	target := fmt.tprintf("%s/large/%s", cache_root, name)
	testing.expect(t, os.symlink(target, file) == nil)
	testing.expect(t, preview_cache_read(file, uri, stat, THUMBNAIL_PIXELS) == nil)
	sync.mutex_lock(&s.mutex)
	s.active_pixels = 0
	sync.mutex_unlock(&s.mutex)

	// A second miss must persist even when the cache directories already exist.
	second := fmt.tprintf("%s/second.png", root)
	preview_test_image(t, second, false)
	surface := preview_thumbnail(s, {path = second, edge = THUMBNAIL_PIXELS})
	if !testing.expect(t, surface != nil) {return}
	sdl.DestroySurface(surface)
	second_uri, second_name := preview_cache_key(second)
	defer delete(second_uri); defer delete(second_name)
	second_stat, second_valid := preview_source_stat(second)
	stored := preview_cache_read(
		fmt.tprintf("%s/large/%s", cache_root, second_name),
		second_uri,
		second_stat,
		THUMBNAIL_PIXELS,
	)
	testing.expect(t, second_valid && stored != nil)
	if stored != nil {sdl.DestroySurface(stored)}
}
