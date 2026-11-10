package main

import "core:os"
import "core:strings"
import "core:sync"

File_Action :: enum {
	Copy,
	Trash,
	Rename,
	New_Folder,
	Restore,
	List_Trash,
	Empty_Trash,
	Open_With,
}
File_History_Mode :: enum {
	Record,
	Undo,
	Redo,
}

File_Change :: struct {
	path, alternate, trash_info: string, // Owned paths. No filesystem data is freed with this record.
	device:                      u64,
	inode:                       u128,
}

File_Batch :: struct {
	kind:    File_Action,
	target:  string,
	changes: [dynamic]File_Change,
}

file_change_destroy :: proc(change: File_Change) {
	delete(change.path)
	delete(change.alternate)
	delete(change.trash_info)
}

file_changes_destroy :: proc(changes: [dynamic]File_Change) {
	for change in changes {file_change_destroy(change)}
	delete(changes)
}

file_history_clear :: proc(history: ^[dynamic]File_Batch) {
	for batch in history^ {delete(batch.target); file_changes_destroy(batch.changes)}
	delete(history^)
	history^ = nil
}

file_history_push :: proc(history: ^[dynamic]File_Batch, batch: File_Batch) {
	if len(batch.changes) == 0 {delete(batch.target); delete(batch.changes); return}
	if len(history^) == 32 {
		delete(history^[0].target)
		file_changes_destroy(history^[0].changes)
		ordered_remove(history, 0)
	}
	append(history, batch)
}

file_change_capture :: proc(path: string) -> (change: File_Change, err: os.Error) {
	info := os.lstat(path, context.allocator) or_return
	defer os.file_info_delete(info, context.allocator)
	return {path = strings.clone(path), device = info.device, inode = info.inode}, nil
}

file_change_check :: proc(change: File_Change, path: string) -> os.Error {
	info := os.lstat(path, context.allocator) or_return
	defer os.file_info_delete(info, context.allocator)
	if info.device != change.device || info.inode != change.inode {return .Invalid_File}
	return nil
}

file_history_run :: proc(op: ^File_Operation) {
	to_trash :=
		(op.kind == .Copy || op.kind == .New_Folder || op.kind == .Restore) &&
			op.history == .Undo ||
		op.kind == .Trash && op.history == .Redo
	mounts: [dynamic]Mount
	if to_trash {
		mount_error: os.Error
		mounts, mount_error = mounts_read()
		if mount_error !=
		   nil {op.failed = len(op.changes); op.error = strings.clone(os.error_string(mount_error)); return}
	}
	defer mounts_destroy(mounts)
	changes := op.changes
	op.changes = nil
	defer delete(changes)
	#reverse for current in changes {
		change := current
		if sync.atomic_load(&op.cancel) {append(&op.changes, change); continue}
		from :=
			to_trash || op.kind == .Rename && op.history == .Redo ? change.path : change.alternate
		err := file_change_check(change, from)
		if err == nil {
			if to_trash {
				next: File_Change
				err = trash_file(from, op.trash_home, mounts[:], &next)
				if err == nil {file_change_destroy(change); change = next}
			} else {
				target :=
					op.kind == .Rename && op.history == .Redo ? change.alternate : change.path
				if op.kind ==
				   .Rename {err = file_rename_new(from, target)} else {err = trash_restore(change)}
				if err == nil &&
				   op.kind != .Rename {delete(change.trash_info); change.trash_info = ""}
			}
		}
		if err !=
		   nil {file_operation_failed(op, change.path, err); append(&op.changes, change)} else {append(&op.applied, change)}
		free_all(context.temp_allocator)
	}
}

file_history_apply :: proc(b: ^Browser, op: ^File_Operation) {
	if op.history == .Record {
		if len(op.changes) == 0 {return}
		file_history_clear(&b.redo_files)
		file_history_push(&b.undo_files, {op.kind, strings.clone(op.target), op.changes})
		op.changes = nil
		return
	}
	from, to := &b.undo_files, &b.redo_files
	if op.history == .Redo {from, to = to, from}
	// Partial success stays reversible. Failed items remain on their original stack.
	file_history_push(from, {op.kind, strings.clone(op.target), op.changes})
	file_history_push(to, {op.kind, strings.clone(op.target), op.applied})
	op.changes, op.applied = nil, nil
}

file_history_start :: proc(b: ^Browser, redo: bool) {
	if b.pending_files != nil {return}
	if b.storage == nil {browser_message(b, "file operations are unavailable"); return}
	from := &b.undo_files
	if redo {from = &b.redo_files}
	if len(from^) == 0 {return}
	batch := pop(from)
	op := new(File_Operation)
	op.kind, op.target, op.changes = batch.kind, batch.target, batch.changes
	op.history = redo ? .Redo : .Undo
	op.trash_home = trash_home_path()
	if !file_operation_launch(b, op) {
		file_history_push(from, batch)
		op.target, op.changes = "", nil
		file_operation_destroy(op)
	}
}
