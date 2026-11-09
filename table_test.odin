package main

import "core:os"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
column_sorting_keeps_selection_and_scroll :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	fixtures := [?]os.File_Info {
		{name = "folder-b", type = .Directory},
		{name = "folder-a", type = .Directory},
		{name = "nine", type = .Regular, size = 9, modification_time = time.unix(300, 0)},
		{name = "hundred-z", type = .Regular, size = 100, modification_time = time.unix(100, 0)},
		{name = "hundred-a", type = .Regular, size = 100, modification_time = time.unix(200, 0)},
		{name = "link", type = .Symlink, size = 1000, modification_time = time.unix(400, 0)},
	}
	b.entries = make([]os.File_Info, len(fixtures))
	copy(b.entries, fixtures[:])
	browser_filter(&b)
	for source, i in b.visible {
		if b.entries[source].name == "nine" {b.selected = i}
	}
	b.first = 2

	browser_set_sort(&b, .Size)
	expected := [?]string{"folder-a", "folder-b", "link", "nine", "hundred-a", "hundred-z"}
	for name, i in expected {testing.expect_value(t, b.entries[b.visible[i]].name, name)}
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "nine")
	testing.expect_value(t, b.first, 2)
	browser_set_sort(&b, .Size)
	testing.expect(t, b.descending)
	testing.expect_value(t, b.entries[b.visible[2]].name, "hundred-a")
	testing.expect_value(t, b.entries[b.visible[3]].name, "hundred-z")
	testing.expect_value(t, b.entries[b.visible[4]].name, "nine")
	testing.expect_value(t, b.entries[b.visible[5]].name, "link")
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "nine")
	testing.expect_value(t, b.first, 2)

	// Click the date header, not a row. Dates sort by timestamp, not by text.
	g := geometry(960, 640, 1)
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = g.width - g.padding - g.columns[.Modified] / 2,
			y = g.header + 1,
		},
	}

	running := true
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.sort_column, Column.Modified)
	testing.expect(t, !b.descending)
	testing.expect_value(t, b.entries[b.visible[2]].name, "hundred-z")
	testing.expect_value(t, b.entries[b.visible[5]].name, "link")
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.descending)
	testing.expect_value(t, b.entries[b.visible[2]].name, "link")
	testing.expect_value(t, b.entries[b.visible[5]].name, "hundred-z")
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "nine")
	testing.expect_value(t, b.first, 2)
	testing.expect(t, b.status_error == "")

	browser_set_sort(&b, .Name)
	browser_set_sort(&b, .Name)
	testing.expect_value(t, b.entries[b.visible[0]].name, "folder-b")
	testing.expect_value(t, b.entries[b.visible[1]].name, "folder-a")
	testing.expect_value(t, b.entries[b.visible[2]].name, "nine")
	clear(&b.visible)
	browser_set_sort(&b, .Size)
	testing.expect_value(t, len(b.visible), 0)
}

@(test)
column_header_bounds :: proc(t: ^testing.T) {
	g := geometry(960, 640, 1)
	left := g.sidebar + g.padding
	for width, column in g.columns {
		found, ok := column_at(g, left + width / 2)
		testing.expect(t, ok)
		testing.expect_value(t, found, column)
		_, in_gap := column_at(g, left + width + g.gap / 2)
		testing.expect(t, !in_gap)
		left += width + g.gap
	}
	_, before := column_at(g, g.padding - 1)
	_, after := column_at(g, g.width)
	testing.expect(t, !before && !after)
	minimum := geometry(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, 1)
	testing.expect(t, minimum.columns[.Name] > 30)
	testing.expect(
		t,
		minimum.list_top + f32(minimum.rows) * minimum.row <=
		minimum.height - minimum.footer - minimum.list_padding,
	)
}
