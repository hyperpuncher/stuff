package main

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
