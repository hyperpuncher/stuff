package main

import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
input_undo_restores_text_and_cursor_without_file_actions :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/test")
	path_edit_start(&b)
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		text = {type = .TEXT_INPUT, text = "雪 a\u0301"},
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_Z, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), "/test")
	testing.expect_value(t, b.header.edit.text.selection, [2]int{5, 5})
	event.key.mod |= sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), "/test雪 a\u0301")
	testing.expect_value(t, b.header.edit.text.selection, [2]int{12, 12})
	event.key.mod = sdl.KMOD_CTRL
	_ = handle_event(&b, &event, g, &running)
	event = {
		text = {type = .TEXT_INPUT, text = "new"},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.header.edit.text.redo), 0)
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), "/testnew")
	testing.expect(t, b.pending_files == nil)
	testing.expect_value(t, b.status_error, "")
	path_edit_end(&b.header.edit)
	path_edit_start(&b)
	testing.expect_value(t, len(b.header.edit.text.undo), 0)
	testing.expect_value(t, len(b.header.edit.text.redo), 0)

	// Use a short interval to test retention without waiting between edits.
	b.header.edit.text.undo_timeout = time.Nanosecond
	for _ in 0 ..< 110 {path_edit_replace(&b, "x")}
	testing.expect_value(t, len(b.header.edit.text.undo), 100)
}
