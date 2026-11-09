package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// Run the real worker body with private fixtures; publication is synchronous here.
file_history_test_run :: proc(t: ^testing.T, b: ^Browser, op: ^File_Operation) -> int {
	defer file_operation_destroy(op)
	op.count = len(op.sources) + len(op.changes)
	b.pending_files = op
	file_operation_run(op)
	testing.expect(t, file_operation_apply(b, op))
	return op.failed
}

file_history_test_step :: proc(t: ^testing.T, b: ^Browser, home: string, redo: bool) -> int {
	from := &b.undo_files
	if redo {from = &b.redo_files}
	if len(from^) == 0 {testing.fail_now(t, "missing file history")}
	batch := pop(from)
	op := new(File_Operation)
	op.kind, op.target, op.changes = batch.kind, batch.target, batch.changes
	op.history, op.trash_home = redo ? .Redo : .Undo, strings.clone(home)
	return file_history_test_run(t, b, op)
}

file_history_test_record :: proc(
	t: ^testing.T,
	b: ^Browser,
	home, target: string,
	kind: File_Action,
	paths: []string,
) {
	op := new(File_Operation)
	op.kind, op.target, op.trash_home = kind, strings.clone(target), strings.clone(home)
	for path in paths {append(&op.sources, strings.clone(path))}
	testing.expect_value(t, file_history_test_run(t, b, op), 0)
}

@(test)
copy_history_preserves_versions_and_partial_conflicts :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-undo-copy-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create history fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, link, dest, home :=
		fmt.aprintf("%s/original.txt", root),
		fmt.aprintf("%s/link", root),
		fmt.aprintf("%s/dest", root),
		fmt.aprintf("%s/data/Trash", root)
	defer delete(source)
	defer delete(link)
	defer delete(dest)
	defer delete(home)
	testing.expect(t, os.write_entire_file(source, "original version") == nil)
	testing.expect(t, os.symlink("missing", link) == nil)
	testing.expect(t, os.make_directory(dest) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, dest) == nil)
	file_history_test_record(t, &b, home, dest, .Copy, []string{source, link})
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect_value(t, len(b.undo_files[0].changes), 2)
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
	testing.expect_value(t, len(b.redo_files), 1)
	copied := fmt.aprintf("%s/original.txt", dest)
	defer delete(copied)
	testing.expect(t, !os.exists(copied))
	// Redo restores the copied version, not a new copy of a changed source.
	testing.expect(t, os.write_entire_file(source, "newer source") == nil)
	testing.expect(t, os.write_entire_file(copied, "unrelated destination") == nil)
	testing.expect_value(t, file_history_test_step(t, &b, home, true), 1)
	testing.expect_value(t, len(b.redo_files[0].changes), 1)
	testing.expect_value(t, len(b.undo_files[0].changes), 1)
	bytes, read_err := os.read_entire_file(copied, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(bytes), "unrelated destination")
	delete(bytes)
	link_value, link_err := os.read_link(fmt.tprintf("%s/link", dest), context.allocator)
	testing.expect(t, link_err == nil)
	testing.expect_value(t, link_value, "missing")
	delete(link_value)
	testing.expect(t, os.remove(copied) == nil)
	testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)
	bytes, read_err = os.read_entire_file(copied, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(bytes), "original version")
	delete(bytes)
	// A different file at the recorded path must not be moved to trash.
	testing.expect(t, file_rename_new(copied, fmt.tprintf("%s/saved", dest)) == nil)
	testing.expect(t, os.write_entire_file(copied, "replacement") == nil)
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 1)
	bytes, read_err = os.read_entire_file(copied, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(bytes), "replacement")
	delete(bytes)
}

