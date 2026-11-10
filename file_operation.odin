package main

import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"

File_Operation :: struct {
	kind:                            File_Action,
	history:                         File_History_Mode,
	count:                           int, // Immutable after launch, including while history lists move.
	changes, applied:                [dynamic]File_Change,
	restores:                        [dynamic]File_Change,
	listed:                          [dynamic]os.File_Info,
	records:                         map[string]File_Change,
	sources:                         [dynamic]string,
	target, trash_home, destination: string,
	storage:                         ^Storage,
	allocator:                       mem.Allocator,
	worker:                          ^thread.Thread,
	cancel:                          bool, // Atomic. All other mutable fields belong to the worker until publication.
	failed:                          int,
	error:                           string,
	label:                           string, // Owned; immutable after launch.
	progress:                        File_Progress,
	progress_due:                    u64,
}

file_operation_stop :: proc(op: ^File_Operation) {
	if op == nil || op.worker == nil {return}
	sync.atomic_store(&op.cancel, true)
	thread.destroy(op.worker)
	op.worker = nil
}

file_operation_destroy :: proc(op: ^File_Operation) {
	if op == nil {return}
	file_operation_stop(op)
	file_paths_destroy(op.sources)
	file_changes_destroy(op.changes)
	file_changes_destroy(op.applied)
	file_changes_destroy(op.restores)
	for info in op.listed {os.file_info_delete(info, context.allocator)}
	delete(op.listed)
	trash_records_destroy(op.records)
	delete(op.target)
	delete(op.destination)
	delete(op.trash_home)
	delete(op.error)
	delete(op.label)
	free(op)
}

file_operation_start :: proc(b: ^Browser, trash: bool) {
	if b.path == TRASH_PATH || trash && len(b.transfers) > 0 {return}
	if b.storage == nil {browser_message(b, "file operations are unavailable"); return}
	paths := trash ? selection_paths(b) : file_clipboard_read(b)
	if len(paths) == 0 {file_paths_destroy(paths); return}
	op := new(File_Operation)
	op.kind = trash ? .Trash : .Copy
	op.sources = paths
	op.target = strings.clone(b.path)
	if trash {op.trash_home = trash_home_path()}
	if !file_operation_launch(b, op) {file_operation_destroy(op)}
}

file_operation_launch :: proc(b: ^Browser, op: ^File_Operation) -> bool {
	for job in b.transfers {
		if op.kind != .Copy ||
		   op.history != .Record ||
		   job.op.kind != .Copy ||
		   job.op.history != .Record {
			browser_message(b, "another file operation is running")
			return false
		}
	}
	op.storage, op.allocator = b.storage, context.allocator
	op.count = len(op.sources) + len(op.changes)
	path := op.destination
	if len(op.sources) > 0 && op.kind != .New_Folder {path = op.sources[0]}
	if len(op.changes) > 0 {path = op.changes[0].path}
	_, name := os.split_path(path)
	if name == "" {name = path}
	if op.count == 1 {op.label = strings.clone(name)} else if op.count > 1 {
		op.label = fmt.aprintf("%d %s", op.count, op.kind == .Copy ? "files" : "items")
	} else {op.label = strings.clone("trash")}
	op.progress.total = u64(op.count)
	if op.kind == .Copy && op.history == .Record {op.progress.phase = .Preparing}
	if op.kind == .Open_With {op.progress.total = 0}
	initial := op.progress
	op.worker = thread.create_and_start_with_data(op, file_operation_worker, name = "stuff-files")
	if op.worker == nil {browser_message(b, "cannot start file operation"); return false}
	append(&b.transfers, File_Transfer{op = op, progress = initial})
	browser_message(b, "")
	return true
}

file_operation_failed :: proc(op: ^File_Operation, path: string, err: os.Error) {
	op.failed += 1
	if op.error != "" {return}
	_, name := os.split_path(path)
	op.error = fmt.aprintf("%s: %s", name, os.error_string(err))
}

