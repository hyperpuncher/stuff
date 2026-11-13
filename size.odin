package main

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import sdl "vendor:sdl3"

SIZE_CACHE_LIMIT :: 4096
SIZE_REFRESH_MS :: 5000 // Recheck completed totals on tab activation, not on a timer.

Size_State :: enum {
	Pending,
	Known,
	Failed,
}
Size_Entry :: struct {
	state:         Size_State,
	bytes:         i64,
	request:       u64,
	used:          u64,
	refresh_after: u64,
}
Size_Request :: struct {
	path:       string, // Owned by the queue, then the worker.
	generation: u64,
}
Size_Result :: struct {
	path:       string, // Owned by the result queue.
	bytes:      i64,
	generation: u64,
	ok:         bool,
	derived:    bool, // A completed immediate-child total, not a requested row.
}

Size_Child :: struct {
	path:  string, // Owned until transferred to a result.
	bytes: i64,
	ok:    bool,
}

// The coordinator owns completed tasks. Scan workers share each root's visited
// set. A generation change cancels scans; only the UI touches the cache.
Size_Service :: struct {
	mutex:      sync.Mutex,
	allocator:  mem.Allocator,
	worker:     ^thread.Thread,
	pool:       thread.Pool,
	workers:    int,
	wake:       [2]linux.Fd,
	event:      sdl.EventType,
	generation: u64, // Atomic.
	stop:       bool, // Atomic.
	queue:      [dynamic]Size_Request,
	scans:      [dynamic]^Size_Scan, // Borrowed active roots; protected by mutex.
	results:    [dynamic]Size_Result,
	children:   int, // Staged child totals; protected by mutex and bounded by the cache limit.
}

// pending uses the service mutex; bytes and ok belong to the coordinator.
// The scan mutex protects the visited set and child totals. Keep each scan alive
// until all its tasks finish.
Size_Scan :: struct {
	service:    ^Size_Service,
	path:       string,
	generation: u64,
	cancel:     bool, // Atomic; scrolling cancels only roots outside the preload range.
	pending:    int,
	bytes:      i64,
	ok:         bool,
	mutex:      sync.Mutex,
	seen:       map[u64]bool, // All entries are on the root device.
	aliases:    bool, // Repeated directories make child totals dependent on traversal order.
	children:   [dynamic]^Size_Child, // Arena-owned; updated under mutex.
	memory:     vmem.Arena, // Return visited-table pages to the OS when the scan ends.
}
Size_Task :: struct {
	scan:   ^Size_Scan,
	child:  ^Size_Child,
	fd:     linux.Fd, // Owned; -1 means open the root path.
	device: u64,
	bytes:  i64,
	ok:     bool,
}

size_start :: proc(workers := 0) -> ^Size_Service {
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC, .NONBLOCK}) != .NONE {return nil}
	event := sdl.RegisterEvents(1)
	if event == 0 {linux.close(fds[0]); linux.close(fds[1]); return nil}
	s := new(Size_Service)
	s.allocator, s.wake, s.event = context.allocator, fds, sdl.EventType(event)
	s.workers = max(1, workers > 0 ? workers : os.get_processor_core_count())
	s.worker = thread.create_and_start_with_poly_data(s, size_worker, name = "stuff-sizes")
	if s.worker == nil {
		linux.close(fds[0]); linux.close(fds[1]); free(s)
		return nil
	}
	return s
}

size_destroy :: proc(s: ^Size_Service) {
	if s == nil {return}
	sync.atomic_store(&s.stop, true)
	size_wake(s)
	thread.destroy(s.worker)
	for request in s.queue {delete(request.path)}
	delete(s.queue)
	delete(s.scans)
	for result in s.results {delete(result.path)}
	delete(s.results)
	linux.close(s.wake[0]); linux.close(s.wake[1])
	free(s)
}

size_wake :: proc(s: ^Size_Service) {
	wake_fd(s.wake[1])
}

size_cancel :: proc(b: ^Browser) {
	b.size_generation += 1
	if b.size_service == nil {return}
	sync.atomic_store(&b.size_service.generation, b.size_generation)
	sync.mutex_guard(&b.size_service.mutex)
	for request in b.size_service.queue {delete(request.path)}
	clear(&b.size_service.queue)
}

