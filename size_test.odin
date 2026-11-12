package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

size_test_wait :: proc(t: ^testing.T, b: ^Browser, path: string, bytes: i64) {
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second {
		_ = size_poll(b)
		if entry, exists := b.sizes[path];
		   exists && entry.state == .Known && entry.bytes == bytes {return}
		time.sleep(time.Millisecond)
	}
	testing.fail_now(t, "directory size did not refresh")
}

@(test)
tab_changes_keep_recent_sizes_and_allow_expired_totals_to_refresh :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-tab-sizes-", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	tree := fmt.aprintf("%s/tree", root)
	defer delete(tree)
	file := fmt.aprintf("%s/sub/file", tree)
	defer delete(file)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/sub", tree)) == nil)
	testing.expect(t, os.write_entire_file(file, "data") == nil)
	b: Browser
	defer browser_destroy(&b)
	b.size_service = size_start(2)
	if !testing.expect(t, b.size_service != nil) {return}
	testing.expect(t, browser_load(&b, root) == nil)
	size_request_visible(&b, 1)
	generation := b.size_generation
	// Changing tabs must not cancel a request that is still being processed.
	testing.expect(t, tab_open(&b, root) == nil)
	size_request_visible(&b, 1)
	testing.expect_value(t, b.size_generation, generation)
	size_test_wait(t, &b, tree, 4)
	testing.expect(t, os.write_entire_file(file, "changed") == nil)
	cached := b.sizes[tree]
	running := true
	for _ in 0 ..< 4 {
		testing.expect(t, tab_open(&b, root) == nil)
		size_request_visible(&b, 1)
		testing.expect(t, tab_close(&b, b.active_tab, &running) == nil)
		size_request_visible(&b, 1)
	}
	testing.expect_value(t, b.size_generation, generation)
	testing.expect_value(t, b.sizes[tree].refresh_after, cached.refresh_after)
	testing.expect_value(t, b.sizes[tree].bytes, i64(4))
	// Expire the cached total without a five-second test sleep. A descendant
	// change must be found even though the top-level folder did not change.
	cached.refresh_after = 0
	b.sizes[tree] = cached
	// An ordinary frame must not start periodic filesystem work.
	size_request_visible(&b, 1)
	testing.expect_value(t, b.sizes[tree].refresh_after, u64(0))
	testing.expect(t, tab_open(&b, root) == nil)
	size_request_visible(&b, 1)
	size_request_visible(&b, 1)
	size_test_wait(t, &b, tree, 7)
}

@(test)
directory_sizes_keep_cached_totals_on_reopen_and_reject_old_results :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-size-worker-", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	for i in 0 ..< 4 {
		folder := fmt.tprintf("%s/%d", root, i)
		testing.expect(t, os.make_directory(folder) == nil)
		testing.expect(t, os.write_entire_file(fmt.tprintf("%s/file", folder), "data") == nil)
	}
	b: Browser
	defer browser_destroy(&b)
	b.size_service = size_start()
	if !testing.expect(t, b.size_service != nil) {return}
	testing.expect(t, browser_load(&b, root) == nil)
	size_request_visible(&b, 1)
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		_ = size_poll(&b)
		ready := 0
		for _, entry in b.sizes {if entry.state == .Known {ready += 1}}
		if ready == 3 {break}
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(b.sizes), 3) // Visible row, overscan, and a screen ahead.
	for _, entry in b.sizes {
		testing.expect_value(t, entry.state, Size_State.Known)
		testing.expect_value(t, entry.bytes, i64(4))
	}
	old_generation := b.size_generation
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/0/file", root), "changed") == nil)
	testing.expect(t, browser_load(&b, fmt.tprintf("%s/0", root)) == nil)
	testing.expect(t, browser_load(&b, root) == nil)
	// A result already queued before reload must not restore the stale total.
	{
		sync.mutex_guard(&b.size_service.mutex)
		append(
			&b.size_service.results,
			Size_Result {
				path = strings.clone(fmt.tprintf("%s/0", root)),
				bytes = 4,
				generation = old_generation,
				ok = true,
			},
		)
	}
	testing.expect(t, !size_poll(&b))
	testing.expect_value(t, len(b.sizes), 3)
	cached := b.sizes[fmt.tprintf("%s/0", root)]
	testing.expect_value(t, cached.state, Size_State.Known)
	testing.expect_value(t, cached.bytes, i64(4))
	size_request_visible(&b, 1)
	testing.expect_value(t, b.sizes[fmt.tprintf("%s/0", root)].state, Size_State.Known)
	size_test_wait(t, &b, fmt.tprintf("%s/0", root), 7)
	// A folder removed after listing must finish as unavailable, not stay pending.
	missing := fmt.tprintf("%s/3", root)
	testing.expect(t, os.remove_all(missing) == nil)
	b.first = 3
	size_request_visible(&b, 1)
	deadline = time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		_ = size_poll(&b)
		if entry, ok := b.sizes[missing]; ok && entry.state == .Failed {return}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "missing folder stayed pending")
}

