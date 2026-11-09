package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import sdl "vendor:sdl3"

@(test)
xdg_places_and_navigation :: proc(t: ^testing.T) {
	if !sdl.Init({}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-places-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create places fixture")}
	defer delete(root)
	defer os.remove_all(root)
	home := fmt.aprintf("%s/home", root)
	defer delete(home)
	config := fmt.aprintf("%s/config", root)
	defer delete(config)
	desktop := fmt.aprintf("%s/Бюро", home)
	defer delete(desktop)
	documents := fmt.aprintf("%s/Work Docs", root)
	defer delete(documents)
	downloads := fmt.aprintf("%s/Get Here", home)
	defer delete(downloads)
	folders := [?]string{home, config, desktop, documents, downloads}
	for path in folders {testing.expect(t, os.make_directory(path) == nil)}
	for i in 0 ..< 6 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/file-%d.txt", home, i), "x") == nil)}
	config_file := fmt.aprintf("%s/user-dirs.dirs", config)
	defer delete(config_file)
	catalog := fmt.tprintf(
		"XDG_DESKTOP_DIR=\"$HOME/Бюро\"\nXDG_DOCUMENTS_DIR=\"%s\"\nXDG_DOWNLOAD_DIR=\"$HOME/Get Here\"\nXDG_PICTURES_DIR=\"$HOME/Get Here/\"\nXDG_MUSIC_DIR=\"$HOME/\"\nXDG_VIDEOS_DIR=\"$HOME/Missing\"\n",
		documents,
	)
	testing.expect(t, os.write_entire_file(config_file, catalog) == nil)

	// Use the real SDL XDG lookup without changing the user's configuration.
	environment := sdl.GetEnvironment()
	home_value := sdl.GetEnvironmentVariable(environment, "HOME")
	config_value := sdl.GetEnvironmentVariable(environment, "XDG_CONFIG_HOME")
	old_home := strings.clone_to_cstring(string(home_value))
	defer delete(old_home)
	old_config := strings.clone_to_cstring(string(config_value))
	defer delete(old_config)
	defer {
		if home_value ==
		   nil {_ = sdl.UnsetEnvironmentVariable(environment, "HOME")} else {_ = sdl.SetEnvironmentVariable(environment, "HOME", old_home, true)}
		if config_value ==
		   nil {_ = sdl.UnsetEnvironmentVariable(environment, "XDG_CONFIG_HOME")} else {_ = sdl.SetEnvironmentVariable(environment, "XDG_CONFIG_HOME", old_config, true)}
	}
	home_c := strings.clone_to_cstring(home)
	defer delete(home_c)
	config_c := strings.clone_to_cstring(config)
	defer delete(config_c)
	if !sdl.SetEnvironmentVariable(environment, "HOME", home_c, true) ||
	   !sdl.SetEnvironmentVariable(environment, "XDG_CONFIG_HOME", config_c, true) {
		testing.fail_now(t, "cannot set the isolated XDG configuration")
	}
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, home) == nil)
	places_init(&b.places)
	// Duplicate paths, disabled folders, and missing directories add no dead entries.
	labels := [?]string{"home", "desktop", "documents", "downloads", "", "filesystem"}
	testing.expect_value(t, len(b.places.entries), len(labels))
	if len(b.places.entries) != len(labels) {return}
	for label, i in labels {testing.expect_value(t, b.places.entries[i].label, label)}
	testing.expect_value(t, b.places.entries[0].path, home)
	testing.expect_value(t, b.places.entries[1].path, desktop)
	testing.expect_value(t, b.places.entries[2].path, documents)
	testing.expect_value(t, b.places.entries[3].path, downloads)
	testing.expect_value(t, b.places.entries[5].path, "/")
	testing.expect_value(t, places_active(&b.places, fmt.tprintf("%s/child", desktop)), 1)
	testing.expect_value(t, places_active(&b.places, fmt.tprintf("%s-other", home)), 5)

	g := geometry(960, 640, 1)
	b.selected = 1
	running := true

	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_TAB},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.places.focused)
	testing.expect_value(t, b.places.selected, 0)
	event.key.key = sdl.K_J
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.places.selected, 1)
	testing.expect_value(t, b.selected, 1)
	testing.expect_value(t, b.path, home)
	event.key.key = sdl.K_L
	event.key.repeat = true
	testing.expect(t, !handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, home)
	event.key.repeat = false
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.status_error == "")
	testing.expect_value(t, b.path, desktop)
	event.key.key = sdl.K_TAB
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, !b.places.focused)

	event = sdl.Event {
		button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_X1},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, home)
	testing.expect_value(t, b.selected, 1)
	event.button = {
		type   = .MOUSE_BUTTON_DOWN,
		button = sdl.BUTTON_LEFT,
		x      = 20,
		y      = places_geometry(g).list_top + 3 * g.row + 1,
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, downloads)
	testing.expect(t, b.places.focused)
	event.button.button = sdl.BUTTON_X1
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, home)
	event = sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_TAB},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, !b.places.focused)
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.places.selected, 0)

	// Sorting the table restores file-list focus without changing the selected entry.
	event = sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = g.sidebar + g.padding + g.columns[.Name] + g.gap + 10,
			y = g.header + 1,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, !b.places.focused)
	testing.expect_value(t, b.sort_column, Column.Size)
	// Each pane owns its scroll offset, even when the other pane has focus.
	g = geometry(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, 1)
	event = sdl.Event {
		wheel = {type = .MOUSE_WHEEL, y = -1, mouse_x = 20, mouse_y = g.list_top + 1},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.places.first, 2)
	testing.expect_value(t, b.first, 0)
	event.wheel.mouse_x = g.sidebar + 20
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.places.first, 2)
	testing.expect_value(t, b.first, 3)

	g = geometry(960, 640, 1)
	b.places.first = 0
	event = sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = 20,
			y = places_geometry(g).list_top + f32(len(b.places.entries)) * g.row + 1,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running)) // Clear the file-row hover.
	testing.expect_value(t, b.hovered, u32(0))
	testing.expect_value(t, b.first, 3)
	// A place removed after startup must fail without changing the current folder.
	testing.expect(t, os.remove(desktop) == nil)
	event.button.y = places_geometry(g).list_top + g.row + 1
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, strings.has_prefix(b.status_error, "cannot read folder:"))
	testing.expect_value(t, b.path, home)
	testing.expect_value(t, places_active(&b.places, b.path), 0)
}

