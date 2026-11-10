package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
sort_choices_follow_folders :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-sorts-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create sort fixture")}
	defer delete(root)
	defer os.remove_all(root)
	first, second := fmt.tprintf("%s/first", root), fmt.tprintf("%s/second", root)
	testing.expect(t, os.make_directory(first) == nil)
	testing.expect(t, os.make_directory(second) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a", first), "a") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/b", second), "b") == nil)

	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, first) == nil)
	browser_set_sort(&b, .Size)
	browser_set_sort(&b, .Size)
	testing.expect_value(t, b.sort_column, Column.Size)
	testing.expect(t, b.descending)

	// A folder without a saved choice keeps the active sort.
	testing.expect(t, browser_navigate(&b, second) == nil)
	testing.expect_value(t, b.sort_column, Column.Size)
	testing.expect(t, b.descending)
	browser_set_sort(&b, .Modified)

	testing.expect(t, browser_navigate(&b, first) == nil)
	testing.expect_value(t, b.sort_column, Column.Size)
	testing.expect(t, b.descending)
	testing.expect(t, browser_navigate(&b, second) == nil)
	testing.expect_value(t, b.sort_column, Column.Modified)
	testing.expect(t, !b.descending)
}

@(test)
sort_choices_survive_a_restart :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-sort-state-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create sort state fixture")}
	defer delete(root)
	defer os.remove_all(root)
	folder := fmt.tprintf("%s/folder\twith space", root)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a", folder), "a") == nil)
	state := fmt.tprintf("%s/state/sort", root)

	first: Browser
	first.sorts_path = state
	defer browser_destroy(&first)
	testing.expect(t, browser_load(&first, folder) == nil)
	browser_set_sort(&first, .Modified)

	restored: Browser
	restored.sorts_path = state
	defer browser_destroy(&restored)
	sort_state_load(&restored)
	testing.expect(t, browser_load(&restored, folder) == nil)
	testing.expect_value(t, restored.sort_column, Column.Modified)
	testing.expect(t, !restored.descending)
}

@(test)
sort_state_ignores_a_broken_file :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-sort-broken-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create broken sort fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.tprintf("%s/sort", root)
	testing.expect(t, os.write_entire_file(path, `{"column":`) == nil)

	b: Browser
	b.sorts_path = path
	defer browser_destroy(&b)
	sort_state_load(&b)
	testing.expect_value(t, len(b.sorts), 0)
}
