package main

import "core:os"
import "core:strings"
import "core:sync"

watch_refresh :: proc(w: ^Watch_Service, reset := false) {
	if w == nil {return}
	sync.mutex_lock(&w.mutex)
	w.version += 1
	w.configure, w.refresh = true, true
	w.reset = w.reset || reset
	sync.mutex_unlock(&w.mutex)
	watch_wake(w)
}

watch_sync :: proc(b: ^Browser, refresh := false) {
	w := b.watch
	if w == nil {return}
	trash := b.path == TRASH_PATH
	active := trash ? "" : b.path
	sync.mutex_lock(&w.mutex)
	if !refresh && w.active == active && w.trash == trash {sync.mutex_unlock(&w.mutex); return}
	delete(w.active)
	w.active = strings.clone(active)
	w.version += 1
	w.trash, w.configure, w.refresh = trash, true, true
	sync.mutex_unlock(&w.mutex)
	watch_wake(w)
}

// Takes ownership of the latest listing. Preserve marks and focus by path/name,
// as on tab activation, without changing navigation, search, or scroll offsets.
browser_replace_entries :: proc(b: ^Browser, entries: []os.File_Info) {
	location, cursor := browser_location(b), b.selected
	selected_type: os.File_Type
	if len(b.visible) > 0 {selected_type = b.entries[b.visible[b.selected]].type}
	defer history_entry_destroy(location)
	marked := make(map[string]os.File_Type)
	defer delete(marked)
	for source in b.marks {entry := b.entries[source]; marked[entry.fullpath] = entry.type}
	anchor := ""
	if b.anchor >= 0 &&
	   b.anchor < len(b.visible) {anchor = b.entries[b.visible[b.anchor]].fullpath}
	old := b.entries
	defer os.file_info_slice_delete(old, context.allocator)
	b.entries = entries
	file_drag_cancel_press(b)
	sort_restore(b)
	browser_filter(b)
	browser_restore_location(b, location, cursor)
	selection_clear(b)
	changed_types := false
	for source, row in b.visible {
		entry := b.entries[source]
		if previous, exists := marked[entry.fullpath]; exists {
			selection_mark(b, row, true)
			changed_types = changed_types || previous != entry.type
		}
		if entry.fullpath == anchor {b.anchor = row}
	}
	if b.menu.active &&
	   !b.menu.places &&
	   (changed_types ||
			   len(b.marks) != len(marked) ||
			   len(b.visible) == 0 ||
			   b.entries[b.visible[b.selected]].type != selected_type) {b.menu = {}}
}

watch_poll :: proc(b: ^Browser) -> bool {
	w := b.watch
	if w == nil {return false}
	sync.mutex_lock(&w.mutex)
	result, version := w.pending, w.version
	w.pending = nil
	sync.mutex_unlock(&w.mutex)
	if result == nil {return false}
	defer watch_result_destroy(result)
	paths := make([dynamic]string, context.temp_allocator)
	if result.overflow {append(&paths, "/")} else {
		for path in result.changes {append(&paths, path)}
	}
	if len(paths) > 0 {size_paths_changed(b, paths[:]); preview_invalidate(b.previews, paths[:])}
	if result.listing && result.path == b.path && result.version == version {
		browser_replace_entries(b, result.entries)
		result.entries = nil
		if result.error != nil {browser_message(b, "the folder is no longer readable")}
	}
	if result.trash && b.path == TRASH_PATH {_ = trash_view_request(b)}
	if result.warning {browser_message(b, "folder changes cannot be monitored")}
	return true
}
