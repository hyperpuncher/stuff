#+build linux
package main

import "core:c"
import linux "core:sys/linux"

// Public libwayland-client ABI and core protocol requests. SDL owns the display
// and window surface; this client owns only its registry, seat and data objects.
foreign import wayland_lib "system:wayland-client"
WL_Object :: struct {}
WL_Interface :: struct {
	name:                  cstring,
	version, method_count: c.int,
	methods:               rawptr,
	event_count:           c.int,
	events:                rawptr,
}

@(default_calling_convention = "c")
foreign wayland_lib {
	wl_registry_interface: WL_Interface
	wl_compositor_interface: WL_Interface
	wl_surface_interface: WL_Interface
	wl_shm_interface: WL_Interface
	wl_shm_pool_interface: WL_Interface
	wl_buffer_interface: WL_Interface
	wl_seat_interface: WL_Interface
	wl_pointer_interface: WL_Interface
	wl_data_device_manager_interface: WL_Interface
	wl_data_device_interface: WL_Interface
	wl_data_source_interface: WL_Interface
	wl_proxy_marshal_flags :: proc(object: ^WL_Object, opcode: u32, interface: ^WL_Interface, version, flags: u32, #c_vararg args: ..any) -> ^WL_Object ---
	wl_proxy_get_version :: proc(object: ^WL_Object) -> u32 ---
	wl_proxy_add_listener :: proc(object: ^WL_Object, listener, data: rawptr) -> c.int ---
	wl_proxy_destroy :: proc(object: ^WL_Object) ---
	wl_display_roundtrip :: proc(display: ^WL_Object) -> c.int ---
	wl_display_flush :: proc(display: ^WL_Object) -> c.int ---
	wl_display_create_queue :: proc(display: ^WL_Object) -> ^WL_Object ---
	wl_event_queue_destroy :: proc(queue: ^WL_Object) ---
	wl_proxy_set_queue :: proc(object, queue: ^WL_Object) ---
	wl_display_dispatch_queue_timeout :: proc(display, queue: ^WL_Object, timeout: ^linux.Time_Spec) -> c.int ---
}

wl_registry_new :: proc(display: ^WL_Object) -> ^WL_Object {
	return wl_proxy_marshal_flags(display, 1, &wl_registry_interface, 1, 0, rawptr(nil))
}

wl_bind :: proc(
	registry: ^WL_Object,
	name: u32,
	interface: ^WL_Interface,
	version: u32,
) -> ^WL_Object {
	return wl_proxy_marshal_flags(
		registry,
		0,
		interface,
		version,
		0,
		name,
		interface.name,
		version,
		rawptr(nil),
	)
}

wl_request_destroy :: proc(object: ^WL_Object, opcode: u32) {
	if object !=
	   nil {_ = wl_proxy_marshal_flags(object, opcode, nil, wl_proxy_get_version(object), 1)}
}

wl_source_new :: proc(manager: ^WL_Object) -> ^WL_Object {
	return wl_proxy_marshal_flags(manager, 0, &wl_data_source_interface, 3, 0, rawptr(nil))
}

wl_device_new :: proc(manager, seat: ^WL_Object) -> ^WL_Object {
	return wl_proxy_marshal_flags(manager, 1, &wl_data_device_interface, 3, 0, rawptr(nil), seat)
}
