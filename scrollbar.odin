package main

import "core:math"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Auto_Scroll :: struct {
	active, places:            bool,
	x, y:                      f32,
	rate_x, rate_y, remainder: f64,
	tick, pressed:             u64,
	folder:                    int, // Entry index plus one; zero means no short-click target.
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
		places = places,
		x      = x,
		y      = y,
		tick   = sdl.GetTicks(),
	}
	b.autoscroll.pressed = b.autoscroll.tick
	b.autoscroll.active =
		scrollbar_for(b, g, places).max_first > 0 || !places && table_scroll_max(g) > 0
	if !places && b.path != TRASH_PATH {
		if row := item_at(g, x, y, b.first, len(b.visible)); row >= 0 {
			source := b.visible[row]
			if entry_is_directory(b.entries[source]) {b.autoscroll.folder = source + 1}
		}
	}
	return b.autoscroll.active || b.autoscroll.folder > 0
}

autoscroll_motion :: proc(b: ^Browser, g: Geometry, x, y: f32) {
	a := &b.autoscroll
	if max(abs(x - a.x), abs(y - a.y)) >= 6 * g.scale {a.folder = 0}
	rate := autoscroll_rate((y - a.y) / g.scale)
	if rate == 0 || (rate < 0) != (a.rate_y < 0) {a.remainder = 0}
	a.rate_y = rate
	a.rate_x = a.places ? 0 : autoscroll_rate((x - a.x) / g.scale)
}

autoscroll_rate :: proc(delta: f32) -> f64 {
	distance := max(abs(delta) - 12, 0)
	rate := f64(min(distance * distance / 800, 120))
	return delta < 0 ? -rate : rate
}

autoscroll_update :: proc(b: ^Browser, g: Geometry, now: u64) -> bool {
	a := &b.autoscroll
	if !a.active {return false}
	last := scrollbar_for(b, g, a.places).max_first
	max_x := a.places ? 0 : table_scroll_max(g)
	if last <= 0 && max_x <= 0 {a^ = {}; return true}
	first := a.places ? &b.places.first : &b.first
	if last <= 0 || a.rate_y < 0 && first^ <= 0 || a.rate_y > 0 && first^ >= last {
		a.rate_y, a.remainder = 0, 0
	}
	x := table_scroll_offset(b, g)
	if max_x <= 0 || a.rate_x < 0 && x <= 0 || a.rate_x > 0 && x >= max_x {a.rate_x = 0}
	// Use elapsed time, but do not jump after a stalled frame.
	elapsed := f64(min(now - a.tick, 100)) / 1000
	a.remainder += a.rate_y * elapsed
	a.tick = now
	rows := int(a.remainder)
	a.remainder -= f64(rows)
	previous := first^
	first^ = clamp(first^ + rows * (a.places ? 1 : max(1, g.stride)), 0, last)
	horizontal := a.rate_x != 0 && table_scroll_by(b, g, f32(a.rate_x * f64(g.row) * elapsed))
	return first^ != previous || horizontal
}

Scroll_Drag :: struct {
	active, places, horizontal: bool,
	grab:                       f32,
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
	stride := max(1, view.stride)
	total_rows := (count + stride - 1) / stride
	thumb_height := min(
		height,
		max(
			24 * g.scale,
			height * height / (f32(total_rows) * (view.grid ? view.cell_height : view.row)),
		),
	)
	last := view_last(view, count)
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

scrollbar_motion :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	if !b.drag.active {return false}
	if b.drag.horizontal {
		bar := table_scrollbar(b, g)
		travel := bar.track.width - bar.thumb.width
		if travel <= 0 {b.drag = {}; return false}
		fraction := clamp((x - bar.track.x - b.drag.grab) / travel, 0, 1)
		return table_scroll_by(b, g, fraction * table_scroll_max(g) - table_scroll_offset(b, g))
	}
	bar := scrollbar_for(b, g, b.drag.places)
	travel := bar.track.height - bar.thumb.height
	if travel <= 0 {b.drag = {}; return false}
	fraction := clamp((y - bar.track.y - b.drag.grab) / travel, 0, 1)
	first := int(math.round(fraction * f32(bar.max_first)))
	if !b.drag.places {first = view_first(g, first, len(b.visible))}
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
	_ = scrollbar_motion(b, g, 0, y)
}

scrollbar_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter, places: bool) {
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
		) {
			marker: Icon = .MoveVertical
			if !places && table_scroll_max(g) > 0 {
				marker = scrollbar_for(b, g, places).max_first > 0 ? .Move : .MoveHorizontal
			}
			icon_element(p, marker, g.scale)
		}
	}
	bar := scrollbar_for(b, g, places)
	if bar.track.height <= 0 {return}
	thumb := bar.thumb
	thumb.x += thumb.width - 3 * g.scale
	thumb.width = 3 * g.scale
	scrollbar_thumb_layout(
		b,
		scrollbar_id(places),
		thumb,
		b.drag.active && !b.drag.horizontal && b.drag.places == places,
	)
}

scrollbar_thumb_layout :: proc(
	b: ^Browser,
	id: clay.ElementId,
	box: clay.BoundingBox,
	dragging: bool,
) {
	color := b.hovered == id.id || dragging ? theme.text : theme.muted
	if clay.UI(id)(
	{
		layout = {sizing = {clay.SizingFixed(box.width), clay.SizingFixed(box.height)}},
		floating = {
			attachTo = .Root,
			offset = {box.x, box.y},
			zIndex = 1,
			pointerCaptureMode = .Passthrough,
		},
		backgroundColor = color,
		cornerRadius = clay.CornerRadiusAll(min(box.width, box.height) / 2),
	},
	) {}
}

table_scrollbar :: proc(b: ^Browser, g: Geometry) -> Scrollbar {
	track := clay.BoundingBox {
		g.sidebar + g.padding,
		g.height - g.footer - g.horizontal_bar,
		g.width - g.sidebar - 2 * g.padding,
		g.horizontal_bar,
	}
	if track.height <= 0 || track.width <= 0 {return {}}
	thumb := track
	thumb.width = min(
		track.width,
		max(24 * g.scale, track.width * (g.width - g.sidebar) / g.table_width),
	)
	thumb.x += table_scroll_offset(b, g) / table_scroll_max(g) * (track.width - thumb.width)
	return {track = track, thumb = thumb}
}

table_scrollbar_hit :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	box := table_scrollbar(b, g).track
	return(
		box.width > 0 &&
		x >= box.x &&
		x < box.x + box.width &&
		y >= box.y &&
		y < box.y + box.height \
	)
}

table_scrollbar_press :: proc(b: ^Browser, g: Geometry, x, y: f32) {
	bar := table_scrollbar(b, g)
	grab := bar.thumb.width / 2
	if x >= bar.thumb.x && x < bar.thumb.x + bar.thumb.width {grab = x - bar.thumb.x}
	file_drag_cancel_press(b)
	b.places.focused = false
	b.drag = {
		active     = true,
		horizontal = true,
		grab       = grab,
	}
	_ = scrollbar_motion(b, g, x, y)
}

table_scrollbar_layout :: proc(b: ^Browser, g: Geometry) {
	bar := table_scrollbar(b, g)
	if bar.track.width <= 0 {return}
	thumb := bar.thumb
	thumb.y += (thumb.height - 3 * g.scale) / 2
	thumb.height = 3 * g.scale
	scrollbar_thumb_layout(
		b,
		clay.ID("table-scrollbar"),
		thumb,
		b.drag.active && b.drag.horizontal,
	)
}
