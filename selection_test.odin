package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
multi_selection_ranges_sort_and_hidden_items :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 5)
	for &entry, i in b.entries {
		entry.fullpath = fmt.aprintf("/tmp/%d", i)
		entry.name = entry.fullpath[5:]
		entry.type, entry.size = .Regular, i64(i + 1)
	}
	b.entries[4].name = ".hidden"
	browser_filter(&b)
	selection_click(&b, 2, true, false)
	testing.expect_value(t, len(b.marks), 2)
	testing.expect_value(t, b.marked_bytes, i64(4))
	selection_click(&b, 0, true, false)
	testing.expect_value(t, len(b.marks), 1)
	selection_click(&b, 2, false, false)
	selection_click(&b, 0, false, true)
	testing.expect_value(t, len(b.marks), 3)
	testing.expect_value(t, b.marked_bytes, i64(6))
	selection_click(&b, 1, false, true)
	testing.expect_value(t, len(b.marks), 2) // A shorter range replaces the previous range.
	browser_set_sort(&b, .Size)
	browser_set_sort(&b, .Size)
	testing.expect(t, b.marks[1] && b.marks[2])
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_A, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.marks), 4)
	testing.expect_value(t, b.marked_bytes, i64(10))
	testing.expect(t, !b.marks[4])
	testing.expect(t, strings.contains(browser_summary(&b), "selected: 4 items (10 B)"))
	b.show_hidden = true
	browser_filter(&b)
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.marks), 5)
	testing.expect_value(t, b.marked_bytes, i64(15))
	selection_single(&b, 1)
	event.key = {
		type = .KEY_DOWN,
		key  = sdl.K_DOWN,
		mod  = sdl.KMOD_SHIFT,
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.marks), 2)
}

@(test)
context_menu_preserves_groups_and_captures_input :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 3)
	for &entry, i in b.entries {
		entry.fullpath = fmt.aprintf("/tmp/menu-%d", i)
		entry.name = entry.fullpath
		entry.type = .Regular
	}
	browser_filter(&b)
	selection_click(&b, 2, true, false)
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_RIGHT,
			x = g.sidebar + 40,
			y = g.list_top + 1,
		},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.menu.active)
	testing.expect_value(t, len(b.marks), 2)
	b.menu.width = 160
	for paste in ([?]bool{false, true}) {
		b.menu.paste = paste
		box := menu_box(&b, g)
		testing.expect_value(t, box.height, (paste ? 4 : 3) * g.row + 8 * g.scale)
		x, y := box.x + box.width / 2, box.y + 4 * g.scale + 1.5 * g.row
		expected: Menu_Action = paste ? .Paste : .Trash
		testing.expect_value(t, menu_action_at(&b, g, x, y), int(expected))
		_ = pointer_move(&b, g, x, y)
		testing.expect_value(t, b.hovered, clay.ID("menu-item", u32(expected)).id)
		key := sdl.Event {
			key = {type = .KEY_DOWN, key = sdl.K_HOME},
		}
		_ = handle_event(&b, &key, g, &running)
		testing.expect_value(t, b.menu.selected, int(Menu_Action.Copy))
		key.key.key = sdl.K_DOWN
		_ = handle_event(&b, &key, g, &running)
		testing.expect_value(t, b.menu.selected, int(expected))
	}
	event.button.y += g.row
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.marks), 1)
	testing.expect(t, b.marks[b.visible[1]])
	// An outside click closes the menu without opening or selecting a background row.
	event.button.button, event.button.x = sdl.BUTTON_LEFT, g.width - 5
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.menu.active)
	testing.expect_value(t, b.selected, 1)
	event.button.button = sdl.BUTTON_RIGHT
	event.button.y = list_bottom(g) - 1
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.menu.active)
	testing.expect_value(t, len(b.marks), 0)
	testing.expect(t, !menu_enabled(&b, .Copy) && !menu_enabled(&b, .Trash))
	box := menu_box(&b, g)
	testing.expect(t, box.x + box.width <= g.width && box.y + box.height <= g.height)
	event = {
		key = {type = .KEY_DOWN, key = sdl.K_END},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.menu.selected, int(Menu_Action.Select_All))
	event.key.key = sdl.K_RETURN
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.menu.active)
	testing.expect_value(t, len(b.marks), 3)
}
