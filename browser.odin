package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import linux "core:sys/linux"
import "core:time"
import "core:unicode/utf8"

Column :: enum {
	Name,
	Size,
	Modified,
}

History_Entry :: struct {
	path, selected_name: string,
	first:               int,
}

// Each view owns its listing, selection, search, and navigation history.
Folder_View :: struct {
	path:                    string,
	entries:                 []os.File_Info,
	visible:                 [dynamic]int,
	selected, first, anchor: int,
	marks:                   map[int]bool,
	marked_bytes:            i64,
	show_hidden:             bool,
	search:                  string,
	sort_column:             Column,
	descending:              bool,
	back, forward:           [dynamic]History_Entry,
	space:                   Space_Info,
	space_device:            linux.Dev,
	trash_records:           map[string]File_Change,
}

Browser :: struct {
	using view:             Folder_View,
	// The active slot is empty. Its owned view lives in view instead.
	tabs:                   [dynamic]Folder_View,
	active_tab:             int,
	file_drag:              ^File_Drag,
	sizes:                  map[string]Size_Entry,
	size_service:           ^Size_Service,
	size_generation:        u64,
	size_clock:             u64,
	sorts:                  map[string]Sort_Spec, // Owned per-folder sort choices.
	sorts_path:             string, // Borrowed state file path; empty disables saving.
	opens:                  [dynamic]File_Open,
	status_error:           string,
	places:                 Places,
	header:                 Header,
	pointer:                Pointer,
	hovered:                u32,
	storage:                ^Storage,
	pending_disk:           ^Disk_Operation, // Borrowed until the worker returns its result.
	drag:                   Scroll_Drag,
	autoscroll:             Auto_Scroll,
	menu:                   Context_Menu,
	pending_files:          ^File_Operation, // Borrowed until its result is applied.
	undo_files, redo_files: [dynamic]File_Batch,
	pending_trash:          ^File_Operation,
	trash_requested:        bool,
}

browser_message :: proc(b: ^Browser, message: string) {
	delete(b.status_error)
	b.status_error = strings.clone(message)
}

browser_destroy :: proc(b: ^Browser) {
	size_destroy(b.size_service)
	file_operation_stop(b.pending_files)
	file_operation_stop(b.pending_trash)
	storage_destroy(b.storage)
	b.storage, b.pending_disk = nil, nil
	header_destroy(&b.header)
	file_history_clear(&b.undo_files)
	file_history_clear(&b.redo_files)
	delete(b.status_error)
	places_destroy(&b.places)
	file_open_destroy(b)
	view_destroy(&b.view)
	for &view in b.tabs {view_destroy(&view)}
	delete(b.tabs)
	size_cache_destroy(b)
	sort_state_destroy(b.sorts)
}

browser_load :: proc(b: ^Browser, path: string) -> os.Error {
	browser_read(b, path) or_return
	size_cancel(b)
	return nil
}

// Reading a listing does not restart size scans. Navigation requests a refresh
// through browser_load; tab activation only needs the updated listing.
browser_read :: proc(b: ^Browser, path: string) -> os.Error {
	b.autoscroll = {}
	if path == TRASH_PATH {
		if !trash_view_request(b) {return .Unsupported}
		if b.path == TRASH_PATH {browser_message(b, ""); return nil}
		search_reset(b)
		os.file_info_slice_delete(b.entries, context.allocator)
		trash_records_destroy(b.trash_records)
		b.entries, b.trash_records = nil, nil
		delete(b.path)
		b.path, b.space, b.drag = strings.clone(TRASH_PATH), {}, {}
		b.menu.active = false
		browser_filter(b)
		browser_message(b, "")
		storage_path(b.storage, "")
		return nil
	}
	dir := directory_open(path) or_return
	defer os.close(dir)
	entries := os.read_all_directory(dir, context.allocator) or_return
	absolute := strings.clone(os.name(dir))
	if b.path != absolute {search_reset(b); b.header.copied_until = 0; b.drag = {}}
	// Keep free space visible during navigation within the same filesystem.
	info: linux.Stat
	if linux.fstat(linux.Fd(os.fd(dir)), &info) != .NONE ||
	   info.dev != b.space_device {b.space = {}}
	b.space_device = info.dev
	b.menu.active = false
	os.file_info_slice_delete(b.entries, context.allocator)
	delete(b.path)
	trash_records_destroy(b.trash_records)
	b.trash_records = nil
	b.path, b.entries = absolute, entries
	sort_restore(b)
	browser_message(b, "")
	browser_filter(b)
	storage_path(b.storage, b.path)
	return nil
}

