package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
path_editor_navigation_clipboard_and_cancel :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-path-edit-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create path fixture")}
	defer delete(root)
	defer os.remove_all(root)
	child := fmt.aprintf("%s/folder space 雪", root)
	defer delete(child)
	testing.expect(t, os.make_directory(child) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_L, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active)
	testing.expect_value(t, b.header.edit.value, root)
	testing.expect_value(t, b.header.edit.cursor - b.header.edit.anchor, len(root))
	event = {
		text = {type = .TEXT_INPUT, text = "folder space 雪"},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.path, root) // Typing must not navigate yet.
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_RETURN},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.path, child)
	testing.expect(t, !b.header.edit.active)
	testing.expect_value(t, len(b.back), 1)
	event.key = {
		type = .KEY_DOWN,
		key  = sdl.K_L,
		mod  = sdl.KMOD_CTRL,
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		text = {type = .TEXT_INPUT, text = "missing"},
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_RETURN},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.path, child)
	testing.expect_value(t, b.header.edit.value, "missing")
	testing.expect(t, b.header.edit.active && b.status_error != "")
	event.key.key = sdl.K_ESCAPE
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.header.edit.active)
	testing.expect_value(t, b.path, child)
	// Text clipboard shortcuts operate on the selected path, not the file list.
	event.key = {
		type = .KEY_DOWN,
		key  = sdl.K_L,
		mod  = sdl.KMOD_CTRL,
	}
	_ = handle_event(&b, &event, g, &running)
	event.key.key = sdl.K_X
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "")
	event.key.key = sdl.K_V
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, child)
	event.key = {
		type = .KEY_DOWN,
		key  = sdl.K_RETURN,
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.header.edit.active)
	testing.expect_value(t, b.path, child)
	path_edit_start(&b)
	path_edit_replace(&b, ".")
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.path, child)
	testing.expect_value(t, len(b.back), 1) // An alias of the current folder adds no history entry.
}

@(test)
path_editor_preserves_graphemes_and_blocks_file_actions :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/test")
	b.entries = make([]os.File_Info, 1)
	b.entries[0] = {
		name = "keep",
		type = .Directory,
	}
	browser_filter(&b)
	b.places.focused = true
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_L, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active && !b.places.focused)
	event = {
		text = {type = .TEXT_INPUT, text = "a\u0301👩‍💻雪"},
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_BACKSPACE},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "a\u0301👩‍💻")
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "a\u0301")
	event.key.key = sdl.K_LEFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.cursor, 0)
	event.key.key, event.key.mod = sdl.K_RIGHT, sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	event.key.key, event.key.mod = sdl.K_DELETE, {}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "")
	testing.expect(t, b.pending_files == nil)
	testing.expect_value(t, len(b.marks), 1)
	path_edit_replace(&b, "bad\npath")
	testing.expect_value(t, b.header.edit.value, "")
	event = {
		edit = {type = .TEXT_EDITING, text = "雪"},
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_RETURN},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active)
	testing.expect_value(t, b.path, "/test")
	event = {
		text = {type = .TEXT_INPUT, text = "雪"},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "雪")
	testing.expect_value(t, b.header.edit.composition, "")
}

verify_path_editor_rendering :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.repeat("/long folder 雪", 30)
	g := geometry(960, 640, 1)
	path_edit_start(&b)
	commands := layout(&b, g, p)
	entry := clay.GetElementData(clay.ID("path-edit"))
	testing.expect(t, entry.found)
	testing.expect(t, b.header.edit.offset > 0)
	paint(p, commands, 960, 640)
	// A pointer drag selects text in the field without changing file selection.
	path_edit_click(&b.header.edit, g, entry.boundingBox.x + 10, false)
	anchor := b.header.edit.anchor
	b.header.edit.dragging = true
	event := sdl.Event {
		motion = {
			type = .MOUSE_MOTION,
			x = entry.boundingBox.x + entry.boundingBox.width - 10,
			y = g.header / 2,
		},
	}
	running := true
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.anchor, anchor)
	testing.expect(t, b.header.edit.cursor > anchor)
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.TEXT)
	paint(p, layout(&b, g, p), 960, 640)
	window := sdl.GetRenderWindow(p.renderer)
	sdl_check(sdl.StartTextInput(window))
	path_edit_ime_area(&b.header.edit, g, window)
	sdl_check(sdl.StopTextInput(window))
}
