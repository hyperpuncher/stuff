package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import sdl "vendor:sdl3"

WATCH_BATCH_MS :: 100
WATCH_CHANGE_LIMIT :: 4096
WATCH_MASK :: linux.Inotify_Event_Mask {
	.MODIFY,
	.ATTRIB,
	.CLOSE_WRITE,
	.CREATE,
	.DELETE,
	.MOVED_FROM,
	.MOVED_TO,
	.DELETE_SELF,
	.MOVE_SELF,
	.ONLYDIR,
	.EXCL_UNLINK,
}

Watch_Directory :: struct {
	path:  string,
	trash: bool,
}
Watch_Result :: struct {
	changes:                           map[string]bool,
	entries:                           []os.File_Info,
	path:                              string,
	error:                             os.Error,
	version:                           u64,
	listing, overflow, trash, warning: bool,
}
// The mutex protects configuration, descriptors, and the latest pending result.
// Only the watcher worker reads events and directory listings.
Watch_Service :: struct {
	mutex:                                                   sync.Mutex,
	allocator:                                               mem.Allocator,
	worker:                                                  ^thread.Thread,
	fd:                                                      linux.Fd,
	wake:                                                    [2]linux.Fd,
	event:                                                   sdl.EventType,
	directories:                                             map[linux.Wd]Watch_Directory,
	paths:                                                   map[string]linux.Wd, // Keys borrow directories' owned paths.
	trash_roots:                                             map[string]bool,
	active:                                                  string,
	version:                                                 u64,
	configure, refresh, reset, trash, stop, warning, warned: bool,
	pending:                                                 ^Watch_Result,
}

watch_result_destroy :: proc(result: ^Watch_Result) {
	if result == nil {return}
	for path in result.changes {delete(path)}
	delete(result.changes)
	os.file_info_slice_delete(result.entries, context.allocator)
	delete(result.path)
	free(result)
}

watch_wake :: proc(w: ^Watch_Service) {
	wake_fd(w.wake[1])
}

watch_start :: proc() -> ^Watch_Service {
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE {return nil}
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.NONBLOCK, .CLOEXEC}) != .NONE {linux.close(fd); return nil}
	event := sdl.RegisterEvents(1)
	if event == 0 {linux.close(fd); linux.close(fds[0]); linux.close(fds[1]); return nil}
	w := new(Watch_Service)
	w.fd, w.wake, w.event, w.allocator = fd, fds, sdl.EventType(event), context.allocator
	w.worker = thread.create_and_start_with_poly_data(w, watch_worker, name = "stuff-watch")
	if w.worker == nil {
		linux.close(fd); linux.close(fds[0]); linux.close(fds[1]); free(w)
		return nil
	}
	return w
}

watch_destroy :: proc(w: ^Watch_Service) {
	if w == nil {return}
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.mutex_unlock(&w.mutex)
	watch_wake(w)
	thread.destroy(w.worker)
	for _, dir in w.directories {delete(dir.path)}
	delete(w.directories)
	delete(w.paths)
	for root in w.trash_roots {delete(root)}
	delete(w.trash_roots)
	delete(w.active)
	watch_result_destroy(w.pending)
	linux.close(w.fd); linux.close(w.wake[0]); linux.close(w.wake[1])
	free(w)
}

// Call with the watcher mutex held.
watch_needed :: proc(w: ^Watch_Service, path: string) -> bool {
	if w.active == "" {return false}
	return path == w.active || path == os.dir(w.active)
}

watch_forget :: proc(w: ^Watch_Service, wd: linux.Wd) {
	dir := w.directories[wd]
	_ = linux.inotify_rm_watch(w.fd, wd)
	delete_key(&w.paths, dir.path)
	delete_key(&w.directories, wd)
	delete(dir.path)
}

// Call with the watcher mutex held. delete_key is safe while iterating.
watch_forget_all :: proc(w: ^Watch_Service) {
	for wd in w.directories {watch_forget(w, wd)}
}

watch_add :: proc(w: ^Watch_Service, path: string, fd: linux.Fd, trash := false) -> bool {
	if wd, exists := w.paths[path]; exists {
		if trash {dir := w.directories[wd]; dir.trash = true; w.directories[wd] = dir}
		return true
	}
	buffer: [64]u8
	source := fmt.bprintf(buffer[:], "/proc/self/fd/%d", fd)
	wd, err := linux.inotify_add_watch(w.fd, cstring(raw_data(source)), WATCH_MASK)
	if err != .NONE {return false}
	if dir, exists := w.directories[wd]; exists {return dir.path == path}
	owned := strings.clone(path, w.allocator)
	w.directories[wd] = {
		path  = owned,
		trash = trash,
	}
	w.paths[owned] = wd
	return true
}