file_operation_run :: proc(op: ^File_Operation) {
	if sync.atomic_load(&op.cancel) {return}
	if op.kind == .List_Trash {trash_view_read(op); return}
	if op.kind == .Empty_Trash {trash_empty_run(op); return}
	if op.kind ==
	   .Open_With {op.error = open_with_run(op); if op.error != "" {op.failed = 1}; return}
	if op.history != .Record {file_history_run(op); return}
	if op.kind == .Copy {
		dir, err := directory_open(op.target)
		if err != nil {
			op.failed = len(op.sources)
			op.error = fmt.aprintf("%s: %s", op.target, os.error_string(err))
			return
		}
		defer os.close(dir)
		delete(op.target)
		op.target = strings.clone(os.name(dir))
		// Count the same tree that will be copied, without following links or
		// creating destinations. The copy pass reports errors if a source changes.
		op.progress = {
			phase = .Preparing,
		}
		for source in op.sources {
			if sync.atomic_load(&op.cancel) {return}
			_ = file_copy(op, source, nil)
			op.progress.total += 1 // Publishing this top-level item.
			free_all(context.temp_allocator)
		}
		if sync.atomic_load(&op.cancel) {return}
		op.progress.phase = .Working
		file_progress_publish(op, force = true)
	}
	buffer: []u8
	if op.kind == .Copy {buffer = make([]u8, 1024 * 1024)}
	defer delete(buffer)
	mounts: [dynamic]Mount
	if op.kind == .Trash {mounts, _ = mounts_read()}
	defer mounts_destroy(mounts)
	for source, index in op.sources {
		if sync.atomic_load(&op.cancel) {break}
		defer file_progress_advance(op)
		err: os.Error
		if op.kind == .Restore {
			record := op.restores[index]
			err = file_change_check(record, source)
			if err == nil {err = trash_restore(record)}
			if err ==
			   nil {append(&op.changes, File_Change{path = strings.clone(record.path), device = record.device, inode = record.inode})}
			if err != nil {file_operation_failed(op, record.path, err)}
			continue
		}
		if op.kind ==
		   .Copy {err = file_copy(op, source, buffer)} else if op.kind == .Rename || op.kind == .New_Folder {
			if op.kind ==
			   .Rename {err = file_rename_new(source, op.destination)} else {err = os.make_directory(op.destination)}
			if err == nil {
				change: File_Change
				change, err = file_change_capture(op.destination)
				if err == nil {
					if op.kind ==
					   .Rename {delete(change.path); change.path = strings.clone(source); change.alternate = strings.clone(op.destination)}
					append(&op.changes, change)
				}
			}
		} else {
			change: File_Change
			err = trash_file(source, op.trash_home, mounts[:], &change)
			if err == nil {append(&op.changes, change)}
		}
		if err != nil && !sync.atomic_load(&op.cancel) {file_operation_failed(op, source, err)}
		free_all(context.temp_allocator)
	}
}

file_operation_worker :: proc(data: rawptr) {
	op := cast(^File_Operation)data
	context.allocator = op.allocator
	file_operation_run(op)
	storage_publish(op.storage, {kind = .Files, files = op})
}

