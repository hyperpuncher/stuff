package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"
import image "vendor:sdl3/image"

preview_test_image :: proc(t: ^testing.T, path: string, green: bool) {
	surface := sdl.CreateSurface(320, 160, .RGBA32)
	if !testing.expect(t, surface != nil) {return}
	defer sdl.DestroySurface(surface)
	sdl_check(sdl.FillSurfaceRect(surface, nil, sdl.MapSurfaceRGBA(surface, 0, 0, 255, 255)))
	left := sdl.Rect{0, 0, 160, 160}
	color :=
		green ? sdl.MapSurfaceRGBA(surface, 0, 255, 0, 255) : sdl.MapSurfaceRGBA(surface, 255, 0, 0, 255)
	sdl_check(sdl.FillSurfaceRect(surface, &left, color))
	file := strings.clone_to_cstring(path)
	defer delete(file)
	testing.expect(t, image.SavePNG(surface, file))
}

preview_test_wait :: proc(
	t: ^testing.T,
	s: ^Preview_Service,
	renderer: ^sdl.Renderer,
	path: string,
) -> ^sdl.Texture {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		_ = preview_poll(s, renderer)
		if texture := preview_texture(s, path);
		   texture != nil && s.cache[path].ready {return texture}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "preview did not finish")
}

preview_test_pixel :: proc(
	t: ^testing.T,
	renderer: ^sdl.Renderer,
	texture: ^sdl.Texture,
	x, y: i32,
) -> [4]u8 {
	sdl_check(sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255))
	sdl_check(sdl.RenderClear(renderer))
	destination := sdl.FRect{0, 0, f32(texture.w), f32(texture.h)}
	sdl_check(sdl.RenderTexture(renderer, texture, nil, &destination))
	region := sdl.Rect{x, y, 1, 1}
	surface := sdl.RenderReadPixels(renderer, &region)
	if !testing.expect(t, surface != nil) {return {}}
	defer sdl.DestroySurface(surface)
	color: [4]u8
	sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &color[0], &color[1], &color[2], &color[3]))
	return color
}

@(test)
previews_prioritize_visible_items_and_preload_two_rows_in_both_directions :: proc(t: ^testing.T) {
	b := Browser {
		icons = true,
	}
	defer browser_destroy(&b)
	entries := make([]os.File_Info, 1000)
	for &entry, i in entries {
		entry.fullpath = fmt.aprintf("/fixture/%04d.png", i)
		_, entry.name = os.split_path(entry.fullpath)
		entry.type, entry.size = .Regular, 1
		append(&b.visible, i)
	}
	b.entries = entries
	// No workers: observe the complete queue before any request is claimed.
	s := new(Preview_Service)
	defer preview_destroy(s)
	g := geometry(960, 640, 1, icons = true)
	b.first = 10 * g.stride
	preview_prepare(s, &b, g)
	visible_end := b.first + g.rows + g.stride
	testing.expect_value(t, len(s.queue), g.rows + 5 * g.stride)
	for i in b.first - 2 * g.stride ..< visible_end + 2 * g.stride {
		testing.expect(t, s.cache[b.entries[i].fullpath].pending)
	}
	testing.expect(t, b.entries[b.first - 2 * g.stride - 1].fullpath not_in s.cache)
	testing.expect(t, b.entries[visible_end + 2 * g.stride].fullpath not_in s.cache)
	for i in 0 ..< g.rows + g.stride {
		testing.expect_value(t, s.queue[i].path, b.entries[b.first + i].fullpath)
	}
	old := strings.clone(s.queue[0].path)
	defer delete(old)
	b.first += 10 * g.stride
	preview_prepare(s, &b, g)
	testing.expect(t, !s.cache[old].pending, "drop requests outside the new preload range")
	for i in 0 ..< g.rows + g.stride {
		testing.expect_value(t, s.queue[i].path, b.entries[b.first + i].fullpath)
	}
	// A full old queue must not keep preload jobs ahead of newly visible files.
	tall := geometry(960, 6000, 1, icons = true)
	preview_prepare(s, &b, tall)
	expected := min(
		tall.rows + 5 * tall.stride,
		max(64, tall.rows + tall.stride),
		len(b.visible) - b.first,
	)
	testing.expect_value(t, len(s.queue), expected)
	b.first += 20 * tall.stride
	preview_prepare(s, &b, tall)
	visible_count := min(tall.rows + tall.stride, len(b.visible) - b.first)
	for i in 0 ..< visible_count {
		testing.expect_value(t, s.queue[i].path, b.entries[b.first + i].fullpath)
	}
	// Preload rows follow the visible band, below before above.
	if len(s.queue) > visible_count {
		testing.expect_value(
			t,
			s.queue[visible_count].path,
			b.entries[b.first + visible_count].fullpath,
		)
	}
}

