package main

import "base:runtime"
import "core:fmt"
import "core:mem"
import sdl "vendor:sdl3"

Drag_Offer :: struct {
	object:  ^WL_Object,
	dropped: bool,
}

File_Drag :: struct {
	window:                                                     ^sdl.Window,
	allocator:                                                  mem.Allocator,
	event:                                                      sdl.EventType,
	display, surface, registry, manager, seat, pointer, device: ^WL_Object,
	compositor, shm, icon_surface, icon_buffer:                 ^WL_Object,
	source:                                                     ^Drag_Source,
	icon_kind:                                                  Icon,
	seat_name, serial:                                          u32,
	focused, pressed, armed, collapse, toggle, receiving:       bool,
	press_x, press_y:                                           f32,
	paths, drop_paths:                                          [dynamic]string,
	clicked, target, drop_target:                               string,
	target_id:                                                  u32,
	invalid_drop:                                               bool,
	current:                                                    ^Drag_Offer,
	offers:                                                     [dynamic]^Drag_Offer,
}

drag_ctx :: proc "contextless" (data: rawptr) -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = (cast(^File_Drag)data).allocator
	return ctx
}

drag_offer_destroy :: proc(d: ^File_Drag, offer: ^Drag_Offer) {
	if offer == nil {return}
	if d.current == offer {d.current = nil}
	wl_request_destroy(offer.object, 2)
	for existing, i in d.offers {if existing == offer {unordered_remove(&d.offers, i); break}}
	free(offer)
}

drag_offer_find :: proc(d: ^File_Drag, object: ^WL_Object) -> ^Drag_Offer {
	for offer in d.offers {if offer.object == object {return offer}}
	return nil
}

// start_drag requires a data device. It also gets incoming offers, but only
// SDL negotiates and reads them. Keep dropped offers until SDL has finished.
drag_offer_mime :: proc "c" (data: rawptr, object: ^WL_Object, mime: cstring) {}
drag_offer_actions :: proc "c" (data: rawptr, object: ^WL_Object, actions: u32) {}
DRAG_OFFER_LISTENER := [3]rawptr {
	rawptr(drag_offer_mime),
	rawptr(drag_offer_actions),
	rawptr(drag_offer_actions),
}

drag_offer_new :: proc "c" (data: rawptr, device, object: ^WL_Object) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	offer := new(Drag_Offer)
	offer.object = object
	append(&d.offers, offer)
	assert(wl_proxy_add_listener(object, &DRAG_OFFER_LISTENER, nil) == 0)
}

drag_enter :: proc "c" (
	data: rawptr,
	device: ^WL_Object,
	serial: u32,
	surface: ^WL_Object,
	x, y: i32,
	object: ^WL_Object,
) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	if surface == d.surface {d.current = drag_offer_find(d, object)}
}

drag_leave :: proc "c" (data: rawptr, device: ^WL_Object) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	if d.current != nil && !d.current.dropped {drag_offer_destroy(d, d.current)}
	d.current = nil
}

drag_motion :: proc "c" (data: rawptr, device: ^WL_Object, time: u32, x, y: i32) {}
drag_drop :: proc "c" (data: rawptr, device: ^WL_Object) {
	d := cast(^File_Drag)data
	if d.current != nil {d.current.dropped = true}
}

drag_selection :: proc "c" (data: rawptr, device, object: ^WL_Object) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	drag_offer_destroy(d, drag_offer_find(d, object)) // SDL keeps its own clipboard offer.
}
DRAG_DEVICE_LISTENER := [6]rawptr {
	rawptr(drag_offer_new),
	rawptr(drag_enter),
	rawptr(drag_leave),
	rawptr(drag_motion),
	rawptr(drag_drop),
	rawptr(drag_selection),
}

drag_pointer_enter :: proc "c" (
	data: rawptr,
	pointer: ^WL_Object,
	serial: u32,
	surface: ^WL_Object,
	x, y: i32,
) {(cast(^File_Drag)data).focused = surface == (cast(^File_Drag)data).surface}
drag_pointer_leave :: proc "c" (
	data: rawptr,
	pointer: ^WL_Object,
	serial: u32,
	surface: ^WL_Object,
) {(cast(^File_Drag)data).focused = false}
drag_pointer_motion :: proc "c" (data: rawptr, pointer: ^WL_Object, time: u32, x, y: i32) {}
drag_pointer_button :: proc "c" (
	data: rawptr,
	pointer: ^WL_Object,
	serial, time, button, state: u32,
) {
	d := cast(^File_Drag)data
	if button == 0x110 {d.pressed = state == 1 && d.focused; if d.pressed {d.serial = serial}}
}
drag_pointer_axis :: proc "c" (data: rawptr, pointer: ^WL_Object, time, axis: u32, value: i32) {}
drag_pointer_frame :: proc "c" (data: rawptr, pointer: ^WL_Object) {}
drag_pointer_axis_source :: proc "c" (data: rawptr, pointer: ^WL_Object, source: u32) {}
drag_pointer_axis_stop :: proc "c" (data: rawptr, pointer: ^WL_Object, time, axis: u32) {}
drag_pointer_axis_discrete :: proc "c" (
	data: rawptr,
	pointer: ^WL_Object,
	axis: u32,
	discrete: i32,
) {}
DRAG_POINTER_LISTENER := [9]rawptr {
	rawptr(drag_pointer_enter),
	rawptr(drag_pointer_leave),
	rawptr(drag_pointer_motion),
	rawptr(drag_pointer_button),
	rawptr(drag_pointer_axis),
	rawptr(drag_pointer_frame),
	rawptr(drag_pointer_axis_source),
	rawptr(drag_pointer_axis_stop),
	rawptr(drag_pointer_axis_discrete),
}

