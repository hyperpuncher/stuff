package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:time"

Archive_Format :: enum {
	Zip,
	Seven_Zip,
	Tar_Zstd,
}
@(rodata)
ARCHIVE_SUFFIX := [Archive_Format]string {
	.Zip       = ".zip",
	.Seven_Zip = ".7z",
	.Tar_Zstd  = ".tar.zst",
}

Archive_Request :: struct {
	source, target: string,
} // Owned; password retries retain the original destination.
Archive_IO :: struct {
	op:     ^File_Operation,
	file:   ^os.File,
	buffer: [64 * 1024]u8,
}
Archive_Metadata :: struct {
	path:    string,
	mode:    os.Permissions,
	seconds: i64,
	nanos:   uint,
}
Archive_Link :: struct {
	path, target: string,
	symbolic:     bool,
}

archive_has_suffix :: proc(name, suffix: string) -> bool {
	return len(name) >= len(suffix) && strings.equal_fold(name[len(name) - len(suffix):], suffix)
}

// Compression and container suffixes that stuff can extract.
@(rodata)
ARCHIVE_SUFFIXES := [?]string {
	".tar.zst",
	".tar.gz",
	".tar.bz2",
	".tar.xz",
	".zip",
	".7z",
	".tar",
	".tgz",
	".tzst",
	".tbz2",
	".txz",
	".rar",
	".cab",
	".cpio",
	".lha",
	".lzh",
	".xar",
}

archive_stem :: proc(name: string) -> (stem: string, recognized: bool) {
	for suffix in ARCHIVE_SUFFIXES {
		if archive_has_suffix(name, suffix) {return name[:len(name) - len(suffix)], true}
	}
	return name, false
}

archive_reject :: proc(op: ^File_Operation, message: string) -> os.Error {
	if op.error == "" {op.error = strings.clone(message)}
	return .Invalid_File
}

archive_check :: proc(op: ^File_Operation, a: ^Archive_Handle, result: c.int) -> os.Error {
	if result == 0 {return nil}
	message := archive_error_string(a)
	return archive_reject(op, message != nil ? string(message) : "archive operation failed")
}

archive_secret_destroy :: proc(secret: string) {
	if secret != "" {mem.zero_slice(raw_data(secret)[:len(secret)])}
	delete(secret)
}

archive_read_callback :: proc "c" (a: ^Archive_Handle, data: rawptr, buffer: ^rawptr) -> int {
	context = runtime.default_context()
	input := cast(^Archive_IO)data
	context.allocator = input.op.allocator
	if sync.atomic_load(&input.op.cancel) {return -1}
	for {
		n, err := os.read(input.file, input.buffer[:])
		if err == linux.Errno.EINTR {continue}
		if err != nil &&
		   err != io.Error.EOF {_ = archive_reject(input.op, os.error_string(err)); return -1}
		buffer^ = raw_data(input.buffer[:])
		return n
	}
}

archive_seek_callback :: proc "c" (
	a: ^Archive_Handle,
	data: rawptr,
	offset: i64,
	whence: c.int,
) -> i64 {
	context = runtime.default_context()
	input := cast(^Archive_IO)data
	if sync.atomic_load(&input.op.cancel) {return -30}
	position, err := os.seek(input.file, offset, io.Seek_From(whence))
	return err == nil ? position : -25
}

archive_write_callback :: proc "c" (
	a: ^Archive_Handle,
	data, buffer: rawptr,
	length: uintptr,
) -> int {
	context = runtime.default_context()
	output := cast(^Archive_IO)data
	context.allocator = output.op.allocator
	if sync.atomic_load(&output.op.cancel) {return -1}
	n, err := os.write(output.file, (cast([^]u8)buffer)[:int(length)])
	if err != nil {_ = archive_reject(output.op, os.error_string(err)); return -1}
	return n
}

