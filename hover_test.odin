package main


import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
hover_tracks_pointer_without_changing_selection :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	resize(&b.visible, 1000)
	for &source, i in b.visible {source = i}
	places_add(&b.places, {label = "root", path = "/", icon = .PlaceFilesystem})
	g := geometry(960, 640, 1)

	running := true
	event := sdl.Event {
		motion = {type = .MOUSE_MOTION, x = g.sidebar + 20, y = g.list_top + g.row / 2},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.hovered, clay.ID("row", 0).id)
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.DEFAULT)
	testing.expect_value(t, b.selected, 0)
	testing.expect_value(t, hover_color(&b, clay.ID("row", 0), {}), theme.hover)
	testing.expect_value(
		t,
		hover_color(&b, clay.ID("row", 0), theme.selected),
		theme.hover_selected,
	)
	event.motion.x += 1
	testing.expect(t, !handle_event(&b, &event, g, &running))

	event = sdl.Event {
		wheel = {
			type = .MOUSE_WHEEL,
			y = -1,
			mouse_x = g.sidebar + 20,
			mouse_y = g.list_top + g.row / 2,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.first, 3)
	testing.expect(
		t,
		hover_update(&b, g),
		"scrolling must update the item under a stationary pointer",
	)
	testing.expect_value(t, b.hovered, clay.ID("row", 3).id)
	event = sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_J},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.hovered, u32(0))
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.DEFAULT)
	testing.expect_value(t, b.selected, 1)
	testing.expect(
		t,
		!hover_update(&b, g),
		"keyboard navigation must not restore a stale pointer hover",
	)

	event = sdl.Event {
		motion = {type = .MOUSE_MOTION, x = 20, y = places_geometry(g).list_top + g.row / 2},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.hovered, clay.ID("place", 0).id)
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.POINTER)
	testing.expect_value(t, b.selected, 1)
	event = sdl.Event {
		window = {type = .WINDOW_MOUSE_LEAVE},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.hovered, u32(0))
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.DEFAULT)
	testing.expect(t, !handle_event(&b, &event, g, &running))

	event = sdl.Event {
		motion = {
			type = .MOUSE_MOTION,
			x = g.sidebar + g.padding + g.columns[.Name] + g.gap + 10,
			y = g.header + 1,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.hovered, clay.ID("column", u32(Column.Size)).id)
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.POINTER)
	testing.expect_value(t, b.sort_column, Column.Name)
	event.motion.y = g.header + g.row + 1
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.hovered == 0, "the list padding must not act like a column header")
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.DEFAULT)
}
