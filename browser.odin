package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

Column :: enum {
	Name,
	Size,
	Modified,
}

History_Entry :: struct {
	path, selected_name: string,
	first:               int,
}

// Entries, path, and history strings are owned. visible contains indices into entries.
Browser :: struct {
	path:            string,
	entries:         []os.File_Info,
	visible:         [dynamic]int,
	selected, first: int,
	anchor:          int,
	marks:           map[int]bool,
	marked_bytes:    i64,
	show_hidden:     bool,
	visible_bytes:   i64,
	sort_column:     Column,
	descending:      bool,
	back, forward:   [dynamic]History_Entry,
	opens:           [dynamic]File_Open,
	status_error:    string,
	places:          Places,
	header:          Header,
	pointer:         Pointer,
	hovered:         u32,
	storage:         ^Storage,
	space:           Space_Info,
	pending_disk:    ^Disk_Operation, // Borrowed until the worker returns its result.
	drag:            Scroll_Drag,
	menu:            Context_Menu,
	pending_files:   ^File_Operation, // Borrowed until its result is applied.
}

browser_message :: proc(b: ^Browser, message: string) {
	delete(b.status_error)
	b.status_error = strings.clone(message)
}

browser_destroy :: proc(b: ^Browser) {
	file_operation_stop(b.pending_files)
	storage_destroy(b.storage)
	b.storage, b.pending_disk = nil, nil
	header_destroy(&b.header)
	delete(b.status_error)
	places_destroy(&b.places)
	file_open_destroy(b)
	os.file_info_slice_delete(b.entries, context.allocator)
	delete(b.visible)
	delete(b.marks)
	delete(b.path)
	for entry in b.back {history_entry_destroy(entry)}
	for entry in b.forward {history_entry_destroy(entry)}
	delete(b.back)
	delete(b.forward)
}

browser_load :: proc(b: ^Browser, path: string) -> os.Error {
	absolute := os.get_absolute_path(path, context.allocator) or_return
	entries, read_err := os.read_all_directory_by_path(absolute, context.allocator)
	if read_err != nil {
		delete(absolute)
		return read_err
	}
	if b.path != absolute {b.header.copied_until = 0; b.space = {}; b.drag = {}}
	b.menu.active = false
	os.file_info_slice_delete(b.entries, context.allocator)
	delete(b.path)
	b.path, b.entries = absolute, entries
	browser_message(b, "")
	browser_filter(b)
	storage_path(b.storage, b.path)
	return nil
}

browser_filter :: proc(b: ^Browser) {
	clear(&b.visible)
	b.visible_bytes = 0
	for entry, i in b.entries {
		if !b.show_hidden && strings.has_prefix(entry.name, ".") {continue}
		append(&b.visible, i)
		if entry.type == .Regular {b.visible_bytes += max(0, entry.size)}
	}
	browser_sort(b)
	selection_single(b, 0)
	b.first = 0
}

browser_sort :: proc(b: ^Browser) {
	selected_source := -1
	if b.selected >= 0 && b.selected < len(b.visible) {
		selected_source = b.visible[b.selected]
	}
	slice.sort_by_with_data(
		b.visible[:],
		proc(i, j: int, data: rawptr) -> bool {
			b := cast(^Browser)data
			a, z := b.entries[i], b.entries[j]
			if (a.type == .Directory) != (z.type == .Directory) {return a.type == .Directory}
			order := slice.cmp(a.name, z.name)
			switch b.sort_column {
			case .Name:
			case .Size:
				// Non-regular entries have no displayed size and sort before files.
				a_size := a.type == .Regular ? max(0, a.size) : -1
				z_size := z.type == .Regular ? max(0, z.size) : -1
				order = slice.cmp(a_size, z_size)
			case .Modified:
				order = slice.cmp(
					time.to_unix_nanoseconds(a.modification_time),
					time.to_unix_nanoseconds(z.modification_time),
				)
			}
			if order != .Equal {return (order == .Less) != b.descending}
			return a.name < z.name
		},
		b,
	)
	for source, i in b.visible {
		if source == selected_source {b.selected = i; break}
	}
	b.anchor = b.selected
}

browser_set_sort :: proc(b: ^Browser, column: Column) {
	if column == b.sort_column {
		b.descending = !b.descending
	} else {
		b.sort_column = column
		b.descending = false
	}
	browser_sort(b)
}

