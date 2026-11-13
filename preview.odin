package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:sys/posix"
import "core:thread"
import "core:time"
import sdl "vendor:sdl3"
import stb "vendor:stb/image"

// Holds about 128 live 256 pixel textures before eviction.
PREVIEW_CACHE_BYTES :: 32 * 1024 * 1024
PREVIEW_CACHE_LIMIT :: 512
PREVIEW_FILE_LIMIT :: 32 * 1024 * 1024
PREVIEW_PIXEL_LIMIT :: 16 * 1024 * 1024

Preview_Entry :: struct {
	texture:        ^sdl.Texture,
	stamp:          time.Time,
	size:           i64,
	id, used:       u64,
	edge, bytes:    int,
	pending, ready: bool,
}
Preview_Request :: struct {
	path: string,
	id:   u64,
	edge: int,
}
Preview_Result :: struct {
	request: Preview_Request,
	surface: ^sdl.Surface,
}
// Only the UI owns the cache and textures. Workers own queued paths and
// decoded surfaces until publication. Every result keeps its request identity.
Preview_Service :: struct {
	mutex:         sync.Mutex,
	changed:       sync.Cond,
	workers:       [4]^thread.Thread,
	active_pixels: i64, // Bound full-size decodes across workers.
	allocator:     mem.Allocator,
	event:         sdl.EventType,
	stop:          bool,
	queue:         [dynamic]Preview_Request,
	results:       [dynamic]Preview_Result,
	cache:         map[string]Preview_Entry,
	clock, serial: u64,
	bytes:         int,
	disk_root:     string,
	disk_prefix:   string,
}

preview_supported :: proc(entry: os.File_Info) -> bool {
	if entry.type != .Regular || entry.size <= 0 || entry.size > PREVIEW_FILE_LIMIT {return false}
	ext := os.ext(entry.name)
	return(
		strings.equal_fold(ext, ".png") ||
		strings.equal_fold(ext, ".jpg") ||
		strings.equal_fold(ext, ".jpeg") ||
		strings.equal_fold(ext, ".gif") ||
		strings.equal_fold(ext, ".bmp") \
	)
}

// Buffered reads avoid keeping a second complete copy of the compressed file.
// The callbacks cannot read or seek past the size checked on the open file.
Preview_Input :: struct {
	file:         ^posix.FILE,
	size, offset: i64,
	failed:       bool,
}

preview_input_read :: proc "c" (user: rawptr, data: [^]u8, size: c.int) -> c.int {
	input := cast(^Preview_Input)user
	if input.failed || size <= 0 {return 0}
	want := min(i64(size), input.size - input.offset)
	n := posix.fread(data, 1, c.size_t(want), input.file)
	input.offset += i64(n)
	if i64(n) != want {input.failed = true}
	return c.int(n)
}

preview_input_skip :: proc "c" (user: rawptr, amount: c.int) {
	input := cast(^Preview_Input)user
	if input.failed {return}
	offset := input.offset + i64(amount)
	if offset < 0 || offset > input.size || posix.fseek(input.file, c.long(offset), .SET) != 0 {
		input.failed = true
		return
	}
	input.offset = offset
}

preview_input_eof :: proc "c" (user: rawptr) -> c.int {
	input := cast(^Preview_Input)user
	return input.failed || input.offset >= input.size ? 1 : 0
}

