package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

archive_test_job :: proc(
	kind: File_Action,
	source, target, destination: string,
	format: Archive_Format = .Zip,
	password: string = "",
) -> ^File_Operation {
	op := new(File_Operation)
	op.kind, op.target, op.destination = kind, strings.clone(target), strings.clone(destination)
	op.archive_format, op.archive_password = format, strings.clone(password)
	append(&op.sources, strings.clone(source))
	return op
}

archive_test_root :: proc(t: ^testing.T, prefix: string) -> string {
	root, err := os.make_directory_temp("/tmp", prefix, context.allocator)
	if err != nil {testing.fail_now(t, "cannot make archive fixture")}
	return root
}

archive_test_contents :: proc(t: ^testing.T, path, expected: string) {
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil, path)
	testing.expect_value(t, string(data), expected)
}

archive_test_no_staging :: proc(t: ^testing.T, root: string) {
	entries, err := os.read_all_directory_by_path(root, context.allocator)
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expect(t, err == nil)
	for entry in entries {testing.expect(t, !strings.has_prefix(entry.name, ".stuff-archive-"))}
}

@(test)
archives_round_trip_content_links_and_collisions :: proc(t: ^testing.T) {
	root := archive_test_root(t, "stuff-archives-")
	defer delete(root)
	defer os.remove_all(root)
	source := fmt.aprintf("%s/source", root)
	defer delete(source)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/nested/empty", source)) == nil)
	large := strings.repeat("0123456789abcdef", 65537) // More than one write chunk.
	defer delete(large)
	for item in ([?][2]string{{"file.txt", "contents survive compression"}, {".hidden", "hidden"}, {"nested/café.txt", "unicode content"}, {"empty", ""}, {"large", large}}) {
		testing.expect(
			t,
			os.write_entire_file(fmt.tprintf("%s/%s", source, item[0]), item[1]) == nil,
		)
	}; testing.expect(t, os.symlink("file.txt", fmt.tprintf("%s/link", source)) == nil)
	testing.expect(t, os.symlink("missing", fmt.tprintf("%s/broken", source)) == nil)
	testing.expect(t, os.symlink("../file.txt", fmt.tprintf("%s/nested/up", source)) == nil)
	for suffix, format in ARCHIVE_SUFFIX {
		path := fmt.aprintf("%s/bundle%s", root, suffix)
		defer delete(path)
		create := archive_test_job(.Compress, source, root, path, format)
		file_operation_run(create)
		if !testing.expect(
			t,
			create.failed == 0,
			create.error,
		) {file_operation_destroy(create); continue}
		testing.expect_value(t, len(create.changes), 1)
		testing.expect_value(t, create.progress.done, create.progress.total)
		file_operation_destroy(create)
		extract := archive_test_job(.Extract, path, root, "")
		file_operation_run(extract)
		if !testing.expect(
			t,
			extract.failed == 0,
			extract.error,
		) {file_operation_destroy(extract); continue}
		testing.expect_value(t, len(extract.changes), 1)
		if len(extract.changes) == 1 {
			output := fmt.tprintf("%s/source", extract.changes[0].path)
			archive_test_contents(
				t,
				fmt.tprintf("%s/file.txt", output),
				"contents survive compression",
			)
			archive_test_contents(t, fmt.tprintf("%s/.hidden", output), "hidden")
			archive_test_contents(t, fmt.tprintf("%s/nested/café.txt", output), "unicode content")
			archive_test_contents(t, fmt.tprintf("%s/empty", output), "")
			archive_test_contents(t, fmt.tprintf("%s/large", output), large)
			testing.expect(t, os.exists(fmt.tprintf("%s/nested/empty", output)))
			link, err := os.read_link(fmt.tprintf("%s/link", output), context.allocator)
			testing.expect(t, err == nil)
			testing.expect_value(t, link, "file.txt")
			delete(link)
			broken, broken_err := os.read_link(fmt.tprintf("%s/broken", output), context.allocator)
			testing.expect(t, broken_err == nil)
			testing.expect_value(t, broken, "missing")
			delete(broken)
			archive_test_contents(
				t,
				fmt.tprintf("%s/nested/up", output),
				"contents survive compression",
			)
		}
		file_operation_destroy(extract)
		archive_test_no_staging(t, root)
	}
	archive_test_contents(t, fmt.tprintf("%s/file.txt", source), "contents survive compression")
	// A conflicting destination must remain byte-for-byte unchanged.
	path := fmt.aprintf("%s/keep.zip", root)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, "do not replace") == nil)
	op := archive_test_job(.Compress, source, root, path)
	defer file_operation_destroy(op)
	file_operation_run(op)
	testing.expect(t, op.failed > 0 && len(op.changes) == 0)
	archive_test_contents(t, path, "do not replace")
	archive_test_no_staging(t, root)
}

Archive_Test_Entry :: struct {
	name, data, link: string,
	kind:             u32,
}

