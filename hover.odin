package main

import clay "vendor/clay"
import sdl "vendor:sdl3"

Pointer :: struct {
	x, y:   f32,
	active: bool,
}

hover_target :: proc(b: ^Browser, g: Geometry) -> u32 {
	x, y := b.pointer.x, b.pointer.y
	if !b.pointer.active || x < 0 || y < 0 || x >= g.width || y >= g.height {return 0}
	if b.header.edit.active && b.header.edit.mode != .Path {
		for name in ([?]string{"file-dialog-cancel", "file-dialog-submit"}) {if header_hit(clay.ID(name), x, y) {return clay.ID(name).id}}
		return 0
	}
	if b.menu.active {
		row := menu_action_at(b, g, x, y)
		if row >= 0 && menu_enabled(b, Menu_Action(row)) {return clay.ID("menu-item", u32(row)).id}
		return 0
	}
	if y < g.header {return header_target(&b.header, x, y)}
	if places, hit := scrollbar_hit(b, g, x, y); hit {return scrollbar_id(places).id}
	if x < g.sidebar {
		index := row_at(places_geometry(g), y, b.places.first, len(b.places.entries))
		if index >= 0 {
			if b.places.entries[index].section {return 0}
			if place_unmount_at(b.places.entries[index], g, x) {return place_unmount_id(index).id}
			return clay.ID("place", u32(index)).id
		}
		return 0
	}
	if y < g.header + g.row {
		if column, ok := column_at(g, x); ok {return clay.ID("column", u32(column)).id}
		return 0
	}
	index := row_at(g, y, b.first, len(b.visible))
	if index >= 0 {return clay.ID("row", u32(b.visible[index])).id}
	return 0
}

hover_update :: proc(b: ^Browser, g: Geometry) -> bool {
	target := hover_target(b, g)
	if b.hovered == target {return false}
	b.hovered = target
	return true
}

pointer_move :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	b.pointer = {
		x      = x,
		y      = y,
		active = true,
	}
	return hover_update(b, g)
}

pointer_cursor :: proc(b: ^Browser, g: Geometry) -> sdl.SystemCursor {
	if b.header.edit.active && b.pointer.active {
		box := path_edit_box(g, b.header.edit.mode)
		if b.pointer.x >= box.x &&
		   b.pointer.x < box.x + box.width &&
		   b.pointer.y >= box.y &&
		   b.pointer.y < box.y + box.height {return .TEXT}
	}
	if b.header.edit.active &&
	   b.header.edit.mode != .Path {return b.hovered != 0 ? .POINTER : .DEFAULT}
	if b.menu.active {return b.hovered != 0 ? .POINTER : .DEFAULT}
	if b.drag.active ||
	   b.hovered == scrollbar_id(false).id ||
	   b.hovered == scrollbar_id(true).id {return .DEFAULT}
	if b.pointer.active &&
	   b.hovered != 0 &&
	   (b.pointer.y < g.header || b.pointer.x < g.sidebar || b.pointer.y < g.header + g.row) {
		return .POINTER
	}
	return .DEFAULT
}

cursor_update :: proc(hand: ^sdl.Cursor, b: ^Browser, g: Geometry, text: ^sdl.Cursor = nil) {
	// Headless SDL backends may not provide system cursors.
	if hand == nil {return}
	cursor := sdl.GetDefaultCursor()
	#partial switch pointer_cursor(b, g) {
	case .POINTER:
		cursor = hand
	case .TEXT:
		cursor = text
	case:
	}
	if cursor != nil && cursor != sdl.GetCursor() {sdl_check(sdl.SetCursor(cursor))}
}

hover_color :: proc(b: ^Browser, id: clay.ElementId, base: clay.Color) -> clay.Color {
	if b.hovered != id.id {return base}
	if base == theme.selected {return theme.hover_selected}
	if base == theme.inactive_selection {return theme.selected}
	return theme.hover
}