preview_decode :: proc(request: Preview_Request, service: ^Preview_Service = nil) -> ^sdl.Surface {
	path := strings.clone_to_cstring(request.path)
	defer delete(path)
	fd, err := linux.open(path, {.CLOEXEC, .NONBLOCK, .NOFOLLOW})
	if err != .NONE {return nil}
	file := posix.fdopen(posix.FD(fd), "rb")
	if file == nil {linux.close(fd); return nil}
	defer posix.fclose(file)
	stat: linux.Stat
	if linux.fstat(fd, &stat) != .NONE ||
	   !linux.S_ISREG(stat.mode) ||
	   stat.size <= 0 ||
	   stat.size > PREVIEW_FILE_LIMIT {return nil}
	input := Preview_Input {
		file = file,
		size = i64(stat.size),
	}
	callbacks := stb.Io_Callbacks{preview_input_read, preview_input_skip, preview_input_eof}
	width, height, channels: c.int
	if stb.info_from_callbacks(&callbacks, &input, &width, &height, &channels) == 0 ||
	   input.failed ||
	   width <= 0 ||
	   height <= 0 ||
	   i64(width) * i64(height) > PREVIEW_PIXEL_LIMIT {return nil}
	count := i64(width) * i64(height)
	if service != nil {
		sync.mutex_lock(&service.mutex)
		for !service.stop && service.active_pixels + count > PREVIEW_PIXEL_LIMIT {
			sync.cond_wait(&service.changed, &service.mutex)
		}
		if service.stop {sync.mutex_unlock(&service.mutex); return nil}
		service.active_pixels += count
		sync.mutex_unlock(&service.mutex)
	}
	// Function scope: release only after decoding, resizing, and freeing pixels.
	defer if service != nil {
		sync.mutex_lock(&service.mutex)
		service.active_pixels -= count
		sync.cond_broadcast(&service.changed)
		sync.mutex_unlock(&service.mutex)
	}
	if posix.fseek(file, 0, .SET) != 0 {return nil}
	input.offset = 0
	pixels := stb.load_from_callbacks(&callbacks, &input, &width, &height, &channels, 4)
	if pixels == nil {return nil}
	defer stb.image_free(pixels)
	if input.failed {return nil}
	return preview_scale(pixels, width, height, width * 4, request.edge)
}

preview_scale :: proc(pixels: [^]u8, width, height, pitch: c.int, edge: int) -> ^sdl.Surface {
	ratio := min(1, f64(edge) / f64(max(width, height)))
	output := sdl.CreateSurface(
		max(1, i32(math.round(f64(width) * ratio))),
		max(1, i32(math.round(f64(height) * ratio))),
		.RGBA32,
	)
	if output == nil {return nil}
	if output.w == width && output.h == height {
		target := cast([^]u8)output.pixels
		row_bytes := int(width) * 4
		for y in 0 ..< int(height) {copy(target[y * int(output.pitch):][:row_bytes], pixels[y * int(pitch):][:row_bytes])}
		return output
	}
	// A reduction filter covers the full source footprint, not just nearby pixels.
	// Resample sRGB colors with straight-alpha weighting to avoid dark fringes.
	if stb.resize_uint8_generic(
		   pixels,
		   width,
		   height,
		   pitch,
		   cast([^]u8)output.pixels,
		   output.w,
		   output.h,
		   output.pitch,
		   4,
		   3,
		   0,
		   .CLAMP,
		   .MITCHELL,
		   .SRGB,
		   nil,
	   ) ==
	   0 {
		sdl.DestroySurface(output)
		return nil
	}
	return output
}

preview_fit :: proc(surface: ^sdl.Surface, edge: int) -> ^sdl.Surface {
	if max(surface.w, surface.h) <= i32(edge) {return surface}
	result := preview_scale(cast([^]u8)surface.pixels, surface.w, surface.h, surface.pitch, edge)
	sdl.DestroySurface(surface)
	return result
}

preview_start :: proc(workers := 0, cache_root := "") -> ^Preview_Service {
	if cache_root != "" {preview_cache_prepare(cache_root)}
	event := sdl.RegisterEvents(1)
	if event == 0 {return nil}
	s := new(Preview_Service)
	s.event, s.allocator = sdl.EventType(event), context.allocator
	s.disk_root = strings.clone(cache_root)
	if cache_root != "" {s.disk_prefix = fmt.aprintf("%s/", cache_root)}
	count := clamp(workers > 0 ? workers : os.get_processor_core_count(), 1, len(s.workers))
	for i in 0 ..< count {
		s.workers[i] = thread.create_and_start_with_poly_data(
			s,
			preview_worker,
			name = "stuff-preview",
		)
		if s.workers[i] == nil {preview_destroy(s); return nil}
	}
	return s
}