browser_filter :: proc(b: ^Browser, reset_selection := true) {
	query_runes := utf8.rune_count_in_string(b.search)
	clear(&b.visible)
	for entry, i in b.entries {
		if b.path != TRASH_PATH && !b.show_hidden && strings.has_prefix(entry.name, ".") {continue}
		if !search_matches(entry.name, b.search, query_runes) {continue}
		append(&b.visible, i)
	}
	browser_sort(b)
	if reset_selection {selection_single(b, 0); b.first = 0}
}

browser_sort :: proc(b: ^Browser) {
	selected_source := -1
	if b.selected >= 0 && b.selected < len(b.visible) {
		selected_source = b.visible[b.selected]
	}
	slice.sort_by_with_data(b.visible[:], proc(i, j: int, data: rawptr) -> bool {
			b := cast(^Browser)data
			a, z := b.entries[i], b.entries[j]
			if (a.type == .Directory) != (z.type == .Directory) {return a.type == .Directory}
			order: slice.Ordering
			switch b.sort_column {
			case .Name:
				order = slice.cmp(a.name, z.name)
			case .Size:
				order = slice.cmp(size_value(b, a), size_value(b, z))
			case .Modified:
				order = slice.cmp(
					time.to_unix_nanoseconds(a.modification_time),
					time.to_unix_nanoseconds(z.modification_time),
				)
			}
			if order != .Equal {return (order == .Less) != b.descending}
			return a.name < z.name
		}, b)
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
	sort_remember(b)
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
	total := fmt.tprintf("%d %s", len(b.visible), noun)
	if len(b.visible) == 0 {return total}
	if len(b.marks) != 1 {
		return fmt.tprintf(
			"%s    selected: %d items (%s)",
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
	if b.path == TRASH_PATH {
		record := b.trash_records[entry.fullpath]
		parent, _ := os.split_path(record.path)
		detail = fmt.tprintf("from %s", parent)
	}
	return fmt.tprintf("%s    selected: %s", total, detail)
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
	if b.path == previous.path {history_entry_destroy(previous); return nil}
	path_edit_end(&b.header.edit)
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
	path_edit_end(&b.header.edit)
	return nil
}

browser_parent :: proc(b: ^Browser) -> os.Error {
	if b.path == TRASH_PATH {return browser_history(b, true)}
	parent, _ := os.split_path(b.path)
	if parent == "" {parent = "/"}
	return browser_navigate(b, parent)
}

entry_is_directory :: proc(entry: os.File_Info) -> bool {
	is_directory := entry.type == .Directory
	if entry.type == .Symlink {
		path := strings.clone_to_cstring(entry.fullpath, context.temp_allocator)
		info: linux.Stat
		is_directory =
			linux.stat(path, &info) == .NONE && info.mode & linux.S_IFMT == linux.S_IFDIR
	}
	return is_directory
}

browser_enter :: proc(b: ^Browser) -> os.Error {
	if len(b.visible) == 0 {return nil}
	entry := b.entries[b.visible[b.selected]]
	is_directory := entry_is_directory(entry)
	if b.path == TRASH_PATH && is_directory {
		browser_message(b, "restore this folder to browse it")
		return nil
	}
	// Directory symlinks are followed only when the user opens them.
	if is_directory {
		return browser_navigate(b, entry.fullpath)
	}
	file_open(b, entry.fullpath)
	return nil
}
