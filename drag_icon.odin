package main

import "core:math"
import linux "core:sys/linux"
import sdl "vendor:sdl3"

// The drag icon is a separate core Wayland surface, not another SDL window.
// Its pixels use the existing embedded Lucide icons and current theme color.
drag_shm_format :: proc "c" (data: rawptr, shm: ^WL_Object, format: u32) {}
drag_icon_surface_event :: proc "c" (data: rawptr, surface, output: ^WL_Object) {}
drag_icon_buffer_release :: proc "c" (data: rawptr, buffer: ^WL_Object) {}
DRAG_SHM_LISTENER := [1]rawptr{rawptr(drag_shm_format)}
DRAG_ICON_SURFACE_LISTENER := [2]rawptr {
	rawptr(drag_icon_surface_event),
	rawptr(drag_icon_surface_event),
}
DRAG_ICON_BUFFER_LISTENER := [1]rawptr{rawptr(drag_icon_buffer_release)}

drag_icon_create :: proc(d: ^File_Drag) {
	if d.compositor == nil || d.shm == nil {return}
	scale := max(1, i32(math.ceil(sdl.GetWindowPixelDensity(d.window))))
	size := 24 * scale
	length := size * size * 4
	fd, err := linux.memfd_create("stuff-drag-icon", {.CLOEXEC})
	if err != .NONE {return}
	defer linux.close(fd)
	if linux.ftruncate(fd, i64(length)) != .NONE {return}
	pixels, map_err := linux.mmap(0, uint(length), {.READ, .WRITE}, {.SHARED}, fd)
	if map_err != .NONE {return}
	defer linux.munmap(pixels, uint(length))
	target := sdl.CreateSurfaceFrom(size, size, .ARGB8888, pixels, size * 4)
	if target == nil {return}
	defer sdl.DestroySurface(target)
	icon := icon_surface(d.icon_kind, size)
	if icon == nil {return}
	defer sdl.DestroySurface(icon)
	sdl_check(
		sdl.SetSurfaceColorMod(icon, u8(theme.text[0]), u8(theme.text[1]), u8(theme.text[2])),
	)
	sdl_check(sdl.SetSurfaceBlendMode(icon, sdl.BLENDMODE_BLEND))
	sdl_check(sdl.BlitSurface(icon, nil, target, nil))
	pool := wl_proxy_marshal_flags(d.shm, 0, &wl_shm_pool_interface, 1, 0, rawptr(nil), fd, length)
	d.icon_buffer = wl_proxy_marshal_flags(
		pool,
		0,
		&wl_buffer_interface,
		1,
		0,
		rawptr(nil),
		i32(0),
		size,
		size,
		size * 4,
		u32(0),
	) // ARGB8888
	assert(wl_proxy_add_listener(d.icon_buffer, &DRAG_ICON_BUFFER_LISTENER, nil) == 0)
	wl_request_destroy(pool, 1)
	d.icon_surface = wl_proxy_marshal_flags(
		d.compositor,
		0,
		&wl_surface_interface,
		3,
		0,
		rawptr(nil),
	)
	assert(wl_proxy_add_listener(d.icon_surface, &DRAG_ICON_SURFACE_LISTENER, nil) == 0)
	_ = wl_proxy_marshal_flags(d.icon_surface, 8, nil, 3, 0, scale)
	_ = wl_proxy_marshal_flags(d.icon_surface, 1, nil, 3, 0, d.icon_buffer, i32(0), i32(0))
	_ = wl_proxy_marshal_flags(d.icon_surface, 2, nil, 3, 0, i32(0), i32(0), i32(24), i32(24))
}

drag_icon_destroy :: proc(d: ^File_Drag) {
	wl_request_destroy(d.icon_surface, 0)
	wl_request_destroy(d.icon_buffer, 0)
	d.icon_surface, d.icon_buffer = nil, nil
}