archive_password_callback :: proc "c" (a: ^Archive_Handle, data: rawptr) -> cstring {
	context = runtime.default_context()
	op := cast(^File_Operation)data
	op.archive_needs_password = true
	return nil // End this attempt. The UI can retry without keeping a worker blocked.
}

archive_reader_setup :: proc(op: ^File_Operation, a: ^Archive_Handle) -> os.Error {
	// A warning can register an external-program fallback. Probe a separate
	// handle, then register only confirmed native filters on the real reader.
	// Never open the probe or call filter_all.
	// gzip, bzip2, UNIX compress, lzma, xz, lz4, zstd.
	for code in ([?]c.int{1, 2, 3, 5, 6, 13, 14}) {
		probe := archive_read_new()
		if probe == nil {return .Invalid_File}
		native := archive_read_support_filter_by_code(probe, code) == 0
		archive_read_free(probe)
		if native {archive_check(op, a, archive_read_support_filter_by_code(a, code)) or_return}
	}
	// cpio, tar, zip, ar, xar, lha, cab, rar, 7z, rar5.
	// Deliberately omit mtree, which can read paths from the host filesystem.
	for code in ([?]c.int{0x10000, 0x30000, 0x50000, 0x70000, 0xa0000, 0xb0000, 0xc0000, 0xd0000, 0xe0000, 0x100000}) {
		archive_check(op, a, archive_read_support_format_by_code(a, code)) or_return
	}
	archive_check(
		op,
		a,
		archive_read_set_passphrase_callback(a, op, archive_password_callback),
	) or_return
	if op.archive_password != "" {
		password := strings.clone_to_cstring(op.archive_password)
		defer archive_secret_destroy(string(password))
		archive_check(op, a, archive_read_add_passphrase(a, password)) or_return
	}
	return nil
}

archive_regular_open :: proc(
	path: string,
	follow: bool = false,
) -> (
	file: ^os.File,
	info: os.File_Info,
	err: os.Error,
) {
	name := strings.clone_to_cstring(path)
	defer delete(name)
	flags := linux.Open_Flags{.NONBLOCK, .CLOEXEC}
	if !follow {flags += {.NOFOLLOW}}
	fd, open_err := linux.open(name, flags)
	if open_err != .NONE {return nil, {}, open_err}
	file = os.new_file(uintptr(fd), path)
	info, err = os.fstat(file, context.allocator)
	if err != nil || info.type != .Regular {
		os.close(file)
		os.file_info_delete(info, context.allocator)
		return nil, {}, err != nil ? err : os.Error(.Invalid_File)
	}
	return file, info, nil
}

