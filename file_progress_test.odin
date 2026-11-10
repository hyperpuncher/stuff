package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"
import "core:testing"
import "core:thread"
import "core:time"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
copy_progress_counts_the_whole_job_without_following_links :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-copy-progress-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create progress fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, target := fmt.aprintf("%s/source", root), fmt.aprintf("%s/target", root)
	defer delete(source)
	defer delete(target)
	for path in ([?]string{source, target, fmt.tprintf("%s/nested", source), fmt.tprintf("%s/empty", source)}) {
		testing.expect(t, os.make_directory(path) == nil)
	}
	data: [1024]u8
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/a", source), "original") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/.hidden", source), "hid") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/nested/data", source), data[:]) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/standalone", root), "more") == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/outside", root), data[:]) == nil)
	testing.expect(t, os.symlink("../outside", fmt.tprintf("%s/link", source)) == nil)
	testing.expect(t, os.symlink("missing", fmt.tprintf("%s/broken", source)) == nil)
	op := new(File_Operation)
	defer file_operation_destroy(op)
	op.target = strings.clone(target)
	append(&op.sources, strings.clone(source), fmt.aprintf("%s/standalone", root))
	op.progress.phase = .Preparing
	testing.expect(
		t,
		file_copy_node(op, source, fmt.tprintf("%s/not-created", target), nil) == nil,
	)
	// Eight nodes, including hidden and empty entries, plus regular-file data.
	testing.expect_value(t, op.progress.total, u64(8 + 8 + 3 + 1024))
	testing.expect(t, !os.exists(fmt.tprintf("%s/not-created", target)))
	cancelled := File_Operation {
		cancel = true,
		progress = {phase = .Preparing},
	}
	testing.expect(t, file_copy_node(&cancelled, source, "", nil) == linux.Errno.ECANCELED)
	file_operation_run(op)
	// Both selected roots contribute, with one publication unit per root.
	testing.expect_value(t, op.failed, 0)
	testing.expect_value(t, op.progress.total, u64(9 + 8 + 3 + 1024 + 4 + 2))
	testing.expect_value(t, op.progress.done, op.progress.total)
	testing.expect_value(t, len(op.changes), 2)
	testing.expect(t, os.exists(fmt.tprintf("%s/source/nested/data", target)))
}

@(test)
progress_snapshots_are_bounded_and_cancelled_jobs_reject_late_updates :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	s := Storage {
		event = sdl.EventType(sdl.RegisterEvents(1)),
	}
	defer delete(s.results)
	first, second := new(File_Operation), new(File_Operation)
	defer file_operation_destroy(first)
	defer file_operation_destroy(second)
	b: Browser
	defer browser_destroy(&b)
	append(&b.transfers, File_Transfer{op = first}, File_Transfer{op = second})
	for result in ([?]Storage_Result{{kind = .Progress, files = first, progress = {done = 10, total = 100}}, {kind = .Progress, files = second, progress = {done = 10, total = 100}}, {kind = .Progress, files = first, progress = {done = 370, total = 1000}}}) {storage_publish(&s, result)}
	testing.expect_value(t, len(s.results), 2)
	for result in s.results {
		_ = storage_apply(&b, result)
		storage_result_destroy(result) // Snapshots borrow their job; they do not free it.
	}
	testing.expect_value(t, file_progress_percent(b.transfers[0].progress), 37)
	testing.expect_value(t, file_progress_percent(b.transfers[1].progress), 10)
	result := Storage_Result {
		kind = .Progress,
		files = first,
		progress = {done = 379, total = 1000},
	}
	testing.expect(t, !storage_apply(&b, result), "unchanged percentages must not redraw")
	result.progress.done = 2000
	testing.expect(t, storage_apply(&b, result))
	testing.expect_value(t, file_progress_percent(b.transfers[0].progress), 99)
	file_transfer_cancel(&b, 0)
	testing.expect(t, !storage_apply(&b, result))
	testing.expect(
		t,
		storage_apply(&b, {kind = .Progress, files = second, progress = {done = 50, total = 100}}),
	)
	testing.expect_value(t, file_progress_percent(b.transfers[1].progress), 50)
	ordered_remove(&b.transfers, 0)
	testing.expect(
		t,
		!storage_apply(&b, result),
		"a finished job must not update another transfer",
	)
}