preview_forget :: proc(s: ^Preview_Service, path: string) {
	key, entry := delete_key(&s.cache, path)
	if entry.texture != nil {sdl.DestroyTexture(entry.texture)}
	s.bytes -= entry.bytes
	delete(key)
}

preview_destroy :: proc(s: ^Preview_Service) {
	if s == nil {return}
	sync.mutex_lock(&s.mutex)
	s.stop = true
	sync.cond_broadcast(&s.changed)
	sync.mutex_unlock(&s.mutex)
	for worker in s.workers {if worker != nil {thread.destroy(worker)}}
	for request in s.queue {delete(request.path)}
	for result in s.results {delete(result.request.path); if result.surface != nil {sdl.DestroySurface(result.surface)}}
	delete(s.queue); delete(s.results)
	for path in s.cache {preview_forget(s, path)}
	delete(s.cache)
	delete(s.disk_root)
	delete(s.disk_prefix)
	free(s)
}

preview_invalidate :: proc(s: ^Preview_Service, paths: []string) {
	if s == nil {return}
	for path in s.cache {if size_path_changed(path, paths) {preview_forget(s, path)}}
}

preview_evict :: proc(s: ^Preview_Service, keep: string = "") -> bool {
	oldest: string
	age := ~u64(0)
	for path, entry in s.cache {
		if entry.used != s.clock &&
		   path != keep &&
		   entry.used < age {oldest, age = path, entry.used}
	}
	if oldest == "" {return false}
	preview_forget(s, oldest)
	return true
}

preview_prepare :: proc(s: ^Preview_Service, b: ^Browser, g: Geometry) {
	if s == nil {return}
	s.clock += 1
	stride := max(1, g.stride)
	visible_first := view_first(g, b.first, len(b.visible))
	visible_last := min(visible_first + g.rows + stride, len(b.visible))
	edge := clamp(int(math.ceil(THUMBNAIL_LOGICAL * g.scale)), THUMBNAIL_LOGICAL, THUMBNAIL_PIXELS)
	first := b.icons ? max(0, visible_first - 2 * stride) : 0
	last := b.icons ? min(visible_last + 2 * stride, len(b.visible)) : 0
	// Pin the visible and preload rows before any eviction, including after sorting.
	for i in first ..< last {
		entry := b.entries[b.visible[i]]
		if cached, exists := &s.cache[entry.fullpath]; exists {
			if !preview_supported(entry) ||
			   cached.size != entry.size ||
			   cached.stamp != entry.modification_time {
				preview_forget(s, entry.fullpath)
			} else {
				cached.used = s.clock
				if cached.edge < edge && (!cached.ready || cached.texture != nil) {
					// Keep good pixels while the denser replacement loads.
					s.serial += 1
					cached.id, cached.edge = s.serial, edge
					cached.pending, cached.ready = false, false
				}
			}
		}
	}
	// Rebuild the bounded queue in view order. Claimed requests stay pending.
	// This also frees queue slots held by old preload jobs after a scroll.
	sync.mutex_guard(&s.mutex)
	for request in s.queue {
		if cached, exists := &s.cache[request.path]; exists && cached.id == request.id {
			cached.pending = false
		}
		delete(request.path)
	}
	clear(&s.queue)
	if b.icons {
		for band in ([3][2]int{{visible_first, visible_last}, {visible_last, last}, {first, visible_first}}) {
			for i in band[0] ..< band[1] {
				entry := b.entries[b.visible[i]]
				if !preview_supported(entry) {continue}
				if _, exists := s.cache[entry.fullpath]; !exists {
					for len(s.cache) >= PREVIEW_CACHE_LIMIT {if !preview_evict(s) {break}}
					if len(s.cache) >= PREVIEW_CACHE_LIMIT {continue}
					s.serial += 1
					s.cache[strings.clone(entry.fullpath)] = {
						id    = s.serial,
						used  = s.clock,
						size  = entry.size,
						stamp = entry.modification_time,
						edge  = edge,
					}
				}
				cached := &s.cache[entry.fullpath]
				if cached.ready || cached.pending {continue}
				// Every visible item must be queued; preload stays bounded.
				if len(s.queue) < max(64, g.rows + g.stride) {
					append(
						&s.queue,
						Preview_Request{strings.clone(entry.fullpath), cached.id, edge},
					)
					cached.pending = true
				}
			}
		}
	}
	if len(s.queue) > 0 {sync.cond_broadcast(&s.changed)}
}

