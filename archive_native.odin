package main

import "core:c"

// Small Linux ABI binding. libarchive owns these opaque objects and entries.
Archive_Handle :: struct {}
Archive_Entry :: struct {}
Archive_Read_Callback :: #type proc "c" (a: ^Archive_Handle, data: rawptr, buffer: ^rawptr) -> int
Archive_Seek_Callback :: #type proc "c" (
	a: ^Archive_Handle,
	data: rawptr,
	offset: i64,
	whence: c.int,
) -> i64
Archive_Write_Callback :: #type proc "c" (
	a: ^Archive_Handle,
	data, buffer: rawptr,
	length: uintptr,
) -> int
Archive_Password_Callback :: #type proc "c" (a: ^Archive_Handle, data: rawptr) -> cstring
Archive_IO_Callback :: #type proc "c" (a: ^Archive_Handle, data: rawptr) -> c.int

foreign import archive_lib "system:archive"
foreign import archive_locale_lib "system:c"

// LC_CTYPE_MASK is 1 on Linux. Locale changes apply only to this worker.
foreign archive_locale_lib {
	@(link_name = "newlocale")
	archive_newlocale :: proc(mask: c.int, name: cstring, base: rawptr) -> rawptr ---
	@(link_name = "uselocale")
	archive_uselocale :: proc(locale: rawptr) -> rawptr ---
	@(link_name = "freelocale")
	archive_freelocale :: proc(locale: rawptr) ---
}
foreign archive_lib {
	archive_read_new :: proc() -> ^Archive_Handle ---
	archive_read_free :: proc(a: ^Archive_Handle) -> c.int ---
	archive_read_support_filter_by_code :: proc(a: ^Archive_Handle, code: c.int) -> c.int ---
	archive_read_support_format_by_code :: proc(a: ^Archive_Handle, code: c.int) -> c.int ---
	archive_read_set_seek_callback :: proc(a: ^Archive_Handle, callback: Archive_Seek_Callback) -> c.int ---
	archive_read_open :: proc(a: ^Archive_Handle, data: rawptr, open: Archive_IO_Callback, read: Archive_Read_Callback, close: Archive_IO_Callback) -> c.int ---
	archive_read_next_header :: proc(a: ^Archive_Handle, entry: ^^Archive_Entry) -> c.int ---
	archive_read_data_block :: proc(a: ^Archive_Handle, data: ^rawptr, size: ^uintptr, offset: ^i64) -> c.int ---
	archive_read_data_skip :: proc(a: ^Archive_Handle) -> c.int ---
	archive_read_add_passphrase :: proc(a: ^Archive_Handle, password: cstring) -> c.int ---
	archive_read_set_passphrase_callback :: proc(a: ^Archive_Handle, data: rawptr, callback: Archive_Password_Callback) -> c.int ---
	archive_write_new :: proc() -> ^Archive_Handle ---
	archive_write_free :: proc(a: ^Archive_Handle) -> c.int ---
	archive_write_fail :: proc(a: ^Archive_Handle) -> c.int ---
	archive_write_set_format_by_name :: proc(a: ^Archive_Handle, name: cstring) -> c.int ---
	archive_write_add_filter_zstd :: proc(a: ^Archive_Handle) -> c.int ---
	archive_write_set_format_option :: proc(a: ^Archive_Handle, module, option, value: cstring) -> c.int ---
	archive_write_set_filter_option :: proc(a: ^Archive_Handle, module, option, value: cstring) -> c.int ---
	archive_write_set_bytes_in_last_block :: proc(a: ^Archive_Handle, size: c.int) -> c.int ---
	archive_write_open2 :: proc(a: ^Archive_Handle, data: rawptr, open: Archive_IO_Callback, write: Archive_Write_Callback, close, free: Archive_IO_Callback) -> c.int ---
	archive_write_open_memory :: proc(a: ^Archive_Handle, data: rawptr, size: uintptr, used: ^uintptr) -> c.int ---
	archive_write_set_passphrase :: proc(a: ^Archive_Handle, password: cstring) -> c.int ---
	archive_write_header :: proc(a: ^Archive_Handle, entry: ^Archive_Entry) -> c.int ---
	archive_write_data :: proc(a: ^Archive_Handle, data: rawptr, size: uintptr) -> int ---
	archive_write_finish_entry :: proc(a: ^Archive_Handle) -> c.int ---
	archive_write_close :: proc(a: ^Archive_Handle) -> c.int ---
	archive_filter_bytes :: proc(a: ^Archive_Handle, filter: c.int) -> i64 ---
	archive_error_string :: proc(a: ^Archive_Handle) -> cstring ---
	archive_entry_new :: proc() -> ^Archive_Entry ---
	archive_entry_free :: proc(entry: ^Archive_Entry) ---
	archive_entry_pathname :: proc(entry: ^Archive_Entry) -> cstring ---
	archive_entry_filetype :: proc(entry: ^Archive_Entry) -> c.uint ---
	archive_entry_perm :: proc(entry: ^Archive_Entry) -> c.uint ---
	archive_entry_size :: proc(entry: ^Archive_Entry) -> i64 ---
	archive_entry_size_is_set :: proc(entry: ^Archive_Entry) -> c.int ---
	archive_entry_mtime :: proc(entry: ^Archive_Entry) -> i64 ---
	archive_entry_mtime_nsec :: proc(entry: ^Archive_Entry) -> c.long ---
	archive_entry_mtime_is_set :: proc(entry: ^Archive_Entry) -> c.int ---
	archive_entry_symlink :: proc(entry: ^Archive_Entry) -> cstring ---
	archive_entry_hardlink :: proc(entry: ^Archive_Entry) -> cstring ---
	archive_entry_set_pathname :: proc(entry: ^Archive_Entry, path: cstring) ---
	archive_entry_set_filetype :: proc(entry: ^Archive_Entry, kind: c.uint) ---
	archive_entry_set_perm :: proc(entry: ^Archive_Entry, mode: c.uint) ---
	archive_entry_set_size :: proc(entry: ^Archive_Entry, size: i64) ---
	archive_entry_set_mtime :: proc(entry: ^Archive_Entry, seconds: i64, nanos: c.long) ---
	archive_entry_set_symlink :: proc(entry: ^Archive_Entry, link: cstring) ---
	archive_entry_set_hardlink :: proc(entry: ^Archive_Entry, link: cstring) ---
}
