package main

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

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
		g := geometry(i32(960 * scale), i32(640 * scale), scale)
		for places in ([?]bool{false, true}) {
			b.first, b.places.first = 100, 100
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
			event.motion.y = y + 112 * scale
			_ = handle_event(&b, &event, g, &running)
			testing.expect(t, ui_wait_timeout(&b, now) > 0)
			for step in 1 ..= 3 {_ = autoscroll_update(&b, g, now + u64(step) * 100)}
			first := places ? &b.places.first : &b.first
			testing.expect_value(t, first^, 103)
			testing.expect_value(t, places ? b.first : b.places.first, 100)
			event.motion.y = y - 112 * scale
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