@(test)
preview_input_stays_within_the_checked_file_size :: proc(t: ^testing.T) {
	data := "original plus later bytes"
	file := posix.fmemopen(raw_data(data), uint(len(data)), "rb")
	if !testing.expect(t, file != nil) {return}
	defer posix.fclose(file)
	input := Preview_Input {
		file = file,
		size = 8,
	}
	buffer: [32]u8
	testing.expect_value(t, preview_input_read(&input, raw_data(buffer[:]), 32), 8)
	testing.expect_value(t, string(buffer[:8]), "original")
	testing.expect_value(t, preview_input_eof(&input), 1)
	testing.expect_value(t, preview_input_read(&input, raw_data(buffer[:]), 32), 0)
	preview_input_skip(&input, -8)
	testing.expect_value(t, preview_input_read(&input, raw_data(buffer[:]), 3), 3)
	testing.expect_value(t, string(buffer[:3]), "ori")
	preview_input_skip(&input, 6)
	testing.expect(t, input.failed)
	testing.expect_value(t, preview_input_read(&input, raw_data(buffer[:]), 32), 0)

	short := Preview_Input {
		file = file,
		size = i64(len(data)) + 1,
	}
	posix.rewind(file)
	_ = preview_input_read(&short, raw_data(buffer[:]), 32)
	testing.expect(t, short.failed, "reject a file truncated after its size was checked")
}

@(test)
previews_reduce_fine_detail_without_aliasing_or_alpha_fringes :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-preview-filter-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create filter fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/detail.png", root)
	defer delete(path)
	file := strings.clone_to_cstring(path)
	defer delete(file)
	stripes := sdl.CreateSurface(1536, 64, .RGBA32)
	if !testing.expect(t, stripes != nil) {return}
	defer sdl.DestroySurface(stripes)
	sdl_check(sdl.FillSurfaceRect(stripes, nil, sdl.MapSurfaceRGBA(stripes, 0, 0, 0, 255)))
	for x: i32 = 0; x < stripes.w; x += 3 {
		line := sdl.Rect{x, 0, 1, stripes.h}
		sdl_check(
			sdl.FillSurfaceRect(stripes, &line, sdl.MapSurfaceRGBA(stripes, 255, 255, 255, 255)),
		)
	}
	testing.expect(t, image.SavePNG(stripes, file))
	native := preview_decode({path = path, edge = 1536})
	if !testing.expect(t, native != nil) {return}
	defer sdl.DestroySurface(native)
	native_r, native_g, native_b, native_a: u8
	sdl_check(sdl.ReadSurfacePixel(native, 300, 32, &native_r, &native_g, &native_b, &native_a))
	testing.expect(
		t,
		native_r == 255 && native_g == 255 && native_b == 255 && native_a == 255,
		"do not blur images that need no reduction",
	)
	thumbnail := preview_decode({path = path, edge = 96})
	if !testing.expect(t, thumbnail != nil) {return}
	defer sdl.DestroySurface(thumbnail)
	// One white pixel in three must average to a uniform sRGB gray, not stripes.
	for x: i32 = 8; x < thumbnail.w - 8; x += 1 {
		r, green, blue, alpha: u8
		sdl_check(sdl.ReadSurfacePixel(thumbnail, x, 1, &r, &green, &blue, &alpha))
		testing.expect(t, r >= 145 && r <= 165 && green == r && blue == r && alpha == 255)
	}
	transparent := sdl.CreateSurface(4, 1, .RGBA32)
	if !testing.expect(t, transparent != nil) {return}
	defer sdl.DestroySurface(transparent)
	sdl_check(sdl.FillSurfaceRect(transparent, nil, sdl.MapSurfaceRGBA(transparent, 0, 0, 255, 0)))
	red := sdl.Rect{0, 0, 1, 1}
	sdl_check(
		sdl.FillSurfaceRect(transparent, &red, sdl.MapSurfaceRGBA(transparent, 255, 0, 0, 255)),
	)
	testing.expect(t, image.SavePNG(transparent, file))
	filtered := preview_decode({path = path, edge = 1})
	if !testing.expect(t, filtered != nil) {return}
	defer sdl.DestroySurface(filtered)
	r, green, blue, alpha: u8
	sdl_check(sdl.ReadSurfacePixel(filtered, 0, 0, &r, &green, &blue, &alpha))
	testing.expect(t, r >= 250 && green <= 2 && blue <= 2 && alpha > 0 && alpha < 255)
}

