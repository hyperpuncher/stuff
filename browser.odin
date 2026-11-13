package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:time"
import "core:unicode/utf8"
import sdl "vendor:sdl3"

Column :: enum {
	Name,
	Size,
	Type,
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
	scroll_x:                f32, // Horizontal table offset in logical pixels.
	marks:                   map[int]bool,
	marked_bytes:            i64,
	show_hidden, icons:      bool,
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
	watch:                  ^Watch_Service,
	previews:               ^Preview_Service, // Borrowed; released before the renderer.
	size_generation:        u64,
	size_clock:             u64,
	sorts:                  map[string]Sort_Spec, // Owned per-folder sort choices.
	sorts_path:             string, // Borrowed state file path; empty disables saving.
	opens:                  [dynamic]File_Open,
	status_error:           string,
	status_until:           u64,
	places:                 Places,
	header:                 Header,
	pointer:                Pointer,
	hovered:                u32,
	storage:                ^Storage,
	pending_disk:           ^Disk_Operation, // Borrowed until the worker returns its result.
	drag:                   Scroll_Drag,
	selection_drag:         Selection_Drag,
	autoscroll:             Auto_Scroll,
	menu:                   Context_Menu,
	transfers:              [dynamic]File_Transfer, // Jobs are borrowed until their results are applied.
	transfer_first:         int,
	archive_requests:       [dynamic]Archive_Request,
	undo_files, redo_files: [dynamic]File_Batch,
	pending_trash:          ^File_Operation,
	trash_requested:        bool,
}

browser_message :: proc(b: ^Browser, message: string) {
	replace_owned(&b.status_error, message)
	b.status_until = message != "" ? sdl.GetTicks() + 3000 : 0
}

browser_message_update :: proc(b: ^Browser, now: u64) -> bool {
	if b.status_until == 0 || now < b.status_until {return false}
	browser_message(b, "")
	return true
}

browser_destroy :: proc(b: ^Browser) {
	// Request cancellation for every file job before waiting for any worker.
	for job in b.transfers {sync.atomic_store(&job.op.cancel, true)}
	if b.pending_trash != nil {sync.atomic_store(&b.pending_trash.cancel, true)}
	size_destroy(b.size_service)
	watch_destroy(b.watch)
	for job in b.transfers {file_operation_stop(job.op)}
	delete(b.transfers)
	for request in b.archive_requests {delete(request.source); delete(request.target)}
	delete(b.archive_requests)
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
		sort_remember(b, persist = false)
		search_reset(b)
		os.file_info_slice_delete(b.entries, context.allocator)
		trash_records_destroy(b.trash_records)
		b.entries, b.trash_records = nil, nil
		replace_owned(&b.path, TRASH_PATH)
		b.space, b.drag = {}, {}
		b.scroll_x = 0
		b.menu.active = false
		browser_filter(b)
		browser_message(b, "")
		storage_path(b.storage, "")
		watch_sync(b)
		return nil
	}
	dir := directory_open(path) or_return
	defer os.close(dir)
	absolute := strings.clone(os.name(dir))
	entries := list_entries(dir, absolute) or_return
	if b.path != absolute {
		// Keep the current choice even if this folder used the default sort.
		sort_remember(b, persist = false)
		search_reset(b)
		b.header.copied_until = 0
		b.drag = {}
		b.scroll_x = 0
	}
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
	browser_sort_entries(b)
	browser_message(b, "")
	browser_filter(b)
	storage_path(b.storage, b.path)
	watch_sync(b, refresh = true)
	return nil
}