@(test)
cancelled_copy_removes_staged_data_and_keeps_completed_items :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-copy-cancel-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create cancellation fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, target := fmt.aprintf("%s/source", root), fmt.aprintf("%s/target", root)
	defer delete(source)
	defer delete(target)
	data: [16384]u8
	testing.expect(t, os.write_entire_file(source, data[:]) == nil)
	testing.expect(t, os.make_directory(target) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/finished", root), "keep") == nil)
	State :: struct {
		op:        File_Operation,
		source:    string,
		allocator: mem.Allocator,
		err:       os.Error,
	}
	state := State {
		op = {target = target},
		source = source,
		allocator = context.allocator,
	}
	defer file_changes_destroy(state.op.changes)
	buffer: [1024]u8
	testing.expect(t, file_copy(&state.op, fmt.tprintf("%s/finished", root), buffer[:]) == nil)
	s := Storage {
		event = sdl.EventType(sdl.RegisterEvents(1)),
	}
	defer {for result in s.results {storage_result_destroy(result)}; delete(s.results)}
	state.op.storage = &s
	// Hold publication until real data reaches staging. Cancellation does not
	// depend on the speed of the test machine or on a large fixture.
	sync.mutex_lock(&s.mutex)
	worker := thread.create_and_start_with_data(&state, proc(data: rawptr) {
		state := cast(^State)data
		context.allocator = state.allocator
		buffer: [1024]u8
		state.err = file_copy(&state.op, state.source, buffer[:])
	})
	if worker == nil {sync.mutex_unlock(&s.mutex); testing.fail_now(t, "cannot start copy worker")}
	staged := false
	deadline := sdl.GetTicks() + 3000
	for !staged && sdl.GetTicks() < deadline {
		entries, read_err := os.read_all_directory_by_path(target, context.allocator)
		if read_err == nil {
			for entry in entries {
				if !strings.has_prefix(entry.name, ".stuff-copy-") {continue}
				info, stat_err := os.lstat(
					fmt.tprintf("%s/item", entry.fullpath),
					context.allocator,
				)
				if stat_err ==
				   nil {staged = info.size > 0; os.file_info_delete(info, context.allocator)}
			}
		}
		os.file_info_slice_delete(entries, context.allocator)
		if !staged {time.sleep(time.Millisecond)}
	}
	sync.atomic_store(&state.op.cancel, true)
	sync.mutex_unlock(&s.mutex)
	thread.destroy(worker)
	testing.expect(t, staged, "cancellation must happen after some data is written")
	testing.expect(t, state.err == linux.Errno.ECANCELED)
	testing.expect(t, os.exists(source))
	entries, read_err := os.read_all_directory_by_path(target, context.allocator)
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, len(entries), 1)
	if len(entries) == 1 {testing.expect_value(t, entries[0].name, "finished")}
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, target) == nil)
	append(&b.transfers, File_Transfer{op = &state.op})
	testing.expect(t, file_operation_apply(&b, &state.op))
	testing.expect_value(t, b.status_error, "operation cancelled")
	testing.expect_value(t, len(b.undo_files), 1)
	if len(b.undo_files) == 1 {testing.expect_value(t, len(b.undo_files[0].changes), 1)}
}

