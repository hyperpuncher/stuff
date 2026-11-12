package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

watch_test_ready :: proc(t: ^testing.T, b: ^Browser) {
	watch_sync(b)
	watch_test_registered(t, b.watch, b.path)
}

watch_test_registered :: proc(t: ^testing.T, w: ^Watch_Service, path: string) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		sync.mutex_lock(&w.mutex)
		ready := path in w.paths
		sync.mutex_unlock(&w.mutex)
		if ready {return}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "directory watch was not installed")
}

watch_test_entry :: proc(b: ^Browser, name: string) -> (os.File_Info, bool) {
	for entry in b.entries {if entry.name == name {return entry, true}}
	return {}, false
}

watch_test_wait :: proc(t: ^testing.T, b: ^Browser, count: int, name: string, bytes: i64 = -1) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		_ = watch_poll(b)
		entry, exists := watch_test_entry(b, name)
		if len(b.entries) == count && exists && (bytes < 0 || entry.size == bytes) {return}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "live listing did not reach the latest state")
}

@(test)
watch_listings_follow_external_changes_without_losing_selection :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-watch-list-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create watch fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/view", root)
	defer delete(path)
	testing.expect(t, os.make_directory(path) == nil)
	for i in 0 ..< 80 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%03d", path, i), "x") == nil)}
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, path) == nil)
	selection_single(&b, 45)
	selection_click(&b, 50, true, false)
	b.first, b.scroll_x = 40, 120
	b.watch = watch_start()
	if !testing.expect(t, b.watch != nil) {return}
	watch_test_ready(t, &b)
	g, running := geometry(600, 480, 1), true
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_MIDDLE,
			x = g.sidebar + 40,
			y = g.list_top + 1,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/000-new", path), "new") == nil)
	testing.expect(t, os.remove(fmt.tprintf("%s/010", path)) == nil)
	testing.expect(
		t,
		os.rename(fmt.tprintf("%s/020", path), fmt.tprintf("%s/renamed", path)) == nil,
	)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/045", path), "updated") == nil)
	watch_test_wait(t, &b, 80, "045", 7)
	_, renamed := watch_test_entry(&b, "renamed")
	testing.expect(t, renamed)
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "050")
	testing.expect_value(t, b.first, 40)
	testing.expect_value(t, b.scroll_x, f32(120))
	testing.expect_value(t, b.marked_bytes, i64(8))
	testing.expect(t, b.autoscroll.active)
	event = {
		button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_MIDDLE},
	}
	_ = handle_event(&b, &event, g, &running)
	for source in b.marks {testing.expect(t, b.entries[source].name == "045" || b.entries[source].name == "050")}
	// Editors often replace a file with a rename rather than writing its inode.
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.save", path), "replacement") == nil)
	testing.expect(t, os.rename(fmt.tprintf("%s/.save", path), fmt.tprintf("%s/045", path)) == nil)
	watch_test_wait(t, &b, 80, "045", 11)
	testing.expect_value(t, b.marked_bytes, i64(12))
	// A deleted/replaced current directory must not leave its old rows visible.
	moved := fmt.aprintf("%s/moved", root)
	defer delete(moved)
	testing.expect(t, os.rename(path, moved) == nil)
	deadline := time.tick_now()
	for len(b.entries) > 0 && time.tick_since(deadline) < 5 * time.Second {
		_ = watch_poll(&b)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(b.entries), 0)
	testing.expect(t, os.make_directory(path) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/returned", path), "x") == nil)
	watch_test_wait(t, &b, 1, "returned")
	// Overflow recovery discards history and takes a fresh snapshot.
	watch_refresh(b.watch, reset = true)
	for i in 0 ..< 100 {testing.expect(t, os.write_entire_file(fmt.tprintf("%s/burst-%03d", path, i), "x") == nil)}
	watch_test_wait(t, &b, 101, "burst-099")
}

