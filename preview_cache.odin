package main

import "core:c"
import "core:crypto/legacy/md5"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:hash"
import "core:math/rand"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import sdl "vendor:sdl3"
import stb "vendor:stb/image"

PREVIEW_DISK_BUCKET :: "large"
PREVIEW_DISK_LIMIT :: 2 * 1024 * 1024

preview_cache_root :: proc(cache_home, home: string) -> string {
	base := cache_home
	if !strings.has_prefix(base, "/") {
		if !strings.has_prefix(home, "/") {return ""}
		base = fmt.tprintf("%s/.cache", strings.trim_right(home, "/"))
	}
	return fmt.tprintf("%s/thumbnails", strings.trim_right(base, "/"))
}

preview_cache_key :: proc(path: string) -> (uri, name: string) {
	out := strings.builder_make()
	strings.write_string(&out, "file://")
	file_uri_path(path, &out)
	uri = strings.to_string(out)
	// MD5 is the standard filename key, not an authenticity check.
	ctx: md5.Context
	md5.init(&ctx)
	md5.update(&ctx, transmute([]u8)uri)
	digest: [md5.DIGEST_SIZE]u8
	md5.final(&ctx, digest[:])
	encoded, _ := hex.encode(digest[:], context.temp_allocator)
	name = fmt.aprintf("%s.png", encoded)
	return
}

// Directories are created once when the service starts, not per write.
preview_cache_prepare :: proc(root: string) {
	for path in ([2]string{root, fmt.tprintf("%s/%s", root, PREVIEW_DISK_BUCKET)}) {
		_ = os.make_directory_all(path, os.perm_number(0o700))
	}
}

preview_source_stat :: proc(path: string) -> (stat: linux.Stat, ok: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(name, {.CLOEXEC, .NONBLOCK, .NOFOLLOW})
	if err != .NONE {return}
	defer linux.close(fd)
	ok =
		linux.fstat(fd, &stat) == .NONE &&
		linux.S_ISREG(stat.mode) &&
		stat.size > 0 &&
		stat.size <= PREVIEW_FILE_LIMIT
	return
}

// PNG metadata is untrusted. Validate chunk bounds and CRCs before decoding.
preview_cache_valid :: proc(data: []u8, uri: string, stat: linux.Stat, limit: int) -> bool {
	if len(data) < 33 || string(data[:8]) != "\x89PNG\r\n\x1a\n" {return false}
	if endian.unchecked_get_u32be(data[8:]) != 13 || string(data[12:16]) != "IHDR" {return false}
	width, height := endian.unchecked_get_u32be(data[16:]), endian.unchecked_get_u32be(data[20:])
	if width == 0 || height == 0 || width > u32(limit) || height > u32(limit) {return false}
	found_uri, found_time, ended := false, false, false
	for offset := 8; offset + 12 <= len(data); {
		length := int(endian.unchecked_get_u32be(data[offset:]))
		if length > len(data) - offset - 12 {return false}
		end := offset + 8 + length
		if hash.crc32(data[offset + 4:end]) !=
		   endian.unchecked_get_u32be(data[end:]) {return false}
		kind := string(data[offset + 4:offset + 8])
		if kind == "IHDR" && offset != 8 {return false}
		if kind == "tEXt" {
			text := string(data[offset + 8:end])
			zero := strings.index_byte(text, 0)
			if zero >= 0 {
				key, value := text[:zero], text[zero + 1:]
				switch key {
				case "Thumb::URI":
					if value != uri {return false}; found_uri = true
				case "Thumb::MTime":
					if value != fmt.tprintf("%d", i64(stat.mtime.time_sec)) {return false}
					found_time = true
				case "Thumb::Size":
					if value != fmt.tprintf("%d", stat.size) {return false}
				case "X-Stuff::MTimeNS":
					if value != fmt.tprintf("%d", stat.mtime.time_nsec) {return false}
				case "X-Stuff::CTime":
					if value !=
					   fmt.tprintf(
						   "%d:%d",
						   stat.ctime.time_sec,
						   stat.ctime.time_nsec,
					   ) {return false}
				}
			}
		}
		if kind == "IEND" {ended = length == 0; break}
		offset = end + 4
	}
	return ended && found_uri && found_time
}

preview_cache_read :: proc(path, uri: string, stat: linux.Stat, limit: int) -> ^sdl.Surface {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd, err := linux.open(name, {.CLOEXEC, .NONBLOCK, .NOFOLLOW})
	if err != .NONE {return nil}
	defer linux.close(fd)
	info: linux.Stat
	if linux.fstat(fd, &info) != .NONE ||
	   !linux.S_ISREG(info.mode) ||
	   info.size == 0 ||
	   info.size > PREVIEW_DISK_LIMIT {return nil}
	data := make([]u8, int(info.size))
	defer delete(data)
	for offset := 0; offset < len(data); {
		n, read_err := linux.read(fd, data[offset:])
		if read_err == .EINTR {continue}
		if read_err != .NONE || n <= 0 {return nil}
		offset += n
	}
	if !preview_cache_valid(data, uri, stat, limit) {return nil}
	w, h, channels: c.int
	pixels := stb.load_from_memory(raw_data(data), c.int(len(data)), &w, &h, &channels, 4)
	if pixels == nil {return nil}
	defer stb.image_free(pixels)
	if w <= 0 || h <= 0 || w > c.int(limit) || h > c.int(limit) {return nil}
	// Return the stored size. The caller downscales to the displayed edge.
	return preview_scale(pixels, w, h, w * 4, int(max(w, h)))
}

