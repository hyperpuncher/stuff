package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"

trash_records_destroy :: proc(records: map[string]File_Change) {
	for _, record in records {file_change_destroy(record)}
	delete(records)
}

trash_restore :: proc(change: File_Change) -> os.Error {
	file_rename_new(change.alternate, change.path) or_return
	if err := os.remove(change.trash_info); err != nil && err != .Not_Exist {
		fmt.eprintfln("cannot remove trash metadata: %v", err)
	}
	return nil
}

// Paths are URI-escaped bytes, not necessarily UTF-8. Relative local-trash paths
// must stay inside the mount root; home-trash records must use absolute paths.
trash_original_path :: proc(data, top: string, local: bool) -> (path: string, ok: bool) {
	text := data
	section := false
	for raw_line in strings.split_by_byte_iterator(&text, '\n') {
		line := strings.trim_suffix(raw_line, "\r")
		if strings.has_prefix(line, "[") {section = line == "[Trash Info]"; continue}
		if !section || !strings.has_prefix(line, "Path=") {continue}
		encoded := line[5:]
		absolute := strings.has_prefix(encoded, "/")
		if !absolute && !local {return}
		uri := absolute ? fmt.tprintf("file://%s", encoded) : fmt.tprintf("file:///%s", encoded)
		decoded, valid := file_uri_parse(uri)
		if !valid {return}
		defer delete(decoded)
		if local {
			parts := decoded
			for part in strings.split_by_byte_iterator(&parts, '/') {if part == ".." {return}}
		}
		path =
			absolute ? strings.clone(decoded) : fmt.aprintf("%s/%s", strings.trim_suffix(top, "/"), strings.trim_prefix(decoded, "/"))
		_, name := os.split_path(path)
		if name == "" ||
		   name == "." ||
		   name == ".." ||
		   local && (!path_contains(top, path) || path == top) {
			delete(path)
			return "", false
		}
		return path, true
	}
	return
}

trash_read_root :: proc(
	op: ^File_Operation,
	root, top: string,
	local, shared: bool,
	seen: ^map[[2]u64]bool,
) -> os.Error {
	trash, open_err := trash_root_open(root, shared)
	if open_err != .NONE {
		if local && (open_err == .EACCES || open_err == .EPERM) {return .Unsupported}
		return open_err
	}
	defer linux.close(trash)
	st: linux.Stat
	if err := linux.fstat(trash, &st); err != .NONE {return err}
	id := [2]u64{u64(st.dev), u64(st.ino)}
	if seen^[id] {return nil}
	seen^[id] = true
	files := trash_private_open_at(trash, "files") or_return
	dir := os.new_file(uintptr(files), fmt.tprintf("%s/files", root))
	defer os.close(dir)
	infos := trash_private_open_at(trash, "info") or_return
	defer linux.close(infos)
	it := os.read_directory_iterator_create(dir)
	defer os.read_directory_iterator_destroy(&it)
	buffer: [65536]u8
	for child in os.read_directory_iterator(&it) {
		if sync.atomic_load(&op.cancel) {break}
		meta_name := fmt.caprintf("%s.trashinfo", child.name)
		meta, meta_err := linux.openat(infos, meta_name, {.NOFOLLOW, .NONBLOCK, .CLOEXEC})
		delete(meta_name)
		if meta_err != .NONE {continue}
		meta_stat: linux.Stat
		if linux.fstat(meta, &meta_stat) != .NONE ||
		   meta_stat.uid != linux.getuid() ||
		   meta_stat.mode & linux.S_IFMT != linux.S_IFREG {
			linux.close(meta)
			continue
		}
		file := os.new_file(uintptr(meta), "trashinfo")
		n, read_err := os.read(file, buffer[:])
		os.close(file)
		if read_err != nil || n == len(buffer) {continue}
		original, valid := trash_original_path(string(buffer[:n]), top, local)
		if !valid {continue}
		info, clone_err := os.file_info_clone(child, context.allocator)
		if clone_err != nil {delete(original); continue}
		_, info.name = os.split_path(original)
		record := File_Change {
			path       = original,
			alternate  = strings.clone(info.fullpath),
			trash_info = fmt.aprintf("%s/info/%s.trashinfo", root, child.name),
			device     = info.device,
			inode      = info.inode,
		}
		op.records[record.alternate] = record
		append(&op.listed, info)
	}
	_, err := os.read_directory_iterator_error(&it)
	return err
}