@(test)
selection_keys_move_only_the_focused_pane :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	resize(&b.visible, 100)
	resize(&b.places.entries, 100)
	g := geometry(960, 640, 1)
	running := true
	panes := [?]bool{false, true}
	for focused in panes {
		rows := focused ? places_geometry(g).rows : g.rows
		cases := [?]struct {
			key:             sdl.Keycode,
			selected, first: int,
		} {
			{sdl.K_PAGEDOWN, rows, 1},
			{sdl.K_END, 99, 100 - rows},
			{sdl.K_PAGEUP, 99 - rows, 99 - rows},
			{sdl.K_HOME, 0, 0},
			{sdl.K_UP, 0, 0},
			{sdl.K_DOWN, 1, 0},
			{sdl.K_K, 0, 0},
			{sdl.K_J, 1, 0},
		}
		b.places.focused = focused
		b.selected, b.first, b.places.selected, b.places.first = 0, 0, 0, 0
		for item in cases {
			event := sdl.Event {
				key = {type = .KEY_DOWN, key = item.key, repeat = true},
			}
			testing.expect(t, handle_event(&b, &event, g, &running))
			if focused {
				testing.expect_value(t, b.places.selected, item.selected)
				testing.expect_value(t, b.places.first, item.first)
				testing.expect_value(t, b.selected, 0)
				testing.expect_value(t, b.first, 0)
			} else {
				testing.expect_value(t, b.selected, item.selected)
				testing.expect_value(t, b.first, item.first)
				testing.expect_value(t, b.places.selected, 0)
				testing.expect_value(t, b.places.first, 0)
			}
		}
	}
}