preview_texture :: proc(s: ^Preview_Service, path: string) -> ^sdl.Texture {
	if s == nil {return nil}
	return s.cache[path].texture
}

preview_pending :: proc(s: ^Preview_Service) -> bool {
	if s == nil {return false}
	sync.mutex_guard(&s.mutex)
	return len(s.results) > 0
}

preview_poll :: proc(s: ^Preview_Service, renderer: ^sdl.Renderer) -> bool {
	if s == nil {return false}
	changed := false
	// Bound texture uploads per frame; pending results prevent an idle wait.
	for _ in 0 ..< 2 {
		sync.mutex_lock(&s.mutex)
		if len(s.results) == 0 {sync.mutex_unlock(&s.mutex); break}
		result := s.results[0]
		ordered_remove(&s.results, 0)
		sync.cond_broadcast(&s.changed)
		sync.mutex_unlock(&s.mutex)
		defer delete(result.request.path)
		defer if result.surface != nil {sdl.DestroySurface(result.surface)}
		cached, exists := &s.cache[result.request.path]
		if !exists || cached.id != result.request.id {continue}
		cached.pending, cached.ready = false, true
		changed = true
		if result.surface == nil {continue}
		bytes := int(result.surface.w) * int(result.surface.h) * 4
		for s.bytes - cached.bytes + bytes >
		    PREVIEW_CACHE_BYTES {if !preview_evict(s, result.request.path) {break}}
		if s.bytes - cached.bytes + bytes > PREVIEW_CACHE_BYTES {continue}
		texture := sdl.CreateTextureFromSurface(renderer, result.surface)
		if texture == nil {continue}
		_ = sdl.SetTextureScaleMode(texture, .LINEAR)
		if cached.texture != nil {sdl.DestroyTexture(cached.texture)}
		s.bytes += bytes - cached.bytes
		cached.texture, cached.bytes = texture, bytes
	}
	return changed
}

preview_worker :: proc(s: ^Preview_Service) {
	context.allocator = s.allocator
	for {
		sync.mutex_lock(&s.mutex)
		for !s.stop && len(s.queue) == 0 {sync.cond_wait(&s.changed, &s.mutex)}
		if s.stop {sync.mutex_unlock(&s.mutex); return}
		request := s.queue[0]
		ordered_remove(&s.queue, 0)
		sync.mutex_unlock(&s.mutex)
		surface := preview_thumbnail(s, request)
		free_all(context.temp_allocator)
		sync.mutex_lock(&s.mutex)
		for !s.stop && len(s.results) >= 4 {sync.cond_wait(&s.changed, &s.mutex)}
		if s.stop {
			sync.mutex_unlock(&s.mutex)
			delete(request.path)
			if surface != nil {sdl.DestroySurface(surface)}
			return
		}
		wake := len(s.results) == 0
		append(&s.results, Preview_Result{request, surface})
		sync.mutex_unlock(&s.mutex)
		if wake {
			notify_ui(s.event, "preview")
		}
	}
}