@(test)
directory_sizes_preload_both_sides_and_keep_scroll_results :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-size-preload-", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	for i in 0 ..< 32 {testing.expect(t, os.make_directory(fmt.tprintf("%s/%02d", root, i)) == nil)}
	b: Browser
	defer browser_destroy(&b)
	// Match app startup: the first directory is loaded before workers start.
	testing.expect(t, browser_load(&b, root) == nil)
	b.size_service = size_start(2)
	if !testing.expect(t, b.size_service != nil) {return}
	b.first = 6
	size_request_visible(&b, 3)
	testing.expect_value(t, len(b.sizes), 10)
	testing.expect(t, fmt.tprintf("%s/03", root) in b.sizes)
	testing.expect(t, fmt.tprintf("%s/12", root) in b.sizes)
	testing.expect(t, fmt.tprintf("%s/02", root) not_in b.sizes)
	testing.expect(t, fmt.tprintf("%s/13", root) not_in b.sizes)
	deadline := time.tick_now()
	ready := false
	for time.tick_since(deadline) < 5 * time.Second {
		_ = size_poll(&b)
		pending := false
		for _, cached in b.sizes {pending = pending || cached.state != .Known}
		if !pending {ready = true; break}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, ready)
	generation := b.size_generation
	b.first += 3 // One wheel step; these rows must already have sizes.
	size_request_visible(&b, 3)
	testing.expect_value(t, b.size_generation, generation)
	for i in 9 ..< 13 {
		cached := b.sizes[fmt.tprintf("%s/%02d", root, i)]
		testing.expect_value(t, cached.state, Size_State.Known)
		testing.expect_value(t, cached.request, generation)
	}
	browser_set_sort(&b, .Modified)
	testing.expect_value(t, b.size_generation, generation)
}

@(test)
directory_size_session_cache_evicts_old_results :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.size_clock = 2
	b.sizes[strings.clone("/recent")] = {
		state = .Known,
		used  = 2,
		bytes = 42,
	}
	for i in 0 ..< SIZE_CACHE_LIMIT {b.sizes[fmt.aprintf("/old/%d", i)] = {
			state = .Known,
			used  = 1,
		}}
	size_cache_prune(&b)
	testing.expect_value(t, len(b.sizes), SIZE_CACHE_LIMIT)
	testing.expect_value(t, b.sizes["/recent"].bytes, i64(42))
}

@(test)
directory_size_cache_invalidates_changed_trees_but_keeps_siblings :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	paths := [?]string {
		"/folder",
		"/folder/changed",
		"/folder/changed/sub",
		"/folder/sibling",
		"/folder/changed-suffix",
		"/other",
	}
	for path in paths {b.sizes[strings.clone(path)] = {
			state = .Known,
			bytes = 42,
		}}
	size_cache_invalidate(&b, "/folder/changed")
	testing.expect_value(t, len(b.sizes), 3)
	testing.expect(t, "/folder/sibling" in b.sizes)
	testing.expect(t, "/folder/changed-suffix" in b.sizes)
	testing.expect(t, "/other" in b.sizes)
	b.sizes[strings.clone("/folder")] = {
		state = .Known,
		bytes = 42,
	}
	size_cache_invalidate(&b, "/folder", descendants = false)
	testing.expect_value(t, len(b.sizes), 3)
}

@(test)
directory_size_workers_have_lower_priority_than_ui :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	before, err := linux.getpriority(.PROCESS, 0)
	if !testing.expect(t, err == .NONE) {return}
	s := size_start(2)
	if !testing.expect(t, s != nil) {return}
	defer size_destroy(s)
	deadline := time.tick_now()
	for time.tick_since(deadline) < 5 * time.Second {
		dir, open_err := directory_open("/proc/self/task")
		if !testing.expect(t, open_err == nil) {return}
		entries, read_err := os.read_all_directory(dir, context.allocator)
		os.close(dir)
		if !testing.expect(t, read_err == nil) {return}
		ready := 0
		for entry in entries {
			name, name_err := os.read_entire_file(
				fmt.tprintf("%s/comm", entry.fullpath),
				context.allocator,
			)
			if name_err == nil && strings.trim_space(string(name)) == "stuff-size-scan" {
				id, valid := strconv.parse_int(entry.name)
				priority, priority_err := linux.getpriority(.PROCESS, i32(id))
				if valid && priority_err == .NONE && priority == max(10, before) {ready += 1}
			}
			delete(name)
		}
		os.file_info_slice_delete(entries, context.allocator)
		if ready == 2 {
			after, after_err := linux.getpriority(.PROCESS, 0)
			testing.expect(t, after_err == .NONE)
			testing.expect_value(t, after, before)
			return
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "scan workers did not reach the expected nice value")
}

