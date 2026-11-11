package main

import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
footer_messages_expire_without_clearing_newer_messages :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	before := sdl.GetTicks()
	browser_message(&b, "operation cancelled")
	testing.expect(t, b.status_until >= before + 3000 && b.status_until <= sdl.GetTicks() + 3000)
	// A new message must outlive the previous message's deadline.
	b.status_until -= 1000
	old_deadline := b.status_until
	browser_message(&b, "cannot open file")
	testing.expect(t, !browser_message_update(&b, old_deadline))
	testing.expect_value(t, b.status_error, "cannot open file")
	deadline := b.status_until
	b.header.copied_until = deadline - 100
	testing.expect_value(t, ui_wait_timeout(&b, deadline - 101), i32(1))
	testing.expect(t, header_update(&b.header, deadline - 100))
	testing.expect(t, !browser_message_update(&b, deadline - 1))
	testing.expect_value(t, ui_wait_timeout(&b, deadline - 1), i32(1))
	testing.expect(t, browser_message_update(&b, deadline))
	testing.expect_value(t, b.status_error, "")
	testing.expect_value(t, ui_wait_timeout(&b, deadline), i32(-1))
	browser_message(&b, "temporary message")
	browser_message(&b, "")
	testing.expect_value(t, ui_wait_timeout(&b, sdl.GetTicks()), i32(-1))
}

@(test)
browse_real_directory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 3 * time.Second)
	root, err := os.make_directory_temp("/tmp", "stuff-test-", context.allocator)
	testing.expect(t, err == nil)
	defer delete(root)
	defer os.remove_all(root)
	folder := fmt.aprintf("%s/alpha", root)
	defer delete(folder)
	hidden := fmt.aprintf("%s/.hidden", root)
	defer delete(hidden)
	file := fmt.aprintf("%s/A-file", root)
	defer delete(file)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.write_entire_file(hidden, "hidden") == nil)
	testing.expect(t, os.write_entire_file(file, "hello") == nil)

	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	testing.expect_value(t, len(b.visible), 2)
	testing.expect_value(t, browser_summary(&b), "2 items    selected: folder")
	testing.expect_value(t, b.entries[b.visible[0]].name, "alpha")
	testing.expect_value(t, b.entries[b.visible[1]].name, "A-file")
	b.show_hidden = true
	browser_filter(&b)
	testing.expect_value(t, len(b.visible), 3)
	testing.expect_value(t, b.selected, 0)
	testing.expect(t, browser_enter(&b) == nil)
	testing.expect_value(t, b.path, folder)
	testing.expect_value(t, len(b.visible), 0)
	testing.expect(t, browser_enter(&b) == nil)
	testing.expect(t, browser_parent(&b) == nil)
	testing.expect_value(t, b.path, root)

	// A failed reload must keep both the old path and its entries alive.
	b.selected = 1
	testing.expect(t, browser_load(&b, file) != nil)
	testing.expect_value(t, b.path, root)
	testing.expect_value(t, len(b.visible), 3)
	testing.expect_value(t, b.selected, 1)
	testing.expect(t, browser_load(&b, b.path) == nil)
	testing.expect_value(t, len(b.visible), 3)

	g := geometry(960, 640, 1)
	running := true

	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_J},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.selected, 1)
	event.key.key = sdl.K_K
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.selected, 0)
	event.key.key = sdl.K_L
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.status_error == "")
	testing.expect_value(t, b.path, folder)
	event.key.key = sdl.K_H
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, root)
	event.key.mod = sdl.KMOD_CTRL
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, root)
	testing.expect_value(t, len(b.visible), 2)
	// Special nodes must be rejected without waiting for a FIFO writer.
	pipe := fmt.caprintf("%s/pipe", root)
	defer delete(pipe)
	testing.expect(
		t,
		linux.mknod(pipe, linux.S_IFIFO | transmute(linux.Mode)u32(0o600), 0) == .NONE,
	)
	testing.expect(t, browser_load(&b, string(pipe)) != nil)
	testing.expect_value(t, b.path, root)
	file_open(&b, string(pipe))
	testing.expect_value(t, len(b.opens), 0)
	testing.expect(t, strings.has_suffix(b.status_error, "not a regular file"))
}

