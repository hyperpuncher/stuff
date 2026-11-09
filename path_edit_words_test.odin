package main

import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
path_editor_word_movement_and_deletion :: proc(t: ^testing.T) {
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
		{"alpha beta.txt", 0, sdl.K_DELETE, false, " beta.txt", 0, 0},
		{"alpha beta.txt", 14, sdl.K_BACKSPACE, false, "alpha beta.", 11, 11},
		{"alpha beta.txt", 14, sdl.K_LEFT, false, "alpha beta.txt", 11, 11},
		{"alpha beta.txt", 5, sdl.K_RIGHT, false, "alpha beta.txt", 10, 10},
		{"alpha beta.txt", 0, sdl.K_RIGHT, true, "alpha beta.txt", 5, 0},
		{"alpha beta.txt", 11, sdl.K_BACKSPACE, false, "alpha txt", 6, 6},
		{"one two", 3, sdl.K_DELETE, true, "one", 3, 3},
		{"雪 a\u0301/👩‍💻", 19, sdl.K_BACKSPACE, false, "雪 a\u0301/", 8, 8},
		{"雪 a\u0301/👩‍💻", 8, sdl.K_BACKSPACE, false, "雪 👩‍💻", 4, 4},
	}
	for item in cases {
		path_edit_start(&b)
		path_edit_replace(&b, item.value)
		b.header.edit.cursor, b.header.edit.anchor = item.cursor, item.cursor
		mods := sdl.KMOD_CTRL
		if item.shift {mods |= sdl.KMOD_SHIFT}
		event := sdl.Event {
			key = {type = .KEY_DOWN, key = item.key, mod = mods},
		}
		_ = handle_event(&b, &event, g, &running)
		testing.expect_value(t, b.header.edit.value, item.expected)
		testing.expect_value(t, b.header.edit.cursor, item.position)
		testing.expect_value(t, b.header.edit.anchor, item.anchor)
		testing.expect(t, b.pending_files == nil)
	}
}
