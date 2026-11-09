package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
copy_keeps_existing_files_and_symbolic_links :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-copy-test-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create copy fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, target := fmt.aprintf("%s/source", root), fmt.aprintf("%s/target", root)
	defer delete(source)
	defer delete(target)
	testing.expect(t, os.make_directory(source) == nil)
	testing.expect(t, os.make_directory(target) == nil)
	file, link := fmt.aprintf("%s/a.txt", source), fmt.aprintf("%s/link", source)
	defer delete(file)
	defer delete(link)
	testing.expect(t, os.write_entire_file(file, "original") == nil)
	testing.expect(t, os.symlink("missing", link) == nil)
	op := File_Operation {
		target = target,
	}
	buffer := make([]u8, 1024)
	defer delete(buffer)
	testing.expect(t, file_copy(&op, source, buffer) == nil)
	copy_path := fmt.aprintf("%s/source/a.txt", target)
	defer delete(copy_path)
	bytes, read_err := os.read_entire_file(copy_path, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(bytes), "original")
	delete(bytes)
	link_value, link_err := os.read_link(fmt.tprintf("%s/source/link", target), context.allocator)
	testing.expect(t, link_err == nil)
	testing.expect_value(t, link_value, "missing")
	delete(link_value)
	for _ in 0 ..< 2 {testing.expect(t, file_copy(&op, file, buffer) == nil)}
	testing.expect(t, os.exists(fmt.tprintf("%s/a.txt", target)))
	testing.expect(t, os.exists(fmt.tprintf("%s/a (copy).txt", target)))
	op.target = source
	testing.expect(t, file_copy(&op, source, buffer) != nil)
	op.target = target
	testing.expect(t, file_copy(&op, "/definitely-not-a-stuff-test-file", buffer) != nil)
	entries, dir_err := os.read_all_directory_by_path(target, context.allocator)
	testing.expect(t, dir_err == nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {testing.expect(t, !strings.has_prefix(entry.name, ".stuff-copy-"))}
}

@(test)
trash_preserves_folders_links_and_restore_metadata :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-trash-test-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create trash fixture")}
	defer delete(root)
	defer os.remove_all(root)
	home := fmt.aprintf("%s/data/Trash", root)
	defer delete(home)
	folder := fmt.aprintf("%s/folder #", root)
	defer delete(folder)
	link := fmt.aprintf("%s/link", root)
	defer delete(link)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/child", folder), "content") == nil)
	testing.expect(t, os.symlink("missing", link) == nil)
	for path in ([?]string{folder, link}) {testing.expect(t, trash_file(path, home, nil) == nil)}
	_, stat_err := os.lstat(link, context.allocator)
	testing.expect(t, stat_err != nil)
	testing.expect(t, !os.exists(folder))
	infos, read_err := os.read_all_directory_by_path(
		fmt.tprintf("%s/info", home),
		context.allocator,
	)
	if read_err != nil {testing.fail_now(t, "cannot read trash records")}
	defer os.file_info_slice_delete(infos, context.allocator)
	testing.expect_value(t, len(infos), 2)
	for info in infos {
		data, data_err := os.read_entire_file(info.fullpath, context.allocator)
		testing.expect(t, data_err == nil)
		text := string(data)
		testing.expect(t, strings.has_prefix(text, "[Trash Info]\nPath="))
		testing.expect(t, strings.contains(text, "\nDeletionDate="))
		base := strings.trim_suffix(info.name, ".trashinfo")
		stored, stored_err := os.lstat(fmt.tprintf("%s/files/%s", home, base), context.allocator)
		testing.expect(t, stored_err == nil)
		if stored_err == nil {
			testing.expect(t, stored.type == .Directory || stored.type == .Symlink)
			os.file_info_delete(stored, context.allocator)
		}
		delete(data)
	}
	// A link cannot replace a private trash directory, and failure keeps the source.
	testing.expect(t, os.remove_all(fmt.tprintf("%s/info", home)) == nil)
	testing.expect(t, os.symlink(root, fmt.tprintf("%s/info", home)) == nil)
	file := fmt.aprintf("%s/keep", root)
	defer delete(file)
	testing.expect(t, os.write_entire_file(file, "keep") == nil)
	testing.expect(t, trash_file(file, home, nil) != nil)
	testing.expect(t, os.exists(file))
	// Remove the fixture link before recursive cleanup, which follows a root link.
	testing.expect(t, os.remove(fmt.tprintf("%s/info", home)) == nil)
}

@(test)
trash_completion_keeps_scroll_and_current_cursor :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-scroll-test-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create scroll fixture")}
	defer delete(root)
	defer os.remove_all(root)
	files, home := fmt.aprintf("%s/files", root), fmt.aprintf("%s/data/Trash", root)
	defer delete(files)
	defer delete(home)
	testing.expect(t, os.make_directory(files) == nil)
	for i in 0 ..< 80 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%03d", files, i), "test") == nil)}
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, files) == nil)
	for moved_cursor in ([?]bool{false, true}) {
		selection_single(&b, 45)
		op := File_Operation {
			kind       = .Trash,
			sources    = selection_paths(&b),
			target     = files,
			trash_home = home,
		}
		defer file_paths_destroy(op.sources)
		defer delete(op.error)
		file_operation_run(&op)
		testing.expect_value(t, op.failed, 0)
		// The user can continue browsing while the worker completes.
		if moved_cursor {selection_single(&b, 60)}
		expected := strings.clone(b.entries[b.visible[moved_cursor ? 60 : 46]].name)
		defer delete(expected)
		b.first = moved_cursor ? 55 : 40
		first := b.first
		b.pending_files = &op
		testing.expect(t, file_operation_apply(&b, &op))
		testing.expect_value(t, b.first, first)
		testing.expect_value(t, b.entries[b.visible[b.selected]].name, expected)
		testing.expect_value(t, b.status_error, "")
	}
}

@(test)
background_paste_does_not_change_navigation :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-background-test-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create background fixture")}
	defer delete(root)
	defer os.remove_all(root)
	file, dest := fmt.aprintf("%s/file", root), fmt.aprintf("%s/dest", root)
	defer delete(file)
	defer delete(dest)
	testing.expect(t, os.write_entire_file(file, "clipboard content") == nil)
	testing.expect(t, os.make_directory(dest) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	selection_single(&b, 1) // The folder sorts before the file.
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start storage")}
	g, running := geometry(960, 640, 1), true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_INSERT, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, browser_navigate(&b, dest) == nil)
	event.key.mod = sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.pending_files != nil)
	testing.expect(t, browser_navigate(&b, root) == nil)
	deadline := sdl.GetTicks() + 3000
	for b.pending_files != nil &&
	    sdl.GetTicks() < deadline {_ = storage_poll(&b); time.sleep(time.Millisecond)}
	testing.expect(t, b.pending_files == nil)
	testing.expect_value(t, b.path, root)
	testing.expect_value(t, b.status_error, "")
	testing.expect(t, os.exists(fmt.tprintf("%s/file", dest)))
}