archive_create_node :: proc(
	op: ^File_Operation,
	a: ^Archive_Handle,
	source, name: string,
	buffer: []u8,
) -> os.Error {
	if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
	info := os.lstat(source, context.allocator) or_return
	defer os.file_info_delete(info, context.allocator)
	if info.type != .Regular &&
	   info.type != .Directory &&
	   info.type != .Symlink {return archive_reject(op, "special files cannot be archived")}
	file: ^os.File
	defer if file != nil {os.close(file)}
	if info.type == .Regular {
		actual: os.File_Info
		file, actual = archive_regular_open(source) or_return
		os.file_info_delete(info, context.allocator)
		info = actual
	}
	entry := archive_entry_new()
	if entry == nil {return .Invalid_File}
	defer archive_entry_free(entry)
	entry_name := strings.clone_to_cstring(name)
	defer delete(entry_name)
	archive_entry_set_pathname(entry, entry_name)
	archive_entry_set_filetype(
		entry,
		info.type == .Directory ? 0o040000 : info.type == .Symlink ? 0o120000 : 0o100000,
	)
	archive_entry_set_perm(entry, transmute(u32)info.mode & 0o777)
	stamp := time.to_unix_nanoseconds(info.modification_time)
	seconds, nanos := stamp / 1_000_000_000, stamp % 1_000_000_000
	if nanos < 0 {seconds -= 1; nanos += 1_000_000_000}
	archive_entry_set_mtime(entry, seconds, c.long(nanos))
	archive_entry_set_size(entry, info.type == .Regular ? info.size : 0)
	if info.type == .Symlink {
		link := os.read_link(source, context.allocator) or_return
		defer delete(link)
		link_c := strings.clone_to_cstring(link)
		defer delete(link_c)
		archive_entry_set_symlink(entry, link_c)
	}
	archive_check(op, a, archive_write_header(a, entry)) or_return
	if file != nil {
		remaining := info.size
		for remaining > 0 {
			if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
			n, err := os.read(file, buffer[:min(len(buffer), int(remaining))])
			if err == linux.Errno.EINTR {continue}
			if err != nil && err != io.Error.EOF {return err}
			if n == 0 {return archive_reject(op, "a source file changed while being archived")}
			written := 0
			for written < n {
				count := archive_write_data(a, raw_data(buffer[written:n]), uintptr(n - written))
				if count <= 0 {return archive_check(op, a, -30)}
				written += count
			}
			remaining -= i64(n)
			op.progress.done += u64(n)
			file_progress_publish(op)
		}
	}
	archive_check(op, a, archive_write_finish_entry(a)) or_return
	file_progress_advance(op)
	if info.type == .Directory {
		dir := directory_open(source, {.NOFOLLOW}) or_return
		defer os.close(dir)
		it := os.read_directory_iterator_create(dir)
		defer os.read_directory_iterator_destroy(&it)
		for child in os.read_directory_iterator(&it) {
			_, err := os.read_directory_iterator_error(&it)
			if err != nil {return err}
			child_name := fmt.aprintf("%s/%s", name, child.name)
			err = archive_create_node(op, a, child.fullpath, child_name, buffer)
			delete(child_name)
			if err != nil {return err}
		}
		_, err := os.read_directory_iterator_error(&it)
		if err != nil {return err}
	}
	return nil
}

archive_create :: proc(op: ^File_Operation, payload: string) -> os.Error {
	op.progress = {
		phase = .Preparing,
		total = 1,
	}
	for source in op.sources {
		_ = file_copy(op, source, nil) // Reuse the copy counting pass, without creating output.
		if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
		free_all(context.temp_allocator)
	}
	op.progress.phase = .Working
	file_progress_publish(op, force = true)
	a := archive_write_new()
	if a == nil {return .Invalid_File}
	defer archive_write_free(a)
	complete := false
	defer if !complete {archive_write_fail(a)}
	formats := [Archive_Format]cstring {
		.Zip       = "zip",
		.Seven_Zip = "7zip",
		.Tar_Zstd  = "paxr",
	}
	format := formats[op.archive_format]
	archive_check(op, a, archive_write_set_format_by_name(a, format)) or_return
	if op.archive_format == .Zip {
		archive_check(
			op,
			a,
			archive_write_set_format_option(a, "zip", "compression", "deflate"),
		) or_return
	} else if op.archive_format == .Seven_Zip {
		archive_check(
			op,
			a,
			archive_write_set_format_option(a, "7zip", "compression", "lzma2"),
		) or_return
	} else {
		archive_check(op, a, archive_write_add_filter_zstd(a)) or_return
		archive_check(
			op,
			a,
			archive_write_set_filter_option(a, "zstd", "compression-level", "3"),
		) or_return
		archive_check(op, a, archive_write_set_filter_option(a, "zstd", "threads", "2")) or_return
	}
	archive_check(op, a, archive_write_set_bytes_in_last_block(a, 1)) or_return
	file := os.open(payload, {.Write, .Create, .Excl}, os.perm(0o600)) or_return
	defer os.close(file)
	output := Archive_IO {
		op   = op,
		file = file,
	}
	archive_check(
		op,
		a,
		archive_write_open2(a, &output, nil, archive_write_callback, nil, nil),
	) or_return
	buffer := make([]u8, 1024 * 1024)
	defer delete(buffer)
	for source in op.sources {
		_, name := os.split_path(source)
		archive_create_node(op, a, source, name, buffer) or_return
		free_all(context.temp_allocator)
	}
	archive_check(op, a, archive_write_close(a)) or_return
	os.flush(file) or_return
	complete = true
	return nil
}

