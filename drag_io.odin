package main

import "core:sync"
import linux "core:sys/linux"
import "core:thread"

Drag_IO :: struct {
	fd:     linux.Fd,
	data:   string, // Borrowed from the source, which joins all writers before freeing it.
	cancel: bool, // Atomic. The worker owns the fd until it exits.
	worker: ^thread.Thread,
}

drag_io_start :: proc(jobs: ^[dynamic]^Drag_IO, fd: linux.Fd, payload: string) -> bool {
	flags, err := linux.fcntl_getfl(fd, .GETFL)
	if err == .NONE {err = linux.fcntl_setfl(fd, .SETFL, flags | {.NONBLOCK})}
	if err != .NONE {linux.close(fd); return false}
	job := new(Drag_IO)
	job.fd, job.data = fd, payload
	job.worker = thread.create_and_start_with_data(job, drag_io_worker, name = "stuff-drag-io")
	if job.worker == nil {linux.close(fd); free(job); return false}
	append(jobs, job)
	return true
}

drag_io_destroy :: proc(job: ^Drag_IO) {
	sync.atomic_store(&job.cancel, true)
	thread.destroy(job.worker)
	free(job)
}

drag_io_worker :: proc(data: rawptr) {
	job := cast(^Drag_IO)data
	defer linux.close(job.fd)
	// Only this short-lived worker blocks SIGPIPE from cancelled receivers.
	signals: linux.Sig_Set
	signals[0] = 1 << (u32(linux.Signal.SIGPIPE) - 1)
	if linux.rt_sigprocmask(.SIG_BLOCK, &signals, nil) != .NONE {return}
	offset := 0
	for !sync.atomic_load(&job.cancel) && offset < len(job.data) {
		n, err := linux.write(job.fd, transmute([]u8)job.data[offset:])
		if err == .NONE {offset += n; continue}
		if err == .EINTR {continue}
		if err != .EAGAIN {return}
		fds := [1]linux.Poll_Fd{{fd = job.fd, events = {.OUT}}}
		_, wait_err := linux.poll(fds[:], 100)
		if wait_err != .NONE && wait_err != .EINTR {return}
	}
}