drag_seat_capabilities :: proc "c" (data: rawptr, seat: ^WL_Object, capabilities: u32) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	if capabilities & 1 != 0 && d.pointer == nil {
		d.pointer = wl_proxy_marshal_flags(seat, 0, &wl_pointer_interface, 5, 0, rawptr(nil))
		assert(wl_proxy_add_listener(d.pointer, &DRAG_POINTER_LISTENER, d) == 0)
	} else if capabilities & 1 == 0 {
		wl_request_destroy(d.pointer, 1)
		d.pointer, d.pressed = nil, false
	}
}
drag_seat_name :: proc "c" (data: rawptr, seat: ^WL_Object, name: cstring) {}
DRAG_SEAT_LISTENER := [2]rawptr{rawptr(drag_seat_capabilities), rawptr(drag_seat_name)}

drag_registry_global :: proc "c" (
	data: rawptr,
	registry: ^WL_Object,
	name: u32,
	interface: cstring,
	version: u32,
) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	if string(interface) == "wl_compositor" &&
	   version >= 3 &&
	   d.compositor == nil {d.compositor = wl_bind(registry, name, &wl_compositor_interface, 3)}
	if string(interface) == "wl_shm" &&
	   d.shm ==
		   nil {d.shm = wl_bind(registry, name, &wl_shm_interface, 1); assert(wl_proxy_add_listener(d.shm, &DRAG_SHM_LISTENER, nil) == 0)}
	if string(interface) == "wl_data_device_manager" &&
	   version >= 3 &&
	   d.manager == nil {d.manager = wl_bind(registry, name, &wl_data_device_manager_interface, 3)}
	if string(interface) == "wl_seat" && version >= 5 && d.seat == nil {
		d.seat_name, d.seat = name, wl_bind(registry, name, &wl_seat_interface, 5)
		assert(wl_proxy_add_listener(d.seat, &DRAG_SEAT_LISTENER, d) == 0)
	}
	if d.manager != nil && d.seat != nil && d.device == nil {
		d.device = wl_device_new(d.manager, d.seat)
		assert(wl_proxy_add_listener(d.device, &DRAG_DEVICE_LISTENER, d) == 0)
	}
}

drag_registry_remove :: proc "c" (data: rawptr, registry: ^WL_Object, name: u32) {
	context = drag_ctx(data)
	d := cast(^File_Drag)data
	if name != d.seat_name {return}
	wl_request_destroy(d.pointer, 1)
	wl_request_destroy(d.device, 2)
	wl_request_destroy(d.seat, 3)
	d.pointer, d.device, d.seat, d.pressed = nil, nil, nil, false
	drag_source_destroy(d.source)
	d.source = nil
	drag_icon_destroy(d)
	file_drag_disarm(d)
}
DRAG_REGISTRY_LISTENER := [2]rawptr{rawptr(drag_registry_global), rawptr(drag_registry_remove)}

file_drag_init :: proc(window: ^sdl.Window) -> ^File_Drag {
	properties := sdl.GetWindowProperties(window)
	display := cast(^WL_Object)sdl.GetPointerProperty(
		properties,
		sdl.PROP_WINDOW_WAYLAND_DISPLAY_POINTER,
		nil,
	)
	surface := cast(^WL_Object)sdl.GetPointerProperty(
		properties,
		sdl.PROP_WINDOW_WAYLAND_SURFACE_POINTER,
		nil,
	)
	if display == nil || surface == nil {return nil}
	event := sdl.RegisterEvents(1)
	if event == 0 {return nil}
	d := new(File_Drag)
	d.window, d.allocator, d.event = window, context.allocator, sdl.EventType(event)
	d.display, d.surface = display, surface
	d.registry = wl_registry_new(display)
	assert(wl_proxy_add_listener(d.registry, &DRAG_REGISTRY_LISTENER, d) == 0)
	if wl_display_roundtrip(display) < 0 || wl_display_roundtrip(display) < 0 || d.device == nil {
		fmt.eprintln("native file dragging is unavailable")
		file_drag_destroy(d)
		return nil
	}
	// SDL remains the only receiver and negotiates copy-only drops.
	return d
}

file_drag_destroy :: proc(d: ^File_Drag) {
	if d == nil {return}
	drag_source_destroy(d.source)
	for offer in d.offers {wl_request_destroy(offer.object, 2); free(offer)}
	delete(d.offers)
	drag_icon_destroy(d)
	file_drag_disarm(d)
	file_paths_destroy(d.drop_paths)
	delete(d.drop_target)
	delete(d.target)
	wl_request_destroy(d.pointer, 1)
	wl_request_destroy(d.device, 2)
	wl_request_destroy(d.seat, 3)
	if d.manager != nil {wl_proxy_destroy(d.manager)}
	if d.compositor != nil {wl_proxy_destroy(d.compositor)}
	if d.shm != nil {wl_proxy_destroy(d.shm)}
	if d.registry != nil {wl_proxy_destroy(d.registry)}
	_ = wl_display_flush(d.display)
	free(d)
}
