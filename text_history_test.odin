package main

import "core:strings"
import "core:testing"
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
	end := b.header.edit.cursor
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_BACKSPACE},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "雪 ")
	event.key.key, event.key.mod = sdl.K_Z, sdl.KMOD_CTRL
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "雪 a\u0301")
	testing.expect_value(t, b.header.edit.cursor, end)
	testing.expect_value(t, b.header.edit.anchor, end)
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "/test")
	testing.expect_value(t, b.header.edit.anchor, 0)
	testing.expect_value(t, b.header.edit.cursor, 5)
	event.key.mod |= sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "雪 ")
	event.key.mod = sdl.KMOD_CTRL
	_ = handle_event(&b, &event, g, &running)
	event = {
		text = {type = .TEXT_INPUT, text = "new"},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.header.edit.redo), 0)
	testing.expect_value(t, b.header.edit.value, "雪 a\u0301new")
	testing.expect(t, b.pending_files == nil)
	testing.expect_value(t, b.status_error, "")
	path_edit_end(&b.header.edit)
	path_edit_start(&b)
	testing.expect_value(t, len(b.header.edit.undo), 0)
	testing.expect_value(t, len(b.header.edit.redo), 0)
}