browser_filter :: proc(b: ^Browser, reset_selection := true) {
	b.selection_drag = {}
	query_runes := utf8.rune_count_in_string(b.search)
	clear(&b.visible)
	// Entries are kept in display order (browser_sort_entries), so the rows
	// read out sorted and the sort below only verifies.
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
	Sort_Data :: struct {
		browser: ^Browser,
		types:   []string,
	}
	data := Sort_Data {
		browser = b,
	}
	if b.sort_column == .Type {
		// Normalize once per entry, not on every comparison.
		data.types = make([]string, len(b.entries), context.temp_allocator)
		for source in b.visible {data.types[source] = entry_type(b.entries[source])}
	}
	slice.sort_by_with_data(b.visible[:], proc(i, j: int, data: rawptr) -> bool {
			data := cast(^Sort_Data)data
			b := data.browser
			a, z := b.entries[i], b.entries[j]
			if (a.type == .Directory) != (z.type == .Directory) {return a.type == .Directory}
			order: slice.Ordering
			switch b.sort_column {
			case .Name:
				order = slice.cmp(a.name, z.name)
			case .Size:
				order = slice.cmp(size_value(b, a), size_value(b, z))
			case .Type:
				order = slice.cmp(data.types[i], data.types[j])
			case .Modified:
				order = slice.cmp(
					time.to_unix_nanoseconds(a.modification_time),
					time.to_unix_nanoseconds(z.modification_time),
				)
			}
			if order != .Equal {return (order == .Less) != b.descending}
			return a.name < z.name
		}, &data)
	for source, i in b.visible {
		if source == selected_source {b.selected = i; break}
	}
	b.anchor = b.selected
}