@(test)
parallel_copies_cancel_independently_and_do_not_overwrite :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	root, err := os.make_directory_temp("/tmp", "stuff-parallel-copy-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create parallel copy fixture")}
	defer delete(root)
	defer os.remove_all(root)
	source, dest := fmt.aprintf("%s/source.bin", root), fmt.aprintf("%s/dest", root)
	defer delete(source)
	defer delete(dest)
	testing.expect(t, os.write_entire_file(source, "copied data") == nil)
	testing.expect(t, os.make_directory(dest) == nil)
	testing.expect(t, os.make_directory(fmt.tprintf("%s/elsewhere", root)) == nil)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/source.bin", dest), "keep original") == nil,
	)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	b.storage = storage_start(root)
	if b.storage == nil {testing.fail_now(t, "cannot start parallel copy storage")}
	// Hold result publication so all three workers remain active until checked.
	sync.mutex_lock(&b.storage.mutex)
	for _ in 0 ..< 3 {
		paths: [dynamic]string
		append(&paths, strings.clone(source))
		file_drop_start(&b, paths, dest)
	}
	testing.expect_value(t, len(b.transfers), 3)
	for job in b.transfers {testing.expect(t, job.op.worker != nil)}
	if len(b.transfers) == 3 {
		file_transfer_cancel(&b, 1)
		testing.expect(t, sync.atomic_load(&b.transfers[1].op.cancel))
		testing.expect(t, !sync.atomic_load(&b.transfers[0].op.cancel))
		testing.expect(t, !sync.atomic_load(&b.transfers[2].op.cancel))
	}
	sync.mutex_unlock(&b.storage.mutex)
	testing.expect(t, browser_navigate(&b, fmt.tprintf("%s/elsewhere", root)) == nil)
	deadline := sdl.GetTicks() + 5000
	for len(b.transfers) > 0 && sdl.GetTicks() < deadline {
		_ = storage_poll(&b)
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, len(b.transfers), 0)
	testing.expect_value(t, b.path, fmt.tprintf("%s/elsewhere", root))
	for name, i in ([?]string{"source.bin", "source (copy).bin", "source (copy 2).bin"}) {
		data, read_err := os.read_entire_file(fmt.tprintf("%s/%s", dest, name), context.allocator)
		testing.expect(t, read_err == nil)
		testing.expect_value(t, string(data), i == 0 ? "keep original" : "copied data")
		delete(data)
	}
	entries, dir_err := os.read_all_directory_by_path(dest, context.allocator)
	defer os.file_info_slice_delete(entries, context.allocator)
	testing.expect(t, dir_err == nil)
	testing.expect_value(t, len(entries), 3)
	testing.expect(t, os.exists(source))
	testing.expect_value(t, len(b.undo_files), 2)
}