size_poll :: proc(b: ^Browser) -> bool {
	if b.size_service == nil {return false}
	sync.mutex_lock(&b.size_service.mutex)
	results := b.size_service.results
	b.size_service.results = nil
	sync.mutex_unlock(&b.size_service.mutex)
	defer delete(results)
	changed := false
	for result in results {
		defer delete(result.path)
		if result.generation != b.size_generation {continue}
		cached, exists := b.sizes[result.path]
		if result.derived {
			// Do not replace an explicit refresh or exceed the session cache budget.
			if exists && cached.request == b.size_generation {continue}
			if !exists && len(b.sizes) >= SIZE_CACHE_LIMIT {continue}
			cached.state, cached.bytes = .Known, result.bytes
			if !exists {
				cached.used = b.size_clock > 0 ? b.size_clock - 1 : 0
				b.sizes[strings.clone(result.path)] = cached
			} else {b.sizes[result.path] = cached}
			continue
		}
		if !exists {continue}
		cached.state, cached.bytes = result.ok ? .Known : .Failed, result.bytes
		cached.request = result.generation
		cached.refresh_after = sdl.GetTicks() + SIZE_REFRESH_MS
		b.sizes[result.path] = cached
		changed = true
	}
	if changed && b.sort_column == .Size {browser_sort(b)}
	return changed
}

// Preload a screen on each side, but draw only the visible rows. Scrolling
// retains overlapping scans and cancels roots outside the new preload range.
// Navigation refreshes totals. Tab changes reuse recent totals and matching
// active scans. Pointer movement alone does not refresh completed totals.
size_request_visible :: proc(b: ^Browser, rows: int) {
	if b.size_service == nil || b.path == "" || b.path == TRASH_PATH || rows <= 0 {return}
	if b.size_generation == 0 {size_cancel(b)}
	// Startup loads the folder before the service exists.
	sync.atomic_store(&b.size_service.generation, b.size_generation)
	b.size_clock += 1
	now := sdl.GetTicks()
	first := clamp(b.first, 0, max(0, len(b.visible) - 1))
	last := min(len(b.visible), first + rows + 1)
	before, after := max(0, first - rows), min(len(b.visible), last + rows)
	for i in before ..< after {
		entry := b.entries[b.visible[i]]
		if entry.type != .Directory {continue}
		cached, exists := b.sizes[entry.fullpath]
		cached.used = b.size_clock
		if exists {b.sizes[entry.fullpath] = cached} else {b.sizes[strings.clone(entry.fullpath)] = cached}
	}
	s := b.size_service
	sync.mutex_lock(&s.mutex)
	for scan in s.scans {
		if sync.atomic_load(&scan.cancel) {continue}
		cached, exists := b.sizes[scan.path]
		if scan.generation == b.size_generation && exists && cached.used == b.size_clock {
			// A slow refresh must not submit another copy of its active root.
			cached.request = b.size_generation
			cached.refresh_after = now + SIZE_REFRESH_MS
			b.sizes[scan.path] = cached
			continue
		}
		sync.atomic_store(&scan.cancel, true)
		if exists && cached.request == scan.generation {
			cached.request = 0
			b.sizes[scan.path] = cached
		}
	}
	// Replace only waiting requests, in viewport order. Active roots are not in
	// this list, so their request markers and cached totals remain unchanged.
	for request in s.queue {
		if cached, exists := b.sizes[request.path]; exists {
			cached.request = 0
			b.sizes[request.path] = cached
		}
		delete(request.path)
	}
	clear(&s.queue)
	ranges := [3][2]int{{first, last}, {last, after}, {before, first}}
	for bounds in ranges {
		for i in bounds[0] ..< bounds[1] {
			entry := b.entries[b.visible[i]]
			if entry.type != .Directory {continue}
			cached := b.sizes[entry.fullpath]
			if cached.request == b.size_generation {continue}
			cached.request = b.size_generation
			cached.refresh_after = now + SIZE_REFRESH_MS
			b.sizes[entry.fullpath] = cached
			append(
				&s.queue,
				Size_Request{path = strings.clone(entry.fullpath), generation = b.size_generation},
			)
		}
	}
	queued := len(s.queue) > 0
	sync.mutex_unlock(&s.mutex)
	if queued {size_wake(s)}
	size_cache_prune(b)
}

