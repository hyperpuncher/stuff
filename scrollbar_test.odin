package main

import "core:fmt"
import "core:os"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

verify_autoscroll_icons :: proc(t: ^testing.T, p: ^Painter) {
	cases := [?]struct {
		width:  i32,
		count:  int,
		places: bool,
		icon:   Icon,
	} {
		{960, 100, false, .MoveVertical},
		{600, 100, false, .Move},
		{600, 1, false, .MoveHorizontal},
		{600, 1, true, .MoveVertical},
	}
	for item in cases {
		b: Browser
		defer browser_destroy(&b)
		b.entries = make([]os.File_Info, item.count)
		for &entry in b.entries {entry.name, entry.type = "sample.txt", .Regular}
		if item.places {resize(&b.places.entries, 100)}
		browser_filter(&b)
		g := geometry(item.width, 480, 1)
		x := item.places ? g.sidebar / 2 : g.sidebar + 100
		testing.expect(t, autoscroll_begin(&b, g, x, g.list_top + g.row / 2))
		commands := layout(&b, g, p)
		markers := 0
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType != .Image {continue}
			for kind in ([?]Icon{.Move, .MoveHorizontal, .MoveVertical}) {
				if cmd.renderData.image.imageData != p.icons[kind] {continue}
				markers += 1
				testing.expect_value(t, kind, item.icon)
			}
		}
		testing.expect_value(t, markers, 1)
	}
}

@(test)
partial_rows_and_scrollbar_range :: proc(t: ^testing.T) {
	g := geometry(960, 640, 1)
	partial_top := g.list_top + f32(g.rows) * g.row
	testing.expect(t, partial_top < list_bottom(g))
	testing.expect_value(t, row_at(g, partial_top + 1, 0, 100), g.rows)
	testing.expect_value(t, row_at(g, list_bottom(g), 0, 100), -1)
	testing.expect_value(t, row_at(g, partial_top + 1, 0, g.rows), -1)
	testing.expect_value(t, scrollbar_geometry(g, g.rows, 0, false).track.height, f32(0))
	top := scrollbar_geometry(g, 1000, 0, false)
	bottom := scrollbar_geometry(g, 1000, 1000, false)
	testing.expect_value(t, top.thumb.y, top.track.y)
	testing.expect_value(
		t,
		bottom.thumb.y + bottom.thumb.height,
		bottom.track.y + bottom.track.height,
	)
	testing.expect(t, top.thumb.height > 0 && top.thumb.height < top.track.height)
	testing.expect_value(t, top.max_first, 1000 - g.rows)
}

@(test)
scrollbars_drag_only_their_own_pane :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	resize(&b.visible, 1000)
	resize(&b.places.entries, 1000)
	b.selected, b.places.selected = 3, 2
	g := geometry(960, 640, 1)
	running := true
	panes := [?]bool{false, true}
	for places in panes {
		b.first, b.places.first = 0, 0
		bar := scrollbar_for(&b, g, places)
		x := bar.track.x + bar.track.width / 2
		event := sdl.Event {
			button = {
				type = .MOUSE_BUTTON_DOWN,
				button = sdl.BUTTON_LEFT,
				x = x,
				y = bar.thumb.y + bar.thumb.height / 2,
			},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect(t, b.drag.active && b.drag.places == places)
		testing.expect_value(t, b.places.focused, places)
		event = sdl.Event {
			motion = {type = .MOUSE_MOTION, x = x, y = bar.track.y + bar.track.height},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, places ? b.places.first : b.first, bar.max_first)
		testing.expect_value(t, places ? b.first : b.places.first, 0)
		testing.expect_value(t, b.selected, 3)
		testing.expect_value(t, b.places.selected, 2)
		event = sdl.Event {
			button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_LEFT},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect(t, !b.drag.active)
		event = sdl.Event {
			button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, x = x, y = bar.track.y},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, places ? b.places.first : b.first, 0)
		event = sdl.Event {
			type = .WINDOW_FOCUS_LOST,
		}
		_ = handle_event(&b, &event, g, &running)
		testing.expect(t, !b.drag.active)
		_, footer_hit := scrollbar_hit(&b, g, x, g.height - g.footer + 1)
		testing.expect(t, !footer_hit)
	}
}

