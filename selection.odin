package main

import "core:strings"

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
