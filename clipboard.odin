package main

import "core:encoding/hex"
import "core:strings"
import sdl "vendor:sdl3"

FILE_URI_MIME :: "text/uri-list"
FILE_GNOME_MIME :: "x-special/gnome-copied-files"
FILE_KDE_CUT_MIME :: "application/x-kde-cutselection"

// File names are bytes on Linux. Do not replace invalid UTF-8 during URI encoding.
file_uri_path :: proc(path: string, out: ^strings.Builder) {
	digits := "0123456789ABCDEF"
	for i in 0 ..< len(path) {
		c := path[i]
		if c >= 'a' && c <= 'z' ||
		   c >= 'A' && c <= 'Z' ||
		   c >= '0' && c <= '9' ||
		   c == '/' ||
		   c == '-' ||
		   c == '_' ||
		   c == '.' ||
		   c == '~' ||
		   strings.index_byte("!$&'()*+,:=@", c) >= 0 {
			strings.write_byte(out, c)
		} else {
			strings.write_byte(out, '%')
			strings.write_byte(out, digits[c >> 4])
			strings.write_byte(out, digits[c & 15])
		}
	}
}

file_uri_list :: proc(paths: []string, gnome := false) -> string {
	out := strings.builder_make()
	if gnome {strings.write_string(&out, "copy")}
	for path in paths {
		strings.write_string(&out, gnome ? "\nfile://" : "file://")
		file_uri_path(path, &out)
		if !gnome {strings.write_string(&out, "\r\n")}
	}
	return strings.to_string(out)
}

file_uri_parse :: proc(uri: string) -> (path: string, ok: bool) {
	if !strings.has_prefix(uri, "file://") {return}
	rest := uri[7:]
	if strings.has_prefix(rest, "localhost/") {rest = rest[9:]}
	if len(rest) == 0 || rest[0] != '/' {return}
	out := strings.builder_make()
	defer if !ok {strings.builder_destroy(&out)}
	for i := 0; i < len(rest); i += 1 {
		c := rest[i]
		if c == '%' {
			if i + 2 >= len(rest) {return}
			value, valid := hex.decode_sequence(rest[i + 1:i + 3])
			if !valid {return}
			c = value
			i += 2
		} else if c == '?' || c == '#' || c <= ' ' {return}
		if c == 0 {return}
		strings.write_byte(&out, c)
	}
	return strings.to_string(out), true
}

file_uri_paths :: proc(data: string, gnome: bool) -> (paths: [dynamic]string, ok: bool) {
	data := data
	if gnome {
		line, _ := strings.split_by_byte_iterator(&data, '\n')
		// Cut is not implemented. Never silently move or reinterpret a cut offer.
		if strings.trim_suffix(line, "\r") != "copy" {return nil, false}
	}
	for raw_line in strings.split_by_byte_iterator(&data, '\n') {
		line := strings.trim_suffix(raw_line, "\r")
		if line == "" || strings.has_prefix(line, "#") {continue}
		path, valid := file_uri_parse(line)
		if !valid {file_paths_destroy(paths); return nil, false}
		append(&paths, path)
	}
	ok = len(paths) > 0
	return
}

// SDL owns this block, including its URI bytes. SDL can retain it after a failed
// SetClipboardData call, so only its cleanup callback frees it.
File_Clipboard :: struct {
	uri_length, gnome_length: uint,
}

file_clipboard_data :: proc "c" (userdata: rawptr, mime: cstring, size: ^uint) -> rawptr {
	if mime == nil {size^ = 0; return nil}
	if string(mime) == FILE_KDE_CUT_MIME {size^ = 1; return raw_data(string("0"))}
	data := cast(^File_Clipboard)userdata
	start := cast([^]u8)userdata
	start = start[size_of(File_Clipboard):]
	if string(mime) == FILE_GNOME_MIME {size^ = data.gnome_length; return &start[data.uri_length]}
	size^ = data.uri_length
	return start
}

file_clipboard_cleanup :: proc "c" (userdata: rawptr) {sdl.free(userdata)}

file_clipboard_copy :: proc(b: ^Browser) {
	paths := selection_paths(b)
	defer file_paths_destroy(paths)
	if len(paths) == 0 {return}
	uris := file_uri_list(paths[:])
	defer delete(uris)
	gnome := file_uri_list(paths[:], true)
	defer delete(gnome)
	length := len(uris) + len(gnome)
	data := cast(^File_Clipboard)sdl.malloc(uint(size_of(File_Clipboard) + length))
	if data == nil {browser_message(b, "cannot allocate clipboard data"); return}
	data.uri_length, data.gnome_length = uint(len(uris)), uint(len(gnome))
	bytes := (cast([^]u8)data)[size_of(File_Clipboard):size_of(File_Clipboard) + length]
	copy(bytes, uris)
	copy(bytes[len(uris):], gnome)
	mimes := [?]cstring{FILE_URI_MIME, FILE_GNOME_MIME, FILE_KDE_CUT_MIME}
	if !sdl.SetClipboardData(
		file_clipboard_data,
		file_clipboard_cleanup,
		data,
		raw_data(mimes[:]),
		len(mimes),
	) {
		browser_message(b, string(sdl.GetError()))
	} else {browser_message(b, ""); b.header.copied_until = 0}
}

file_clipboard_has_files :: proc() -> bool {
	return sdl.HasClipboardData(FILE_GNOME_MIME) || sdl.HasClipboardData(FILE_URI_MIME)
}

file_clipboard_read :: proc(b: ^Browser) -> [dynamic]string {
	// KDE sends its action separately from the URI list. Check it even when
	// the same offer also provides a GNOME action, so conflicting cut offers fail.
	if sdl.HasClipboardData(FILE_KDE_CUT_MIME) {
		size: uint
		data := sdl.GetClipboardData(FILE_KDE_CUT_MIME, &size)
		if data ==
		   nil {browser_message(b, "cannot paste: the clipboard action is unavailable"); return nil}
		marker := string((cast([^]u8)data)[:size])
		copy_offer := marker == "0"
		sdl.free(data)
		if !copy_offer {
			browser_message(b, "cannot paste: only copied local files are supported")
			return nil
		}
	}
	gnome := sdl.HasClipboardData(FILE_GNOME_MIME)
	mime: cstring = FILE_URI_MIME
	if gnome {mime = FILE_GNOME_MIME}
	if !sdl.HasClipboardData(mime) {browser_message(b, "the clipboard has no files"); return nil}
	size: uint
	data := sdl.GetClipboardData(mime, &size)
	if data == nil {browser_message(b, string(sdl.GetError())); return nil}
	defer sdl.free(data)
	paths, ok := file_uri_paths(string((cast([^]u8)data)[:size]), gnome)
	if !ok {browser_message(b, "cannot paste: only copied local files are supported")}
	return paths
}