@(test)
middle_button_autoscroll_keeps_selection_and_targets_one_pane :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 1000)
	resize(&b.visible, 1000)
	resize(&b.places.entries, 1000)
	b.selected, b.places.selected = 3, 2
	running := true
	for scale in ([?]f32{1, 2}) {
		g := geometry(i32(600 * scale), i32(640 * scale), scale)
		for places in ([?]bool{false, true}) {
			b.first, b.places.first, b.scroll_x = 100, 100, 0
			x := places ? g.sidebar / 2 : g.sidebar + 100 * scale
			y := (g.list_top + list_bottom(g)) / 2
			event := sdl.Event {
				button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_MIDDLE, x = x, y = y},
			}
			testing.expect(t, handle_event(&b, &event, g, &running))
			now := b.autoscroll.tick
			event = {
				motion = {type = .MOUSE_MOTION, x = x, y = y + 10 * scale},
			}
			_ = handle_event(&b, &event, g, &running)
			testing.expect_value(t, ui_wait_timeout(&b, now), i32(-1))
			event.motion.x, event.motion.y = x + 112 * scale, y + 112 * scale
			_ = handle_event(&b, &event, g, &running)
			testing.expect(t, ui_wait_timeout(&b, now) > 0)
			for step in 1 ..= 3 {_ = autoscroll_update(&b, g, now + u64(step) * 100)}
			first := places ? &b.places.first : &b.first
			testing.expect_value(t, first^, 103)
			testing.expect_value(t, places ? b.first : b.places.first, 100)
			testing.expect_value(t, b.scroll_x > 0, !places)
			event.motion.x, event.motion.y = x, y - 112 * scale
			_ = handle_event(&b, &event, g, &running)
			_ = autoscroll_update(&b, g, now + 400)
			testing.expect_value(t, first^, 102)
			first^ = 0
			_ = autoscroll_update(&b, g, now + 500)
			testing.expect_value(t, first^, 0)
			testing.expect_value(t, ui_wait_timeout(&b, now + 500), i32(-1))
			event.motion.y = y + 112 * scale
			_ = handle_event(&b, &event, g, &running)
			_ = autoscroll_update(&b, g, now + 10_000)
			testing.expect(t, first^ == 1, "a stalled frame must not cause a large jump")
			testing.expect_value(t, b.selected, 3)
			testing.expect_value(t, b.places.selected, 2)
			event = {
				button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_MIDDLE},
			}
			testing.expect(t, handle_event(&b, &event, g, &running))
			testing.expect(t, !autoscroll_update(&b, g, now + 10_100))
			testing.expect_value(t, first^, 1)
			testing.expect_value(t, ui_wait_timeout(&b, now + 10_100), i32(-1))
		}
	}
}

@(test)
middle_button_autoscroll_handles_horizontal_only_overflow :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 2)
	b.entries[0] = {
		name = "a",
		type = .Regular,
	}
	b.entries[1] = {
		name = "b",
		type = .Regular,
	}
	browser_filter(&b)
	selection_single(&b, 1)
	scale: f32 = 1.5
	g, running := geometry(900, 720, scale), true
	x, y := g.sidebar + 60 * scale, g.list_top + g.row / 2
	event := sdl.Event {
		button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_MIDDLE, x = x, y = y},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	now := b.autoscroll.tick
	event = {
		motion = {type = .MOUSE_MOTION, x = x + 112 * scale, y = y},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, ui_wait_timeout(&b, now) > 0)
	testing.expect(t, autoscroll_update(&b, g, now + 10_000))
	testing.expect(
		t,
		b.scroll_x > 0 && table_scroll_offset(&b, g) < table_scroll_max(g),
		"a stalled frame must scroll without jumping to the end",
	)
	event.motion.x = x + 1000 * scale
	_ = handle_event(&b, &event, g, &running)
	_ = autoscroll_update(&b, g, now + 10_100)
	testing.expect_value(t, table_scroll_offset(&b, g), table_scroll_max(g))
	_ = autoscroll_update(&b, g, now + 10_200)
	testing.expect_value(t, ui_wait_timeout(&b, now + 10_200), i32(-1))
	event.motion.x = x - 112 * scale
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, autoscroll_update(&b, g, now + 10_300))
	testing.expect(t, table_scroll_offset(&b, g) < table_scroll_max(g))
	testing.expect_value(t, b.first, 0)
	testing.expect(t, b.selected == 1 && len(b.marks) == 1 && b.marks[1])
	event = {
		button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_MIDDLE},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, !autoscroll_update(&b, g, now + 10_400))
}

