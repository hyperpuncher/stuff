package main

import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"

// Empty every trash root this user can see. Files without a .trashinfo record
// are removed too, because they are trash even when the view cannot list them.
trash_empty_run :: proc(op: ^File_Operation) {
	roots, err := trash_roots_all(op.trash_home)
	if err != nil {file_operation_failed(op, TRASH_PATH, err); return}
	defer trash_roots_destroy(&roots)
	for root in roots {
		if sync.atomic_load(&op.cancel) {return}
		err = trash_empty_root(op, root.root, root.shared, root.local)
		trash_root_error(op, root.root, err, root.local)
		free_all(context.temp_allocator)
	}
}

trash_empty_root :: proc(
	op: ^File_Operation,
	root: string,
	shared: bool,
	local := false,
) -> os.Error {
	trash := trash_root_open(root, shared, local) or_return
	defer linux.close(trash)
	files := private_dir_open_at(trash, "files") or_return
	// Invalidate this tree even if deletion later fails or is cancelled.
	append(&op.applied, File_Change{path = strings.clone(root)})
	if err := trash_remove_children(op, files); err != nil {return err}
	infos, info_err := private_dir_open_at(trash, "info")
	if info_err == .NONE {
		if err := trash_remove_children(op, infos); err != nil {return err}
	} else if info_err != linux.Errno.ENOENT && info_err != .Not_Exist {
		return info_err
	}
	name := strings.clone_to_cstring("directorysizes")
	defer delete(name)
	_ = linux.unlinkat(trash, name, {})
	return nil
}

// Takes ownership of dir.
trash_remove_children :: proc(op: ^File_Operation, dir: linux.Fd) -> os.Error {
	file := os.new_file(uintptr(dir), "trash")
	defer os.close(file)
	it := os.read_directory_iterator_create(file)
	defer os.read_directory_iterator_destroy(&it)
	for entry in os.read_directory_iterator(&it) {
		if sync.atomic_load(&op.cancel) {return nil}
		name := strings.clone_to_cstring(entry.name, context.temp_allocator)
		if err := trash_remove_entry(op, dir, name); err != nil {
			file_operation_failed(op, string(entry.name), err)
		}
	}
	_, err := os.read_directory_iterator_error(&it)
	return err
}

trash_remove_entry :: proc(op: ^File_Operation, parent: linux.Fd, name: cstring) -> os.Error {
	st: linux.Stat
	if err := linux.fstatat(parent, name, &st, {.SYMLINK_NOFOLLOW}); err != .NONE {
		return err
	}
	if linux.S_ISDIR(st.mode) {
		child, open_err := linux.openat(parent, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
		if open_err != .NONE {return open_err}
		if err := trash_remove_children(op, child); err != nil {return err}
		if err := linux.unlinkat(parent, name, {.REMOVEDIR}); err != .NONE && err != .ENOTEMPTY {
			return err
		}
		return nil
	}
	// A symlink is unlinked as a link; its target is never touched.
	return linux.unlinkat(parent, name, {})
}