// Names are relative POSIX paths. Reject traversal rather than repairing it.
archive_safe_path :: proc(name: string) -> (string, bool) {
	if strings.has_prefix(name, "/") || strings.contains_any(name, "\\\x00") {return "", false}
	parts := make([dynamic]string, context.temp_allocator)
	rest := name
	for part in strings.split_by_byte_iterator(&rest, '/') {
		if part == ".." {return "", false}
		if part == "" || part == "." {continue}
		append(&parts, part)
	}
	return strings.join(parts[:], "/", context.temp_allocator), true
}

archive_restore_metadata :: proc(info: Archive_Metadata) -> os.Error {
	os.chmod(info.path, info.mode) or_return
	if info.nanos == max(uint) {return nil}
	name := strings.clone_to_cstring(info.path, context.temp_allocator)
	times := [2]linux.Time_Spec {
		{time_nsec = linux.UTIME_OMIT},
		{time_sec = uint(info.seconds), time_nsec = info.nanos},
	}
	return linux.utimensat(linux.AT_FDCWD, name, raw_data(times[:]), {.SYMLINK_NOFOLLOW})
}

archive_make_directories :: proc(path: string) -> os.Error {
	err := os.make_directory_all(path, os.perm(0o700))
	return err == .Exist ? nil : err
}

// Links are made last, so no archive link can redirect a file or directory write.
// Reject link chains rather than resolving potentially escaping intermediate links.
archive_extract_links :: proc(
	op: ^File_Operation,
	root: string,
	links: []Archive_Link,
) -> os.Error {
	symbolic := make(map[string]bool)
	defer delete(symbolic)
	for link in links {if link.symbolic {symbolic[link.path] = true}}
	parts: [dynamic]string
	defer delete(parts)
	for link in links {
		if !link.symbolic {continue}
		if strings.has_prefix(link.target, "/") ||
		   strings.contains_any(
			   link.target,
			   "\\\x00",
		   ) {return archive_reject(op, "unsafe archive link")}
		parent, _ := os.split_path(link.path)
		clear(&parts)
		target := fmt.tprintf("%s/%s", parent, link.target)
		for part in strings.split_by_byte_iterator(&target, '/') {
			if part == "" || part == "." {continue}
			if part == ".." {
				if len(parts) ==
				   0 {return archive_reject(op, "archive link leaves the extracted folder")}
				pop(&parts)
			} else {append(&parts, part)}
			if symbolic[strings.join(parts[:], "/", context.temp_allocator)] {return archive_reject(op, "archive link chains are not supported")}
		}
	}
	for pass in 0 ..< 2 {
		for link in links {
			if link.symbolic != (pass == 1) {continue}
			if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
			path := fmt.tprintf("%s/%s", root, link.path)
			if link.symbolic {os.symlink(link.target, path) or_return} else {
				target, safe := archive_safe_path(link.target)
				if !safe || target == "" {return archive_reject(op, "unsafe archive hard link")}
				// Hard links may reference only an extracted regular file, before
				// any symbolic links exist in this private directory.
				from := fmt.tprintf("%s/%s", root, target)
				info := os.lstat(from, context.allocator) or_return
				defer os.file_info_delete(info, context.allocator)
				if info.type !=
				   .Regular {return archive_reject(op, "archive hard link does not reference a regular file")}
				err := linux.linkat(
					linux.AT_FDCWD,
					strings.clone_to_cstring(from, context.temp_allocator),
					linux.AT_FDCWD,
					strings.clone_to_cstring(path, context.temp_allocator),
					{},
				)
				if err != .NONE {return err}
			}
		}
	}
	return nil
}