verify_file_progress_layout :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	fixtures: [dynamic]^File_Operation
	defer {
		browser_destroy(&b)
		for op in fixtures {file_operation_destroy(op)}
		delete(fixtures)
	}
	for name, i in ([?]string{"a very long virtual machine image.qcow2", "5 files", "other.bin"}) {
		op := new(File_Operation)
		op.label = strings.clone(name)
		append(&fixtures, op)
		progress := File_Progress {
			done  = 37,
			total = 100,
		}
		if i == 1 {progress = {
				phase = .Preparing,
			}}
		append(&b.transfers, File_Transfer{op = op, progress = progress})
	}
	b.path = strings.clone("/tmp")
	places_add(&b.places, {label = "home", path = "/tmp", icon = .PlaceHome})
	append(
		&b.places.entries,
		Place {
			label = strings.clone("filesystem"),
			path = strings.clone("/"),
			icon = .PlaceFilesystem,
			disk = true,
			space = {valid = true, available = 25, total = 100},
		},
	)
	b.places.focused = true
	b.space = {
		valid     = true,
		available = 123456789,
		total     = 987654321,
	}
	for scale in ([?]f32{1, 1.25, 1.5, 2}) {
		g := geometry(i32(MIN_WINDOW_WIDTH * scale), i32(480 * scale), scale)
		g.transfers = file_transfers_height(&b, g)
		commands := layout(&b, g, p)
		cancel := clay.GetElementData(clay.ID("transfer-cancel", 0))
		track := clay.GetElementData(clay.ID("transfer-track", 0))
		fill := clay.GetElementData(clay.ID("progress-fill", clay.ID("transfer-track", 0).id))
		testing.expect(t, cancel.found && track.found && fill.found)
		testing.expect(t, cancel.boundingBox.x + cancel.boundingBox.width <= g.sidebar)
		testing.expect(t, abs(fill.boundingBox.width - track.boundingBox.width * 0.37) < 0.01)
		testing.expect(t, clay.GetElementData(clay.ID("transfer-track", 1)).found)
		testing.expect(t, clay.GetElementData(clay.ID("transfer-track", 2)).found)
		first_row := clay.GetElementData(clay.ID("transfer-row", 0)).boundingBox
		next_row := clay.GetElementData(clay.ID("transfer-row", 1)).boundingBox
		testing.expect_value(t, first_row.height, g.row)
		testing.expect_value(t, next_row.y - first_row.y, g.row)
		last_place := clay.GetElementData(clay.ID("place", 1)).boundingBox
		testing.expect(t, abs(first_row.y - (last_place.y + last_place.height) - g.row) < 0.01)
		free_space := false
		root_center: f32 = -1
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType == .Image &&
			   cmd.boundingBox.y >= g.header &&
			   cmd.boundingBox.x < g.sidebar {
				icon := cmd.renderData.image.imageData
				if icon == p.icons[.PlaceHome] ||
				   icon == p.icons[.PlaceFilesystem] ||
				   icon == p.icons[.CopyPath] {
					testing.expect(
						t,
						root_center >= 0 &&
						abs(cmd.boundingBox.x + cmd.boundingBox.width / 2 - root_center) < 1.01,
					)
				}
			}
			if cmd.commandType != .Text {continue}
			text := string(
				cmd.renderData.text.stringContents.chars[:cmd.renderData.text.stringContents.length],
			)
			if text == "/" {root_center = cmd.boundingBox.x + cmd.boundingBox.width / 2}
			if strings.has_suffix(text, "free") {
				free_space = true
				testing.expect(
					t,
					abs(
						cmd.boundingBox.x +
						cmd.boundingBox.width -
						(g.width - f32(u16(g.padding))),
					) <
					0.01,
				)
			}
			if strings.has_suffix(text, ".qcow2") {
				testing.expect(
					t,
					cmd.boundingBox.x + cmd.boundingBox.width <= cancel.boundingBox.x,
				)
				testing.expect(
					t,
					abs(
						track.boundingBox.y -
						(cmd.boundingBox.y + cmd.boundingBox.height) -
						f32(u16(3 * scale)),
					) <
					0.01,
				)
				if scale == 1 {testing.expect(t, strings.contains(text, "…"))}
			}
		}
		testing.expect(t, free_space)
	}
	g, running := geometry(960, 640, 1), true
	g.transfers = file_transfers_height(&b, g)
	_ = layout(&b, g, p)
	box := clay.GetElementData(clay.ID("transfer-cancel", 0)).boundingBox
	b.header.edit.active, b.header.edit.mode, b.header.edit.waiting = true, .Rename, fixtures[0]
	b.pointer = {
		x      = box.x + box.width / 2,
		y      = box.y + box.height / 2,
		active = true,
	}
	testing.expect_value(t, hover_target(&b, g), clay.ID("transfer-cancel", 0).id)
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = b.pointer.x,
			y = b.pointer.y,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, sync.atomic_load(&fixtures[0].cancel))
	b.header.edit.active, b.header.edit.waiting = false, nil
	_ = layout(&b, g, p)
	box = clay.GetElementData(clay.ID("transfer-cancel", 1)).boundingBox
	event.button.x, event.button.y = box.x + box.width / 2, box.y + box.height / 2
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, len(b.transfers), 3)
	testing.expect(t, sync.atomic_load(&fixtures[1].cancel))
	testing.expect(t, !sync.atomic_load(&fixtures[2].cancel))
	for _ in 0 ..< 10 {
		op := new(File_Operation)
		op.label = strings.clone("extra.bin")
		append(&fixtures, op)
		append(&b.transfers, File_Transfer{op = op})
	}
	g = geometry(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, 1)
	g.transfers = file_transfers_height(&b, g)
	_ = layout(&b, g, p)
	viewport := clay.GetElementData(clay.ID("transfers-viewport")).boundingBox
	event = {
		wheel = {
			type = .MOUSE_WHEEL,
			y = -5,
			mouse_x = viewport.x + 10,
			mouse_y = viewport.y + 10,
		},
	}
	first := b.places.first
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.transfer_first > 0)
	testing.expect_value(t, b.places.first, first)
	_ = layout(&b, g, p)
	testing.expect(t, clay.GetElementData(clay.ID("transfer-row", u32(b.transfer_first))).found)
	clear(&b.transfers)
	g.transfers = file_transfers_height(&b, g)
	_ = layout(&b, g, p)
	testing.expect(t, !clay.GetElementData(clay.ID("transfers-viewport")).found)
}