@(test)
previews_preserve_pixels_reuse_cache_reject_stale_results_and_stop :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.VIDEO})) {return}
	defer sdl.Quit()
	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !testing.expect(
		t,
		sdl.CreateWindowAndRenderer("preview test", 320, 200, {.HIDDEN}, &window, &renderer),
	) {return}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	root, err := os.make_directory_temp("/tmp", "stuff-previews-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create preview fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/photo.png", root)
	defer delete(path)
	preview_test_image(t, path, false)
	bad := fmt.aprintf("%s/bad.png", root)
	defer delete(bad)
	testing.expect(t, os.write_entire_file(bad, "not an image") == nil)
	link := fmt.aprintf("%s/link.png", root)
	defer delete(link)
	testing.expect(t, os.symlink(path, link) == nil)
	testing.expect(t, preview_decode({path = link, edge = 96}) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.icons = true
	s := preview_start()
	if !testing.expect(t, s != nil) {return}
	defer {preview_destroy(s)}
	b.previews = s
	g := geometry(960, 640, 1, icons = true)
	preview_prepare(s, &b, g)
	texture := preview_test_wait(t, s, renderer, path)
	testing.expect_value(t, texture.w, i32(96))
	testing.expect_value(t, texture.h, i32(48))
	testing.expect_value(t, preview_test_pixel(t, renderer, texture, 5, 5), [4]u8{255, 0, 0, 255})
	testing.expect_value(t, preview_test_pixel(t, renderer, texture, 85, 5), [4]u8{0, 0, 255, 255})
	testing.expect_value(t, s.bytes, int(texture.w) * int(texture.h) * 4)
	identity := s.cache[path].id
	preview_prepare(s, &b, g)
	testing.expect_value(t, s.cache[path].id, identity)
	failed_start := time.tick_now()
	for !s.cache[bad].ready && time.tick_since(failed_start) < 5 * time.Second {
		_ = preview_poll(s, renderer)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, s.cache[bad].ready && s.cache[bad].texture == nil)
	testing.expect(t, link not_in s.cache)
	dense := geometry(1920, 1280, 2, icons = true)
	preview_prepare(s, &b, dense)
	testing.expect(
		t,
		preview_texture(s, path) == texture,
		"keep the current preview during a density change",
	)
	texture = preview_test_wait(t, s, renderer, path)
	testing.expect_value(t, texture.w, i32(192))
	testing.expect_value(t, s.bytes, int(texture.w) * int(texture.h) * 4)
	// Leave an old decoded result queued, then change the same path again.
	preview_invalidate(s, []string{path})
	preview_prepare(s, &b, g)
	start := time.tick_now()
	for !preview_pending(s) &&
	    time.tick_since(start) < 5 * time.Second {time.sleep(time.Millisecond)}
	testing.expect(t, preview_pending(s))
	preview_invalidate(s, []string{path})
	preview_test_image(t, path, true)
	preview_prepare(s, &b, g)
	texture = preview_test_wait(t, s, renderer, path)
	testing.expect(t, s.cache[path].id != identity)
	testing.expect_value(t, preview_test_pixel(t, renderer, texture, 5, 5), [4]u8{0, 255, 0, 255})
	// Cache eviction must keep the visible preview, including after filtering.
	b.search = strings.clone("photo")
	browser_filter(&b)
	preview_prepare(s, &b, g)
	testing.expect(t, preview_evict(s))
	testing.expect(t, bad not_in s.cache && preview_texture(s, path) == texture)
	search_reset(&b)
	browser_filter(&b)
	// Shutdown must wake a producer waiting behind a full result queue.
	data, read_err := os.read_entire_file(path, context.allocator)
	testing.expect(t, read_err == nil)
	defer delete(data)
	for i in 0 ..< 12 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/copy-%02d.png", root, i), data) == nil)}
	testing.expect(t, browser_load(&b, root) == nil)
	preview_prepare(s, &b, g)
	full := false
	start = time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		sync.mutex_lock(&s.mutex)
		full = len(s.results) == 4
		sync.mutex_unlock(&s.mutex)
		if full {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, full)
	preview_destroy(s)
	s, b.previews = nil, nil
	// Shutdown must also wake a worker waiting for decode memory.
	s = preview_start(1)
	if !testing.expect(t, s != nil) {return}
	b.previews = s
	b.search = strings.clone("photo")
	browser_filter(&b)
	s.active_pixels = PREVIEW_PIXEL_LIMIT
	preview_prepare(s, &b, g)
	claimed := false
	start = time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		sync.mutex_lock(&s.mutex)
		claimed = len(s.queue) == 0
		sync.mutex_unlock(&s.mutex)
		if claimed {break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, claimed && !preview_pending(s))
	preview_destroy(s)
	s, b.previews = nil, nil
}

@(test)
svg_previews_rasterize_into_the_requested_box :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.VIDEO})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-svg-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create svg fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/logo.svg", root)
	defer delete(path)
	svg := `<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100"><rect width="200" height="100" fill="#0000ff"/></svg>`
	if !testing.expect(t, os.write_entire_file(path, svg) == nil) {return}
	native := preview_decode({path = path, edge = 64})
	if !testing.expect(t, native != nil) {return}
	defer sdl.DestroySurface(native)
	// The 2:1 logo fits the 64 pixel box with the aspect ratio kept.
	testing.expect_value(t, native.w, i32(64))
	testing.expect_value(t, native.h, i32(32))
	r, green, blue, alpha: u8
	sdl_check(sdl.ReadSurfacePixel(native, 32, 16, &r, &green, &blue, &alpha))
	testing.expect(t, r <= 2 && green <= 2 && blue >= 250 && alpha == 255)
}