@(test)
returning_from_a_child_keeps_the_parent_sort_and_selection :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-return-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create navigation fixture")}
	defer delete(root)
	defer os.remove_all(root)
	downloads := fmt.aprintf("%s/Downloads", root)
	defer delete(downloads)
	for name in ([?]string{"Desktop", "Downloads", "Pictures"}) {
		testing.expect(t, os.make_directory(fmt.tprintf("%s/%s", root, name)) == nil)
	}
	b: Browser
	defer browser_destroy(&b)
	// The parent uses the default sort. Only the child has a saved choice.
	b.sorts[strings.clone(downloads)] = {
		column     = .Modified,
		descending = true,
	}
	testing.expect(t, browser_load(&b, root) == nil)
	for history in ([?]bool{true, false}) {
		for index, row in b.visible {
			if b.entries[index].name == "Downloads" {selection_single(&b, row)}
		}
		testing.expect(t, browser_enter(&b) == nil)
		testing.expect_value(t, b.path, downloads)
		testing.expect_value(t, b.sort_column, Column.Modified)
		testing.expect(t, b.descending)
		if history {
			testing.expect(t, browser_history(&b, true) == nil)
		} else {
			// The parent action also covers direct navigation to this ancestor.
			testing.expect(t, browser_parent(&b) == nil)
		}
		testing.expect_value(t, b.path, root)
		testing.expect_value(t, b.sort_column, Column.Name)
		testing.expect(t, !b.descending)
		testing.expect_value(t, b.entries[b.visible[b.selected]].name, "Downloads")
		testing.expect(t, len(b.marks) == 1 && b.marks[b.visible[b.selected]])
	}
}

@(test)
mouse_history_restores_location :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-history-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create history fixture")}
	defer delete(root)
	defer os.remove_all(root)
	a := fmt.aprintf("%s/a", root)
	defer delete(a)
	b_path := fmt.aprintf("%s/b", root)
	defer delete(b_path)
	missing := fmt.aprintf("%s/missing", root)
	defer delete(missing)
	file := fmt.aprintf("%s/z.txt", root)
	defer delete(file)
	other := fmt.aprintf("%s/y.txt", root)
	defer delete(other)
	testing.expect(t, os.make_directory(a) == nil)
	testing.expect(t, os.make_directory(b_path) == nil)
	testing.expect(t, os.write_entire_file(file, "z") == nil)
	testing.expect(t, os.write_entire_file(other, "y") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	testing.expect(t, browser_history(&b, true) == nil)
	testing.expect(t, browser_history(&b, false) == nil)
	b.selected, b.first = 3, 1
	testing.expect(t, browser_navigate(&b, a) == nil)
	testing.expect(t, browser_navigate(&b, b_path) == nil)

	g := geometry(960, 240, 1)
	running := true

	event := sdl.Event {
		button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_X1},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.status_error == "")
	testing.expect_value(t, b.path, a) // Back visits the sibling, not the parent.
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, root)
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "z.txt")
	testing.expect_value(t, b.first, 1)
	event.button.button = sdl.BUTTON_X2
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, a)
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, b_path)

	event.button.button = sdl.BUTTON_X1
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, a)
	// Failed navigation preserves both history branches and the current view.
	testing.expect(t, browser_navigate(&b, missing) != nil)
	testing.expect_value(t, len(b.forward), 1)
	testing.expect_value(t, b.path, a)
	testing.expect(t, os.remove_all(b_path) == nil)
	testing.expect(t, browser_history(&b, false) != nil)
	testing.expect_value(t, len(b.forward), 1)
	testing.expect_value(t, b.path, a)
	// A new successful visit replaces the forward branch.
	testing.expect(t, browser_navigate(&b, root) == nil)
	testing.expect_value(t, len(b.forward), 0)
	testing.expect(t, browser_history(&b, false) == nil)
	testing.expect_value(t, b.path, root)
	testing.expect(t, browser_navigate(&b, root) == nil)
	testing.expect_value(t, len(b.back), 2)
}

@(test)
pointer_selection_respects_list_bounds :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.entries = make([]os.File_Info, 100)
	resize(&b.visible, len(b.entries))
	for &source, i in b.visible {source = i}
	g := geometry(960, 640, 1)

	running := true
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = g.sidebar + 20,
			y = g.list_top + g.row + 1,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.selected, 1)
	event.button.y = g.height - 1
	testing.expect(t, handle_event(&b, &event, g, &running)) // Clear the previous hover.
	testing.expect_value(t, b.hovered, u32(0))
	testing.expect_value(t, b.selected, 1)
	event.button.y = g.header - 1
	testing.expect(t, !handle_event(&b, &event, g, &running))
	b.first = 7
	event.button.y = g.list_top + g.row / 2
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.selected, 7)
	event.button.y = g.list_top + f32(g.rows) * g.row - 0.25
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.selected, 7 + g.rows - 1)
	event.button.y += 0.25
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.selected, 7 + g.rows)
	event.button.y = list_bottom(g)
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.selected, 7 + g.rows)
	event.button.y = g.list_top - 0.25
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.selected, 7 + g.rows)
	clear(&b.visible)
	event.button.y = g.list_top + 1
	testing.expect(t, !handle_event(&b, &event, g, &running))
}
