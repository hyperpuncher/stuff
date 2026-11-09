package main

import "core:os"
import "core:strings"
import "core:sync"
import clay "vendor/clay"
import sdl "vendor:sdl3"

drag_target :: proc(b: ^Browser, g: Geometry, x, y: f32) -> (path: string, id: u32) {
	if b.pending_files != nil || b.storage == nil || b.header.edit.active || b.menu.active {return}
	if x < 0 || y < 0 || x >= g.width || y >= g.height - g.footer {return}
	if y < g.header {
		target := header_target(&b.header, x, y)
		for crumb, i in b.header.crumbs {
			if target == clay.ID("crumb", u32(i)).id {return b.header.path[:crumb.end], target}
		}
		return
	}
	if x < g.sidebar {
		index := row_at(places_geometry(g), y, b.places.first, len(b.places.entries))
		if index < 0 {return}
		place := b.places.entries[index]
		if place.section || place.path == "" || place.path == TRASH_PATH {return}
		return place.path, clay.ID("place", u32(index)).id
	}
	if y < g.list_top || y >= list_bottom(g) || b.path == TRASH_PATH {return}
	index := row_at(g, y, b.first, len(b.visible))
	if index < 0 {return b.path, clay.ID("files-viewport").id}
	entry := b.entries[b.visible[index]]
	if entry.type == .Directory ||
	   entry.type == .Symlink {return entry.fullpath, clay.ID("row", u32(b.visible[index])).id}
	return
}

drag_destination_update :: proc(b: ^Browser, g: Geometry, x, y: f32) {
	d := b.file_drag
	path, id := drag_target(b, g, x, y)
	for source in d.paths {
		parent, _ := os.split_path(source)
		if path_contains(source, path) ||
		   strings.trim_suffix(parent, "/") ==
			   strings.trim_suffix(path, "/") {path, id = "", 0; break}
	}
	if d.target != path {delete(d.target); d.target = strings.clone(path)}
	d.target_id = id
}

file_drag_disarm :: proc(d: ^File_Drag) {
	file_paths_destroy(d.paths)
	d.paths = nil
	delete(d.clicked)
	d.clicked = ""
	d.armed, d.collapse, d.toggle = false, false, false
}

file_drag_cancel_press :: proc(b: ^Browser) {
	if b.file_drag != nil && b.file_drag.source == nil {file_drag_disarm(b.file_drag)}
}

file_drag_press :: proc(
	b: ^Browser,
	g: Geometry,
	index: int,
	event: ^sdl.Event,
	mods: sdl.Keymod,
) {
	d := b.file_drag
	marked := b.marks[b.visible[index]]
	ctrl, shift := mods & sdl.KMOD_CTRL != {}, mods & sdl.KMOD_SHIFT != {}
	eligible :=
		d != nil &&
		d.source == nil &&
		d.pressed &&
		event.button.clicks == 1 &&
		b.path != TRASH_PATH &&
		b.pending_files == nil
	defer_selection := eligible && marked && !shift && (ctrl || len(b.marks) > 1)
	if !defer_selection {selection_click(b, index, ctrl, shift)}
	if !eligible {return}
	file_drag_disarm(d)
	d.paths, d.clicked = selection_paths(b), strings.clone(b.entries[b.visible[index]].fullpath)
	d.icon_kind = len(d.paths) > 1 ? .CopyPath : entry_icon(b.entries[b.visible[index]])
	d.press_x, d.press_y = event.button.x, event.button.y
	d.armed, d.collapse, d.toggle = true, defer_selection && !ctrl, defer_selection && ctrl
}

file_drag_release :: proc(b: ^Browser) -> bool {
	d := b.file_drag
	if d == nil || !d.armed {return false}
	for source, i in b.visible {
		if b.entries[source].fullpath == d.clicked {
			if d.toggle {selection_click(b, i, true, false)} else if d.collapse {selection_single(b, i)}
			break
		}
	}
	file_drag_disarm(d)
	return true
}

file_drag_motion :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	d := b.file_drag
	if d == nil || !d.armed || !d.pressed {return false}
	if max(abs(x - d.press_x), abs(y - d.press_y)) < 6 * g.scale {return false}
	if len(d.paths) == 0 {file_drag_disarm(d); return false}
	d.source = drag_source_begin(d)
	if d.source ==
	   nil {file_drag_disarm(d); browser_message(b, "cannot start a file drag"); return true}
	d.armed, d.collapse, d.toggle = false, false, false
	return true
}

file_drop_start :: proc(b: ^Browser, paths: [dynamic]string, target: string) -> bool {
	if b.pending_files != nil || b.storage == nil || target == "" || target == TRASH_PATH {
		file_paths_destroy(paths)
		browser_message(b, "cannot copy dropped files here")
		return false
	}
	op := new(File_Operation)
	op.kind, op.sources, op.target = .Copy, paths, strings.clone(target)
	if !file_operation_launch(b, op) {file_operation_destroy(op); return false}
	return true
}

// SDL owns offer negotiation, URI decoding and drop completion. No second
// receiver reads the offer. Paths become owned snapshots before the next pump.
file_drop_input :: proc(b: ^Browser, event: ^sdl.Event, g: Geometry) -> bool {
	d := b.file_drag
	if d == nil {return false}
	#partial switch event.type {
	case .DROP_BEGIN:
		file_paths_destroy(d.drop_paths)
		d.drop_paths, d.invalid_drop, d.receiving = nil, false, true
	case .DROP_POSITION:
		previous := d.target_id
		drag_destination_update(b, g, event.drop.x, event.drop.y)
		return previous != d.target_id
	case .DROP_FILE:
		if len(d.drop_paths) == 0 {
			drag_destination_update(b, g, event.drop.x, event.drop.y)
			delete(d.drop_target)
			d.drop_target = strings.clone(d.target)
		}
		path := string(event.drop.data)
		if !strings.has_prefix(
			path,
			"/",
		) {d.invalid_drop = true} else {append(&d.drop_paths, strings.clone(path))}
	case .DROP_COMPLETE:
		paths := d.drop_paths
		d.drop_paths = nil
		if d.invalid_drop {file_paths_destroy(paths); browser_message(b, "the drop must contain local files")} else if len(paths) > 0 {_ = file_drop_start(b, paths, d.drop_target)}
		delete(d.drop_target)
		d.drop_target = ""
		delete(d.target)
		d.target, d.target_id = "", 0
		d.invalid_drop, d.receiving = false, false
		// SDL's finish request is already queued. Releasing these passive offers
		// earlier can cancel the source before SDL reads its data.
		#reverse for offer in d.offers {if offer.dropped {drag_offer_destroy(d, offer)}}
	case:
		return false
	}
	return true
}

file_drag_poll :: proc(b: ^Browser) -> bool {
	d := b.file_drag
	if d == nil || d.source == nil || !sync.atomic_load(&d.source.done) {return false}
	drag_source_destroy(d.source)
	d.source = nil
	drag_icon_destroy(d)
	file_drag_disarm(d)
	d.pressed = false
	_ = wl_display_flush(d.display)
	return true
}