// Recheck old totals only when a tab becomes active. The request pass keeps
// matching scans, even if a slow scan still has an old cached value.
size_refresh_stale :: proc(b: ^Browser) {
	now := sdl.GetTicks()
	for _, &cached in b.sizes {
		if cached.state == .Pending || now < cached.refresh_after {continue}
		cached.request = 0
	}
}

// Bound session history without evicting the current preload range.
size_cache_prune :: proc(b: ^Browser) {
	for len(b.sizes) > SIZE_CACHE_LIMIT {
		oldest := ""
		used := b.size_clock
		for path, cached in b.sizes {
			if cached.used < used {oldest, used = path, cached.used}
		}
		if oldest == "" {break}
		delete_key(&b.sizes, oldest)
		delete(oldest)
	}
}

size_value :: proc(b: ^Browser, entry: os.File_Info) -> i64 {
	if entry.type == .Regular {return max(0, entry.size)}
	if entry.type == .Directory {
		if cached, ok := b.sizes[entry.fullpath];
		   ok && cached.state == .Known {return cached.bytes}
	}
	return -1
}

size_path_changed :: proc(path: string, changes: []string) -> bool {
	for change in changes {
		if path_contains(path, change) || path_contains(change, path) {return true}
	}
	return false
}

// Cancel only affected roots and remove their queued results under the same
// lock used by publication. Unrelated scans and request generations stay valid.
size_paths_changed :: proc(b: ^Browser, paths: []string) {
	if s := b.size_service; s != nil {
		sync.mutex_lock(&s.mutex)
		for scan in s.scans {
			if size_path_changed(scan.path, paths) {sync.atomic_store(&scan.cancel, true)}
		}
		#reverse for request, i in s.queue {
			if size_path_changed(request.path, paths) {
				delete(request.path)
				ordered_remove(&s.queue, i)
			}
		}
		#reverse for result, i in s.results {
			if size_path_changed(result.path, paths) {
				delete(result.path)
				ordered_remove(&s.results, i)
			}
		}
		sync.mutex_unlock(&s.mutex)
	}
	for path in paths {size_cache_invalidate(b, path)}
}

size_cache_invalidate :: proc(b: ^Browser, path: string, descendants := true) {
	if path == "" {return}
	for cached_path in b.sizes {
		if !path_contains(cached_path, path) &&
		   !(descendants && path_contains(path, cached_path)) {continue}
		delete_key(&b.sizes, cached_path)
		delete(cached_path)
	}
}

size_cache_clear :: proc(b: ^Browser) {
	size_cancel(b)
	for path in b.sizes {delete(path)}
	clear(&b.sizes)
}

size_cache_destroy :: proc(b: ^Browser) {
	for path in b.sizes {delete(path)}
	delete(b.sizes)
}

size_thread_init :: proc(_: ^thread.Thread, _: rawptr) {
	priority, err := linux.getpriority(.PROCESS, 0)
	if err == .NONE && priority < 10 {err = linux.setpriority(.PROCESS, 0, 10)}
	if err != .NONE {fmt.eprintfln("cannot lower size worker priority: %v", err)}
}

size_current :: proc(s: ^Size_Service, generation: u64) -> bool {
	return !sync.atomic_load(&s.stop) && sync.atomic_load(&s.generation) == generation
}

size_scan_current :: proc(scan: ^Size_Scan) -> bool {
	return !sync.atomic_load(&scan.cancel) && size_current(scan.service, scan.generation)
}

// Call with the service mutex held. This bounds waiting and completed task data.
size_has_room :: proc(s: ^Size_Service) -> bool {
	return thread.pool_num_waiting(&s.pool) + thread.pool_num_done(&s.pool) < 2 * s.workers
}