// Sort the listing itself, before any selection marks exist. Rows then read
// out in order, so browser_filter never pays a fresh index sort.
browser_sort_entries :: proc(b: ^Browser) {
	Sort_Data :: struct {
		browser: ^Browser,
		types:   []string,
	}
	data := Sort_Data {
		browser = b,
	}
	if b.sort_column == .Type {
		data.types = make([]string, len(b.entries), context.temp_allocator)
		for source in 0 ..< len(b.entries) {data.types[source] = entry_type(b.entries[source])}
	}
	order := make([]int, len(b.entries), context.temp_allocator)
	for i in 0 ..< len(order) {order[i] = i}
	slice.sort_by_with_data(order, proc(i, j: int, data: rawptr) -> bool {
			data := cast(^Sort_Data)data
			b := data.browser
			a, z := b.entries[i], b.entries[j]
			if (a.type == .Directory) != (z.type == .Directory) {return a.type == .Directory}
			order: slice.Ordering
			switch b.sort_column {
			case .Name:
				order = slice.cmp(a.name, z.name)
			case .Size:
				order = slice.cmp(size_value(b, a), size_value(b, z))
			case .Type:
				order = slice.cmp(data.types[i], data.types[j])
			case .Modified:
				order = slice.cmp(
					time.to_unix_nanoseconds(a.modification_time),
					time.to_unix_nanoseconds(z.modification_time),
				)
			}
			if order != .Equal {return (order == .Less) != b.descending}
			return a.name < z.name
		}, &data)
	move := make([]os.File_Info, len(b.entries))
	defer delete(move)
	for i in 0 ..< len(order) {move[i] = b.entries[order[i]]}
	copy(b.entries, move[:])
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

@(rodata)
FILE_TYPE_LABELS := [os.File_Type]string {
	.Undetermined     = "unknown",
	.Regular          = "file",
	.Directory        = "folder",
	.Symlink          = "symlink",
	.Named_Pipe       = "pipe",
	.Socket           = "socket",
	.Block_Device     = "block device",
	.Character_Device = "character device",
}

// Lowercase extensions use the temporary allocator. No file reads are needed.
entry_type :: proc(entry: os.File_Info) -> string {
	if entry.type == .Regular {
		ext := os.ext(entry.name)
		if len(ext) > 1 && len(ext) < len(entry.name) {
			return strings.to_lower(ext[1:], context.temp_allocator)
		}
	}
	return FILE_TYPE_LABELS[entry.type]
}

// These labels borrow the temporary allocator and must not be retained.
format_size :: proc(bytes: i64) -> string {
	if bytes < 1024 {return fmt.tprintf("%d B", bytes)}
	value := f64(bytes)
	units := [?]string{"KiB", "MiB", "GiB", "TiB", "PiB", "EiB"}
	for unit, i in units {
		value /= 1024
		if value < 1024 || i == len(units) - 1 {return fmt.tprintf("%.1f %s", value, unit)}
	}
	unreachable()
}

browser_summary :: proc(b: ^Browser) -> string {
	noun := "items"
	if len(b.visible) == 1 {noun = "item"}
	total := fmt.tprintf("%d %s", len(b.visible), noun)
	if len(b.visible) == 0 || len(b.marks) == 0 {return total}
	if len(b.marks) != 1 {
		bytes := b.marked_bytes
		complete := true
		for source in b.marks {
			entry := b.entries[source]
			if entry.type != .Directory {continue}
			size := b.path == TRASH_PATH ? -1 : size_value(b, entry)
			if size < 0 {complete = false} else {bytes += size}
		}
		return fmt.tprintf(
			"%s    selected: %d items (%s%s)",
			total,
			len(b.marks),
			complete ? "" : "at least ",
			format_size(bytes),
		)
	}
	entry := b.entries[selection_sole(b)]
	detail := "special file"
	#partial switch entry.type {
	case .Regular:
		detail = format_size(entry.size)
	case .Directory:
		detail = "folder"
		if size := size_value(b, entry); size >= 0 {detail = format_size(size)}
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

stat_file_type :: proc(mode: linux.Mode) -> os.File_Type {
	switch mode & linux.S_IFMT {
	case linux.S_IFBLK:
		return .Block_Device
	case linux.S_IFCHR:
		return .Character_Device
	case linux.S_IFDIR:
		return .Directory
	case linux.S_IFIFO:
		return .Named_Pipe
	case linux.S_IFLNK:
		return .Symlink
	case linux.S_IFREG:
		return .Regular
	case linux.S_IFSOCK:
		return .Socket
	}
	return .Undetermined
}

// One getdents pass and one fstatat per entry. core:os's directory iterator
// pays an O_PATH open, a statx, and a /proc readlink per entry, which measured
// six times slower on a 100k folder.
list_entries :: proc(dir: ^os.File, folder: string) -> (entries: []os.File_Info, err: os.Error) {
	fd := linux.Fd(os.fd(dir))
	buffer := make([]u8, 64 * 1024)
	defer delete(buffer)
	prefix := strings.concatenate({folder == "/" ? "" : folder, "/"})
	defer delete(prefix)
	out := make([dynamic]os.File_Info, 0, 256)
	for {
		n, read_err := linux.getdents(fd, buffer)
		if read_err == linux.Errno.EINTR {continue}
		if read_err != .NONE {
			for &info in out {os.file_info_delete(info, context.allocator)}
			delete(out)
			return nil, read_err
		}
		if n == 0 {break}
		offset := 0
		for d in linux.dirent_iterate_buf(buffer[:n], &offset) {
			name := linux.dirent_name(d)
			if name == "." || name == ".." {continue}
			st: linux.Stat
			// Entries that vanish mid-scan are skipped, not failures.
			if linux.fstatat(fd, cstring(raw_data(name)), &st, {.SYMLINK_NOFOLLOW}) !=
			   .NONE {continue}
			fullpath := strings.concatenate({prefix, name})
			append(
				&out,
				os.File_Info {
					fullpath          = fullpath,
					// core:os owns only fullpath; name aliases it (file_info_delete).
					name              = fullpath[len(prefix):],
					inode             = u128(u64(st.ino)),
					device            = u64(st.dev),
					size              = i64(st.size),
					mode              = transmute(os.Permissions)(0o7777 & transmute(u32)st.mode),
					type              = stat_file_type(st.mode),
					modification_time = time.Time {
						i64(st.mtime.time_sec) * i64(time.Second) + i64(st.mtime.time_nsec),
					},
				},
			)
		}
	}
	entries = out[:]
	return
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
	// Going to an ancestor selects the child folder we came from.
	if path_contains(b.path, previous.path) {
		relative := strings.trim_left(strings.trim_prefix(previous.path, b.path), "/")
		child, _ := strings.split_by_byte_iterator(&relative, '/')
		browser_restore_location(b, {selected_name = child})
	}
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
