package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import sdl "vendor:sdl3"

Storage_Result :: struct {
	kind:        enum {
		Disks,
		Space,
		Operation,
		Files,
		Progress,
		Watch_Reset,
	},
	disks:       [dynamic]Disk,
	path, error: string,
	space:       Space_Info,
	op:          ^Disk_Operation,
	files:       ^File_Operation, // Borrowed for Progress; owned for Files.
	progress:    File_Progress,
}

// Requests and results are owned. The mutex protects only shared queue/state
// handoffs. All filesystem, udev, and D-Bus work runs without this lock.
Storage :: struct {
	mutex:                                   sync.Mutex,
	allocator:                               mem.Allocator,
	worker:                                  ^thread.Thread,
	wake:                                    [2]linux.Fd,
	event:                                   sdl.EventType,
	path:                                    string,
	visible, stop, refresh, space_requested: bool,
	op:                                      ^Disk_Operation,
	results:                                 [dynamic]Storage_Result,
}

storage_result_destroy :: proc(result: Storage_Result) {
	disks_destroy(result.disks)
	delete(result.path)
	delete(result.error)
	disk_operation_destroy(result.op)
	if result.kind == .Files {file_operation_destroy(result.files)}
}

storage_wake :: proc(s: ^Storage) {
	wake_fd(s.wake[1])
}

storage_publish :: proc(s: ^Storage, result: Storage_Result) {
	sync.mutex_lock(&s.mutex)
	// Keep at most one pending snapshot per job, even if the UI is busy.
	if result.kind == .Progress {
		for &pending in s.results {
			if pending.kind == .Progress && pending.files == result.files {
				pending.progress = result.progress
				sync.mutex_unlock(&s.mutex)
				return
			}
		}
	}
	wake := len(s.results) == 0
	append(&s.results, result)
	sync.mutex_unlock(&s.mutex)
	if !wake {return}
	notify_ui(s.event, "storage update")
}

storage_start :: proc(path: string) -> ^Storage {
	fds: [2]linux.Fd
	if linux.pipe2(&fds, {.CLOEXEC, .NONBLOCK}) != .NONE {return nil}
	event := sdl.RegisterEvents(1)
	if event == 0 {linux.close(fds[0]); linux.close(fds[1]); return nil}
	assert(dbus_threads_init_default() != 0)
	s := new(Storage)
	s.allocator = context.allocator
	s.wake = fds
	s.event = sdl.EventType(event)
	s.path = strings.clone(path)
	s.visible, s.refresh, s.space_requested = true, true, true
	s.worker = thread.create_and_start_with_data(s, storage_worker, name = "stuff-storage")
	if s.worker == nil {
		linux.close(fds[0]); linux.close(fds[1]); delete(s.path); free(s)
		return nil
	}
	return s
}

storage_path :: proc(s: ^Storage, path: string) {
	if s == nil {return}
	sync.mutex_lock(&s.mutex)
	changed := s.path != path
	if changed {replace_owned(&s.path, path); s.space_requested = true}
	sync.mutex_unlock(&s.mutex)
	if changed {storage_wake(s)}
}

storage_visible :: proc(s: ^Storage, visible: bool) {
	if s == nil {return}
	sync.mutex_lock(&s.mutex)
	changed := s.visible != visible
	if changed {s.visible = visible; s.space_requested = visible}
	sync.mutex_unlock(&s.mutex)
	if changed {storage_wake(s)}
}

storage_refresh :: proc(s: ^Storage) {
	if s == nil {return}
	sync.mutex_lock(&s.mutex)
	s.refresh, s.space_requested = true, true
	sync.mutex_unlock(&s.mutex)
	storage_wake(s)
}

storage_submit :: proc(s: ^Storage, op: ^Disk_Operation) {
	sync.mutex_lock(&s.mutex)
	assert(s.op == nil)
	s.op = op
	sync.mutex_unlock(&s.mutex)
	storage_wake(s)
}

storage_take :: proc(s: ^Storage) -> [dynamic]Storage_Result {
	sync.mutex_guard(&s.mutex)
	results := s.results
	s.results = nil
	return results
}

storage_destroy :: proc(s: ^Storage) {
	if s == nil {return}
	sync.mutex_lock(&s.mutex)
	s.stop = true
	sync.mutex_unlock(&s.mutex)
	storage_wake(s)
	thread.destroy(s.worker)
	for result in s.results {storage_result_destroy(result)}
	delete(s.results)
	disk_operation_destroy(s.op)
	delete(s.path)
	linux.close(s.wake[0]); linux.close(s.wake[1])
	free(s)
}

