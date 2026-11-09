package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
search_shortcuts_filter_unicode_names_and_preserve_pointer_targets :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/fixture")
	b.entries = make([]os.File_Info, 6)
	for name, i in ([?]string{"alpha.txt", "ALPHABET.md", "Beta.txt", "ПРИВЕТ.txt", "ΟΣ.txt", "Kelvin.txt"}) {
		b.entries[i] = {
			name = name,
			type = .Regular,
			size = i64(i + 1),
		}
	}
	browser_filter(&b)
	b.places.focused = true
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_F, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .Search && !b.places.focused)
	event = {
		text = {type = .TEXT_INPUT, text = "ALPHA"},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.visible), 2)
	testing.expect_value(t, b.visible_bytes, i64(3))
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_Z, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.visible), 6)
	event.key.mod |= sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.visible), 2)
	event.key.key, event.key.mod = sdl.K_RETURN, {}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.header.edit.active && b.header.edit.mode == .Search)
	// Clicking a result must not clear the filter before hit testing the row.
	event = {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = g.sidebar + 20,
			y = g.list_top + g.row + 1,
			clicks = 1,
		},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.search, "ALPHA")
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "alpha.txt")
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_ESCAPE},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.search, "")
	testing.expect_value(t, len(b.visible), 6)
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "alpha.txt")
	testing.expect(t, b.marks[0] && len(b.marks) == 1)
	search_start(&b)
	path_edit_replace(&b, "ALPHA")
	search_blur(&b.header.edit)
	selection_all(&b)
	b.menu.active = true
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.menu.active && b.search == "ALPHA")
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.marks), 2)
	testing.expect_value(t, b.marked_bytes, i64(3))
	testing.expect_value(t, len(b.visible), 6)
	event.key.key = sdl.K_SLASH
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active && b.header.edit.value == "")
	for item in ([?]struct {
			query, name: string,
		}{{"прив", "ПРИВЕТ.txt"}, {"ος", "ΟΣ.txt"}, {"kelvin", "Kelvin.txt"}}) {
		b.header.edit.anchor, b.header.edit.cursor = 0, len(b.header.edit.value)
		path_edit_replace(&b, item.query)
		testing.expect_value(t, len(b.visible), 1)
		if len(b.visible) == 1 {testing.expect_value(t, b.entries[b.visible[0]].name, item.name)}
	}
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_L, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.search, "")
	testing.expect_value(t, len(b.visible), 6)
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .Path)
	testing.expect_value(t, b.header.edit.value, b.path)
}

@(test)
search_stays_local_survives_refresh_and_clears_on_navigation :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-search-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create search fixture")}
	defer delete(root)
	defer os.remove_all(root)
	child := fmt.aprintf("%s/child", root)
	defer delete(child)
	testing.expect(t, os.make_directory(child) == nil)
	for name in ([?]string{"Alpha.txt", ".Alpha-hidden"}) {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%s", root, name), "data") == nil)}
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/nested-only.txt", child), "data") == nil,
	)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	search_start(&b)
	path_edit_replace(&b, "ALPHA")
	testing.expect_value(t, len(b.visible), 1)
	b.show_hidden = true
	browser_filter(&b)
	testing.expect_value(t, len(b.visible), 2)
	search_blur(&b.header.edit)
	testing.expect(t, browser_load(&b, root) == nil)
	testing.expect_value(t, b.search, "ALPHA")
	testing.expect_value(t, len(b.visible), 2)
	search_start(&b)
	path_edit_replace(&b, "nested-only")
	testing.expect_value(t, len(b.visible), 0)
	testing.expect(t, browser_navigate(&b, fmt.tprintf("%s/missing", root)) != nil)
	testing.expect_value(t, b.search, "nested-only")
	testing.expect(t, browser_navigate(&b, child) == nil)
	testing.expect_value(t, b.search, "")
	testing.expect(t, !b.header.edit.active && b.header.edit.mode == .Path)
	testing.expect_value(t, len(b.visible), 1)
	search_start(&b)
	path_edit_replace(&b, "nested")
	search_blur(&b.header.edit)
	file_dialog_start(&b, true)
	testing.expect_value(t, b.search, "")
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .Rename)
	testing.expect_value(t, b.header.edit.value, "nested-only.txt")
}

verify_search_rendering :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp")
	b.entries = make([]os.File_Info, 3)
	for name, i in ([?]string{"Alpha.txt", "Beta.txt", "Zoo.txt"}) {b.entries[i] = {
			name = name,
			type = .Regular,
		}}
	browser_filter(&b)
	g := geometry(960, 640, 1)
	search_start(&b)
	path_edit_replace(&b, "alpha")
	search_blur(&b.header.edit)
	commands := layout(&b, g, p)
	paint(p, commands, 960, 640)
	field := clay.GetElementData(clay.ID("path-edit"))
	testing.expect(t, field.found)
	testing.expect_value(t, field.boundingBox, path_edit_box(g))
	testing.expect(t, !clay.GetElementData(clay.ID("file-dialog")).found)
	testing.expect(t, !clay.GetElementData(clay.ID("path-edit-caret")).found)
	b.pointer = {
		x      = field.boundingBox.x + 10,
		y      = g.header / 2,
		active = true,
	}
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.TEXT)
	search_start(&b)
	path_edit_replace(&b, "zoo")
	search_end(&b)
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect_value(t, b.first, 0)
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "Zoo.txt")
}
