package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
tabs_preserve_views_and_refresh_changed_entries :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-tabs-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create tab fixture")}
	defer delete(root)
	defer os.remove_all(root)
	one, two := fmt.aprintf("%s/one", root), fmt.aprintf("%s/two", root)
	defer delete(one)
	defer delete(two)
	testing.expect(t, os.make_directory(one) == nil)
	testing.expect(t, os.make_directory(two) == nil)
	for i in 0 ..< 20 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/item-%02d", one, i), "data") == nil)}
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	testing.expect(t, browser_navigate(&b, one) == nil)
	search_start(&b)
	path_edit_replace(&b, "item")
	search_blur(&b.header.edit)
	selection_single(&b, 2)
	selection_click(&b, 4, true, false)
	b.first = 3
	testing.expect(t, tab_open(&b, two) == nil)
	testing.expect_value(t, b.path, two)
	testing.expect_value(t, b.search, "")
	testing.expect_value(t, len(b.back), 0)
	// Inserting an earlier name changes entry and row indices in the saved tab.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/item-00a", one), "new") == nil)
	testing.expect(t, tab_switch(&b, 0) == nil)
	testing.expect_value(t, b.path, one)
	testing.expect_value(t, b.search, "item")
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), "item")
	testing.expect(t, !b.header.edit.active)
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "item-04")
	testing.expect_value(t, b.first, 3)
	testing.expect_value(t, len(b.marks), 2)
	testing.expect_value(t, b.marked_bytes, i64(8))
	for source in b.marks {testing.expect(t, b.entries[source].name == "item-02" || b.entries[source].name == "item-04")}
	testing.expect_value(t, len(b.back), 1)
	testing.expect(t, browser_history(&b, true) == nil)
	testing.expect_value(t, b.path, root)
	testing.expect(t, tab_switch(&b, 1) == nil)
	testing.expect_value(t, b.path, two)
	testing.expect_value(t, len(b.back), 0)
	testing.expect(t, tab_switch(&b, 0) == nil)
	testing.expect(t, browser_history(&b, false) == nil)
	testing.expect_value(t, b.path, one)
	// An unavailable folder must not add a tab or replace the current view.
	testing.expect(t, tab_open(&b, fmt.tprintf("%s/missing", root)) != nil)
	testing.expect_value(t, tab_count(&b), 2)
	testing.expect_value(t, b.path, one)
}

@(test)
tab_shortcuts_open_switch_and_close_tabs :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-tab-keys-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create tab fixture")}
	defer delete(root)
	defer os.remove_all(root)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	g, running := geometry(960, 640, 1), true
	path_edit_start(&b)
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_T, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, tab_count(&b), 2)
	testing.expect_value(t, b.active_tab, 1)
	testing.expect_value(t, b.path, root)
	testing.expect(t, !b.header.edit.active)
	event.key.key, event.key.mod = sdl.K_TAB, sdl.KMOD_CTRL | sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.active_tab, 0)
	event.key.mod = sdl.KMOD_CTRL
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.active_tab, 1)
	testing.expect(t, tab_open(&b, root, activate = false) == nil)
	testing.expect_value(t, b.active_tab, 1)
	// Closing a background tab keeps the active view.
	testing.expect(t, tab_close(&b, 0, &running) == nil)
	testing.expect_value(t, b.active_tab, 0)
	event.key.key = sdl.K_W
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, running)
	testing.expect_value(t, tab_count(&b), 1)
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !running)
}

@(test)
folder_middle_click_opens_a_background_tab_but_holding_scrolls :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-tab-middle-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create tab fixture")}
	defer delete(root)
	defer os.remove_all(root)
	child := fmt.aprintf("%s/child", root)
	defer delete(child)
	testing.expect(t, os.make_directory(child) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_MIDDLE,
			x = g.sidebar + 100,
			y = g.list_top + g.row / 2,
		},
	}
	_ = handle_event(&b, &event, g, &running)
	event.button.type = .MOUSE_BUTTON_UP
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, tab_count(&b), 2)
	testing.expect_value(t, b.active_tab, 0)
	testing.expect_value(t, b.path, root)
	testing.expect_value(t, tab_view(&b, 1).path, child)
	g = geometry(960, 640, 1, tab_count = tab_count(&b))
	event.button.y = g.list_top + g.row / 2
	// A stationary hold must not turn into a click when released.
	event.button.type = .MOUSE_BUTTON_DOWN
	_ = handle_event(&b, &event, g, &running)
	sdl.Delay(260)
	event.button.type = .MOUSE_BUTTON_UP
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, tab_count(&b), 2)
	for i in 0 ..< 30 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/file-%02d", root, i), "data") == nil)}
	testing.expect(t, browser_load(&b, root) == nil)
	event.button.type = .MOUSE_BUTTON_DOWN
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.autoscroll.active)
	now := b.autoscroll.tick
	motion := sdl.Event {
		motion = {type = .MOUSE_MOTION, x = event.button.x, y = event.button.y + 112},
	}
	_ = handle_event(&b, &motion, g, &running)
	_ = autoscroll_update(&b, g, now + 100)
	testing.expect(t, b.first > 0)
	event.button.type = .MOUSE_BUTTON_UP
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, !b.autoscroll.active)
	testing.expect_value(t, tab_count(&b), 2)
	// A regular file is not a folder-tab target.
	event.button.type, event.button.y = .MOUSE_BUTTON_DOWN, g.list_top + 1.5 * g.row
	_ = handle_event(&b, &event, g, &running)
	event.button.type = .MOUSE_BUTTON_UP
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, tab_count(&b), 2)
}