file_operation_apply :: proc(b: ^Browser, op: ^File_Operation) -> bool {
	if op.kind == .List_Trash {return trash_view_apply(b, op)}
	index := -1
	for job, i in b.transfers {if job.op == op {index = i; break}}
	if index < 0 {return false}
	ordered_remove(&b.transfers, index)
	if index < b.transfer_first {b.transfer_first -= 1}
	cancelled := sync.atomic_load(&op.cancel)
	if op.kind == .Open_With {
		if cancelled {browser_message(b, "operation cancelled")} else if op.error != "" {browser_message(b, op.error)}
		return true
	}
	if op.kind == .Empty_Trash {size_cache_clear(b)} else {
		size_cancel(b)
		size_cache_invalidate(b, op.target, descendants = false)
		size_cache_invalidate(b, op.destination)
	}
	renamed_target := ""
	if op.kind == .Rename && len(b.visible) > 0 {
		changes := op.history == .Record ? op.changes : op.applied
		for change in changes {
			from, to := change.path, change.alternate
			if op.history == .Undo {from, to = to, from}
			if b.entries[b.visible[b.selected]].fullpath == from {renamed_target = to; break}
		}
	}
	refresh := b.path == op.target
	for changes in ([?][dynamic]File_Change{op.changes, op.applied}) {
		for change in changes {
			size_cache_invalidate(b, change.path)
			size_cache_invalidate(b, change.alternate)
			parent, _ := os.split_path(change.path)
			if strings.trim_suffix(parent, "/") ==
			   strings.trim_suffix(b.path, "/") {refresh = true}
		}
	}
	file_history_apply(b, op)
	// Refresh only the affected folder. Completion must not change navigation.
	if b.path == TRASH_PATH {_ = trash_view_request(b)} else if refresh {
		location := browser_location(b)
		selected_target := renamed_target
		if op.failed == 0 && b.header.edit.waiting == op {selected_target = op.destination}
		if selected_target != "" {
			delete(location.selected_name)
			_, name := os.split_path(selected_target)
			location.selected_name = strings.clone(name)
		}
		defer history_entry_destroy(location)
		cursor := b.selected
		if err := browser_load(b, b.path); err != nil {
			browser_message(b, fmt.tprintf("cannot refresh folder: %v", err))
		} else {browser_restore_location(b, location, cursor)}
	}
	if cancelled {browser_message(b, "operation cancelled")}
	if op.kind == .Empty_Trash {
		if op.failed > 0 {browser_message(b, fmt.tprintf("cannot empty trash: %s", op.error))}
		return true
	}
	if op.failed > 0 {
		verb :=
			op.kind == .Copy ? "copy" : op.kind == .Rename ? "rename" : op.kind == .New_Folder ? "create folder" : op.kind == .Restore ? "restore" : "move to trash"
		if op.history != .Record {verb = op.history == .Undo ? "undo" : "redo"}
		browser_message(
			b,
			fmt.tprintf(
				"cannot %s %d of %d items: %s",
				verb,
				op.failed,
				op.history == .Record ? len(op.sources) : op.count,
				op.error,
			),
		)
	}
	if b.header.edit.waiting == op {
		b.header.edit.waiting = nil
		if op.failed == 0 {path_edit_end(&b.header.edit)}
	}
	storage_refresh(b.storage)
	return true
}

// One directory-only open also provides its canonical path through os.name.
// O_DIRECTORY rejects pipes and devices without opening them for data.
directory_open :: proc(
	path: string,
	flags: linux.Open_Flags = {},
) -> (
	file: ^os.File,
	err: os.Error,
) {
	path_c := strings.clone_to_cstring(path, context.temp_allocator)
	fd, open_err := linux.open(path_c, flags | {.DIRECTORY, .NONBLOCK, .CLOEXEC})
	if open_err != .NONE {return nil, open_err}
	return os.new_file(uintptr(fd), path), nil
}

file_rename_new :: proc(source, target: string) -> os.Error {
	a, z := strings.clone_to_cstring(source), strings.clone_to_cstring(target)
	defer delete(a)
	defer delete(z)
	err := linux.renameat2(linux.AT_FDCWD, a, linux.AT_FDCWD, z, {.NOREPLACE})
	return err
}