watch_path :: proc(w: ^Watch_Service, path: string, trash := false) -> bool {
	dir, err := directory_open(path)
	if err != nil {return false}
	defer os.close(dir)
	sync.mutex_guard(&w.mutex)
	if trash ? !w.trash : !watch_needed(w, path) {return false}
	if watch_add(w, path, linux.Fd(os.fd(dir)), trash) {return true}
	if !w.warned {w.warning, w.warned = true, true; watch_wake(w)}
	return false
}

watch_register :: proc(w: ^Watch_Service) {
	dirs: [2]string
	sync.mutex_lock(&w.mutex)
	for wd, dir in w.directories {
		if !watch_needed(w, dir.path) && !(w.trash && dir.trash) {watch_forget(w, wd)}
	}
	if w.active != "" {
		dirs[0] = strings.clone(w.active, context.temp_allocator)
		parent := os.dir(dirs[0])
		if parent != dirs[0] {dirs[1] = parent}
	}
	sync.mutex_unlock(&w.mutex)
	for path in dirs {if path != "" {_ = watch_path(w, path)}}
}

// Trash discovery and directory opens stay on the worker, not the UI thread.
watch_register_trash :: proc(w: ^Watch_Service) {
	home := trash_home_path()
	defer delete(home)
	mounts, err := mounts_read()
	if err != nil {return}
	defer mounts_destroy(mounts)
	roots := trash_roots(home, mounts[:])
	defer trash_roots_destroy(&roots)
	{
		sync.mutex_guard(&w.mutex)
		for root in w.trash_roots {delete(root)}
		clear(&w.trash_roots)
		for root in roots {
			if root.root != "" &&
			   !w.trash_roots[root.root] {w.trash_roots[strings.clone(root.root, w.allocator)] = true}
		}
	}
	for root in roots {
		parent, _ := os.split_path(root.root)
		parent = strings.trim_suffix(parent, "/")
		if root.local && !watch_path(w, root.top, trash = true) {continue}
		// Observe creation of home roots and shared .Trash/<uid> roots.
		for parent != "" {
			if watch_path(w, parent, trash = true) ||
			   parent == "/" ||
			   root.local && parent == root.top {break}
			ancestor, _ := os.split_path(parent)
			parent = strings.trim_suffix(ancestor, "/")
			if parent == "" {parent = "/"}
		}
		fd, open_err := trash_root_open(root.root, root.shared, root.local)
		if open_err != nil {continue}
		paths := [3]string {
			root.root,
			fmt.tprintf("%s/files", root.root),
			fmt.tprintf("%s/info", root.root),
		}
		for path in paths {_ = watch_path(w, path, trash = true)}
		linux.close(fd)
	}
}

watch_trash_changed :: proc(w: ^Watch_Service, dir: Watch_Directory, path: string) -> bool {
	if !w.trash || !dir.trash {return false}
	for root in w.trash_roots {
		if path_contains(root, dir.path) || path_contains(path, root) {return true}
	}
	return false
}

watch_overflow :: proc(batch: ^Watch_Result) {
	batch.overflow = true
	for path in batch.changes {delete(path)}
	delete(batch.changes)
	batch.changes = nil
}

// The caller stores an owned path only when this returns true.
watch_accept_change :: proc(batch: ^Watch_Result, path: string) -> bool {
	if batch.overflow || batch.changes[path] {return false}
	if len(batch.changes) >= WATCH_CHANGE_LIMIT {watch_overflow(batch); return false}
	return true
}

watch_read :: proc(w: ^Watch_Service, batch: ^Watch_Result) {
	// Kernel records and their name padding are aligned to four bytes.
	buffer: [2048]u64
	bytes := mem.slice_to_bytes(buffer[:])
	sync.mutex_guard(&w.mutex)
	for reads := 0; reads < 8; reads += 1 {
		n, err := linux.read(w.fd, bytes)
		if err == .EINTR {continue}
		if err != .NONE || n == 0 {break}
		for offset := 0; offset < n; {
			event := cast(^linux.Inotify_Event)raw_data(bytes[offset:])
			offset += size_of(linux.Inotify_Event) + int(event.len)
			if .Q_OVERFLOW in event.mask {
				watch_overflow(batch)
				batch.listing, batch.trash = true, w.trash
				watch_forget_all(w)
				w.configure = true
				continue
			}
			dir, exists := w.directories[event.wd]
			if !exists {continue}
			name := ""
			if event.len > 0 {name = string(cstring(raw_data(bytes[offset - int(event.len):])))}
			path :=
				name == "" ? dir.path : fmt.tprintf("%s/%s", strings.trim_suffix(dir.path, "/"), name)
			self := event.mask & {.IGNORED, .DELETE_SELF, .MOVE_SELF, .UNMOUNT} != {}
			trash := watch_trash_changed(w, dir, path)
			relevant := self || dir.path == w.active || path_contains(path, w.active) || trash
			if !relevant {continue}
			if watch_accept_change(batch, path) {batch.changes[strings.clone(path)] = true}
			batch.listing = batch.listing || dir.path == w.active || path_contains(path, w.active)
			batch.trash = batch.trash || trash
			if self {
				watch_forget(w, event.wd)
				w.configure = true
			} else if .ISDIR in event.mask &&
			   (w.trash || path == w.active) &&
			   event.mask & {.CREATE, .DELETE, .MOVED_FROM, .MOVED_TO} != {} {
				// Drop moved path mappings before registering replacement folders.
				if _, watched := w.paths[path]; watched {
					for wd, child in w.directories {
						if path_contains(path, child.path) {watch_forget(w, wd)}
					}
				}
				w.configure = true
			}
		}
	}
}

