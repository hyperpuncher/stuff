package main

import "base:runtime"
import "core:mem"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import sdl "vendor:sdl3"

// Only source callbacks run on this queue. SDL can read a drop synchronously
// on the UI thread while this worker answers the source's send request.
Drag_Source :: struct {
	display, object, queue: ^WL_Object,
	payload:                string,
	allocator:              mem.Allocator,
	event:                  sdl.EventType,
	worker:                 ^thread.Thread,
	jobs:                   [dynamic]^Drag_IO,
	stop, done:             bool, // Atomic. Main joins before freeing the snapshot.
}

drag_source_target :: proc "c" (data: rawptr, source: ^WL_Object, mime: cstring) {}
drag_source_action :: proc "c" (data: rawptr, source: ^WL_Object, action: u32) {}
drag_source_performed :: proc "c" (data: rawptr, source: ^WL_Object) {}
drag_source_done :: proc "c" (data: rawptr, source: ^WL_Object) {
	state := cast(^Drag_Source)data
	sync.atomic_store(&state.stop, true)
}

drag_source_send :: proc "c" (data: rawptr, object: ^WL_Object, mime: cstring, fd: i32) {
	source := cast(^Drag_Source)data
	context = runtime.default_context()
	context.allocator = source.allocator
	if string(mime) != FILE_URI_MIME {linux.close(linux.Fd(fd)); return}
	_ = drag_io_start(&source.jobs, linux.Fd(fd), source.payload)
}
DRAG_SOURCE_LISTENER := [6]rawptr {
	rawptr(drag_source_target),
	rawptr(drag_source_send),
	rawptr(drag_source_done),
	rawptr(drag_source_performed),
	rawptr(drag_source_done),
	rawptr(drag_source_action),
}

drag_source_begin :: proc(d: ^File_Drag) -> ^Drag_Source {
	source := new(Drag_Source)
	source.display, source.allocator, source.event = d.display, d.allocator, d.event
	source.payload = file_uri_list(d.paths[:])
	source.queue = wl_display_create_queue(d.display)
	source.object = wl_source_new(d.manager)
	wl_proxy_set_queue(source.object, source.queue)
	assert(wl_proxy_add_listener(source.object, &DRAG_SOURCE_LISTENER, source) == 0)
	_ = wl_proxy_marshal_flags(source.object, 0, nil, 3, 0, cstring(FILE_URI_MIME))
	_ = wl_proxy_marshal_flags(source.object, 2, nil, 3, 0, u32(1)) // Copy only.
	drag_icon_create(d)
	_ = wl_proxy_marshal_flags(
		d.device,
		0,
		nil,
		3,
		0,
		source.object,
		d.surface,
		d.icon_surface,
		d.serial,
	)
	if d.icon_surface != nil {_ = wl_proxy_marshal_flags(d.icon_surface, 6, nil, 3, 0)}
	_ = wl_display_flush(d.display)
	source.worker = thread.create_and_start_with_data(
		source,
		drag_source_worker,
		name = "stuff-drag",
	)
	if source.worker == nil {
		wl_request_destroy(source.object, 1)
		wl_event_queue_destroy(source.queue)
		delete(source.payload)
		free(source)
		drag_icon_destroy(d)
		return nil
	}
	return source
}

drag_source_worker :: proc(data: rawptr) {
	source := cast(^Drag_Source)data
	context.allocator = source.allocator
	defer {
		for job in source.jobs {drag_io_destroy(job)}
		delete(source.jobs)
		wl_request_destroy(source.object, 1)
		wl_event_queue_destroy(source.queue)
		_ = wl_display_flush(source.display)
		sync.atomic_store(&source.done, true)
		event := sdl.Event {
			type = source.event,
		}
		_ = sdl.PushEvent(&event)
	}
	for !sync.atomic_load(&source.stop) {
		timeout := linux.Time_Spec {
			time_nsec = 100_000_000,
		}
		if wl_display_dispatch_queue_timeout(source.display, source.queue, &timeout) < 0 {return}
	}
}

drag_source_destroy :: proc(source: ^Drag_Source) {
	if source == nil {return}
	sync.atomic_store(&source.stop, true)
	thread.destroy(source.worker)
	delete(source.payload)
	free(source)
}
