package main

import "core:math"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Selection_Drag :: struct {
	active:     bool,
	start, end: clay.Vector2,
}

selection_drag_box :: proc(d: Selection_Drag) -> clay.BoundingBox {
	return {
		min(d.start.x, d.end.x),
		min(d.start.y, d.end.y),
		abs(d.end.x - d.start.x),
		abs(d.end.y - d.start.y),
	}
}

selection_drag_input :: proc(b: ^Browser, event: ^sdl.Event, g: Geometry) -> bool {
	d := &b.selection_drag
	if !d.active {return false}
	#partial switch event.type {
	case .MOUSE_MOTION:
		d.end = {
			clamp(event.motion.x, g.sidebar, g.width),
			clamp(event.motion.y, g.list_top, list_bottom(g)),
		}
		box := selection_drag_box(d^)
		selection_clear(b)
		if box.width > 0 && box.height > 0 {
			for row in b.first ..< min(b.first + g.rows + 1, len(b.visible)) {
				top := g.list_top + f32(row - b.first) * g.row
				if top < box.y + box.height && top + g.row > box.y {
					selection_mark(b, row, true)
					b.selected = row
				}
			}
		}
		b.anchor = b.selected
		return true
	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl.BUTTON_LEFT {d^ = {}; return true}
	case .KEY_DOWN,
	     .MOUSE_BUTTON_DOWN,
	     .MOUSE_WHEEL,
	     .WINDOW_FOCUS_LOST,
	     .WINDOW_HIDDEN,
	     .WINDOW_MINIMIZED,
	     .WINDOW_PIXEL_SIZE_CHANGED,
	     .WINDOW_DISPLAY_SCALE_CHANGED,
	     .DROP_BEGIN:
		d^ = {}
	}
	return false
}

selection_drag_begin :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	if x < g.sidebar || x >= g.width || y < g.list_top || y >= list_bottom(g) {return false}
	file_drag_cancel_press(b)
	selection_clear(b)
	b.places.focused, b.pointer.active, b.hovered = false, false, 0
	b.selection_drag = {
		active = true,
		start  = {x, y},
		end    = {x, y},
	}
	return true
}

selection_drag_layout :: proc(b: ^Browser) {
	if !b.selection_drag.active {return}
	box := selection_drag_box(b.selection_drag)
	// Geometry is already in physical pixels. Snap both edges, not just the size.
	right, bottom := math.round(box.x + box.width), math.round(box.y + box.height)
	box.x, box.y = math.round(box.x), math.round(box.y)
	box.width, box.height = right - box.x, bottom - box.y
	if box.width <= 0 || box.height <= 0 {return}
	stroke :: 1
	fill := theme.text
	fill[3] = 24
	if clay.UI(clay.ID("selection-drag"))(
	{
		layout = {sizing = {clay.SizingFixed(box.width), clay.SizingFixed(box.height)}},
		backgroundColor = fill,
		floating = {
			attachTo = .Root,
			offset = {box.x, box.y},
			zIndex = 2,
			pointerCaptureMode = .Passthrough,
		},
	},
	) {
		for edge in ([4]clay.BoundingBox{{0, 0, box.width, stroke}, {0, box.height - stroke, box.width, stroke}, {0, 0, stroke, box.height}, {box.width - stroke, 0, stroke, box.height}}) {
			if clay.UI()(
			{
				layout = {sizing = {clay.SizingFixed(edge.width), clay.SizingFixed(edge.height)}},
				floating = {
					attachTo = .Parent,
					offset = {edge.x, edge.y},
					zIndex = 2,
					pointerCaptureMode = .Passthrough,
				},
				backgroundColor = theme.muted,
			},
			) {}
		}
	}
}

// Marks use entry indices, not sorted row positions. The cursor can move without marks.
selection_clear :: proc(b: ^Browser) {
	clear(&b.marks)
	b.marked_bytes = 0
}

selection_mark :: proc(b: ^Browser, row: int, marked: bool) {
	if row < 0 || row >= len(b.visible) {return}
	source := b.visible[row]
	if b.marks[source] == marked {return}
	if marked {
		if b.marks == nil {b.marks = make(map[int]bool)}
		b.marks[source] = true
	} else {delete_key(&b.marks, source)}
	if b.entries[source].type == .Regular {
		size := max(0, b.entries[source].size)
		b.marked_bytes += marked ? size : -size
	}
}

selection_single :: proc(b: ^Browser, row: int) {
	selection_clear(b)
	b.selected = clamp(row, 0, max(0, len(b.visible) - 1))
	b.anchor = b.selected
	selection_mark(b, b.selected, true)
}

selection_extend :: proc(b: ^Browser, row: int, add: bool) {
	if !add {selection_clear(b)}
	b.selected = clamp(row, 0, max(0, len(b.visible) - 1))
	b.anchor = clamp(b.anchor, 0, max(0, len(b.visible) - 1))
	for i in min(b.anchor, b.selected) ..= max(b.anchor, b.selected) {selection_mark(b, i, true)}
}

selection_click :: proc(b: ^Browser, row: int, ctrl, shift: bool) {
	if shift {selection_extend(b, row, ctrl); return}
	if !ctrl {selection_single(b, row); return}
	b.selected, b.anchor = row, row
	selection_mark(b, row, !b.marks[b.visible[row]])
}

selection_all :: proc(b: ^Browser) {
	for i in 0 ..< len(b.visible) {selection_mark(b, i, true)}
	b.anchor = b.selected
}

// Owned paths in display order. Only explicit marks are included.
selection_paths :: proc(b: ^Browser) -> [dynamic]string {
	paths := make([dynamic]string, 0, len(b.marks))
	for source in b.visible {
		if b.marks[source] {append(&paths, strings.clone(b.entries[source].fullpath))}
	}
	return paths
}

file_paths_destroy :: proc(paths: [dynamic]string) {
	for path in paths {delete(path)}
	delete(paths)
}