@(test)
watch_only_tracks_the_active_directory_and_parent :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-watch-scope-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create watch scope fixture")}
	defer delete(root)
	defer os.remove_all(root)
	a, other := fmt.aprintf("%s/a", root), fmt.aprintf("%s/b", root)
	defer delete(a)
	defer delete(other)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/deep/nested", a)) == nil)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/deep/nested", other)) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, a) == nil)
	testing.expect(t, tab_open(&b, other, activate = false) == nil)
	b.watch = watch_start()
	if !testing.expect(t, b.watch != nil) {return}
	watch_test_ready(t, &b)
	watch_test_registered(t, b.watch, root)
	{
		sync.mutex_guard(&b.watch.mutex)
		testing.expect_value(t, len(b.watch.directories), 2)
		testing.expect(t, a in b.watch.paths && root in b.watch.paths)
	}
	testing.expect(t, tab_switch(&b, 1) == nil)
	watch_test_ready(t, &b)
	{
		sync.mutex_guard(&b.watch.mutex)
		testing.expect_value(t, len(b.watch.directories), 2)
		testing.expect(t, other in b.watch.paths && a not_in b.watch.paths)
	}
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/current", other), "live") == nil)
	watch_test_wait(t, &b, 2, "current", 4)
	time.sleep(3 * WATCH_BATCH_MS * time.Millisecond)
	_ = watch_poll(&b)
	// Deep changes and inactive tabs do not generate refresh work.
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/deep/nested/file", other), "nested") == nil,
	)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/inactive", a), "inactive") == nil)
	time.sleep(3 * WATCH_BATCH_MS * time.Millisecond)
	testing.expect(t, !watch_poll(&b))
	testing.expect(t, tab_switch(&b, 0) == nil)
	_, exists := watch_test_entry(&b, "inactive")
	testing.expect(t, exists, "inactive tabs must read the latest contents on activation")
}

watch_test_trash_notice :: proc(t: ^testing.T, w: ^Watch_Service) {
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		sync.mutex_lock(&w.mutex)
		result := w.pending
		w.pending = nil
		sync.mutex_unlock(&w.mutex)
		if result != nil {
			changed := result.trash
			watch_result_destroy(result)
			if changed {return}
		}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "external trash change was not reported")
}

@(test)
watch_trash_tracks_roots_created_after_startup :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-watch-trash-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create trash watch fixture")}
	defer delete(root)
	defer os.remove_all(root)
	previous, present := os.lookup_env("XDG_DATA_HOME", context.allocator)
	defer delete(previous)
	defer {
		if present {_ = os.set_env("XDG_DATA_HOME", previous)} else {_ = os.unset_env("XDG_DATA_HOME")}
	}
	data, home, source :=
		fmt.aprintf("%s/data", root),
		fmt.aprintf("%s/data/Trash", root),
		fmt.aprintf("%s/source", root)
	defer delete(data)
	defer delete(home)
	defer delete(source)
	testing.expect(t, os.make_directory(data) == nil)
	testing.expect(t, os.set_env("XDG_DATA_HOME", data) == nil)
	b: Browser
	defer browser_destroy(&b)
	b.path, b.watch = strings.clone(TRASH_PATH), watch_start()
	if !testing.expect(t, b.watch != nil) {return}
	watch_sync(&b)
	watch_test_registered(t, b.watch, data)
	testing.expect(t, os.write_entire_file(source, "fixture") == nil)
	record: File_Change
	defer file_change_destroy(record)
	// Only this fixture is moved to its private trash. No mounted trash is emptied.
	testing.expect(t, trash_file(source, home, nil, &record) == nil)
	watch_test_trash_notice(t, b.watch)
	watch_test_registered(t, b.watch, fmt.tprintf("%s/files", home))
	time.sleep(2 * WATCH_BATCH_MS * time.Millisecond)
	_ = watch_poll(&b)
	testing.expect(t, os.write_entire_file(record.alternate, "changed") == nil)
	watch_test_trash_notice(t, b.watch)
}

watch_test_batch :: proc(name: string, changes: []string = nil) -> Watch_Result {
	batch := Watch_Result {
		path    = strings.clone("/watched"),
		version = 1,
		listing = true,
	}
	batch.entries = make([]os.File_Info, 1)
	batch.entries[0].fullpath = fmt.aprintf("/watched/%s", name)
	batch.entries[0].name = os.base(batch.entries[0].fullpath)
	batch.entries[0].type = .Regular
	for path in changes {
		if watch_accept_change(&batch, path) {batch.changes[strings.clone(path)] = true}
	}
	return batch
}

