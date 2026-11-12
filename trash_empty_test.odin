package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

trash_test_count :: proc(t: ^testing.T, path: string) -> int {
	entries, err := os.read_all_directory_by_path(path, context.allocator)
	if err != nil {testing.fail_now(t, "cannot read trash directory")}
	defer os.file_info_slice_delete(entries, context.allocator)
	return len(entries)
}

@(test)
empty_trash_removes_contents_without_following_links :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-empty-trash-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create empty trash fixture")}
	defer delete(root)
	defer os.remove_all(root)
	outside := fmt.tprintf("%s/outside", root)
	source := fmt.tprintf("%s/source", root)
	folder := fmt.tprintf("%s/folder", root)
	link := fmt.tprintf("%s/link", root)
	testing.expect(t, os.write_entire_file(outside, "keep") == nil)
	testing.expect(t, os.write_entire_file(source, "source") == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/sub/deep", folder)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/child", folder), "child") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/sub/deep/leaf", folder), "leaf") == nil)
	testing.expect(t, os.symlink(outside, link) == nil)
	testing.expect(t, os.symlink(outside, fmt.tprintf("%s/inner-link", folder)) == nil)
	home := fmt.tprintf("%s/data/Trash", root)
	for path in ([?]string{source, folder, link}) {
		testing.expect(t, trash_file(path, home, nil) == nil)
	}
	// Entries without a record are invisible in the view but still belong to the trash.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/files/orphan", home), "x") == nil)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/info/stale.trashinfo", home), "stale") == nil,
	)

	sibling := fmt.tprintf("%s/kept", root)
	testing.expect(t, os.make_directory(sibling) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/child", sibling), "keep") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	for path in ([?]string{root, fmt.tprintf("%s/data", root), home, sibling}) {
		b.sizes[strings.clone(path)] = {
			state   = .Known,
			bytes   = 4,
			request = b.size_generation,
		}
	}
	op := File_Operation {
		kind   = .Empty_Trash,
		target = TRASH_PATH,
	}
	defer file_changes_destroy(op.applied)
	defer delete(op.error)
	testing.expect(t, trash_empty_root(&op, home, false) == nil)
	testing.expect_value(t, op.failed, 0)
	testing.expect_value(t, trash_test_count(t, fmt.tprintf("%s/files", home)), 0)
	testing.expect_value(t, trash_test_count(t, fmt.tprintf("%s/info", home)), 0)
	append(&b.transfers, File_Transfer{op = &op})
	testing.expect(t, file_operation_apply(&b, &op))
	testing.expect_value(t, len(b.sizes), 1)
	testing.expect_value(t, size_value(&b, {type = .Directory, fullpath = sibling}), i64(4))
	testing.expect_value(t, b.sizes[sibling].request, b.size_generation)
	content, read_err := os.read_entire_file(outside, context.allocator)
	defer delete(content)
	testing.expect(t, read_err == nil && string(content) == "keep")
}

@(test)
empty_trash_refuses_a_shared_directory :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-empty-shared-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create shared trash fixture")}
	defer delete(root)
	defer os.remove_all(root)
	trash := fmt.tprintf("%s/Trash", root)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/files", trash)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/info", trash)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/files/keep", trash), "keep") == nil)
	testing.expect(t, os.chmod(trash, os.perm(0o777)) == nil)

	op: File_Operation
	testing.expect(t, trash_empty_root(&op, trash, false) != nil)
	testing.expect(t, os.exists(fmt.tprintf("%s/files/keep", trash)))
}

@(test)
empty_trash_menu_follows_the_trash_place :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone(TRASH_PATH)
	testing.expect(t, menu_visible(&b, .Empty_Trash))
	testing.expect(t, !menu_enabled(&b, .Empty_Trash))
	append(&b.visible, 0)
	testing.expect(t, menu_enabled(&b, .Empty_Trash))
	delete(b.path)
	b.path = strings.clone("/tmp")
	testing.expect(t, !menu_visible(&b, .Empty_Trash))
	// The trash place offers the same action while another folder is open.
	append(
		&b.places.entries,
		Place{label = strings.clone("trash"), path = strings.clone(TRASH_PATH)},
	)
	append(&b.places.entries, Place{label = strings.clone("tmp"), path = strings.clone("/tmp")})
	g := geometry(960, 640, 1)
	b.menu.width = 160
	y := places_geometry(g).list_top + 1
	testing.expect(t, menu_open_places(&b, g, 20, y))
	testing.expect(t, b.menu.active && b.menu.places)
	testing.expect(t, menu_visible(&b, .Empty_Trash) && menu_enabled(&b, .Empty_Trash))
	box := menu_box(&b, g)
	testing.expect_value(
		t,
		menu_action_at(&b, g, box.x + box.width / 2, box.y + 4 * g.scale + g.row / 2),
		int(Menu_Action.Empty_Trash),
	)
	b.menu.active = false
	testing.expect(t, !menu_open_places(&b, g, 20, y + g.row))
}