archive_test_fixture :: proc(
	t: ^testing.T,
	path: string,
	entries: []Archive_Test_Entry,
	password: string = "",
) {
	a := archive_write_new()
	if a == nil {testing.fail_now(t, "cannot make archive writer")}
	defer archive_write_free(a)
	buffer := make([]u8, 1024 * 1024)
	defer delete(buffer)
	used: uintptr
	format: cstring = password == "" ? "pax" : "zip"
	testing.expect_value(t, archive_write_set_format_by_name(a, format), 0)
	if password != "" {
		testing.expect_value(
			t,
			archive_write_set_passphrase(
				a,
				strings.clone_to_cstring(password, context.temp_allocator),
			),
			0,
		)
		testing.expect_value(
			t,
			archive_write_set_format_option(a, "zip", "encryption", "aes256"),
			0,
		)
	}
	testing.expect_value(
		t,
		archive_write_open_memory(a, raw_data(buffer), uintptr(len(buffer)), &used),
		0,
	)
	for item in entries {
		entry := archive_entry_new()
		archive_entry_set_pathname(
			entry,
			strings.clone_to_cstring(item.name, context.temp_allocator),
		)
		archive_entry_set_filetype(entry, item.kind)
		archive_entry_set_perm(entry, 0o644)
		archive_entry_set_size(entry, i64(len(item.data)))
		if item.link != "" {
			link := strings.clone_to_cstring(item.link, context.temp_allocator)
			if item.kind ==
			   0o120000 {archive_entry_set_symlink(entry, link)} else {archive_entry_set_hardlink(entry, link)}
		}
		testing.expect_value(t, archive_write_header(a, entry), 0)
		if item.data !=
		   "" {testing.expect_value(t, archive_write_data(a, raw_data(item.data), uintptr(len(item.data))), len(item.data))}
		archive_entry_free(entry)
	}
	testing.expect_value(t, archive_write_close(a), 0)
	testing.expect(t, os.write_entire_file(path, buffer[:int(used)]) == nil)
}

@(test)
unsafe_and_corrupt_archives_leave_no_output :: proc(t: ^testing.T) {
	root := archive_test_root(t, "stuff-unsafe-archive-")
	defer delete(root)
	defer os.remove_all(root)
	outside := fmt.aprintf("%s/outside", root)
	defer delete(outside)
	testing.expect(t, os.write_entire_file(outside, "keep") == nil)
	cases := [][]Archive_Test_Entry {
		{{name = "../outside", data = "bad", kind = 0o100000}},
		{{name = outside, data = "bad", kind = 0o100000}},
		{{name = "dir/../../outside", data = "bad", kind = 0o100000}},
		{{name = "a", data = "one", kind = 0o100000}, {name = "a", data = "two", kind = 0o100000}},
		{{name = "pipe", kind = 0o010000}},
		{{name = "link", link = "../outside", kind = 0o120000}},
		{{name = "dir/link", link = "../../outside", kind = 0o120000}},
		{
			{name = "dir/a", link = "..", kind = 0o120000},
			{name = "dir/c", link = "a/../../outside", kind = 0o120000},
		},
		{{name = "a", link = "../outside", kind = 0o100000}},
		{
			{name = "link", link = "../outside", kind = 0o120000},
			{name = "link/inside", data = "bad", kind = 0o100000},
		},
	}
	for entries, index in cases {
		path := fmt.aprintf("%s/unsafe-%d.tar", root, index)
		defer delete(path)
		archive_test_fixture(t, path, entries)
		op := archive_test_job(.Extract, path, root, "")
		file_operation_run(op)
		testing.expect(t, op.failed > 0 && len(op.changes) == 0, path)
		testing.expect(t, !os.exists(fmt.tprintf("%s/unsafe-%d", root, index)))
		file_operation_destroy(op)
		archive_test_contents(t, outside, "keep")
		archive_test_no_staging(t, root)
	}
	path := fmt.aprintf("%s/corrupt.zip", root)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, "PK\x03\x04not an archive") == nil)
	op := archive_test_job(.Extract, path, root, "")
	defer file_operation_destroy(op)
	file_operation_run(op)
	testing.expect(t, op.failed > 0 && len(op.changes) == 0)
	archive_test_no_staging(t, root)
	// Fail after a valid source entry. No partial writer output may survive.
	pipe := fmt.aprintf("%s/pipe", root)
	defer delete(pipe)
	pipe_c := strings.clone_to_cstring(pipe)
	defer delete(pipe_c)
	testing.expect_value(
		t,
		linux.mknodat(linux.AT_FDCWD, pipe_c, transmute(linux.Mode)u32(0o010600), 0),
		linux.Errno.NONE,
	)
	for suffix, format in ARCHIVE_SUFFIX {
		created := fmt.aprintf("%s/rejected%s", root, suffix)
		job := archive_test_job(.Compress, outside, root, created, format)
		append(&job.sources, strings.clone(pipe))
		file_operation_run(job)
		testing.expect(t, job.failed > 0 && len(job.changes) == 0)
		testing.expect(t, !os.exists(created))
		file_operation_destroy(job)
		delete(created)
		archive_test_no_staging(t, root)
	}
	// A source folder cannot include its own temporary output.
	nested := fmt.aprintf("%s/nested", root)
	defer delete(nested)
	testing.expect(t, os.make_directory(nested) == nil)
	job := archive_test_job(.Compress, root, nested, fmt.tprintf("%s/inside.zip", nested))
	defer file_operation_destroy(job)
	file_operation_run(job)
	testing.expect(t, job.failed > 0 && len(job.changes) == 0)
	archive_test_no_staging(t, nested)
}