size_worker :: proc(s: ^Size_Service) {
	context.allocator = s.allocator
	thread.pool_init(&s.pool, s.allocator, s.workers, init_proc = size_thread_init)
	for t in s.pool.threads {t.name = "stuff-size-scan"}
	thread.pool_start(&s.pool)
	defer thread.pool_destroy(&s.pool)
	defer {
		// Canceled tasks still run so that each owned directory FD is closed.
		thread.pool_join(&s.pool)
		size_complete(s)
	}
	for {
		wake_drain(s.wake[0])
		size_complete(s)
		{
			sync.mutex_guard(&s.mutex)
			for !sync.atomic_load(&s.stop) && len(s.queue) > 0 && size_has_room(s) {
				request := s.queue[0]
				ordered_remove(&s.queue, 0)
				if !size_current(s, request.generation) {delete(request.path); continue}
				scan := new(Size_Scan)
				scan^ = {
					service = s,
					path = request.path,
					generation = request.generation,
					pending = 1,
					ok = true,
					memory = {minimum_block_size = 64 * mem.Kilobyte},
				}
				scan.seen.allocator = vmem.arena_allocator(&scan.memory)
				scan.children.allocator = vmem.arena_allocator(&scan.memory)
				append(&s.scans, scan)
				job := new(Size_Task)
				job.scan, job.fd = scan, -1
				thread.pool_add_task(&s.pool, s.allocator, size_task, job)
			}
		}
		outstanding := thread.pool_num_outstanding(&s.pool)
		if sync.atomic_load(&s.stop) && outstanding == 0 {return}
		if thread.pool_num_done(&s.pool) > 0 {continue}
		fds := [1]linux.Poll_Fd{{fd = s.wake[0], events = {.IN}}}
		// A task wakes us before the pool records its completion. The short
		// timeout covers that race while busy; idle waits have no timeout.
		timeout := poll_timeout(1)
		_, err := linux.ppoll(fds[:], outstanding > 0 ? &timeout : nil, nil)
		if err != .NONE && err != .EINTR {
			fmt.eprintfln("cannot wait for size work: %v", err)
			sync.atomic_store(&s.stop, true)
		}
	}
}

size_complete :: proc(s: ^Size_Service) {
	for task in thread.pool_pop_done(&s.pool) {
		job := cast(^Size_Task)task.data
		scan := job.scan
		scan.bytes += job.bytes
		scan.ok = scan.ok && job.ok
		free(job)
		sync.mutex_lock(&s.mutex)
		scan.pending -= 1
		finished := scan.pending == 0
		sync.mutex_unlock(&s.mutex)
		if !finished {continue}
		size_publish(scan)
		for child in scan.children {delete(child.path)}
		sync.mutex_lock(&s.mutex)
		s.children -= len(scan.children)
		sync.mutex_unlock(&s.mutex)
		vmem.arena_destroy(&scan.memory)
		free(scan)
	}
}

size_task :: proc(task: thread.Task) {
	job := cast(^Size_Task)task.data
	scan := job.scan
	if job.fd < 0 {
		job.bytes, job.ok = size_walk_root(scan)
	} else {
		job.bytes, job.ok = size_walk_dir(scan, job.fd, job.device, job.child)
		linux.close(job.fd)
	}
	size_child_add(scan, job.child, job.bytes, job.ok)
	size_wake(scan.service)
}

// A successful submission transfers the FD to the task. Otherwise scan locally.
size_split :: proc(scan: ^Size_Scan, fd: linux.Fd, device: u64, child: ^Size_Child) -> bool {
	s := scan.service
	sync.mutex_guard(&s.mutex)
	// Give visible roots priority over more tasks from a large folder.
	if !size_scan_current(scan) || len(s.queue) > 0 || !size_has_room(s) {return false}
	job := new(Size_Task)
	job.scan, job.fd, job.device, job.child = scan, fd, device, child
	scan.pending += 1
	thread.pool_add_task(&s.pool, s.allocator, size_task, job)
	return true
}

size_child_begin :: proc(scan: ^Size_Scan, name: string) -> ^Size_Child {
	s := scan.service
	sync.mutex_lock(&s.mutex)
	if s.children + len(s.results) >= SIZE_CACHE_LIMIT {
		sync.mutex_unlock(&s.mutex)
		return nil
	}
	s.children += 1
	sync.mutex_unlock(&s.mutex)
	sync.mutex_guard(&scan.mutex)
	child := new(Size_Child, vmem.arena_allocator(&scan.memory))
	child.path, child.ok = fmt.aprintf("%s/%s", strings.trim_suffix(scan.path, "/"), name), true
	append(&scan.children, child)
	return child
}