@(test)
middle_button_autoscroll_stops_on_input_and_window_changes :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 1000)
	resize(&b.visible, 1000)
	g, running := geometry(960, 640, 1), true
	x, y := g.sidebar + 100, g.list_top + 100
	stops := [?]sdl.Event {
		{button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, x = x, y = y, clicks = 2}},
		{button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_RIGHT, x = x, y = y}},
		{key = {type = .KEY_DOWN, key = sdl.K_ESCAPE}},
		{key = {type = .KEY_DOWN, key = sdl.K_A}},
		{wheel = {type = .MOUSE_WHEEL}},
		{type = .WINDOW_MOUSE_LEAVE},
		{type = .WINDOW_FOCUS_LOST},
		{type = .WINDOW_MINIMIZED},
		{type = .WINDOW_DISPLAY_SCALE_CHANGED},
		{type = .DROP_BEGIN},
	}
	for &event in stops {
		start := sdl.Event {
			button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_MIDDLE, x = x, y = y},
		}
		_ = handle_event(&b, &start, g, &running)
		testing.expect(t, b.autoscroll.active)
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect(t, !b.autoscroll.active && !b.menu.active)
		testing.expect_value(t, len(b.marks), 0)
	}
	start := sdl.Event {
		button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_MIDDLE, x = x, y = g.height - 1},
	}
	_ = handle_event(&b, &start, g, &running)
	testing.expect(t, !b.autoscroll.active)
	start.button.y = y
	clear(&b.visible)
	_ = handle_event(&b, &start, g, &running)
	testing.expect(t, !b.autoscroll.active)
}

@(test)
horizontal_table_scrolling_keeps_selection_and_header_targets :: proc(t: ^testing.T) {
	mods := sdl.GetModState()
	defer sdl.SetModState(mods)
	for scale in ([?]f32{1, 1.5}) {
		b: Browser
		defer browser_destroy(&b)
		b.entries = make([]os.File_Info, 100)
		for &entry, i in b.entries {
			entry.fullpath = fmt.aprintf("/horizontal-scroll/%03d.txt", i)
			entry.name = entry.fullpath[len("/horizontal-scroll/"):]
			entry.type = .Regular
		}
		browser_filter(&b)
		selection_single(&b, 5)
		selected := b.visible[b.selected]
		b.first, b.places.first = 3, 2
		resize(&b.places.entries, 50)
		g, running := geometry(i32(600 * scale), i32(480 * scale), scale), true
		event := sdl.Event {
			wheel = {
				type = .MOUSE_WHEEL,
				x = 100,
				mouse_x = g.sidebar + 30 * scale,
				mouse_y = g.list_top + 1,
			},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, table_scroll_offset(&b, g), table_scroll_max(g))
		x := g.width - g.padding - g.columns[.Modified] / 2
		_ = pointer_move(&b, g, x, g.header + 1)
		testing.expect_value(t, b.hovered, clay.ID("column", u32(Column.Modified)).id)
		event.wheel.direction = .FLIPPED
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, b.scroll_x, f32(0))
		sdl.SetModState(sdl.KMOD_SHIFT)
		event.wheel.x, event.wheel.y, event.wheel.direction = 0, -1, .NORMAL
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, table_scroll_offset(&b, g), 3 * g.row)
		sdl.SetModState(mods)
		event = {
			button = {
				type = .MOUSE_BUTTON_DOWN,
				button = sdl.BUTTON_LEFT,
				x = x,
				y = g.header + 1,
			},
		}
		_ = table_scroll_by(&b, g, table_scroll_max(g))
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, b.sort_column, Column.Modified)
		bar := table_scrollbar(&b, g)
		y := bar.track.y + bar.track.height / 2
		event = {
			button = {
				type = .MOUSE_BUTTON_DOWN,
				button = sdl.BUTTON_LEFT,
				x = bar.thumb.x + bar.thumb.width / 2,
				y = y,
			},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		event = {
			motion = {type = .MOUSE_MOTION, x = bar.track.x, y = y},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, b.scroll_x, f32(0))
		event = {
			button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_LEFT},
		}
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, b.first, 3)
		testing.expect_value(t, b.places.first, 2)
		testing.expect(
			t,
			b.visible[b.selected] == selected && len(b.marks) == 1 && b.marks[selected],
		)
		testing.expect(t, !table_scrollbar_hit(&b, g, x, g.height - g.footer + 1))
	}
}