watch_publish :: proc(w: ^Watch_Service, batch: ^Watch_Result) {
	sync.mutex_lock(&w.mutex)
	wake := w.pending == nil
	old_entries: []os.File_Info
	old_path: string
	if wake {
		// Move the common case; merge only if an older result is still pending.
		w.pending = new(Watch_Result)
		w.pending^ = batch^
	} else {
		pending := w.pending
		if batch.overflow {watch_overflow(pending)}
		for path in batch.changes {
			if watch_accept_change(
				pending,
				path,
			) {pending.changes[path] = true} else {delete(path)}
		}
		delete(batch.changes)
		pending.trash = pending.trash || batch.trash
		pending.warning = pending.warning || batch.warning
		if batch.listing {
			old_entries, old_path = pending.entries, pending.path
			pending.entries, pending.path, pending.error, pending.version, pending.listing =
				batch.entries, batch.path, batch.error, batch.version, true
		}
	}
	sync.mutex_unlock(&w.mutex)
	os.file_info_slice_delete(old_entries, context.allocator)
	delete(old_path)
	batch^ = {}
	if wake {
		notify_ui(w.event, "folder update")
	}
}

watch_worker :: proc(w: ^Watch_Service) {
	context.allocator = w.allocator
	batch: Watch_Result
	defer {
		for path in batch.changes {delete(path)}
		delete(batch.changes)
	}
	due: u64
	for {
		sync.mutex_lock(&w.mutex)
		stop, configure, refresh, trash := w.stop, w.configure, w.refresh, w.trash
		if w.reset {
			watch_forget_all(w)
			watch_overflow(&batch)
			batch.listing, batch.trash = true, trash
			w.reset = false
			configure = true
		}
		w.configure, w.refresh = false, false
		warning := w.warning
		w.warning = false
		sync.mutex_unlock(&w.mutex)
		if stop {return}
		if configure {watch_register(w); if trash {watch_register_trash(w)}}
		if refresh && !trash {batch.listing = true}
		batch.warning = batch.warning || warning
		watch_read(w, &batch)
		if batch.listing ||
		   batch.overflow ||
		   batch.trash ||
		   batch.warning ||
		   len(batch.changes) > 0 {
			if due == 0 {due = sdl.GetTicks() + WATCH_BATCH_MS}
		}
		if due != 0 && sdl.GetTicks() >= due {
			if batch.listing {
				sync.mutex_lock(&w.mutex)
				batch.path, batch.version = strings.clone(w.active), w.version
				sync.mutex_unlock(&w.mutex)
				if batch.path != "" {
					dir, err := directory_open(batch.path)
					batch.error = err
					if err == nil {
						batch.entries, batch.error = os.read_all_directory(dir, context.allocator)
						os.close(dir)
					}
				}
			}
			watch_publish(w, &batch)
			due = 0
		}
		free_all(context.temp_allocator)
		fds := [2]linux.Poll_Fd{{fd = w.wake[0], events = {.IN}}, {fd = w.fd, events = {.IN}}}
		wait: linux.Time_Spec
		timeout: ^linux.Time_Spec
		if due != 0 {
			now := sdl.GetTicks()
			ms := due > now ? due - now : 0
			wait = {
				time_sec  = uint(ms / 1000),
				time_nsec = uint(ms % 1000) * 1_000_000,
			}
			timeout = &wait
		}
		_, err := linux.ppoll(fds[:], timeout, nil)
		if err == .EINTR {continue}
		if err != .NONE {return}
		if .IN in fds[0].revents {
			buffer: [128]u8
			for {n, read_err := linux.read(w.wake[0], buffer[:]); if read_err != .NONE || n == 0 {break}}
		}
	}
}
