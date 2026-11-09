package main

import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
input_history_is_bounded_and_cleared_on_close :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/test")
	path_edit_start(&b)
	// Use a short interval to test retention without waiting between edits.
	b.header.edit.text.undo_timeout = time.Nanosecond
	for _ in 0 ..< 110 {path_edit_replace(&b, "x")}
	testing.expect_value(t, len(b.header.edit.text.undo), 100)

	// Close with both stacks populated, so the allocator checks cover their cleanup.
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_Z, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.header.edit.text.redo), 1)
	path_edit_end(&b.header.edit)
	path_edit_start(&b)
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), b.path)
	testing.expect_value(t, len(b.header.edit.text.undo), 0)
	testing.expect_value(t, len(b.header.edit.text.redo), 0)
}