size_test_fd_count :: proc(t: ^testing.T) -> int {
	fd, err := linux.open("/proc/self/fd", {.DIRECTORY, .CLOEXEC})
	if !testing.expect(t, err == .NONE) {return -1}
	defer linux.close(fd)
	buffer: [4096]u8
	count := 0
	for {
		n, read_err := linux.getdents(fd, buffer[:])
		if !testing.expect(t, read_err == .NONE) {return -1}
		if n == 0 {return count}
		offset := 0
		for entry in linux.dirent_iterate_buf(buffer[:n], &offset) {
			name := linux.dirent_name(entry)
			if name != "." && name != ".." {count += 1}
		}
	}
}

@(test)
directory_size_split_totals_cancel_and_close_descriptors :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-size-split-", context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(root)
	defer os.remove_all(root)
	for d in 0 ..< 64 {
		dir := fmt.tprintf("%s/large/%d", root, d)
		testing.expect(t, os.make_directory_all(dir) == nil)
		for f in 0 ..< 32 {
			testing.expect(t, os.write_entire_file(fmt.tprintf("%s/%d", dir, f), "payload") == nil)
		}
		for n in 0 ..< 4 {
			nested := fmt.tprintf("%s/nested/%d", dir, n)
			testing.expect(t, os.make_directory_all(nested) == nil)
			testing.expect(
				t,
				os.write_entire_file(fmt.tprintf("%s/file", nested), "nested") == nil,
			)
		}
	}
	testing.expect(t, os.make_directory(fmt.tprintf("%s/small", root)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/small/.hidden", root), "hidden") == nil)
	testing.expect(t, os.symlink(root, fmt.tprintf("%s/large/loop", root)) == nil)
	testing.expect(
		t,
		os.symlink(
			fmt.tprintf("%s/small/.hidden", root),
			fmt.tprintf("%s/large/file-link", root),
		) ==
		nil,
	)
	before := size_test_fd_count(t)
	b: Browser
	defer browser_destroy(&b)
	b.size_service = size_start(2)
	if !testing.expect(t, b.size_service != nil) {return}
	testing.expect(t, browser_load(&b, root) == nil)
	size_request_visible(&b, 1)
	deadline := time.tick_now()
	ready := false
	for time.tick_since(deadline) < 5 * time.Second {
		_ = size_poll(&b)
		large := b.sizes[fmt.tprintf("%s/large", root)]
		small := b.sizes[fmt.tprintf("%s/small", root)]
		if large.state == .Known && small.state == .Known {
			testing.expect_value(
				t,
				large.bytes,
				i64(64 * (32 * len("payload") + 4 * len("nested"))),
			)
			testing.expect_value(t, small.bytes, i64(len("hidden")))
			ready = true
			break
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, ready, "split scan did not return complete totals")
	// Child totals must be complete even when work splits below those children.
	for d in 0 ..< 64 {
		cached, exists := b.sizes[fmt.tprintf("%s/large/%d", root, d)]
		testing.expect(t, exists && cached.state == .Known)
		testing.expect_value(t, cached.bytes, i64(32 * len("payload") + 4 * len("nested")))
	}
	testing.expect(t, fmt.tprintf("%s/large/0/nested", root) not_in b.sizes)
	testing.expect(t, browser_navigate(&b, fmt.tprintf("%s/large", root)) == nil)
	// All rows already have sizes, before another request or result poll.
	for source in b.visible {
		entry := b.entries[source]
		if entry.type == .Directory {testing.expect_value(t, size_value(&b, entry), i64(248))}
	}
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/large/0/nested/0/file", root), "changed-content") ==
		nil,
	)
	size_request_visible(&b, 1)
	testing.expect_value(t, b.sizes[fmt.tprintf("%s/large/0", root)].bytes, i64(248))
	size_test_wait(t, &b, fmt.tprintf("%s/large/0", root), 257)
	for _ in 0 ..< 12 {
		size_cache_clear(&b)
		size_request_visible(&b, 1)
		time.sleep(time.Millisecond)
	}
	// Change generation while subtree tasks can still own queued directory FDs.
	size_cache_clear(&b)
	testing.expect(t, !size_poll(&b), "canceled scans must not change the cache")
	size_request_visible(&b, 1)
	size_destroy(b.size_service)
	b.size_service = nil
	testing.expect_value(t, size_test_fd_count(t), before)
}

@(test)
directory_size_child_results_respect_cache_limit_and_explicit_refreshes :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	b.size_service = size_start(1)
	if !testing.expect(t, b.size_service != nil) {return}
	size_cancel(&b)
	b.sizes[strings.clone("/requested")] = {
		state   = .Pending,
		request = b.size_generation,
	}
	for i in 0 ..< SIZE_CACHE_LIMIT - 1 {b.sizes[fmt.aprintf("/cached/%d", i)] = {
			state = .Known,
			bytes = 7,
		}}
	children := [3]Size_Child {
		{path = strings.clone("/extra"), bytes = 42, ok = true},
		{path = strings.clone("/requested"), bytes = 42, ok = true},
		{path = strings.clone("/cached/0"), bytes = 42, ok = false},
	}
	defer for child in children {delete(child.path)}
	scan := Size_Scan {
		service    = b.size_service,
		path       = strings.clone("/parent"),
		generation = b.size_generation,
		ok         = true,
	}
	defer delete(scan.children)
	for &child in children {append(&scan.children, &child)}
	size_publish(&scan)
	_ = size_poll(&b)
	testing.expect_value(t, len(b.sizes), SIZE_CACHE_LIMIT)
	testing.expect(t, "/extra" not_in b.sizes)
	testing.expect_value(t, b.sizes["/requested"].state, Size_State.Pending)
	testing.expect_value(t, b.sizes["/cached/0"].bytes, i64(7))
}

