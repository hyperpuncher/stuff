package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
archive_actions_keep_destinations_and_undo_created_outputs :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root := archive_test_root(t, "stuff-archive-actions-")
	defer delete(root)
	defer os.remove_all(root)
	source, archive, output, elsewhere, home :=
		fmt.aprintf("%s/notes.txt", root),
		fmt.aprintf("%s/bundle.7z", root),
		fmt.aprintf("%s/bundle", root),
		fmt.aprintf("%s/elsewhere", root),
		fmt.aprintf("%s/data/Trash", root)
	defer delete(source)
	defer delete(archive)
	defer delete(output)
	defer delete(elsewhere)
	defer delete(home)
	testing.expect(t, os.write_entire_file(source, "original notes") == nil)
	testing.expect(t, os.make_directory(elsewhere) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start storage")}
	for index, row in b.visible {if b.entries[index].name == "notes.txt" {selection_single(&b, row)}}
	menu_execute(&b, .Compress)
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .Compress)
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), "notes.txt.zip")
	b.header.edit.text.selection = {len(strings.to_string(b.header.edit.buffer)), 0}
	path_edit_replace(&b, "../outside.zip")
	file_dialog_submit(&b)
	testing.expect(t, len(b.transfers) == 0 && b.header.edit.active)
	b.header.edit.text.selection = {len(strings.to_string(b.header.edit.buffer)), 0}
	path_edit_replace(&b, "bundle.ZIP")
	archive_dialog_format(&b, .Seven_Zip)
	testing.expect_value(t, strings.to_string(b.header.edit.buffer), "bundle.7z")
	file_dialog_submit(&b)
	testing.expect(t, !b.header.edit.active && len(b.transfers) == 1)
	testing.expect(t, browser_navigate(&b, elsewhere) == nil)
	file_history_test_wait(t, &b)
	testing.expect_value(t, b.path, elsewhere)
	testing.expect(t, os.exists(archive))
	// File opening selects extraction, not gio or an archive browser.
	file_open(&b, archive)
	testing.expect_value(t, len(b.opens), 0)
	file_history_test_wait(t, &b)
	archive_test_contents(t, fmt.tprintf("%s/notes.txt", output), "original notes")
	testing.expect(t, !os.exists(fmt.tprintf("%s/bundle", elsewhere)))
	testing.expect_value(t, len(b.undo_files), 2)
	for _ in 0 ..< 2 {testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)}
	testing.expect(t, !os.exists(output) && !os.exists(archive))
	testing.expect(t, os.write_entire_file(source, "new notes") == nil)
	for _ in 0 ..< 2 {testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)}
	archive_test_contents(t, fmt.tprintf("%s/notes.txt", output), "original notes")
	archive_test_contents(t, source, "new notes")
	testing.expect(t, os.exists(archive))
	archive_test_no_staging(t, root)
}

@(test)
selected_archives_extract_in_parallel_from_enter_and_menu :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root := archive_test_root(t, "stuff-selected-archives-")
	defer delete(root)
	defer os.remove_all(root)
	sources := [2]string{fmt.aprintf("%s/one.txt", root), fmt.aprintf("%s/two.txt", root)}
	archives := [2]string{fmt.aprintf("%s/bundle.ZIP", root), fmt.aprintf("%s/bundle.7z", root)}
	defer {for path in sources {delete(path)}; for path in archives {delete(path)}}
	formats := [2]Archive_Format{.Zip, .Seven_Zip}
	for source, i in sources {
		testing.expect(t, os.write_entire_file(source, i == 0 ? "one" : "two") == nil)
		op := archive_test_job(.Compress, source, root, archives[i], formats[i])
		file_operation_run(op)
		testing.expect_value(t, op.failed, 0)
		file_operation_destroy(op)
	}
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start storage")}
	g, running := geometry(960, 640, 1), true
	for keyboard in ([?]bool{true, false}) {
		selection_clear(&b)
		for index, row in b.visible {
			if b.entries[index].fullpath == archives[0] ||
			   b.entries[index].fullpath == archives[1] {
				selection_mark(&b, row, true)
				b.selected = row
			}
		}
		testing.expect_value(t, len(b.marks), 2)
		testing.expect(t, menu_enabled(&b, .Extract))
		previous := len(b.undo_files)
		// Hold publication so both workers remain visible until checked.
		sync.mutex_lock(&b.storage.mutex)
		if keyboard {
			event := sdl.Event {
				key = {type = .KEY_DOWN, key = sdl.K_RETURN, repeat = true},
			}
			testing.expect(t, !handle_event(&b, &event, g, &running))
			testing.expect_value(t, len(b.transfers), 0)
			event.key.repeat = false
			testing.expect(t, handle_event(&b, &event, g, &running))
		} else {menu_execute(&b, .Extract)}
		testing.expect_value(t, len(b.transfers), 2)
		for transfer in b.transfers {testing.expect_value(t, transfer.op.kind, File_Action.Extract)}
		sync.mutex_unlock(&b.storage.mutex)
		file_history_test_wait(t, &b)
		testing.expect_value(t, len(b.opens), 0)
		testing.expect_value(t, len(b.undo_files), previous + 2)
		found: [2]bool
		for batch in b.undo_files[previous:] {
			testing.expect_value(t, len(batch.changes), 1)
			for change in batch.changes {
				for source, i in sources {
					path := fmt.tprintf("%s/%s", change.path, os.base(source))
					if !os.exists(path) {continue}
					testing.expect(t, !found[i])
					found[i] = true
					archive_test_contents(t, path, i == 0 ? "one" : "two")
				}
			}
		}
		testing.expect(t, found[0] && found[1])
		testing.expect(t, os.exists(archives[0]) && os.exists(archives[1]))
		archive_test_no_staging(t, root)
	}
	// A selected directory named *.zip must still open as a directory.
	folder := fmt.aprintf("%s/folder.zip", root)
	defer delete(folder)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, browser_load(&b, root) == nil)
	selection_clear(&b)
	for index, row in b.visible {
		if b.entries[index].fullpath == archives[0] ||
		   b.entries[index].fullpath == folder {selection_mark(&b, row, true)}
		if b.entries[index].fullpath == folder {b.selected = row}
	}
	testing.expect(t, !menu_visible(&b, .Extract))
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_RETURN},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.path, folder)
	testing.expect_value(t, len(b.transfers), 0)
}