Trash_Root :: struct {
	root, top:     string,
	local, shared: bool,
}

// Every trash location this user can see, including other mounted filesystems.
trash_roots :: proc(home: string, mounts: []Mount) -> [dynamic]Trash_Root {
	roots: [dynamic]Trash_Root
	for i in -1 ..< len(mounts) {
		top := i < 0 ? "/" : mounts[i].path
		for variant in 0 ..< (i < 0 ? 1 : 2) {
			root := strings.clone(home)
			if i >= 0 {
				root =
					variant == 0 ? fmt.aprintf("%s/.Trash/%d", strings.trim_suffix(top, "/"), linux.getuid()) : fmt.aprintf("%s/.Trash-%d", strings.trim_suffix(top, "/"), linux.getuid())
			}
			append(
				&roots,
				Trash_Root {
					root = root,
					top = top,
					local = i >= 0,
					shared = i >= 0 && variant == 0,
				},
			)
		}
	}
	return roots
}

trash_roots_destroy :: proc(roots: ^[dynamic]Trash_Root) {
	for root in roots {delete(root.root)}
	delete(roots^)
}

trash_view_read :: proc(op: ^File_Operation) {
	op.records = make(map[string]File_Change)
	seen := make(map[[2]u64]bool)
	defer delete(seen)
	mounts, err := mounts_read()
	if err != nil {file_operation_failed(op, TRASH_PATH, err); return}
	defer mounts_destroy(mounts)
	roots := trash_roots(op.trash_home, mounts[:])
	defer trash_roots_destroy(&roots)
	for root in roots {
		if sync.atomic_load(&op.cancel) {return}
		err = trash_read_root(op, root.root, root.top, root.local, root.shared, &seen)
		trash_root_error(op, root.root, err, root.local)
		free_all(context.temp_allocator)
	}
}

trash_view_request :: proc(b: ^Browser) -> bool {
	if b.pending_trash != nil {b.trash_requested = true; return true}
	if b.storage == nil {return false}
	op := new(File_Operation)
	op.kind, op.storage, op.allocator = .List_Trash, b.storage, context.allocator
	op.trash_home = trash_home_path()
	op.worker = thread.create_and_start_with_data(op, file_operation_worker, name = "stuff-trash")
	if op.worker == nil {file_operation_destroy(op); return false}
	b.pending_trash = op
	b.trash_requested = false
	return true
}

trash_view_apply :: proc(b: ^Browser, op: ^File_Operation) -> bool {
	if b.pending_trash != op {return false}
	b.pending_trash = nil
	if b.path != TRASH_PATH {b.trash_requested = false; return false}
	location, cursor := browser_location(b), b.selected
	defer history_entry_destroy(location)
	os.file_info_slice_delete(b.entries, context.allocator)
	trash_records_destroy(b.trash_records)
	b.entries = make([]os.File_Info, len(op.listed))
	copy(b.entries, op.listed[:])
	delete(op.listed)
	op.listed = nil
	b.trash_records, op.records = op.records, nil
	browser_filter(b)
	browser_restore_location(b, location, cursor)
	if op.error !=
	   "" {browser_message(b, fmt.tprintf("cannot read some trash locations: %s", op.error))}
	if b.trash_requested {_ = trash_view_request(b)}
	return true
}

file_restore_start :: proc(b: ^Browser) {
	if b.path != TRASH_PATH || b.pending_files != nil || b.storage == nil {return}
	paths := selection_paths(b)
	if len(paths) == 0 {file_paths_destroy(paths); return}
	op := new(File_Operation)
	op.kind, op.sources, op.target = .Restore, paths, strings.clone(TRASH_PATH)
	for path in paths {
		record := b.trash_records[path]
		append(
			&op.restores,
			File_Change {
				path = strings.clone(record.path),
				alternate = strings.clone(record.alternate),
				trash_info = strings.clone(record.trash_info),
				device = record.device,
				inode = record.inode,
			},
		)
	}
	if !file_operation_launch(b, op) {file_operation_destroy(op)}
}

trash_empty_start :: proc(b: ^Browser) {
	if b.pending_files != nil || b.pending_trash != nil || b.storage == nil {return}
	op := new(File_Operation)
	op.kind, op.target, op.trash_home = .Empty_Trash, strings.clone(TRASH_PATH), trash_home_path()
	if !file_operation_launch(b, op) {file_operation_destroy(op)}
}
