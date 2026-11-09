package main

import "core:mem"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import sdl "vendor:sdl3"

Drag_IO :: struct {
	fd:           linux.Fd,
	data:         string, // Owned snapshot, independent of the drag source lifetime.
	error:        linux.Errno,
	cancel, done: bool, // Atomic. Other results belong to the worker until done.
	allocator:    mem.Allocator,
	event:        sdl.EventType,
	worker:       ^thread.Thread,
}

drag_io_start :: proc(
	jobs: ^[dynamic]^Drag_IO,
	allocator: mem.Allocator,
	event: sdl.EventType,
	fd: linux.Fd,
	payload: string,
) -> bool {
	flags, err := linux.fcntl_getfl(fd, .GETFL)
	if err == .NONE {err = linux.fcntl_setfl(fd, .SETFL, flags | {.NONBLOCK})}
	if err != .NONE {linux.close(fd); return false}
	job := new(Drag_IO)
	job.fd, job.data = fd, strings.clone(payload)
	job.allocator, job.event = allocator, event
	job.worker = thread.create_and_start_with_data(job, drag_io_worker, name = "stuff-drag-io")
	if job.worker == nil {linux.close(fd); delete(job.data); free(job); return false}
	append(jobs, job)
	return true
}

drag_io_destroy :: proc(job: ^Drag_IO) {
	sync.atomic_store(&job.cancel, true)
	thread.destroy(job.worker)
	delete(job.data)
	free(job)
}

drag_io_worker :: proc(data: rawptr) {
	job := cast(^Drag_IO)data
	context.allocator = job.allocator
	defer {
		linux.close(job.fd)
		sync.atomic_store(&job.done, true)
		event := sdl.Event {
			type = job.event,
		}
		_ = sdl.PushEvent(&event)
	}
	// Only this short-lived worker blocks SIGPIPE from cancelled receivers.
	signals: linux.Sig_Set
	signals[0] = 1 << (u32(linux.Signal.SIGPIPE) - 1)
	job.error = linux.rt_sigprocmask(.SIG_BLOCK, &signals, nil)
	if job.error != .NONE {return}
	offset := 0
	for !sync.atomic_load(&job.cancel) {
		if offset == len(job.data) {return}
		n: int
		n, job.error = linux.write(job.fd, transmute([]u8)job.data[offset:])
		if job.error == .NONE {offset += n; continue}
		if job.error == .EINTR {continue}
		if job.error != .EAGAIN {return}
		fds := [1]linux.Poll_Fd{{fd = job.fd, events = {.OUT}}}
		_, wait_err := linux.poll(fds[:], 100)
		if wait_err != .NONE && wait_err != .EINTR {job.error = wait_err; return}
	}
	job.error = .ECANCELED
}
