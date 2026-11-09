package main

import "core:strings"
import "core:testing"
import text_edit "core:text/edit"
import sdl "vendor:sdl3"

@(test)
path_editor_word_delete_preserves_undo_selection :: proc(t: ^testing.T) {
	for item in ([?]struct {
			selection: [2]int,
			expected:  string,
		}{{{20, 20}, "/home/user/"}, {{6, 1}, "/user/Downloads"}}) {
		b: Browser
		defer browser_destroy(&b)
		b.path = strings.clone("/home/user/Downloads")
		path_edit_start(&b)
		b.header.edit.text.selection = item.selection
		g, running := geometry(960, 640, 1), true
		event := sdl.Event {
			key = {type = .KEY_DOWN, key = sdl.K_BACKSPACE, mod = sdl.KMOD_CTRL},
		}
		_ = handle_event(&b, &event, g, &running)
		testing.expect_value(t, strings.to_string(b.header.edit.buffer), item.expected)
		event.key.key = sdl.K_Z
		_ = handle_event(&b, &event, g, &running)
		testing.expect_value(t, strings.to_string(b.header.edit.buffer), b.path)
		testing.expect_value(t, b.header.edit.text.selection, item.selection)
		event.key.mod |= sdl.KMOD_SHIFT
		_ = handle_event(&b, &event, g, &running)
		testing.expect_value(t, strings.to_string(b.header.edit.buffer), item.expected)
		testing.expect(t, b.pending_files == nil)
	}
}

@(test)
path_editor_word_shortcuts :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/test")
	g, running := geometry(960, 640, 1), true
	cases := [?]struct {
		value:            string,
		cursor:           int,
		key:              sdl.Keycode,
		shift:            bool,
		expected:         string,
		position, anchor: int,
	} {
		{"/home/user/Downloads", 20, sdl.K_BACKSPACE, false, "/home/user/", 11, 11},
		{"/home/user/Downloads", 11, sdl.K_LEFT, false, "/home/user/Downloads", 6, 6},
		{"/home/user/Downloads", 11, sdl.K_DELETE, false, "/home/user/", 11, 11},
		{"alpha beta.txt", 14, sdl.K_BACKSPACE, false, "alpha beta.", 11, 11},
		{"alpha beta.txt", 14, sdl.K_LEFT, true, "alpha beta.txt", 11, 14},
		{"alpha beta.txt", 6, sdl.K_RIGHT, true, "alpha beta.txt", 10, 6},
		{"alpha beta.txt", 0, sdl.K_RIGHT, false, "alpha beta.txt", 6, 6},
		{"report-final.txt", 12, sdl.K_BACKSPACE, false, "report-.txt", 7, 7},
		{"report_final.txt", 12, sdl.K_BACKSPACE, false, ".txt", 0, 0},
		{"雪 a\u0301/👩‍💻", 19, sdl.K_BACKSPACE, false, "雪 a\u0301/", 8, 8},
		{"alpha\u00a0beta", 0, sdl.K_RIGHT, false, "alpha\u00a0beta", 7, 7},
		{"one two", 0, sdl.K_DELETE, true, "two", 0, 0},
	}
	for item in cases {
		path_edit_start(&b)
		text_edit.perform_command(&b.header.edit.text, .Select_All)
		path_edit_replace(&b, item.value)
		b.header.edit.text.selection = {item.cursor, item.cursor}
		mods := sdl.KMOD_CTRL
		if item.shift {mods |= sdl.KMOD_SHIFT}
		event := sdl.Event {
			key = {type = .KEY_DOWN, key = item.key, mod = mods},
		}
		_ = handle_event(&b, &event, g, &running)
		testing.expect_value(t, strings.to_string(b.header.edit.buffer), item.expected)
		testing.expect_value(t, b.header.edit.text.selection, [2]int{item.position, item.anchor})
		testing.expect(t, b.pending_files == nil)
	}
}