size_child_add :: proc(scan: ^Size_Scan, child: ^Size_Child, bytes: i64, ok: bool) {
	if child == nil {return}
	sync.mutex_guard(&scan.mutex)
	child.bytes += bytes
	child.ok = child.ok && ok
}

// Retire the completed scan and publish its owned results under one lock.
size_publish :: proc(scan: ^Size_Scan) {
	s := scan.service
	sync.mutex_lock(&s.mutex)
	for active, i in s.scans {
		if active == scan {unordered_remove(&s.scans, i); break}
	}
	if !size_scan_current(scan) {
		sync.mutex_unlock(&s.mutex)
		delete(scan.path)
		return
	}
	wake := len(s.results) == 0
	append(
		&s.results,
		Size_Result {
			path = scan.path,
			bytes = scan.bytes,
			generation = scan.generation,
			ok = scan.ok,
		},
	)
	children := scan.children[:]
	if scan.aliases {children = nil}
	for child in children {
		if !child.ok || len(s.results) >= SIZE_CACHE_LIMIT {continue}
		append(
			&s.results,
			Size_Result {
				path = child.path,
				bytes = child.bytes,
				generation = scan.generation,
				ok = true,
				derived = true,
			},
		)
		child.path = ""
	}
	sync.mutex_unlock(&s.mutex)
	if !wake {return}
	notify_ui(s.event, "size update")
}

size_walk_root :: proc(scan: ^Size_Scan) -> (i64, bool) {
	if !size_scan_current(scan) {return 0, false}
	path_c := strings.clone_to_cstring(scan.path)
	defer delete(path_c)
	fd, err := linux.open(path_c, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if err != .NONE {return 0, false}
	defer linux.close(fd)
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE {return 0, false}
	scan.seen[u64(st.ino)] = true
	return size_walk_dir(scan, fd, u64(st.dev), root = true)
}

size_walk_dir :: proc(
	scan: ^Size_Scan,
	fd: linux.Fd,
	device: u64,
	total: ^Size_Child = nil,
	root := false,
) -> (
	bytes: i64,
	ok: bool,
) {
	if !size_scan_current(scan) {return 0, false}
	buffer := make([]u8, 4096)
	defer delete(buffer)
	for {
		n, err := linux.getdents(fd, buffer)
		if err == .EINTR {continue}
		if err != .NONE {return 0, false}
		if n == 0 {return bytes, size_scan_current(scan)}
		offset := 0
		for entry in linux.dirent_iterate_buf(buffer[:n], &offset) {
			if !size_scan_current(scan) {return 0, false}
			name := linux.dirent_name(entry)
			if name == "." || name == ".." {continue}
			st: linux.Stat
			name_c := cstring(raw_data(name))
			if linux.fstatat(fd, name_c, &st, {.SYMLINK_NOFOLLOW}) != .NONE {return 0, false}
			if u64(st.dev) != device {continue}
			if linux.S_ISREG(st.mode) {bytes += i64(st.size); continue}
			if !linux.S_ISDIR(st.mode) {continue}
			child, open_err := linux.openat(fd, name_c, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
			if open_err != .NONE {return 0, false}
			if linux.fstat(child, &st) != .NONE {linux.close(child); return 0, false}
			if u64(st.dev) != device {linux.close(child); continue}
			id := u64(st.ino)
			sync.mutex_lock(&scan.mutex)
			visited := scan.seen[id]
			scan.aliases = scan.aliases || visited
			scan.seen[id] = true
			sync.mutex_unlock(&scan.mutex)
			if visited {linux.close(child); continue}
			subtotal := total
			if root {subtotal = size_child_begin(scan, name)}
			if size_split(scan, child, device, subtotal) {continue}
			child_bytes, complete := size_walk_dir(scan, child, device, subtotal)
			linux.close(child)
			if root {size_child_add(scan, subtotal, child_bytes, complete)}
			if !complete {return 0, false}
			bytes += child_bytes
		}
	}
}
