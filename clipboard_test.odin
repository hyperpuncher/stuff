package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

Test_Clipboard_Offer :: struct {
	uris, gnome, kde: string,
}

test_clipboard_offer :: proc "c" (userdata: rawptr, mime: cstring, size: ^uint) -> rawptr {
	if mime == nil {size^ = 0; return nil}
	offer := cast(^Test_Clipboard_Offer)userdata
	value := offer.uris
	if string(mime) == FILE_GNOME_MIME {value = offer.gnome}
	if string(mime) == FILE_KDE_CUT_MIME {value = offer.kde}
	size^ = uint(len(value))
	return raw_data(value)
}

@(test)
file_clipboard_formats :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 1)
	b.entries[0] = {
		fullpath = strings.clone("/tmp/a b#%.txt"),
		name     = "a b#%.txt",
		type     = .Regular,
	}
	browser_filter(&b)
	file_clipboard_copy(&b)
	testing.expect_value(t, b.status_error, "")
	for mime in ([?]cstring{FILE_URI_MIME, FILE_GNOME_MIME, FILE_KDE_CUT_MIME}) {
		testing.expect(t, sdl.HasClipboardData(mime))
		size: uint
		data := sdl.GetClipboardData(mime, &size)
		if data == nil {testing.fail_now(t, string(sdl.GetError()))}
		value := string((cast([^]u8)data)[:size])
		if string(mime) == FILE_GNOME_MIME {
			testing.expect_value(t, value, "copy\nfile:///tmp/a%20b%23%25.txt")
		}
		if string(mime) ==
		   FILE_KDE_CUT_MIME {testing.expect_value(t, value, "0")} else {testing.expect(t, strings.contains(value, "file:///tmp/a%20b%23%25.txt"))}
		sdl.free(data)
	}
	paths := file_clipboard_read(&b)
	testing.expect_value(t, len(paths), 1)
	if len(paths) == 1 {testing.expect_value(t, paths[0], b.entries[0].fullpath)}
	file_paths_destroy(paths)

	offer := Test_Clipboard_Offer {
		uris = "file:///tmp/example\r\n",
		kde  = "0",
	}
	kde_mimes := [?]cstring{FILE_URI_MIME, FILE_KDE_CUT_MIME}
	testing.expect(
		t,
		sdl.SetClipboardData(
			test_clipboard_offer,
			nil,
			&offer,
			raw_data(kde_mimes[:]),
			len(kde_mimes),
		),
	)
	defer sdl.ClearClipboardData()
	paths = file_clipboard_read(&b)
	testing.expect_value(t, len(paths), 1)
	if len(paths) == 1 {testing.expect_value(t, paths[0], "/tmp/example")}
	file_paths_destroy(paths)
	// Reject KDE cuts, malformed markers, and contradictory GNOME/KDE offers.
	for marker in ([?]string{"1", "", "invalid"}) {
		offer.kde = marker
		paths = file_clipboard_read(&b)
		testing.expect_value(t, len(paths), 0)
		file_paths_destroy(paths)
		testing.expect(t, b.status_error != "")
	}
	mimes := [?]cstring{FILE_URI_MIME, FILE_GNOME_MIME, FILE_KDE_CUT_MIME}
	testing.expect(
		t,
		sdl.SetClipboardData(test_clipboard_offer, nil, &offer, raw_data(mimes[:]), len(mimes)),
	)
	for cut_gnome in ([?]bool{false, true}) {
		offer.gnome = cut_gnome ? "cut\nfile:///tmp/example\n" : "copy\nfile:///tmp/example\n"
		offer.kde = cut_gnome ? "0" : "1"
		paths = file_clipboard_read(&b)
		testing.expect_value(t, len(paths), 0)
		file_paths_destroy(paths)
	}
}

@(test)
file_uris_preserve_names_and_reject_remote_paths :: proc(t: ^testing.T) {
	names := [?]string{"/tmp/a b#%\n.txt", "/tmp/日本語", "/tmp/invalid-\xff"}
	data := file_uri_list(names[:])
	defer delete(data)
	paths, ok := file_uri_paths(data, false)
	defer file_paths_destroy(paths)
	testing.expect(t, ok)
	testing.expect_value(t, len(paths), len(names))
	for path, i in paths {testing.expect_value(t, path, names[i])}
	for bad in ([?]string{"file://remote/tmp/a", "https://example.com/a", "file:///tmp/%00", "file:///tmp/%zz", "file:///tmp/a?query", "file:///tmp/a#fragment"}) {
		parsed, valid := file_uri_paths(fmt.tprintf("file:///tmp/valid\n%s", bad), false)
		testing.expect(t, !valid)
		testing.expect_value(t, len(parsed), 0)
		file_paths_destroy(parsed)
	}
}