@(test)
closing_a_tab_does_not_cancel_its_file_operation :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-tab-files-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create tab fixture")}
	defer delete(root)
	defer os.remove_all(root)
	one, two := fmt.aprintf("%s/one", root), fmt.aprintf("%s/two", root)
	defer delete(one)
	defer delete(two)
	testing.expect(t, os.make_directory(one) == nil)
	testing.expect(t, os.make_directory(two) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/keep.txt", two), "keep") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, one) == nil)
	b.storage = storage_start(one)
	if !testing.expect(t, b.storage != nil) {return}
	file_dialog_start(&b, false)
	file_dialog_submit(&b)
	testing.expect(t, len(b.transfers) > 0)
	testing.expect(t, tab_open(&b, two) == nil)
	running := true
	testing.expect(t, tab_close(&b, 0, &running) == nil)
	file_history_test_wait(t, &b)
	testing.expect_value(t, tab_count(&b), 1)
	testing.expect_value(t, b.path, two)
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "keep.txt")
	testing.expect(t, os.is_directory(fmt.tprintf("%s/new folder", one)))
}

verify_tabs_layout :: proc(t: ^testing.T, p: ^Painter) {
	root, err := os.make_directory_temp("/tmp", "stuff-tab-layout-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create tab fixture")}
	defer delete(root)
	defer os.remove_all(root)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	g := geometry(960, 640, 1)
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect(t, !clay.GetElementData(clay.ID("tabs")).found)
	original_header := g.header
	for _ in 0 ..< 40 {testing.expect(t, tab_open(&b, root, activate = false) == nil)}
	testing.expect(t, tab_switch(&b, 40) == nil)
	g = geometry(960, 640, 1, tab_count = tab_count(&b))
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect(t, clay.GetElementData(clay.ID("tabs")).found)
	first, last, _ := tabs_range(&b, g)
	shown := 0
	previous_right := f32(0)
	for i in 0 ..< tab_count(&b) {
		element := clay.GetElementData(clay.ID("tab", u32(i)))
		if !element.found {continue}
		shown += 1
		box := element.boundingBox
		testing.expect_value(t, box.height, g.row)
		if shown == 1 {
			testing.expect_value(t, box.y, box.x)
			testing.expect_value(t, g.tabs - box.y - box.height, box.x)
		}
		testing.expect(t, box.x >= 0 && box.x + box.width <= g.width - g.tabs)
		testing.expect_value(
			t,
			tabs_target(&b, g, box.x + 4, box.y + 4),
			clay.ID("tab", u32(i)).id,
		)
		if shown > 1 {
			testing.expect_value(t, box.x - previous_right, g.row_gap)
			testing.expect_value(
				t,
				tabs_target(&b, g, (previous_right + box.x) / 2, box.y + 4),
				u32(0),
			)
		}
		previous_right = box.x + box.width
	}
	testing.expect_value(t, shown, last - first)
	testing.expect(t, shown < tab_count(&b))
	testing.expect(t, clay.GetElementData(clay.ID("tab", u32(b.active_tab))).found)
	for scale in ([?]f32{1.25, 2}) {
		scaled := geometry(i32(960 * scale), i32(640 * scale), scale, tab_count = tab_count(&b))
		_ = layout(&b, scaled, p)
		start, end, _ := tabs_range(&b, scaled)
		for i in start ..< end {
			close := clay.GetElementData(clay.ID("tab-close", u32(i))).boundingBox
			testing.expect_value(t, close.width, close.height)
			testing.expect_value(t, close.height, scaled.row)
			testing.expect_value(
				t,
				tabs_target(&b, scaled, close.x + close.width / 2, close.y + close.height / 2),
				clay.ID("tab-close", u32(i)).id,
			)
		}
	}
	paint(p, layout(&b, g, p), 960, 640)
	running := true
	event := sdl.Event {
		wheel = {type = .MOUSE_WHEEL, y = 1, mouse_x = 10, mouse_y = g.tabs / 2},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.active_tab, 39)
	// The new-tab button and tab close controls use the same layout hit regions.
	event = {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = g.width - g.tabs / 2,
			y = g.tabs / 2,
		},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, tab_count(&b), 42)
	paint(p, layout(&b, g, p), 960, 640)
	close := clay.GetElementData(clay.ID("tab-close", u32(b.active_tab))).boundingBox
	testing.expect_value(t, close.width, close.height)
	event.button.x, event.button.y = close.x + close.width / 2, close.y + close.height / 2
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, tab_count(&b), 41)
	for tab_count(&b) > 1 {testing.expect(t, tab_close(&b, tab_count(&b) - 1, &running) == nil)}
	g = geometry(960, 640, 1, tab_count = tab_count(&b))
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect(t, !clay.GetElementData(clay.ID("tabs")).found)
	testing.expect_value(t, g.header, original_header)
}