verify_archive_dialog_rendering :: proc(t: ^testing.T, p: ^Painter) {
	window := sdl.GetRenderWindow(p.renderer)
	defer {
		sdl_check(sdl.SetWindowSize(window, 960, 640))
		sdl_check(ttf.SetFontSize(p.font, 14))
		clay.ResetMeasureTextCache()
		painter_load_icons(p, 1)
	}
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp")
	for scale in ([?]f32{1, 2}) {
		sdl_check(sdl.SetWindowSize(window, i32(960 * scale), i32(640 * scale)))
		sdl_check(ttf.SetFontSize(p.font, 14 * scale))
		clay.ResetMeasureTextCache()
		painter_load_icons(p, scale)
		g, running := geometry(i32(960 * scale), i32(640 * scale), scale), true
		path_edit_end(&b.header.edit)
		b.header.edit.mode, b.header.edit.active = .Compress, true
		path_edit_init(&b, "bundle.zip")
		paint(p, layout(&b, g, p), i32(g.width), i32(g.height))
		input := clay.GetElementData(clay.ID("path-edit")).boundingBox
		previous_right := input.x
		for format in Archive_Format {
			box := clay.GetElementData(clay.ID("archive-format", u32(format))).boundingBox
			testing.expect_value(t, box.height, g.row)
			testing.expect(t, abs(box.y - input.y - input.height - 8 * g.scale) < 0.01)
			if format == .Zip {testing.expect_value(t, box.x, input.x)} else {
				testing.expect(t, abs(box.x - previous_right - 2 * g.scale) < 0.01)
			}
			previous_right = box.x + box.width
			if format ==
			   .Tar_Zstd {testing.expect(t, abs(previous_right - input.x - input.width) < 0.01)}
			x, y := box.x + box.width / 2, box.y + box.height / 2
			event := sdl.Event {
				button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, x = x, y = y},
			}
			testing.expect(t, handle_event(&b, &event, g, &running))
			testing.expect_value(t, b.header.edit.archive_format, format)
			testing.expect_value(
				t,
				strings.to_string(b.header.edit.buffer),
				fmt.tprintf("bundle%s", ARCHIVE_SUFFIX[format]),
			)
		}
		path_edit_end(&b.header.edit)
		b.header.edit.mode, b.header.edit.active = .Password, true
		b.header.edit.source = strings.clone("/tmp/locked.zip")
		path_edit_init(&b, "a\u0301👩‍💻")
		b.header.edit.composition = strings.clone("secret composition")
		commands := layout(&b, g, p)
		field := clay.GetElementData(clay.ID("path-edit")).boundingBox
		testing.expect_value(t, field, path_edit_box(g, .Password))
		masked := false
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType != .Text {continue}
			text := string(
				cmd.renderData.text.stringContents.chars[:cmd.renderData.text.stringContents.length],
			)
			testing.expect(
				t,
				!strings.contains(text, "👩") && !strings.contains(text, "secret composition"),
			)
			if strings.has_prefix(text, "••") {masked = true}
		}
		testing.expect(t, masked)
		testing.expect(t, !path_edit_clipboard_set(&b, "private"))
		password_input := false
		path_edit_sync_input(&b.header.edit, window, &password_input)
		testing.expect(t, password_input && sdl.TextInputActive(window))
		paint(p, commands, i32(g.width), i32(g.height))
		path_edit_end(&b.header.edit)
		path_edit_sync_input(&b.header.edit, window, &password_input)
		testing.expect(t, !sdl.TextInputActive(window))
	}
}
