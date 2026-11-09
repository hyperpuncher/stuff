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
	kind:               enum {
		Copy,
		Trash,
	},
	sources:            [dynamic]string,
	target, trash_home: string,
	storage:            ^Storage,
	allocator:          mem.Allocator,
	worker:             ^thread.Thread,
	cancel:             bool, // Atomic. All other mutable fields belong to the worker until publication.
	completed, failed:  int,
	error:              string,
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
	delete(op.target)
	delete(op.trash_home)
	delete(op.error)
	free(op)
}

file_operation_start :: proc(b: ^Browser, trash: bool) {
	if b.pending_files != nil {return}
	if b.storage == nil {browser_message(b, "file operations are unavailable"); return}
	paths := trash ? selection_paths(b) : file_clipboard_read(b)
	if len(paths) == 0 {file_paths_destroy(paths); return}
	op := new(File_Operation)
	op.kind = trash ? .Trash : .Copy
	op.sources = paths
	op.target = strings.clone(b.path)
	op.trash_home = trash_home_path()
	op.storage, op.allocator = b.storage, context.allocator
	op.worker = thread.create_and_start_with_data(op, file_operation_worker, name = "stuff-files")
	if op.worker == nil {
		file_operation_destroy(op)
		browser_message(b, "cannot start file operation")
		return
	}
	b.pending_files = op
	browser_message(b, "")
}

file_operation_run :: proc(op: ^File_Operation) {
	buffer := make([]u8, 1024 * 1024)
	defer delete(buffer)
	mounts: [dynamic]Mount
	if op.kind == .Trash {mounts, _ = mounts_read()}
	defer mounts_destroy(mounts)
	for source in op.sources {
		if sync.atomic_load(&op.cancel) {break}
		err: os.Error
		if op.kind ==
		   .Copy {err = file_copy(op, source, buffer)} else {err = trash_file(source, op.trash_home, mounts[:])}
		if err == nil {op.completed += 1} else {
			op.failed += 1
			if op.error == "" {
				_, name := os.split_path(source)
				op.error = fmt.aprintf("%s: %s", name, os.error_string(err))
			}
		}
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
	if b.pending_files != op {return false}
	b.pending_files = nil
	// Refresh only the affected folder. Completion must not change navigation.
	if b.path == op.target {
		location := browser_location(b)
		defer history_entry_destroy(location)
		cursor := b.selected
		if err := browser_load(b, b.path); err != nil {
			browser_message(b, fmt.tprintf("cannot refresh folder: %v", err))
		} else {
			for source, i in b.visible {
				if b.entries[source].name == location.selected_name {cursor = i; break}
			}
			selection_single(b, cursor)
			b.first = min(location.first, max(0, len(b.visible) - 1))
		}
	}
	if op.failed > 0 {
		verb := op.kind == .Copy ? "copy" : "move to trash"
		browser_message(
			b,
			fmt.tprintf(
				"cannot %s %d of %d items: %s",
				verb,
				op.failed,
				len(op.sources),
				op.error,
			),
		)
	}
	storage_refresh(b.storage)
	return true
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
	#partial switch info.type {
	case .Symlink:
		link := os.read_link(source, context.allocator) or_return
		defer delete(link)
		return os.symlink(link, target)
	case .Directory:
		os.make_directory(target, os.perm(0o700)) or_return
		path_c := strings.clone_to_cstring(source)
		defer delete(path_c)
		fd, open_err := linux.open(path_c, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
		if open_err != .NONE {return open_err}
		dir := os.new_file(uintptr(fd), source)
		defer os.close(dir)
		it := os.read_directory_iterator_create(dir)
		defer os.read_directory_iterator_destroy(&it)
		for child in os.read_directory_iterator(&it) {
			_, err = os.read_directory_iterator_error(&it)
			if err != nil {return}
			destination := fmt.aprintf("%s/%s", target, child.name)
			err = file_copy_node(op, child.fullpath, destination, buffer)
			delete(destination)
			if err != nil {return}
		}
		_, err = os.read_directory_iterator_error(&it)
		if err != nil {return}
		// Keep new folders writable by their owner, including copies from read-only media.
		return os.chmod(target, info.mode | os.perm(0o700))
	case .Regular:
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
			if n > 0 {_, err = os.write(dst, buffer[:n]); if err != nil {return}}
			if read_err == io.Error.EOF || n == 0 {break}
		}
		return os.flush(dst)
	case:
		return .Unsupported
	}
}
