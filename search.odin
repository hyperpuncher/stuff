package main

import "core:strings"
import "core:unicode/utf8"

// Compare equal-length rune windows without allocating a folded copy of each
// filename. The core comparison handles Unicode simple case folding.
search_matches :: proc(name, query: string, query_runes: int) -> bool {
	if query == "" {return true}
	end, needed := 0, query_runes
	for _, start in name {
		for needed > 0 {
			if end >= len(name) {return false}
			_, size := utf8.decode_rune_in_string(name[end:])
			end += size
			needed -= 1
		}
		if strings.equal_fold(name[start:end], query) {return true}
		needed = 1
	}
	return false
}

search_reset :: proc(b: ^Browser) {
	if b.header.edit.mode == .Search {path_edit_end(&b.header.edit)}
	delete(b.search)
	b.search = ""
}

search_start :: proc(b: ^Browser) {
	edit := &b.header.edit
	if edit.mode != .Search {
		path_edit_end(edit)
		edit.mode, edit.value = .Search, strings.clone(b.search)
	}
	edit.active, edit.dragging = true, false
	edit.anchor, edit.cursor = 0, len(edit.value)
	b.menu.active, b.places.focused, b.drag = false, false, {}
	browser_message(b, "")
}

search_update :: proc(b: ^Browser) {
	if b.header.edit.mode != .Search || b.search == b.header.edit.value {return}
	delete(b.search)
	b.search = strings.clone(b.header.edit.value)
	browser_filter(b)
	browser_message(b, "")
}

search_end :: proc(b: ^Browser) {
	if b.header.edit.mode != .Search {return}
	source, row := -1, b.selected - b.first
	if len(b.visible) > 0 {source = b.visible[b.selected]}
	path_edit_end(&b.header.edit)
	delete(b.search)
	b.search = ""
	browser_filter(b, false)
	b.selected = 0
	for index, i in b.visible {
		if index == source {b.selected = i; break}
	}
	b.anchor = b.selected
	b.first = clamp(b.selected - row, 0, max(0, len(b.visible) - 1))
}

search_blur :: proc(edit: ^Path_Edit) {
	edit.active, edit.dragging = false, false
	edit.anchor = edit.cursor
	delete(edit.composition)
	edit.composition = ""
}