archive_extract :: proc(op: ^File_Operation, payload: string) -> os.Error {
	file, info := archive_regular_open(op.sources[0], follow = true) or_return
	defer os.close(file)
	defer os.file_info_delete(info, context.allocator)
	op.progress = {
		total = u64(max(0, info.size)),
	}
	a := archive_read_new()
	if a == nil {return .Invalid_File}
	defer archive_read_free(a)
	archive_reader_setup(op, a) or_return
	input := Archive_IO {
		op   = op,
		file = file,
	}
	archive_check(op, a, archive_read_set_seek_callback(a, archive_seek_callback)) or_return
	archive_check(op, a, archive_read_open(a, &input, nil, archive_read_callback, nil)) or_return
	os.make_directory(payload, os.perm(0o700)) or_return
	directories: [dynamic]Archive_Metadata
	links: [dynamic]Archive_Link
	defer {
		for item in directories {delete(item.path)}
		delete(directories)
		for item in links {delete(item.path); delete(item.target)}
		delete(links)
	}
	for {
		if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
		entry: ^Archive_Entry
		result := archive_read_next_header(a, &entry)
		if result == 1 {break}
		archive_check(op, a, result) or_return
		name_c := archive_entry_pathname(entry)
		if name_c == nil {return archive_reject(op, "archive entry has no usable name")}
		name, safe := archive_safe_path(string(name_c))
		if !safe {return archive_reject(op, "unsafe archive path")}
		kind := archive_entry_filetype(entry)
		if name ==
		   "" {if kind == 0o040000 {continue}; return archive_reject(op, "empty archive filename")}
		path := fmt.tprintf("%s/%s", payload, name)
		parent, _ := os.split_path(path)
		archive_make_directories(parent) or_return
		hardlink := archive_entry_hardlink(entry)
		if kind == 0o120000 || hardlink != nil {
			target := hardlink
			if kind == 0o120000 {target = archive_entry_symlink(entry)}
			if target == nil {return archive_reject(op, "archive link has no target")}
			append(
				&links,
				Archive_Link{strings.clone(name), strings.clone(string(target)), kind == 0o120000},
			)
			archive_check(op, a, archive_read_data_skip(a)) or_return
		} else if kind == 0o040000 {
			archive_make_directories(path) or_return
		} else if kind == 0o100000 {
			dst := os.open(path, {.Write, .Create, .Excl}, os.perm(0o600)) or_return
			err := archive_extract_data(op, a, entry, dst)
			os.close(dst)
			if err != nil {return err}
		} else {return archive_reject(op, "archive contains an unsupported special file")}
		if hardlink == nil && (kind == 0o040000 || kind == 0o100000) {
			metadata := Archive_Metadata {
				path,
				os.perm(int(archive_entry_perm(entry) & 0o777)) |
				os.perm(kind == 0o040000 ? 0o700 : 0o600),
				archive_entry_mtime(entry),
				max(uint),
			}
			if archive_entry_mtime_is_set(entry) !=
			   0 {metadata.nanos = uint(archive_entry_mtime_nsec(entry))}
			if kind == 0o040000 {
				metadata.path = strings.clone(path)
				append(&directories, metadata)
			} else {archive_restore_metadata(metadata) or_return}
		}
		free_all(context.temp_allocator)
	}
	archive_extract_links(op, payload, links[:]) or_return
	#reverse for metadata in directories {archive_restore_metadata(metadata) or_return}
	return nil
}

