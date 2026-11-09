package main

import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:testing"

trash_view_test_read :: proc(t: ^testing.T, b: ^Browser, root, top: string, local: bool) {
	op := new(File_Operation)
	defer file_operation_destroy(op)
	op.kind, op.records = .List_Trash, make(map[string]File_Change)
	seen := make(map[[2]u64]bool)
	defer delete(seen)
	testing.expect(t, trash_read_root(op, root, top, local, false, &seen) == nil)
	b.pending_trash = op
	testing.expect(t, trash_view_apply(b, op))
}

@(test)
trash_metadata_paths_preserve_bytes_and_reject_mount_escape :: proc(t: ^testing.T) {
	cases := [?]struct {
		data, top:    string,
		local, valid: bool,
		expected:     string,
	} {
		{"[Trash Info]\nPath=/home/test/a%20%23%FF\n", "/", false, true, "/home/test/a #\xff"},
		{"[Trash Info]\nPath=dir/a%20b\n", "/mnt/test", true, true, "/mnt/test/dir/a b"},
		{"[Trash Info]\nPath=/mnt/test/a\n", "/mnt/test", true, true, "/mnt/test/a"},
		{"[Trash Info]\nPath=../outside\n", "/mnt/test", true, false, ""},
		{"[Trash Info]\nPath=%2e%2e/outside\n", "/mnt/test", true, false, ""},
		{"[Trash Info]\nPath=/outside\n", "/mnt/test", true, false, ""},
		{"[Trash Info]\nPath=relative\n", "/", false, false, ""},
		{"[Trash Info]\nPath=/a%00b\n", "/", false, false, ""},
	}
	for item in cases {
		path, valid := trash_original_path(item.data, item.top, item.local)
		testing.expect_value(t, valid, item.valid)
		if valid {testing.expect_value(t, path, item.expected)}
		delete(path)
	}
}

@(test)
trash_view_lists_original_names_and_restores_without_overwrite :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-trash-view-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create trash view fixture")}
	defer delete(root)
	defer os.remove_all(root)
	home, source, folder, link :=
		fmt.aprintf("%s/data/Trash", root),
		fmt.aprintf("%s/.hidden 雪", root),
		fmt.aprintf("%s/folder", root),
		fmt.aprintf("%s/link", root)
	defer delete(home)
	defer delete(source)
	defer delete(folder)
	defer delete(link)
	testing.expect(t, os.write_entire_file(source, "original") == nil)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/child", folder), "child") == nil)
	testing.expect(t, os.symlink("missing", link) == nil)
	for path in ([?]string{source, folder, link}) {testing.expect(t, trash_file(path, home, nil) == nil)}
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone(TRASH_PATH)
	trash_view_test_read(t, &b, home, "/", false)
	testing.expect_value(t, len(b.entries), 3)
	testing.expect_value(t, len(b.visible), 3) // Hidden items must remain recoverable.
	testing.expect(
		t,
		!menu_visible(&b, .Trash) && !menu_visible(&b, .Paste) && menu_visible(&b, .Restore),
	)
	record: File_Change
	for info in b.entries {
		if info.name == ".hidden 雪" {record = b.trash_records[info.fullpath]}
		testing.expect(
			t,
			info.name == ".hidden 雪" || info.name == "folder" || info.name == "link",
		)
	}
	testing.expect_value(t, record.path, source)
	// Restoration must not replace a file created since the deletion.
	testing.expect(t, os.write_entire_file(source, "replacement") == nil)
	for attempt in 0 ..< 2 {
		op := new(File_Operation)
		op.kind, op.target = .Restore, strings.clone(TRASH_PATH)
		append(&op.sources, strings.clone(record.alternate))
		append(
			&op.restores,
			File_Change {
				path = strings.clone(record.path),
				alternate = strings.clone(record.alternate),
				trash_info = strings.clone(record.trash_info),
				device = record.device,
				inode = record.inode,
			},
		)
		testing.expect_value(t, file_history_test_run(t, &b, op), attempt == 0 ? 1 : 0)
		data, read_err := os.read_entire_file(source, context.allocator)
		testing.expect(t, read_err == nil)
		testing.expect_value(t, string(data), attempt == 0 ? "replacement" : "original")
		delete(data)
		if attempt == 0 {
			testing.expect(t, os.exists(record.alternate) && os.exists(record.trash_info))
			testing.expect(t, os.remove(source) == nil)
		}
	}
	trash_view_test_read(t, &b, home, "/", false)
	testing.expect_value(t, len(b.entries), 2)
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
	testing.expect(t, !os.exists(source))
	testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)
	testing.expect(t, os.exists(source))
	// A completed listing must not return the user to trash after navigation.
	op := new(File_Operation)
	defer file_operation_destroy(op)
	op.kind, op.records = .List_Trash, make(map[string]File_Change)
	seen := make(map[[2]u64]bool)
	defer delete(seen)
	testing.expect(t, trash_read_root(op, home, "/", false, false, &seen) == nil)
	b.pending_trash = op
	testing.expect(t, browser_load(&b, root) == nil)
	testing.expect(t, !trash_view_apply(&b, op))
	testing.expect_value(t, b.path, root)
}

@(test)
local_trash_view_uses_relative_metadata_without_creating_directories :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-local-trash-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create local trash fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, local :=
		fmt.aprintf("%s/file", root), fmt.aprintf("%s/.Trash-%d", root, linux.getuid())
	defer delete(source)
	defer delete(local)
	op := new(File_Operation)
	defer file_operation_destroy(op)
	seen := make(map[[2]u64]bool)
	defer delete(seen)
	testing.expect(t, trash_read_root(op, local, root, true, false, &seen) != nil)
	testing.expect(t, !os.exists(local))
	testing.expect(t, os.write_entire_file(source, "local") == nil)
	testing.expect(t, trash_file(source, "", []Mount{{path = root}}) == nil)
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone(TRASH_PATH)
	trash_view_test_read(t, &b, local, root, true)
	testing.expect_value(t, len(b.entries), 1)
	testing.expect_value(t, b.entries[0].name, "file")
	testing.expect_value(t, b.trash_records[b.entries[0].fullpath].path, source)
}

@(test)
trash_scan_skips_protected_optional_mounts_but_reports_home_errors :: proc(t: ^testing.T) {
	if linux.getuid() == 0 {return}
	root, err := os.make_directory_temp("/tmp", "stuff-protected-trash-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create protected mount fixture")}
	defer delete(root)
	defer os.remove_all(root)
	defer os.chmod(root, os.perm(0o700))
	op := new(File_Operation)
	defer file_operation_destroy(op)
	seen := make(map[[2]u64]bool)
	defer delete(seen)
	testing.expect(t, os.chmod(root, os.perm(0)) == nil)
	path := fmt.aprintf("%s/.Trash-%d", root, linux.getuid())
	defer delete(path)
	testing.expect_value(
		t,
		trash_read_root(op, path, root, true, false, &seen),
		os.Error(.Unsupported),
	)
	testing.expect(t, trash_read_root(op, path, root, false, false, &seen) != nil)
	testing.expect_value(t, len(op.listed), 0)
}