@(test)
archive_password_attempts_keep_the_original_destination :: proc(t: ^testing.T) {
	root := archive_test_root(t, "stuff-password-archive-")
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/locked.zip", root)
	defer delete(path)
	archive_test_fixture(
		t,
		path,
		[]Archive_Test_Entry{{name = "secret.txt", data = "private content", kind = 0o100000}},
		"correct",
	)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	for password in ([?]string{"", "wrong"}) {
		op := archive_test_job(.Extract, path, root, "", password = password)
		append(&b.transfers, File_Transfer{op = op})
		file_operation_run(op)
		testing.expect(t, op.archive_needs_password && len(op.changes) == 0, op.error)
		testing.expect(t, file_operation_apply(&b, op))
		file_operation_destroy(op)
		testing.expect_value(t, len(b.archive_requests), 1)
		testing.expect(t, archive_prompt_update(&b))
		testing.expect_value(t, b.header.edit.mode, Edit_Mode.Password)
		testing.expect_value(t, b.header.edit.source, path)
		testing.expect_value(t, b.header.edit.parent, root)
		path_edit_end(&b.header.edit)
		archive_test_no_staging(t, root)
	}
	op := archive_test_job(.Extract, path, root, "", password = "correct")
	defer file_operation_destroy(op)
	file_operation_run(op)
	if testing.expect(
		t,
		op.failed == 0 && len(op.changes) == 1,
		op.error,
	) {archive_test_contents(t, fmt.tprintf("%s/secret.txt", op.changes[0].path), "private content")}
	seven_path := fmt.aprintf("%s/locked.7z", root)
	defer delete(seven_path)
	testing.expect(t, os.write_entire_file(seven_path, #load("testdata/encrypted.7z")) == nil)
	seven := archive_test_job(.Extract, seven_path, root, "", password = "correct")
	defer file_operation_destroy(seven)
	file_operation_run(seven)
	testing.expect(t, seven.failed > 0 && !seven.archive_needs_password && len(seven.changes) == 0)
	testing.expect(
		t,
		strings.contains(strings.to_lower(seven.error, context.temp_allocator), "encrypt"),
	)
	archive_test_no_staging(t, root)
}

@(test)
archive_jobs_are_parallel_and_cancel_after_real_output :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root := archive_test_root(t, "stuff-archive-cancel-")
	defer delete(root)
	defer os.remove_all(root)
	data := strings.repeat("data", 16384)
	defer delete(data)
	path := fmt.aprintf("%s/data.tar", root)
	defer delete(path)
	archive_test_fixture(
		t,
		path,
		[]Archive_Test_Entry{{name = "file", data = data, kind = 0o100000}},
	)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start storage")}
	sync.mutex_lock(&b.storage.mutex)
	extract := archive_test_job(.Extract, path, root, "")
	testing.expect(t, file_operation_launch(&b, extract))
	staged := false
	deadline := sdl.GetTicks() + 3000
	for !staged && sdl.GetTicks() < deadline {
		entries, _ := os.read_all_directory_by_path(root, context.allocator)
		for entry in entries {
			if !strings.has_prefix(entry.name, ".stuff-archive-") {continue}
			info, err := os.lstat(fmt.tprintf("%s/item/file", entry.fullpath), context.allocator)
			if err == nil {staged = info.size > 0; os.file_info_delete(info, context.allocator)}
		}
		os.file_info_slice_delete(entries, context.allocator)
		if !staged {time.sleep(time.Millisecond)}
	}
	// Start an independent copy while the archive worker is still active.
	copy := archive_test_job(.Copy, path, root, "")
	testing.expect(t, file_operation_launch(&b, copy))
	file_transfer_cancel(&b, 0)
	sync.mutex_unlock(&b.storage.mutex)
	testing.expect(t, staged)
	file_history_test_wait(t, &b)
	testing.expect(t, !os.exists(fmt.tprintf("%s/data", root)))
	testing.expect(t, os.exists(fmt.tprintf("%s/data (copy).tar", root)))
	testing.expect_value(t, len(b.undo_files), 1)
	archive_test_no_staging(t, root)
}
