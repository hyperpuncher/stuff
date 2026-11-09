package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

wait_for_open_file :: proc(t: ^testing.T, path: string) {
	start := time.tick_now()
	for !os.exists(path) && time.tick_since(start) < 2 * time.Second {time.sleep(time.Millisecond)}
	if !os.exists(path) {testing.fail_now(t, "the test opener did not write its result")}
}

wait_for_opens :: proc(t: ^testing.T, b: ^Browser) -> (changed: bool) {
	start := time.tick_now()
	for len(b.opens) > 0 && time.tick_since(start) < 2 * time.Second {
		changed = file_open_poll(b) || changed
		time.sleep(time.Millisecond)
	}
	if len(b.opens) != 0 {testing.fail_now(t, "the test opener did not finish")}
	return
}

@(test)
file_open_uses_default_handler_without_blocking :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-open-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create opener fixture")}
	defer delete(root)
	defer os.remove_all(root)
	bin := fmt.aprintf("%s/bin", root)
	defer delete(bin)
	opener := fmt.aprintf("%s/xdg-open", bin)
	defer delete(opener)
	argument := fmt.aprintf("%s/argument", root)
	defer delete(argument)
	count := fmt.aprintf("%s/count", root)
	defer delete(count)
	gate := fmt.aprintf("%s/wait", root)
	defer delete(gate)
	marker := fmt.aprintf("%s/executed", root)
	defer delete(marker)
	folder := fmt.aprintf("%s/folder", root)
	defer delete(folder)
	path := fmt.aprintf("%s/-quotes '\"; $(touch injected) 雪.sh", root)
	defer delete(path)
	testing.expect(t, os.make_directory(bin) == nil)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.write_entire_file(gate, "wait") == nil)
	// This selected file has execute permission, but must never be executed by stuff.
	testing.expect(
		t,
		os.write_entire_file(
			path,
			fmt.tprintf("#!/bin/sh\nprintf executed > '%s'\n", marker),
			os.perm_number(0o700),
		) ==
		nil,
	)
	script := fmt.tprintf(
		"#!/bin/sh\nprintf '%%s' \"$1\" > '%s'\nprintf '%%s' \"$#\" > '%s'\nwhile [ -e '%s' ]; do /bin/sleep 0.01; done\n",
		argument,
		count,
		gate,
	)
	testing.expect(t, os.write_entire_file(opener, script, os.perm_number(0o700)) == nil)

	// Keep both the native PATH search and SDL's child environment isolated.
	// The suite is serialized; no real desktop application can be selected here.
	environment := sdl.GetEnvironment()
	native_path := strings.clone_to_cstring(string(sdl.getenv_unsafe("PATH")))
	defer delete(native_path)
	sdl_path := strings.clone_to_cstring(string(sdl.GetEnvironmentVariable(environment, "PATH")))
	defer delete(sdl_path)
	defer sdl.setenv_unsafe("PATH", native_path, true)
	defer sdl.SetEnvironmentVariable(environment, "PATH", sdl_path, true)
	bin_c := strings.clone_to_cstring(bin)
	defer delete(bin_c)
	if sdl.setenv_unsafe("PATH", bin_c, true) != 0 ||
	   !sdl.SetEnvironmentVariable(environment, "PATH", bin_c, true) {
		testing.fail_now(t, "cannot isolate the opener PATH")
	}
	if string(sdl.getenv_unsafe("PATH")) != bin ||
	   string(sdl.GetEnvironmentVariable(environment, "PATH")) != bin {
		testing.fail_now(t, "the opener PATH is not isolated")
	}

	b: Browser
	defer browser_destroy(&b)
	defer {
		// Only controlled test processes are terminated if an assertion fails.
		for job in b.opens {
			_ = sdl.KillProcess(job.process, true)
			_ = sdl.WaitProcess(job.process, true, nil)
		}
	}
	testing.expect(t, browser_load(&b, root) == nil)
	for source, i in b.visible {if b.entries[source].fullpath == path {b.selected = i}}
	g := geometry(960, 640, 1)

	running := true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_RETURN, repeat = true},
	}
	testing.expect(t, !handle_event(&b, &event, g, &running))
	testing.expect_value(t, len(b.opens), 0)
	event.key.repeat = false
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, b.status_error == "")
	testing.expect_value(t, len(b.opens), 1)
	wait_for_open_file(t, count)
	bytes, read_err := os.read_entire_file(argument, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(bytes), path)
	delete(bytes)
	bytes, read_err = os.read_entire_file(count, context.allocator)
	testing.expect(t, read_err == nil)
	testing.expect_value(t, string(bytes), "1")
	delete(bytes)
	testing.expect(t, !file_open_poll(&b))
	testing.expect_value(t, len(b.opens), 1)
	// Replacing the listing while the opener waits must not invalidate its path.
	testing.expect(t, browser_navigate(&b, folder) == nil)
	testing.expect_value(t, b.path, folder)
	testing.expect(t, os.remove(gate) == nil)
	testing.expect(t, !wait_for_opens(t, &b))
	testing.expect_value(t, b.status_error, "")
	testing.expect(t, !os.exists(marker))

	// Missing handlers and failed associations must be reported without a crash.
	testing.expect(t, os.remove(opener) == nil)
	file_open(&b, path)
	testing.expect_value(t, len(b.opens), 0)
	testing.expect(t, strings.has_prefix(b.status_error, "cannot open "))
	testing.expect(
		t,
		os.write_entire_file(opener, "#!/bin/sh\nexit 4\n", os.perm_number(0o700)) == nil,
	)
	testing.expect(t, browser_load(&b, root) == nil)
	for source, i in b.visible {if b.entries[source].fullpath == path {b.selected = i}}
	event = sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			clicks = 2,
			x = g.sidebar + 20,
			y = g.list_top + f32(b.selected) * g.row + 1,
		},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect(t, wait_for_opens(t, &b))
	testing.expect(t, strings.has_suffix(b.status_error, "code 4"))
	testing.expect_value(t, b.path, root)
	file_open(&b, folder)
	testing.expect(t, strings.has_suffix(b.status_error, "not a regular file"))
	testing.expect_value(t, len(b.opens), 0)

	// Closing stuff must release tracking without waiting for or killing the handler.
	testing.expect(t, os.write_entire_file(gate, "wait") == nil)
	testing.expect(t, os.write_entire_file(opener, script, os.perm_number(0o700)) == nil)
	closing: Browser
	file_open(&closing, path)
	if len(closing.opens) != 1 {testing.fail_now(t, "cannot start the close test")}
	pid := int(
		sdl.GetNumberProperty(
			sdl.GetProcessProperties(closing.opens[0].process),
			sdl.PROP_PROCESS_PID_NUMBER,
			0,
		),
	)
	observer, open_err := os.process_open(pid)
	if open_err != nil {testing.fail_now(t, "cannot observe the test opener")}
	observer_done := false
	defer if !observer_done {_ = os.process_kill(observer); _, _ = os.process_wait(observer)}
	browser_destroy(&closing)
	testing.expect(t, os.remove(gate) == nil)
	state, wait_err := os.process_wait(observer, timeout = 2 * time.Second)
	observer_done = wait_err == nil
	testing.expect(t, wait_err == nil)
	testing.expect(t, state.exited && state.exit_code == 0)
	testing.expect(t, !os.exists(marker))
}