file_copy :: proc(op: ^File_Operation, source: string, buffer: []u8) -> os.Error {
	info := os.lstat(source, context.allocator) or_return
	defer os.file_info_delete(info, context.allocator)
	if info.type == .Directory {
		absolute := os.get_absolute_path(source, context.allocator) or_return
		defer delete(absolute)
		if path_contains(absolute, op.target) {return .Invalid_Path}
	}
	if op.progress.phase == .Preparing {return file_copy_node(op, source, "", nil)}
	// Build privately, then publish with a no-replace rename. Failed copies never
	// merge into existing folders or leave a partial file under its final name.
	stage := os.make_directory_temp(op.target, ".stuff-copy-", context.allocator) or_return
	defer delete(stage)
	defer os.remove_all(stage)
	payload := fmt.aprintf("%s/item", stage)
	defer delete(payload)
	file_copy_node(op, source, payload, buffer) or_return
	_, name := os.split_path(source)
	if name == "" || name == "." || name == ".." {return .Invalid_Path}
	stem, ext := name, ""
	if info.type == .Regular {
		if dot := strings.last_index_byte(name, '.'); dot > 0 {stem, ext = name[:dot], name[dot:]}
	}
	for i := 0;; i += 1 {
		if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
		base := name
		if i == 1 {base = fmt.tprintf("%s (copy)%s", stem, ext)}
		if i > 1 {base = fmt.tprintf("%s (copy %d)%s", stem, i, ext)}
		target := fmt.aprintf("%s/%s", op.target, base)
		err := file_rename_new(payload, target)
		if err == nil {
			change, stat_err := file_change_capture(target)
			if stat_err == nil {append(&op.changes, change)}
			err = stat_err
		}
		delete(target)
		if err == linux.Errno.EEXIST {continue}
		return err
	}
}

file_copy_node :: proc(
	op: ^File_Operation,
	source, target: string,
	buffer: []u8,
) -> (
	err: os.Error,
) {
	if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
	info := os.lstat(source, context.allocator) or_return
	defer os.file_info_delete(info, context.allocator)
	preparing := op.progress.phase == .Preparing
	// One unit per node also gives empty files, folders, and links progress.
	if preparing {op.progress.total += 1} else {op.progress.done += 1}
	defer file_progress_publish(op)
	#partial switch info.type {
	case .Symlink:
		if preparing {return nil}
		link := os.read_link(source, context.allocator) or_return
		defer delete(link)
		return os.symlink(link, target)
	case .Directory:
		if !preparing {os.make_directory(target, os.perm(0o700)) or_return}
		dir := directory_open(source, {.NOFOLLOW}) or_return
		defer os.close(dir)
		it := os.read_directory_iterator_create(dir)
		defer os.read_directory_iterator_destroy(&it)
		for child in os.read_directory_iterator(&it) {
			_, err = os.read_directory_iterator_error(&it)
			if err != nil {return}
			destination := ""
			if !preparing {destination = fmt.aprintf("%s/%s", target, child.name)}
			err = file_copy_node(op, child.fullpath, destination, buffer)
			delete(destination)
			if err != nil {return}
		}
		_, err = os.read_directory_iterator_error(&it)
		if err != nil {return}
		if preparing {return nil}
		// Keep new folders writable by their owner, including copies from read-only media.
		return os.chmod(target, info.mode | os.perm(0o700))
	case .Regular:
		if preparing {op.progress.total += u64(max(0, info.size)); return nil}
		path_c := strings.clone_to_cstring(source)
		defer delete(path_c)
		fd, open_err := linux.open(path_c, {.NOFOLLOW, .NONBLOCK, .CLOEXEC})
		if open_err != .NONE {return open_err}
		src := os.new_file(uintptr(fd), source)
		defer os.close(src)
		actual := os.fstat(src, context.allocator) or_return
		defer os.file_info_delete(actual, context.allocator)
		if actual.type != .Regular {return .Invalid_File}
		dst := os.open(target, {.Write, .Create, .Excl}, actual.mode) or_return
		defer os.close(dst)
		for {
			if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
			n, read_err := os.read(src, buffer)
			if read_err == linux.Errno.EINTR {continue}
			if read_err != nil && read_err != io.Error.EOF {return read_err}
			if n > 0 {
				written: int
				written, err = os.write(dst, buffer[:n])
				op.progress.done += u64(written)
				file_progress_publish(op)
				if err != nil {return}
			}
			if read_err == io.Error.EOF || n == 0 {break}
		}
		return os.flush(dst)
	case:
		return .Unsupported
	}
}
