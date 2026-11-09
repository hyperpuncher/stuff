package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
rename_and_new_folder_keep_conflicts_and_support_history :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-name-dialog-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create name fixture")}
	defer delete(root)
	defer os.remove_all(root)
	original, occupied, renamed, home :=
		fmt.aprintf("%s/a.txt", root),
		fmt.aprintf("%s/keep.txt", root),
		fmt.aprintf("%s/renamed.txt", root),
		fmt.aprintf("%s/data/Trash", root)
	defer delete(original)
	defer delete(occupied)
	defer delete(renamed)
	defer delete(home)
	testing.expect(t, os.write_entire_file(original, "original") == nil)
	testing.expect(t, os.write_entire_file(occupied, "keep") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start storage")}
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_R, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .Rename)
	testing.expect_value(t, b.header.edit.value[:b.header.edit.cursor], "a")
	event.key.key, event.key.mod = sdl.K_N, sdl.KMOD_CTRL | sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.mode, Edit_Mode.Rename)
	path_edit_replace(&b, "keep")
	event.key.key, event.key.mod = sdl.K_RETURN, {}
	_ = handle_event(&b, &event, g, &running)
	file_history_test_wait(t, &b)
	testing.expect(t, b.header.edit.active && b.header.edit.waiting == nil)
	testing.expect(t, b.status_error != "" && os.exists(original))
	data, read_err := os.read_entire_file(occupied, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(data), "keep")
	delete(data)
	b.header.edit.anchor, b.header.edit.cursor = 0, len(b.header.edit.value)
	path_edit_replace(&b, "renamed.txt")
	_ = handle_event(&b, &event, g, &running)
	file_history_test_wait(t, &b)
	testing.expect(t, !b.header.edit.active && !os.exists(original) && os.exists(renamed))
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "renamed.txt")
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
	testing.expect(t, os.exists(original) && !os.exists(renamed))
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "a.txt")
	testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)
	testing.expect(t, os.exists(renamed))
	menu_execute(&b, .New_Folder)
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .New_Folder)
	testing.expect_value(t, b.header.edit.source, root)
	testing.expect_value(t, len(b.marks), 1)
	event.key.key = sdl.K_ESCAPE
	_ = handle_event(&b, &event, g, &running)
	event.key.key, event.key.mod = sdl.K_N, sdl.KMOD_CTRL | sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.header.edit.active && b.header.edit.mode == .New_Folder)
	path_edit_replace(&b, "../outside")
	file_dialog_submit(&b)
	testing.expect(t, b.pending_files == nil && b.header.edit.active)
	b.header.edit.anchor, b.header.edit.cursor = 0, len(b.header.edit.value)
	path_edit_replace(&b, "folder")
	file_dialog_submit(&b)
	file_history_test_wait(t, &b)
	folder := fmt.aprintf("%s/folder", root)
	defer delete(folder)
	testing.expect(t, os.is_dir(folder))
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "folder")
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/child", folder), "new data") == nil)
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
	testing.expect(t, !os.exists(folder))
	testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)
	testing.expect(t, os.exists(fmt.tprintf("%s/child", folder)))
}

verify_file_dialog_rendering :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp")
	b.entries = make([]os.File_Info, 1)
	b.entries[0] = {
		name     = "sample.txt",
		fullpath = strings.clone("/tmp/sample.txt"),
		type     = .Regular,
	}
	browser_filter(&b)
	g := geometry(960, 640, 1)
	file_dialog_start(&b, true)
	commands := layout(&b, g, p)
	paint(p, commands, 960, 640)
	rename_labels := 0
	for i in 0 ..< commands.length {
		cmd := commands.internalArray[i]
		if cmd.commandType != .Text {continue}
		text := cmd.renderData.text.stringContents
		if string(text.chars[:text.length]) == "rename" {rename_labels += 1}
	}
	testing.expect_value(t, rename_labels, 1) // The button supplies the action, without a duplicate title.
	box := file_dialog_box(g)
	pixel := sdl.Rect{i32(g.width / 2), i32(box.y + box.height + 3), 1, 1}
	surface := sdl.RenderReadPixels(p.renderer, &pixel)
	if surface == nil {testing.fail_now(t, string(sdl.GetError()))}
	r, green, blue, alpha: u8
	sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &r, &green, &blue, &alpha))
	sdl.DestroySurface(surface)
	testing.expect(
		t,
		r < u8(theme.background[0]),
		"the dialog must cast a shadow outside its bounds",
	)
	field := clay.GetElementData(clay.ID("path-edit"))
	testing.expect_value(t, field.boundingBox, path_edit_box(g, .Rename))
	testing.expect_value(t, field.boundingBox.x - box.x, 8 * g.scale)
	testing.expect_value(t, field.boundingBox.y - box.y, 8 * g.scale)
	for name in ([?]string{"file-dialog-cancel", "file-dialog-submit"}) {
		button := clay.GetElementData(clay.ID(name))
		testing.expect(t, button.found)
		if name ==
		   "file-dialog-submit" {testing.expect_value(t, field.boundingBox.x + field.boundingBox.width, button.boundingBox.x + button.boundingBox.width)}
	}
	b.header.edit.anchor = b.header.edit.cursor
	commands = layout(&b, g, p)
	caret := clay.GetElementData(clay.ID("path-edit-caret"))
	testing.expect(
		t,
		caret.found &&
		caret.boundingBox.x > field.boundingBox.x &&
		caret.boundingBox.x < field.boundingBox.x + field.boundingBox.width,
	)
	paint(p, commands, 960, 640)
}