// These labels borrow the temporary allocator and must not be retained.
format_size :: proc(bytes: i64) -> string {
	if bytes < 1024 {return fmt.tprintf("%d B", bytes)}
	value := f64(bytes)
	units := [?]string{"KiB", "MiB", "GiB", "TiB", "PiB", "EiB"}
	for unit in units {
		value /= 1024
		if value < 1024 || unit == "EiB" {return fmt.tprintf("%.1f %s", value, unit)}
	}
	unreachable()
}

browser_summary :: proc(b: ^Browser) -> string {
	noun := "items"
	if len(b.visible) == 1 {noun = "item"}
	total := fmt.tprintf(
		"%d %s  |  %s in files",
		len(b.visible),
		noun,
		format_size(b.visible_bytes),
	)
	if len(b.visible) == 0 {return total}
	if len(b.marks) != 1 {
		return fmt.tprintf(
			"%s  |  selected: %d items (%s)",
			total,
			len(b.marks),
			format_size(b.marked_bytes),
		)
	}
	source := 0
	for index in b.marks {source = index}
	entry := b.entries[source]
	detail := "special file"
	#partial switch entry.type {
	case .Regular:
		detail = format_size(entry.size)
	case .Directory:
		detail = "folder"
	case .Symlink:
		detail = "symbolic link"
	}
	return fmt.tprintf("%s  |  selected: %s", total, detail)
}

reveal_rows :: proc(selected, first: ^int, count, visible_rows: int) {
	rows := max(visible_rows, 1)
	selected^ = clamp(selected^, 0, max(0, count - 1))
	if selected^ < first^ {first^ = selected^}
	if selected^ >= first^ + rows {first^ = selected^ - rows + 1}
	first^ = clamp(first^, 0, max(0, count - rows))
}

browser_reveal :: proc(b: ^Browser, visible_rows: int) {
	reveal_rows(&b.selected, &b.first, len(b.visible), visible_rows)
}

history_entry_destroy :: proc(entry: History_Entry) {
	delete(entry.path)
	delete(entry.selected_name)
}

browser_location :: proc(b: ^Browser) -> History_Entry {
	entry := History_Entry {
		path  = strings.clone(b.path),
		first = b.first,
	}
	if len(b.visible) > 0 {
		entry.selected_name = strings.clone(b.entries[b.visible[b.selected]].name)
	}
	return entry
}

browser_restore_location :: proc(b: ^Browser, location: History_Entry, fallback := 0) {
	cursor := fallback
	for source, i in b.visible {
		if b.entries[source].name == location.selected_name {cursor = i; break}
	}
	selection_single(b, cursor)
	b.first = clamp(location.first, 0, max(0, len(b.visible) - 1))
}

browser_navigate :: proc(b: ^Browser, path: string) -> os.Error {
	if path == b.path {return nil}
	previous := browser_location(b)
	if err := browser_load(b, path); err != nil {
		history_entry_destroy(previous)
		return err
	}
	append(&b.back, previous)
	for entry in b.forward {history_entry_destroy(entry)}
	clear(&b.forward)
	return nil
}

browser_history :: proc(b: ^Browser, backward: bool) -> os.Error {
	from, to := &b.forward, &b.back
	if backward {from, to = &b.back, &b.forward}
	if len(from^) == 0 {return nil}
	destination := from^[len(from^) - 1]
	previous := browser_location(b)
	if err := browser_load(b, destination.path); err != nil {
		history_entry_destroy(previous)
		return err
	}
	pop(from)
	defer history_entry_destroy(destination)
	append(to, previous)
	browser_restore_location(b, destination)
	return nil
}

browser_parent :: proc(b: ^Browser) -> os.Error {
	parent, _ := os.split_path(b.path)
	if parent == "" {parent = "/"}
	return browser_navigate(b, parent)
}

browser_enter :: proc(b: ^Browser) -> os.Error {
	if len(b.visible) == 0 {return nil}
	entry := b.entries[b.visible[b.selected]]
	// Directory symlinks are followed only when the user opens them.
	if entry.type == .Directory || (entry.type == .Symlink && os.is_dir(entry.fullpath)) {
		return browser_navigate(b, entry.fullpath)
	}
	file_open(b, entry.fullpath)
	return nil
}