storage_worker :: proc(data: rawptr) {
	s := cast(^Storage)data
	context.allocator = s.allocator
	udev := udev_new()
	if udev ==
	   nil {storage_publish(s, {kind = .Disks, error = strings.clone("cannot read disk information")}); return}
	defer udev_unref(udev)
	monitor := udev_monitor_new_from_netlink(udev, "udev")
	monitor_fd := linux.Fd(-1)
	defer if monitor != nil {udev_monitor_unref(monitor)}
	if monitor != nil {
		if udev_monitor_filter_add_match_subsystem_devtype(monitor, "block", nil) >= 0 &&
		   udev_monitor_enable_receiving(monitor) >=
			   0 {monitor_fd = linux.Fd(udev_monitor_get_fd(monitor))}
	}
	mounts_fd, mounts_err := linux.open("/proc/self/mounts", {.CLOEXEC})
	if mounts_err != .NONE {mounts_fd = -1}
	defer if mounts_fd >= 0 {linux.close(mounts_fd)}
	if monitor_fd < 0 || mounts_fd < 0 {fmt.eprintln("disk change notifications are unavailable")}

	disks: [dynamic]Disk
	defer disks_destroy(disks)
	call: Disk_Call
	defer {disk_operation_destroy(call.op); disk_call_destroy(&call)}
	reported_path: string
	defer delete(reported_path)
	last_space: Space_Info
	space_due: u64
	need_disks, need_space := true, true
	for {
		sync.mutex_lock(&s.mutex)
		stop, visible := s.stop, s.visible
		path := strings.clone(s.path, context.temp_allocator)
		need_disks = need_disks || s.refresh
		need_space = need_space || s.space_requested
		s.refresh, s.space_requested = false, false
		op := s.op
		s.op = nil
		sync.mutex_unlock(&s.mutex)
		if stop {disk_operation_destroy(op); return}
		if op != nil {assert(call.op == nil); disk_call_start(&call, op)}
		disks_changed := false
		if need_disks {
			next, error := disks_read(udev)
			if error == "" {
				disks_destroy(disks)
				disks = next
				disks_changed = true
			} else {storage_publish(s, {kind = .Disks, error = strings.clone(error)})}
			need_disks = false
		}
		if visible && (need_space || sdl.GetTicks() >= space_due) {
			space := space_query(path)
			if path != reported_path || space != last_space {
				storage_publish(s, {kind = .Space, path = strings.clone(path), space = space})
				replace_owned(&reported_path, path)
				last_space = space
			}
			for &disk in disks {
				disk_space := space
				if disk.path !=
				   path {disk_space = disk.path != "" ? space_query(disk.path) : Space_Info{}}
				if disk_space != disk.space {disk.space = disk_space; disks_changed = true}
			}
			space_due = sdl.GetTicks() + 5000
			need_space = false
		}
		if disks_changed {
			copy: [dynamic]Disk
			for disk in disks {
				append(
					&copy,
					Disk {
						device = strings.clone(disk.device),
						label = strings.clone(disk.label),
						path = strings.clone(disk.path),
						space = disk.space,
					},
				)
			}
			storage_publish(s, {kind = .Disks, disks = copy})
		}
		if disk_call_poll(&call) {
			storage_publish(s, {kind = .Operation, op = call.op})
			call.op = nil
			disk_call_destroy(&call)
			need_disks, need_space = true, true
			continue
		}
		free_all(context.temp_allocator)
		fds := [4]linux.Poll_Fd {
			{fd = s.wake[0], events = {.IN}},
			{fd = monitor_fd, events = {.IN}},
			{fd = mounts_fd, events = {.PRI}},
			{fd = -1, events = {.IN}},
		}
		if call.bus != nil {
			fd: c.int
			if dbus_connection_get_unix_fd(call.bus, &fd) != 0 {fds[3].fd = linux.Fd(fd)}
		}
		deadline := visible ? space_due : max(u64)
		if call.op != nil {deadline = min(deadline, call.deadline)}
		wait: linux.Time_Spec
		timeout: ^linux.Time_Spec
		if deadline != max(u64) {
			now := sdl.GetTicks()
			wait = poll_timeout(deadline > now ? deadline - now : 0)
			timeout = &wait
		}
		_, err := linux.ppoll(fds[:], timeout, nil)
		if err == .EINTR {continue}
		if err != .NONE {fmt.eprintfln("cannot wait for disk changes: %v", err); return}
		if .IN in fds[0].revents {wake_drain(s.wake[0])}
		if .IN in fds[1].revents || .ERR in fds[1].revents {
			for {device := udev_monitor_receive_device(monitor); if device == nil {break}; udev_device_unref(device)}
			need_disks, need_space = true, true
		}
		if .PRI in fds[2].revents {
			need_disks, need_space = true, true
			storage_publish(s, {kind = .Watch_Reset})
		}
	}
}
