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
	// Header gaps and points outside the pane must not change the sort.
	for x in ([?]f32{g.sidebar - 1, g.sidebar + g.padding + g.columns[.Name] + g.gap / 2, g.width}) {
		event.button.x = x
		_ = handle_event(&b, &event, g, &running)
		testing.expect_value(t, b.sort_column, Column.Modified)
		testing.expect(t, b.descending)
	}

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
file_type_labels :: proc(t: ^testing.T) {
	cases := [?]struct {
		name:  string,
		kind:  os.File_Type,
		label: string,
	} {
		{"photo.PNG", .Regular, "png"},
		{"README", .Regular, "file"},
		{".gitignore", .Regular, "file"},
		{".config.json", .Regular, "json"},
		{"trailing.", .Regular, "file"},
		{"folder.zip", .Directory, "folder"},
		{"link.png", .Symlink, "symlink"},
		{"pipe.txt", .Named_Pipe, "pipe"},
	}
	for item in cases {
		testing.expect_value(t, entry_type({name = item.name, type = item.kind}), item.label)
	}
}

@(test)
type_column_sorting_keeps_folders_first_and_name_ties :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	fixtures := [?]os.File_Info {
		{name = "folder.zip", type = .Directory},
		{name = "alpha.zip", type = .Regular},
		{name = "beta.TXT", type = .Regular},
		{name = "gamma.txt", type = .Regular},
		{name = "README", type = .Regular},
		{name = "link.txt", type = .Symlink},
	}
	b.entries = make([]os.File_Info, len(fixtures))
	copy(b.entries, fixtures[:])
	browser_filter(&b)
	g := geometry(960, 640, 1)
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = g.width - g.padding - g.columns[.Modified] - g.gap - g.columns[.Type] / 2,
			y = g.header + 1,
		},
	}
	running := true
	orders := [?][len(fixtures)]string {
		{"folder.zip", "README", "link.txt", "beta.TXT", "gamma.txt", "alpha.zip"},
		{"folder.zip", "alpha.zip", "beta.TXT", "gamma.txt", "link.txt", "README"},
	}
	for expected, pass in orders {
		testing.expect(t, handle_event(&b, &event, g, &running))
		testing.expect_value(t, b.sort_column, Column.Type)
		testing.expect_value(t, b.descending, pass == 1)
		for name, i in expected {testing.expect_value(t, b.entries[b.visible[i]].name, name)}
	}
}