archive_extract_data :: proc(
	op: ^File_Operation,
	a: ^Archive_Handle,
	entry: ^Archive_Entry,
	file: ^os.File,
) -> os.Error {
	declared := archive_entry_size_is_set(entry) != 0
	size := archive_entry_size(entry)
	if declared && size < 0 {return archive_reject(op, "invalid archived file size")}
	end: i64
	for {
		if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
		data: rawptr
		length: uintptr
		offset: i64
		result := archive_read_data_block(a, &data, &length, &offset)
		if result != 0 && result != 1 {return archive_check(op, a, result)}
		if offset < end ||
		   u64(length) >
			   u64(max(i64) - offset) {return archive_reject(op, "invalid archived data range")}
		end = offset + i64(length)
		if declared &&
		   end > size {return archive_reject(op, "archived data exceeds its declared size")}
		if result == 1 {break}
		bytes := (cast([^]u8)data)[:int(length)]
		for len(bytes) > 0 {
			if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
			n := min(len(bytes), 1024 * 1024)
			_, err := os.write_at(file, bytes[:n], offset)
			if err != nil {return err}
			bytes = bytes[n:]
			offset += i64(n)
			op.progress.done = u64(max(0, archive_filter_bytes(a, -1)))
			file_progress_publish(op)
		}
	}
	os.truncate(file, declared ? size : end) or_return
	return os.flush(file)
}

archive_run :: proc(op: ^File_Operation) {
	// Libarchive converts filenames through the C locale, including UTF-16 in
	// 7z. Use a thread-local UTF-8 locale, never process-wide setlocale().
	locale := archive_newlocale(1, "C.UTF-8", nil)
	if locale == nil {
		op.failed, op.error =
			max(1, len(op.sources)), strings.clone("cannot use UTF-8 for archives")
		return
	}
	defer archive_freelocale(locale)
	previous := archive_uselocale(locale)
	if previous == nil {
		op.failed, op.error =
			max(1, len(op.sources)), strings.clone("cannot set archive text encoding")
		return
	}
	defer archive_uselocale(previous)
	if op.allocator.procedure == nil {op.allocator = context.allocator}
	err := archive_execute(op)
	if err != nil && !sync.atomic_load(&op.cancel) {
		op.failed = max(1, len(op.sources))
		if op.error == "" {op.error = strings.clone(os.error_string(err))}
	}
}

archive_execute :: proc(op: ^File_Operation) -> os.Error {
	if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
	dir := operation_target_open(op) or_return
	defer os.close(dir)
	if len(op.sources) == 0 {return archive_reject(op, "no archive sources selected")}
	if op.kind == .Compress {
		name := strings.clone(os.base(op.destination))
		defer delete(name)
		if name == "" || name == "." || name == ".." {return .Invalid_Path}
		delete(op.destination)
		op.destination = fmt.aprintf("%s/%s", strings.trim_suffix(op.target, "/"), name)
		for source in op.sources {
			info := os.lstat(source, context.allocator) or_return
			defer os.file_info_delete(info, context.allocator)
			if info.type == .Directory &&
			   path_contains(
				   source,
				   op.target,
			   ) {return archive_reject(op, "cannot create an archive inside its source folder")}
		}
	}
	stage := os.make_directory_temp(op.target, ".stuff-archive-", context.allocator) or_return
	defer delete(stage)
	defer os.remove_all(stage)
	payload := fmt.aprintf("%s/item", stage)
	defer delete(payload)
	if op.kind ==
	   .Compress {archive_create(op, payload) or_return} else {archive_extract(op, payload) or_return}
	if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
	change := file_change_capture(payload) or_return
	recorded := false
	defer if !recorded {file_change_destroy(change)}
	stem, _ := archive_stem(os.base(op.sources[0]))
	if stem == "" {stem = "archive"}
	for index := 0;; index += 1 {
		if sync.atomic_load(&op.cancel) {return linux.Errno.ECANCELED}
		name := stem
		if index > 0 {name = fmt.tprintf("%s (%d)", stem, index + 1)}
		destination :=
			op.kind == .Compress ? op.destination : fmt.tprintf("%s/%s", strings.trim_suffix(op.target, "/"), name)
		err := file_rename_new(payload, destination)
		if err == linux.Errno.EEXIST && op.kind == .Extract {continue}
		if err != nil {return err}
		replace_owned(&change.path, destination)
		append(&op.changes, change)
		recorded = true
		if op.kind == .Compress {file_progress_advance(op)}
		return nil
	}
}
