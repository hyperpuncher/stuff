package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

@(test)
drag_pipe_transfers_handle_backpressure_and_closed_receivers :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	jobs: [dynamic]^Drag_IO
	defer {for job in jobs {drag_io_destroy(job)}; delete(jobs)}
	event := sdl.EventType(sdl.RegisterEvents(1))
	fds: [2]linux.Fd
	testing.expect(t, linux.pipe2(&fds, {.CLOEXEC, .NONBLOCK}) == .NONE)
	reader := fds[0]
	defer linux.close(reader)
	payload := strings.repeat("file:///tmp/large%20drag\r\n", 50_000)
	defer delete(payload)
	testing.expect(t, drag_io_start(&jobs, context.allocator, event, fds[1], payload))
	received: [dynamic]u8
	defer delete(received)
	buffer: [16384]u8
	deadline := sdl.GetTicks() + 3000
	for sdl.GetTicks() < deadline {
		n, err := linux.read(reader, buffer[:])
		if err == .NONE && n == 0 {break}
		if err ==
		   .NONE {append(&received, ..buffer[:n])} else if err == .EAGAIN {time.sleep(time.Millisecond)} else {testing.expect(t, false, "cannot read drag pipe"); break}
	}
	testing.expect_value(t, string(received[:]), payload)
	for !sync.atomic_load(&jobs[0].done) &&
	    sdl.GetTicks() < deadline {time.sleep(time.Millisecond)}
	testing.expect(t, sync.atomic_load(&jobs[0].done))
	testing.expect_value(t, jobs[0].error, linux.Errno.NONE)
	testing.expect(t, linux.pipe2(&fds, {.CLOEXEC, .NONBLOCK}) == .NONE)
	linux.close(fds[0])
	testing.expect(t, drag_io_start(&jobs, context.allocator, event, fds[1], payload))
	job := jobs[len(jobs) - 1]
	deadline = sdl.GetTicks() + 3000
	for !sync.atomic_load(&job.done) && sdl.GetTicks() < deadline {time.sleep(time.Millisecond)}
	testing.expect(t, sync.atomic_load(&job.done))
	testing.expect_value(t, job.error, linux.Errno.EPIPE)
}

@(test)
drag_press_preserves_group_and_owns_paths :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp/drag-fixture")
	b.entries = make([]os.File_Info, 3)
	for &entry, i in b.entries {
		entry.fullpath = fmt.aprintf("/tmp/drag-fixture/file-%d", i)
		_, entry.name = os.split_path(entry.fullpath)
		entry.type = .Regular
	}
	browser_filter(&b)
	selection_all(&b)
	d := File_Drag {
		pressed = true,
	}
	b.file_drag = &d
	defer file_drag_disarm(&d)
	g := geometry(960, 640, 1)
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			clicks = 1,
			x = g.sidebar + 40,
			y = g.list_top + 1,
		},
	}
	file_drag_press(&b, g, 0, &event, {})
	testing.expect_value(t, len(b.marks), 3)
	testing.expect_value(t, len(d.paths), 3)
	selection_single(&b, 2)
	testing.expect_value(t, len(d.paths), 3)
	testing.expect(t, file_drag_release(&b))
	testing.expect_value(t, b.selected, 0)
	testing.expect_value(t, len(b.marks), 1)
	selection_all(&b)
	event.button.clicks = 2
	file_drag_press(&b, g, 1, &event, {})
	testing.expect_value(t, b.selected, 1)
	testing.expect_value(t, len(b.marks), 1)
	testing.expect(t, !d.armed)
}

@(test)
drop_copy_resolves_directory_links_before_descendant_checks :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-drag-target-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create drop fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, inside, alias :=
		fmt.aprintf("%s/source", root),
		fmt.aprintf("%s/source/inside", root),
		fmt.aprintf("%s/alias", root)
	defer delete(source)
	defer delete(inside)
	defer delete(alias)
	testing.expect(t, os.make_directory_all(inside, os.perm(0o700)) == nil)
	testing.expect(t, os.symlink(inside, alias) == nil)
	op := new(File_Operation)
	defer file_operation_destroy(op)
	op.target = strings.clone(alias)
	append(&op.sources, strings.clone(source))
	file_operation_run(op)
	testing.expect_value(t, op.failed, 1)
	entries, read_err := os.read_all_directory_by_path(inside, context.allocator)
	testing.expect(t, read_err == nil)
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expect_value(t, len(entries), 0)
}

@(test)
sdl_drop_batches_own_paths_and_keep_the_drop_destination :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.expect(t, false, string(sdl.GetError())); return}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-sdl-drop-", context.allocator)
	if err != nil {testing.expect(t, false, "cannot create drop fixture"); return}
	defer delete(root)
	defer os.remove_all(root)
	dest, source := fmt.aprintf("%s/dest", root), fmt.aprintf("%s/source", root)
	defer delete(dest)
	defer delete(source)
	testing.expect(t, os.make_directory(dest) == nil)
	testing.expect(t, os.write_entire_file(source, "owned drop") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, dest) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.expect(t, false, "cannot start storage"); return}
	d: File_Drag
	b.file_drag = &d
	defer {file_paths_destroy(d.drop_paths); delete(d.drop_target); delete(d.target)}
	g := geometry(960, 640, 1)
	input := strings.clone_to_cstring(source)
	defer delete(input)
	event := sdl.Event {
		type = .DROP_BEGIN,
	}
	testing.expect(t, file_drop_input(&b, &event, g))
	event.drop = {
		type = .DROP_FILE,
		data = input,
		x    = g.sidebar + 40,
		y    = g.list_top + 4,
	}
	testing.expect(t, file_drop_input(&b, &event, g))
	testing.expect(t, b.pending_files == nil)
	// SDL owns its event strings. A later change must not alter our snapshot.
	(cast([^]u8)input)[0] = '!'
	event.drop = {
		type = .DROP_POSITION,
		x    = -1,
		y    = -1,
	}
	_ = file_drop_input(&b, &event, g)
	testing.expect_value(t, d.target, "")
	testing.expect_value(t, d.drop_target, dest)
	event.type = .DROP_COMPLETE
	testing.expect(t, file_drop_input(&b, &event, g))
	file_history_test_wait(t, &b)
	testing.expect(t, os.exists(fmt.tprintf("%s/source", dest)))
	testing.expect(t, os.exists(source))
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect_value(t, b.status_error, "")
	// A bad item rejects the complete batch instead of copying only its peers.
	event.type = .DROP_BEGIN
	_ = file_drop_input(&b, &event, g)
	(cast([^]u8)input)[0] = '/'
	event.drop = {
		type = .DROP_FILE,
		data = input,
		x    = g.sidebar + 40,
		y    = g.list_top + g.row + 4,
	}
	_ = file_drop_input(&b, &event, g)
	event.drop = {
		type = .DROP_FILE,
		data = "relative-path",
		x    = g.sidebar + 40,
		y    = g.list_top + 4,
	}
	_ = file_drop_input(&b, &event, g)
	event.type = .DROP_COMPLETE
	_ = file_drop_input(&b, &event, g)
	testing.expect(t, b.pending_files == nil)
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect_value(t, b.status_error, "the drop must contain local files")
}