preview_cache_text :: proc(out: ^[dynamic]u8, key, value: string) {
	length := len(key) + 1 + len(value)
	header: [8]u8
	endian.unchecked_put_u32be(header[:], u32(length))
	copy(header[4:], "tEXt")
	append(out, ..header[:])
	start := len(out^) - 4
	append(out, ..transmute([]u8)key)
	append(out, 0)
	append(out, ..transmute([]u8)value)
	crc: [4]u8
	endian.unchecked_put_u32be(crc[:], hash.crc32(out^[start:]))
	append(out, ..crc[:])
}

preview_cache_store :: proc(root, name, uri: string, stat: linux.Stat, surface: ^sdl.Surface) {
	io := sdl.IOFromDynamicMem()
	if io == nil {return}
	defer sdl.CloseIO(io)
	if !sdl.SavePNG_IO(surface, io, false) {return}
	length := sdl.GetIOSize(io)
	if length < 12 || length > PREVIEW_DISK_LIMIT {return}
	data := make([]u8, int(length))
	defer delete(data)
	if sdl.SeekIO(io, 0, .SEEK_SET) < 0 ||
	   sdl.ReadIO(io, raw_data(data), uint(len(data))) != uint(len(data)) {return}
	if string(data[len(data) - 8:len(data) - 4]) != "IEND" {return}
	tagged := make([dynamic]u8)
	defer delete(tagged)
	append(&tagged, ..data[:len(data) - 12])
	preview_cache_text(&tagged, "Thumb::URI", uri)
	preview_cache_text(&tagged, "Thumb::MTime", fmt.tprintf("%d", i64(stat.mtime.time_sec)))
	preview_cache_text(&tagged, "Thumb::Size", fmt.tprintf("%d", stat.size))
	preview_cache_text(&tagged, "X-Stuff::MTimeNS", fmt.tprintf("%d", stat.mtime.time_nsec))
	preview_cache_text(
		&tagged,
		"X-Stuff::CTime",
		fmt.tprintf("%d:%d", stat.ctime.time_sec, stat.ctime.time_nsec),
	)
	preview_cache_text(&tagged, "Software", "stuff")
	append(&tagged, ..data[len(data) - 12:])
	root_c := strings.clone_to_cstring(root, context.temp_allocator)
	parent, parent_err := private_dir_open_at(linux.AT_FDCWD, root_c)
	if parent_err != nil {return}
	defer linux.close(parent)
	dir, dir_err := private_dir_open_at(parent, PREVIEW_DISK_BUCKET)
	if dir_err != nil {return}
	defer linux.close(dir)
	// The shared cache must be private. The open helpers verify ownership;
	// repair only these owned directory descriptors, never a followed link.
	for fd in ([2]linux.Fd{parent, dir}) {
		st: linux.Stat
		if linux.fstat(fd, &st) != .NONE {return}
		if transmute(u32)st.mode & 0o077 != 0 &&
		   linux.fchmod(fd, transmute(linux.Mode)u32(0o700)) != .NONE {return}
	}
	temporary := strings.clone_to_cstring(
		fmt.tprintf(".stuff-%d-%016x", linux.getpid(), rand.uint64()),
		context.temp_allocator,
	)
	fd, open_err := linux.openat(
		dir,
		temporary,
		{.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC},
		transmute(linux.Mode)u32(0o600),
	)
	if open_err != .NONE {return}
	defer linux.unlinkat(dir, temporary, {})
	for offset := 0; offset < len(tagged); {
		n, write_err := linux.write(fd, tagged[offset:])
		if write_err == .EINTR {continue}
		if write_err != .NONE || n <= 0 {linux.close(fd); return}
		offset += n
	}
	if linux.close(fd) != .NONE {return}
	name_c := strings.clone_to_cstring(name, context.temp_allocator)
	_ = linux.renameat(dir, temporary, dir, name_c)
}

// Disk I/O and PNG encoding stay on preview workers, never on the UI thread.
preview_thumbnail :: proc(s: ^Preview_Service, request: Preview_Request) -> ^sdl.Surface {
	if s.disk_root == "" || strings.has_prefix(request.path, s.disk_prefix) {
		return preview_decode(request, s)
	}
	stat, readable := preview_source_stat(request.path)
	if !readable {return nil}
	uri, name := preview_cache_key(request.path)
	defer delete(uri); defer delete(name)
	path := fmt.tprintf("%s/%s/%s", s.disk_root, PREVIEW_DISK_BUCKET, name)
	if surface := preview_cache_read(path, uri, stat, THUMBNAIL_PIXELS); surface != nil {
		return preview_fit(surface, request.edge)
	}
	source := request
	source.edge = THUMBNAIL_PIXELS
	surface := preview_decode(source, s)
	if surface == nil {return nil}
	after, valid := preview_source_stat(request.path)
	if valid &&
	   stat.dev == after.dev &&
	   stat.ino == after.ino &&
	   stat.size == after.size &&
	   stat.mtime == after.mtime &&
	   stat.ctime == after.ctime {
		preview_cache_store(s.disk_root, name, uri, stat, surface)
	}
	return preview_fit(surface, request.edge)
}
