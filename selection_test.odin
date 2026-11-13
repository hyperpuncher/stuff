package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

verify_selection_drag_rendering :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	defer browser_destroy(&b)
	clay.SetLayoutDimensions({960, 640})
	cases := [?]struct {
		scale, offset: f32,
	}{{1, 0}, {1.25, 0.25}, {1.5, 0.5}, {2, 0.75}}
	for item in cases {
		b.selection_drag = {
			active = true,
			start  = {30 * item.scale + item.offset, 80 * item.scale + item.offset},
			end    = {130 * item.scale + item.offset, 160 * item.scale + item.offset},
		}
		clay.BeginLayout()
		selection_drag_layout(&b)
		commands := clay.EndLayout(0)
		borders, fills := 0, 0
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType != .Rectangle {continue}
			box := cmd.boundingBox
			for value in ([4]f32{box.x, box.y, box.width, box.height}) {
				testing.expect_value(t, value, math.round(value))
			}
			if cmd.id == clay.ID("selection-drag").id {
				fills += 1
				alpha := cmd.renderData.rectangle.backgroundColor[3]
				testing.expect(t, alpha > 0 && alpha < 64)
			} else {
				borders += 1
				testing.expect_value(t, min(box.width, box.height), f32(1))
			}
		}
		testing.expect(t, borders == 4 && fills == 1)
		paint(p, commands, 960, 640)
	}
}

@(test)
empty_space_drag_selects_rows_and_can_shrink :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 4)
	for &entry, i in b.entries {
		entry.fullpath = fmt.aprintf("/tmp/selection-%d", i)
		entry.name = entry.fullpath
		entry.type, entry.size = .Regular, i64(i + 1)
	}
	browser_filter(&b)
	g, running := geometry(960, 640, 1), true
	x, y := g.sidebar + 200, g.list_top + 6 * g.row
	event := sdl.Event {
		button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, x = x, y = y},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.selection_drag.active && len(b.marks) == 0)
	event = {
		motion = {type = .MOUSE_MOTION, x = x - 100, y = g.list_top + 1.5 * g.row},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, len(b.marks) == 3 && !b.marks[b.visible[0]])
	testing.expect_value(t, b.marked_bytes, i64(9))
	// Reversing the drag replaces the range instead of accumulating marks.
	event.motion.y = g.list_top + 3.5 * g.row
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, len(b.marks) == 1 && b.marks[b.visible[3]])
	testing.expect_value(t, b.marked_bytes, i64(4))
	event = {
		button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_LEFT},
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		motion = {type = .MOUSE_MOTION, x = x, y = g.list_top},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, len(b.marks) == 1 && b.marks[b.visible[3]])
	// Focus loss must stop the gesture and request a redraw of its outline.
	event = {
		button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, x = x, y = y},
	}
	_ = handle_event(&b, &event, g, &running)
	event = {
		window = {type = .WINDOW_FOCUS_LOST},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, !b.selection_drag.active)
}

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
selection_summary_uses_cached_folder_sizes :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	fixtures := [?]os.File_Info {
		{name = "folder", type = .Directory},
		{name = "waiting", type = .Directory},
		{name = "file.txt", type = .Regular, size = 1024},
		{name = "link", type = .Symlink, size = 4096},
	}
	b.entries = make([]os.File_Info, len(fixtures))
	copy(b.entries, fixtures[:])
	for &entry in b.entries {entry.fullpath = fmt.aprintf("/selection-summary/%s", entry.name)}
	browser_filter(&b)
	selection_all(&b)
	b.sizes[strings.clone(b.entries[0].fullpath)] = {
		state = .Known,
		bytes = 2048,
	}
	waiting := strings.clone(b.entries[1].fullpath)
	for state in ([?]Size_State{.Pending, .Failed}) {
		b.sizes[waiting] = {
			state = state,
			bytes = 5120,
		}
		testing.expect_value(
			t,
			browser_summary(&b),
			"4 items    selected: 4 items (at least 3.0 KiB)",
		)
	}
	// A known empty folder completes the total. Later cache updates need no reselection.
	b.sizes[waiting] = {
		state = .Known,
	}
	testing.expect_value(t, browser_summary(&b), "4 items    selected: 4 items (3.0 KiB)")
	selection_single(&b, 1)
	testing.expect_value(t, browser_summary(&b), "4 items    selected: 0 B")
	b.sizes[waiting] = {
		state = .Known,
		bytes = 5120,
	}
	testing.expect_value(t, browser_summary(&b), "4 items    selected: 5.0 KiB")
	selection_all(&b)
	testing.expect_value(t, browser_summary(&b), "4 items    selected: 4 items (8.0 KiB)")
	selection_clear(&b)
	testing.expect_value(t, browser_summary(&b), "4 items")
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
		testing.expect_value(t, box.height, (paste ? 6 : 5) * g.row + 8 * g.scale)
		x, y := box.x + box.width / 2, box.y + 4 * g.scale + 1.5 * g.row
		expected: Menu_Action = paste ? .Paste : .New_Folder
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

@(test)
space_toggles_the_cursor_row :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 3)
	for &entry, i in b.entries {
		entry.fullpath = fmt.aprintf("/tmp/space-%d", i)
		entry.name = entry.fullpath
		entry.type, entry.size = .Regular, i64(10)
	}
	browser_filter(&b)
	// The filter marks the cursor row already; the first space clears it.
	g, running := geometry(960, 640, 1), true
	space := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_SPACE},
	}
	testing.expect(t, handle_event(&b, &space, g, &running))
	testing.expect_value(t, len(b.marks), 0)
	// The next space marks the cursor row again.
	testing.expect(t, handle_event(&b, &space, g, &running))
	testing.expect(t, b.marks[b.visible[0]])
	// Repeats must not flip the mark.
	space.key.repeat = true
	_ = handle_event(&b, &space, g, &running)
	testing.expect_value(t, len(b.marks), 1)
	// Toggling marks the cursor row only and leaves the cursor in place.
	space.key.repeat = false
	b.selected = 2
	testing.expect(t, handle_event(&b, &space, g, &running))
	// The toggle adds the cursor row without clearing other marks.
	testing.expect(t, b.marks[b.visible[0]] && b.marks[b.visible[2]])
	testing.expect_value(t, b.selected, 2)
}