@(test)
watch_batches_keep_latest_listing_and_discard_overflowed_changes :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	event := sdl.RegisterEvents(1)
	if !testing.expect(t, event != 0) {return}
	w := Watch_Service {
		event   = sdl.EventType(event),
		version = 1,
	}
	defer {watch_result_destroy(w.pending)}
	b: Browser
	defer browser_destroy(&b)
	b.path, b.watch = strings.clone("/watched"), &w
	defer b.watch = nil
	cached := []string{"/watched/first", "/watched/second", "/watched/shared", "/elsewhere/cached"}
	for path in cached {
		b.sizes[strings.clone(path)] = {
			state = .Known,
			bytes = 7,
		}
	}
	batch := watch_test_batch("first", []string{"/watched/first", "/watched/shared"})
	watch_publish(&w, &batch)
	batch = watch_test_batch("second", []string{"/watched/second", "/watched/shared"})
	watch_publish(&w, &batch)
	testing.expect(t, watch_poll(&b))
	testing.expect_value(t, b.entries[0].name, "second")
	testing.expect_value(t, len(b.sizes), 1)
	testing.expect(t, "/elsewhere/cached" in b.sizes)
	// Two valid batches can exceed the limit when merged before the UI reads them.
	for half in 0 ..< 2 {
		batch = watch_test_batch(half == 0 ? "queued" : "overflow")
		count :=
			half == 0 ? WATCH_CHANGE_LIMIT / 2 : WATCH_CHANGE_LIMIT - WATCH_CHANGE_LIMIT / 2 + 1
		for i in 0 ..< count {
			path := fmt.tprintf("/watched/burst/%d/%d", half, i)
			if watch_accept_change(&batch, path) {batch.changes[strings.clone(path)] = true}
		}
		watch_publish(&w, &batch)
	}
	// Later updates must still replace the listing, without retaining more paths.
	batch = watch_test_batch("latest", []string{"/watched/latest"})
	watch_publish(&w, &batch)
	testing.expect(t, w.pending.overflow)
	testing.expect_value(t, len(w.pending.changes), 0)
	testing.expect(t, watch_poll(&b))
	testing.expect_value(t, b.entries[0].name, "latest")
	testing.expect_value(t, len(b.sizes), 0)
	// Overflow within one batch must also release its paths before publication.
	batch = watch_test_batch("resnapshot")
	for i in 0 ..= WATCH_CHANGE_LIMIT {
		path := fmt.tprintf("/watched/burst/%d", i)
		if watch_accept_change(&batch, path) {batch.changes[strings.clone(path)] = true}
	}
	testing.expect(t, batch.overflow)
	testing.expect_value(t, len(batch.changes), 0)
	watch_publish(&w, &batch)
	testing.expect(t, watch_poll(&b))
	testing.expect_value(t, b.entries[0].name, "resnapshot")
}

@(test)
watch_rejects_old_snapshots_and_cancelled_size_publications :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/watched")
	watch: Watch_Service
	b.watch = &watch
	defer b.watch = nil
	watch.version = 2
	watch.pending = new(Watch_Result)
	watch.pending^ = watch_test_batch("obsolete")
	testing.expect(t, watch_poll(&b))
	testing.expect_value(t, len(b.entries), 0)
	s: Size_Service
	b.size_service = &s
	defer b.size_service = nil
	b.size_generation, s.generation = 1, 1
	scan := Size_Scan {
		service    = &s,
		path       = strings.clone("/watched/a"),
		generation = 1,
	}
	append(&s.scans, &scan)
	defer delete(s.scans)
	size_paths_changed(&b, []string{"/watched/a/deep/file"})
	// Simulate a scan that finished just before its change notification arrived.
	size_publish(&scan)
	testing.expect_value(t, len(s.results), 0)
	testing.expect_value(t, len(s.scans), 0)
}