@(test)
trash_history_restores_metadata_and_keeps_discarded_copies :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-undo-trash-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create history fixture")}
	defer delete(root)
	defer os.remove_all(root)
	folder, home := fmt.aprintf("%s/folder", root), fmt.aprintf("%s/data/Trash", root)
	defer delete(folder)
	defer delete(home)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/child", folder), "keep") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	file_history_test_record(t, &b, home, root, .Trash, []string{folder})
	for _ in 0 ..< 2 {
		metadata := strings.clone(b.undo_files[0].changes[0].trash_info)
		testing.expect(t, os.exists(metadata))
		testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
		testing.expect(t, os.exists(fmt.tprintf("%s/child", folder)))
		testing.expect(t, !os.exists(metadata))
		delete(metadata)
		testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)
		testing.expect(t, !os.exists(folder))
	}
	// An emptied trash is a recoverable failure, not permission to touch another path.
	stored := b.undo_files[0].changes[0].alternate
	testing.expect(t, os.remove_all(stored) == nil)
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 1)
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect_value(t, len(b.redo_files), 0)
	file := fmt.aprintf("%s/file", root)
	defer delete(file)
	testing.expect(t, os.write_entire_file(file, "copy") == nil)
	file_history_test_record(t, &b, home, root, .Copy, []string{file})
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
	trashed_copy := strings.clone(b.redo_files[0].changes[0].alternate)
	defer delete(trashed_copy)
	file_history_test_record(t, &b, home, root, .Trash, []string{file})
	testing.expect_value(t, len(b.redo_files), 0)
	testing.expect(t, os.exists(trashed_copy)) // Discarding history never deletes filesystem data.
}

file_history_test_wait :: proc(t: ^testing.T, b: ^Browser) {
	deadline := sdl.GetTicks() + 3000
	for b.pending_files != nil && sdl.GetTicks() < deadline {
		_ = storage_poll(b)
		time.sleep(time.Millisecond)
	}
	if b.pending_files != nil {testing.fail_now(t, "file worker did not finish")}
}

@(test)
background_history_shortcuts_respect_input_focus_and_navigation :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-history-worker-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create worker fixture")}
	defer delete(root)
	defer os.remove_all(root)
	previous, was_set := os.lookup_env("XDG_DATA_HOME", context.allocator)
	defer delete(previous)
	defer {
		if was_set {_ = os.set_env("XDG_DATA_HOME", previous)} else {_ = os.unset_env("XDG_DATA_HOME")}
	}
	testing.expect(t, os.set_env("XDG_DATA_HOME", fmt.tprintf("%s/data", root)) == nil)
	dest, source := fmt.aprintf("%s/dest", root), fmt.aprintf("%s/source", root)
	defer delete(dest)
	defer delete(source)
	testing.expect(t, os.make_directory(dest) == nil)
	testing.expect(t, os.write_entire_file(source, "private fixture") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, dest) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start storage")}
	op := new(File_Operation)
	op.target = strings.clone(dest)
	append(&op.sources, strings.clone(source))
	if !file_operation_launch(
		&b,
		op,
	) {file_operation_destroy(op); testing.fail_now(t, "cannot start file worker")}
	file_history_test_wait(t, &b)
	testing.expect_value(t, len(b.undo_files), 1)
	g, running := geometry(960, 640, 1), true
	path_edit_start(&b)
	path_edit_replace(&b, "draft")
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_Z, mod = sdl.KMOD_CTRL},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, dest)
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect(t, b.pending_files == nil)
	event.key.mod |= sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.header.edit.value, "draft")
	path_edit_end(&b.header.edit)
	event.key.mod = sdl.KMOD_CTRL
	_ = handle_event(&b, &event, g, &running)
	testing.expect(t, b.pending_files != nil)
	testing.expect(t, browser_navigate(&b, root) == nil)
	file_history_test_wait(t, &b)
	testing.expect_value(t, b.path, root)
	testing.expect_value(t, len(b.redo_files), 1)
	testing.expect(t, !os.exists(fmt.tprintf("%s/source", dest)))
	testing.expect(t, os.exists(source))
	event.key.mod |= sdl.KMOD_SHIFT
	_ = handle_event(&b, &event, g, &running)
	file_history_test_wait(t, &b)
	testing.expect_value(t, b.path, root)
	testing.expect(t, os.exists(fmt.tprintf("%s/source", dest)))
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect_value(t, b.status_error, "")
}
