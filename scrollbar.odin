package main

import "core:math"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Auto_Scroll :: struct {
	active, places:  bool,
	x, y:            f32,
	rate, remainder: f64,
	tick, pressed:   u64,
	folder:          int, // Entry index plus one; zero means no short-click target.
}

autoscroll_begin :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	places := x < g.sidebar
	view := places ? places_geometry(g) : g
	if b.header.edit.active ||
	   b.menu.active ||
	   x < 0 ||
	   x >= g.width ||
	   y < view.list_top ||
	   y >= list_bottom(view) {return false}
	file_drag_cancel_press(b)
	b.drag = {}
	b.places.focused = places
	b.pointer.active = false
	b.hovered = 0
	b.autoscroll = {
		active = true,
		places = places,
		x      = x,
		y      = y,
		tick   = sdl.GetTicks(),
	}
	b.autoscroll.pressed = b.autoscroll.tick
	b.autoscroll.active = scrollbar_for(b, g, places).max_first > 0
	if !places && b.path != TRASH_PATH {
		if row := row_at(g, y, b.first, len(b.visible)); row >= 0 {
			source := b.visible[row]
			if entry_is_directory(b.entries[source]) {b.autoscroll.folder = source + 1}
		}
	}
	return b.autoscroll.active || b.autoscroll.folder > 0
}

autoscroll_motion :: proc(b: ^Browser, g: Geometry, x, y: f32) {
	a := &b.autoscroll
	if max(abs(x - a.x), abs(y - a.y)) >= 6 * g.scale {a.folder = 0}
	delta := (y - a.y) / g.scale
	distance := max(abs(delta) - 12, 0)
	rate := f64(min(distance * distance / 800, 120))
	if delta < 0 {rate = -rate}
	if rate == 0 || (rate < 0) != (a.rate < 0) {a.remainder = 0}
	a.rate = rate
}

autoscroll_update :: proc(b: ^Browser, g: Geometry, now: u64) -> bool {
	a := &b.autoscroll
	if !a.active {return false}
	last := scrollbar_for(b, g, a.places).max_first
	if last <= 0 {a^ = {}; return true}
	first := a.places ? &b.places.first : &b.first
	if a.rate < 0 && first^ <= 0 || a.rate > 0 && first^ >= last {
		a.rate, a.remainder = 0, 0
	}
	// Use elapsed time, but do not jump after a stalled frame.
	a.remainder += a.rate * f64(min(now - a.tick, 100)) / 1000
	a.tick = now
	rows := int(a.remainder)
	a.remainder -= f64(rows)
	previous := first^
	first^ = clamp(first^ + rows, 0, last)
	return first^ != previous
}

Scroll_Drag :: struct {
	active, places: bool,
	grab:           f32,
}

Scrollbar :: struct {
	track, thumb: clay.BoundingBox,
	max_first:    int,
}

scrollbar_id :: proc(places: bool) -> clay.ElementId {return clay.ID("scrollbar", places ? 1 : 0)}

scrollbar_geometry :: proc(g: Geometry, count, first: int, places: bool) -> Scrollbar {
	view, right := g, g.width
	if places {view, right = places_geometry(g), g.sidebar}
	height := list_bottom(view) - view.list_top
	if count <= view.rows || height <= 0 {return {}}
	thumb_height := min(height, max(24 * g.scale, height * height / (f32(count) * g.row)))
	last := count - view.rows
	top := view.list_top + f32(clamp(first, 0, last)) / f32(last) * (height - thumb_height)
	return {
		track = {right - 10 * g.scale, view.list_top, 8 * g.scale, height},
		thumb = {right - 10 * g.scale, top, 8 * g.scale, thumb_height},
		max_first = last,
	}
}

scrollbar_for :: proc(b: ^Browser, g: Geometry, places: bool) -> Scrollbar {
	if places {return scrollbar_geometry(g, len(b.places.entries), b.places.first, true)}
	return scrollbar_geometry(g, len(b.visible), b.first, false)
}

scrollbar_hit :: proc(b: ^Browser, g: Geometry, x, y: f32) -> (places: bool, hit: bool) {
	places = x < g.sidebar
	bar := scrollbar_for(b, g, places)
	box := bar.track
	return places,
		box.height > 0 &&
		x >= box.x &&
		x < box.x + box.width &&
		y >= box.y &&
		y < box.y + box.height
}

scrollbar_motion :: proc(b: ^Browser, g: Geometry, y: f32) -> bool {
	if !b.drag.active {return false}
	bar := scrollbar_for(b, g, b.drag.places)
	travel := bar.track.height - bar.thumb.height
	if travel <= 0 {b.drag.active = false; return false}
	fraction := clamp((y - bar.track.y - b.drag.grab) / travel, 0, 1)
	first := int(math.round(fraction * f32(bar.max_first)))
	offset := &b.first
	if b.drag.places {offset = &b.places.first}
	if offset^ == first {return false}
	offset^ = first
	return true
}

scrollbar_press :: proc(b: ^Browser, g: Geometry, places: bool, y: f32) {
	bar := scrollbar_for(b, g, places)
	grab := bar.thumb.height / 2
	if y >= bar.thumb.y && y < bar.thumb.y + bar.thumb.height {grab = y - bar.thumb.y}
	b.places.focused = places
	b.drag = {
		active = true,
		places = places,
		grab   = grab,
	}
	_ = scrollbar_motion(b, g, y)
}

scrollbar_layout :: proc(b: ^Browser, g: Geometry, places: bool) {
	if a := b.autoscroll; a.active && a.places == places {
		size := 24 * g.scale
		if clay.UI(clay.ID("autoscroll"))(
		{
			layout = {
				sizing = {clay.SizingFixed(size), clay.SizingFixed(size)},
				childAlignment = {x = .Center, y = .Center},
			},
			floating = {
				attachTo = .Root,
				offset = {a.x - size / 2, a.y - size / 2},
				zIndex = 2,
				pointerCaptureMode = .Passthrough,
			},
			backgroundColor = theme.text,
			cornerRadius = clay.CornerRadiusAll(size / 2),
		},
		) {label("↕", theme.background, g.font_size)}
	}
	bar := scrollbar_for(b, g, places)
	if bar.track.height <= 0 {return}
	id := scrollbar_id(places)
	color := theme.muted
	if b.hovered == id.id || (b.drag.active && b.drag.places == places) {color = theme.text}
	width := 3 * g.scale
	if clay.UI(id)(
	{
		layout = {sizing = {clay.SizingFixed(width), clay.SizingFixed(bar.thumb.height)}},
		floating = {
			attachTo = .Root,
			offset = {bar.thumb.x + bar.thumb.width - width, bar.thumb.y},
			zIndex = 1,
			pointerCaptureMode = .Passthrough,
		},
		backgroundColor = color,
		cornerRadius = clay.CornerRadiusAll(width / 2),
	},
	) {}
}