size_test_request :: proc(s: ^Size_Service, path: string) {
	sync.mutex_lock(&s.mutex)
	append(&s.queue, Size_Request{path = strings.clone(path)})
	sync.mutex_unlock(&s.mutex)
	size_wake(s)
}

when #config(SIZE_BENCH, false) {
	@(test)
	directory_size_benchmark :: proc(t: ^testing.T) {
		root, err := os.make_directory_temp("/tmp", "stuff-size-bench-", context.allocator)
		if !testing.expect(t, err == nil) {return}
		defer delete(root)
		defer os.remove_all(root)
		payload: [1024]u8
		dirs, per_dir := 128, 128
		for d in 0 ..< dirs {
			dir := fmt.tprintf("%s/%d", root, d)
			testing.expect(t, os.make_directory(dir) == nil)
			for f in 0 ..< per_dir {
				testing.expect(
					t,
					os.write_entire_file(fmt.tprintf("%s/%d", dir, f), payload[:]) == nil,
				)
			}
		}
		if !testing.expect(t, sdl.Init({.EVENTS})) {return}
		defer sdl.Quit()
		worker_counts := [?]int{1, max(1, os.get_processor_core_count())}
		for workers in worker_counts {
			parallel: Browser
			defer browser_destroy(&parallel)
			parallel.size_service = size_start(workers)
			if !testing.expect(t, parallel.size_service != nil) {return}
			parallel.sizes[strings.clone(root)] = {}
			for _ in 0 ..< 3 {
				start := time.tick_now()
				s := parallel.size_service
				size_test_request(s, root)
				ready := false
				for time.tick_since(start) < 5 * time.Second {
					if size_poll(&parallel) {ready = true; break}
					time.sleep(100 * time.Microsecond)
				}
				entry := parallel.sizes[root]
				testing.expect(t, ready && entry.state == .Known)
				testing.expect_value(t, entry.bytes, i64(dirs * per_dir * len(payload)))
				fmt.printfln(
					"adaptive scan: workers=%d, nice >=10, time=%v",
					s.workers,
					time.tick_since(start),
				)
			}
		}
		b: Browser
		defer browser_destroy(&b)
		load_start := time.tick_now()
		testing.expect(t, browser_load(&b, root) == nil)
		fmt.printfln("folder listing without scanning: %v", time.tick_since(load_start))
		b.size_service = size_start()
		if !testing.expect(t, b.size_service != nil) {return}
		queue_start := time.tick_now()
		size_request_visible(&b, 10)
		fmt.printfln("UI scheduling 10 rows + preload: %v", time.tick_since(queue_start))
		cancel_start := time.tick_now()
		b.first = 100
		size_request_visible(&b, 10)
		fmt.printfln("UI scrolling and replacing queued work: %v", time.tick_since(cancel_start))
		shutdown_start := time.tick_now()
		size_destroy(b.size_service)
		b.size_service = nil
		fmt.printfln("cancel and join workers: %v", time.tick_since(shutdown_start))
	}
}
