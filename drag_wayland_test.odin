package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

// Test-only wlr virtual-pointer v1 requests (protocol: MIT, Josef Gajdusek).
WL_Test_Message :: struct {
	name, signature: cstring,
	types:           rawptr,
}
TEST_POINTER_REQUESTS := [9]WL_Test_Message {
	{"motion", "uff", nil},
	{"motion_absolute", "uuuuu", nil},
	{"button", "uuu", nil},
	{"axis", "uuf", nil},
	{"frame", "", nil},
	{"axis_source", "u", nil},
	{"axis_stop", "uu", nil},
	{"axis_discrete", "uufi", nil},
	{"destroy", "", nil},
}
TEST_POINTER_INTERFACE := WL_Interface {
	name         = "zwlr_virtual_pointer_v1",
	version      = 1,
	method_count = 9,
	methods      = &TEST_POINTER_REQUESTS,
}
TEST_POINTER_TYPES := [2]^WL_Interface{&wl_seat_interface, &TEST_POINTER_INTERFACE}
TEST_MANAGER_REQUESTS := [2]WL_Test_Message {
	{"create_virtual_pointer", "?on", &TEST_POINTER_TYPES},
	{"destroy", "", nil},
}
TEST_MANAGER_INTERFACE := WL_Interface {
	name         = "zwlr_virtual_pointer_manager_v1",
	version      = 1,
	method_count = 2,
	methods      = &TEST_MANAGER_REQUESTS,
}

Drag_Test_Pointer :: struct {
	manager, pointer: ^WL_Object,
}
drag_test_global :: proc "c" (
	data: rawptr,
	registry: ^WL_Object,
	name: u32,
	interface: cstring,
	version: u32,
) {
	context = runtime.default_context()
	state := cast(^Drag_Test_Pointer)data
	if string(interface) ==
	   "zwlr_virtual_pointer_manager_v1" {state.manager = wl_bind(registry, name, &TEST_MANAGER_INTERFACE, 1)}
}
drag_test_remove :: proc "c" (data: rawptr, registry: ^WL_Object, name: u32) {}
DRAG_TEST_REGISTRY_LISTENER := [2]rawptr{rawptr(drag_test_global), rawptr(drag_test_remove)}

Drag_Test_Env :: struct {
	key, value: string,
	present:    bool,
}
drag_test_env :: proc(key, value: string) -> Drag_Test_Env {
	old, present := os.lookup_env(key, context.allocator)
	assert(os.set_env(key, value) == nil)
	k, v := strings.clone_to_cstring(key), strings.clone_to_cstring(value)
	defer delete(k)
	defer delete(v)
	assert(sdl.SetEnvironmentVariable(sdl.GetEnvironment(), k, v, true))
	return {key, old, present}
}
drag_test_env_restore :: proc(saved: []Drag_Test_Env) {
	for item in saved {
		k, v := strings.clone_to_cstring(item.key), strings.clone_to_cstring(item.value)
		if item.present {_ = os.set_env(item.key, item.value); _ = sdl.SetEnvironmentVariable(sdl.GetEnvironment(), k, v, true)} else {_ = os.unset_env(item.key); _ = sdl.UnsetEnvironmentVariable(sdl.GetEnvironment(), k)}
		delete(k); delete(v); delete(item.value)
	}
}

drag_test_pump :: proc(b: ^Browser, g: Geometry, renderer: ^sdl.Renderer) {
	sdl.PumpEvents()
	event: sdl.Event
	running := true
	for sdl.PollEvent(&event) {
		sdl_check(sdl.ConvertEventToRenderCoordinates(renderer, &event))
		_ = handle_event(b, &event, g, &running)
	}
	_ = file_drag_poll(b)
	_ = storage_poll(b)
}

drag_test_point :: proc(pointer: ^WL_Object, x, y: u32) {
	_ = wl_proxy_marshal_flags(
		pointer,
		1,
		nil,
		1,
		0,
		u32(sdl.GetTicks()),
		x,
		y,
		u32(1280),
		u32(720),
	)
	_ = wl_proxy_marshal_flags(pointer, 4, nil, 1, 0)
}


drag_test_peer :: proc(t: ^testing.T, role, root: string) {
	if !sdl.Init({.VIDEO}) {testing.expect(t, false, string(sdl.GetError())); return}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	if role ==
	   "send" {testing.expect(t, browser_load(&b, fmt.tprintf("%s/peer-files", root)) == nil)}
	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !sdl.CreateWindowAndRenderer(
		"stuff-drag-peer",
		320,
		300,
		{.BORDERLESS},
		&window,
		&renderer,
	) {testing.expect(t, false, string(sdl.GetError())); return}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	sdl_check(sdl.RenderClear(renderer))
	sdl_check(sdl.RenderPresent(renderer))
	sdl_check(sdl.SyncWindow(window))
	if role ==
	   "send" {b.file_drag = file_drag_init(window); if b.file_drag == nil {testing.expect(t, false, "peer drag backend unavailable"); return}}
	defer {file_drag_destroy(b.file_drag); b.file_drag = nil}
	g := geometry(320, 300, 1)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/peer-%s-ready", root, role), "ready") == nil,
	)
	paths: [dynamic]string
	defer file_paths_destroy(paths)
	started := false
	deadline := sdl.GetTicks() + 10000
	for sdl.GetTicks() < deadline {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			if role == "receive" {
				if event.type ==
				   .DROP_FILE {append(&paths, strings.clone(string(event.drop.data)))}
				if event.type == .DROP_COMPLETE && len(paths) > 0 {
					uris := file_uri_list(paths[:])
					defer delete(uris)
					testing.expect(
						t,
						os.write_entire_file(fmt.tprintf("%s/peer-received", root), uris) == nil,
					)
					return
				}
			} else {
				running := true
				_ = handle_event(&b, &event, g, &running)
			}
		}
		_ = file_drag_poll(&b)
		if b.file_drag != nil {
			started = started || b.file_drag.source != nil
			if started && b.file_drag.source == nil {return}
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "external drag peer timed out")
}

drag_test_spawn_peer :: proc(role, root: string) -> ^sdl.Process {
	env := sdl.CreateEnvironment(true)
	defer sdl.DestroyEnvironment(env)
	actual, err := os.read_link("/proc/self/exe", context.allocator)
	if err != nil {return nil}
	defer delete(actual)
	role_c, root_c, executable :=
		strings.clone_to_cstring(role),
		strings.clone_to_cstring(root),
		strings.clone_to_cstring(actual)
	defer delete(role_c)
	defer delete(root_c)
	defer delete(executable)
	sdl_check(sdl.SetEnvironmentVariable(env, "STUFF_DRAG_TEST_PEER", role_c, true))
	sdl_check(sdl.SetEnvironmentVariable(env, "STUFF_DRAG_TEST_ROOT", root_c, true))
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	args := [?]cstring{executable, nil}
	sdl_check(
		sdl.SetPointerProperty(props, sdl.PROP_PROCESS_CREATE_ARGS_POINTER, raw_data(args[:])),
	)
	sdl_check(sdl.SetPointerProperty(props, sdl.PROP_PROCESS_CREATE_ENVIRONMENT_POINTER, env))
	process := sdl.CreateProcessWithProperties(props)
	if process ==
	   nil {fmt.eprintfln("cannot start peer %s: %s (executable %s)", role, string(sdl.GetError()), os.args[0])}
	return process
}

drag_test_stop_peer :: proc(process: ^sdl.Process) {
	_ = sdl.KillProcess(process, true)
	code: c.int
	_ = sdl.WaitProcess(process, true, &code)
	sdl.DestroyProcess(process)
}

drag_test_gesture :: proc(
	b: ^Browser,
	g: Geometry,
	renderer: ^sdl.Renderer,
	pointer: ^WL_Object,
	x, y, to_x, to_y: u32,
) {
	for step in 0 ..< 5 {
		switch step {
		case 0:
			drag_test_point(pointer, x, y)
		case 1, 4:
			_ = wl_proxy_marshal_flags(
				pointer,
				2,
				nil,
				1,
				0,
				u32(sdl.GetTicks()),
				u32(0x110),
				u32(step == 1 ? 1 : 0),
			)
			_ = wl_proxy_marshal_flags(pointer, 4, nil, 1, 0)
		case 2:
			drag_test_point(pointer, x + 20, y)
		case 3:
			drag_test_point(pointer, to_x, to_y)
		}
		_ = wl_display_flush(b.file_drag.display)
		for _ in 0 ..< 25 {drag_test_pump(b, g, renderer); time.sleep(time.Millisecond)}
	}
}

@(test)
native_wayland_file_drag :: proc(t: ^testing.T) {
	when !#config(NATIVE_WAYLAND_TESTS, false) {return}
	role := os.get_env("STUFF_DRAG_TEST_PEER", context.temp_allocator)
	if role !=
	   "" {drag_test_peer(t, role, os.get_env("STUFF_DRAG_TEST_ROOT", context.temp_allocator)); return}
	root, err := os.make_directory_temp("/tmp", "stuff-native-drag-", context.allocator)
	if err != nil {testing.expect(t, false, "cannot create native drag fixture"); return}
	defer delete(root)
	defer os.remove_all(root)
	config := fmt.aprintf("%s/config", root)
	defer delete(config)
	testing.expect(t, os.make_directory(config) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/rc.xml", config),
			"<labwc_config><windowRules><windowRule title=\"stuff-drag-test\" serverDecoration=\"no\"><action name=\"MoveTo\" x=\"0\" y=\"0\"/></windowRule><windowRule title=\"stuff-drag-peer\" serverDecoration=\"no\"><action name=\"MoveTo\" x=\"960\" y=\"0\"/></windowRule></windowRules></labwc_config>",
		) ==
		nil,
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/autostart", config), "#!/bin/sh\n") == nil,
	)
	saved := [?]Drag_Test_Env {
		drag_test_env("XDG_RUNTIME_DIR", root),
		drag_test_env("WAYLAND_DISPLAY", "wayland-0"),
		drag_test_env("WLR_BACKENDS", "headless"),
		drag_test_env("WLR_HEADLESS_OUTPUTS", "1"),
		drag_test_env("WLR_RENDERER", "pixman"),
		drag_test_env("WLR_LIBINPUT_NO_DEVICES", "1"),
		drag_test_env("SDL_VIDEODRIVER", "wayland"),
		drag_test_env("SDL_RENDER_DRIVER", "software"),
		drag_test_env("SDL_MOUSE_DOUBLE_CLICK_TIME", "10"),
	}
	defer drag_test_env_restore(saved[:])
	config_c := strings.clone_to_cstring(config)
	defer delete(config_c)
	args := [?]cstring{"labwc", "-C", config_c, nil}
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	sdl_check(
		sdl.SetPointerProperty(props, sdl.PROP_PROCESS_CREATE_ARGS_POINTER, raw_data(args[:])),
	)
	sdl_check(
		sdl.SetNumberProperty(
			props,
			sdl.PROP_PROCESS_CREATE_STDOUT_NUMBER,
			i64(sdl.ProcessIO.STDIO_APP),
		),
	)
	sdl_check(
		sdl.SetBooleanProperty(props, sdl.PROP_PROCESS_CREATE_STDERR_TO_STDOUT_BOOLEAN, true),
	)
	process := sdl.CreateProcessWithProperties(props)
	if process == nil {testing.expect(t, false, "native drag tests require labwc"); return}
	defer {
		_ = sdl.KillProcess(process, true)
		code: c.int
		_ = sdl.WaitProcess(process, true, &code)
		sdl.DestroyProcess(process)
	}
	ready := false
	for _ in 0 ..< 100 {
		info, socket_err := os.lstat(fmt.tprintf("%s/wayland-0", root), context.allocator)
		if socket_err == nil {os.file_info_delete(info, context.allocator); ready = true; break}
		time.sleep(20 * time.Millisecond)
	}
	if !ready {
		_ = sdl.KillProcess(process, true)
		code: c.int
		output := sdl.ReadProcess(process, nil, &code)
		defer sdl.free(output)
		testing.expect(
			t,
			false,
			fmt.tprintf(
				"private Wayland compositor did not start (exit %d): %s",
				code,
				string(cast(cstring)output),
			),
		)
		return
	}
	if !sdl.Init({.VIDEO}) {testing.expect(t, false, string(sdl.GetError())); return}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	files := fmt.aprintf("%s/files", root)
	defer delete(files)
	testing.expect(t, os.make_directory_all(fmt.tprintf("%s/dest", files), os.perm(0o700)) == nil)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/source.txt", files), "native drag content") == nil,
	)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/source two.txt", files), "second file") == nil,
	)
	testing.expect(t, browser_load(&b, files) == nil)
	b.storage = storage_start(files)
	if b.storage == nil {testing.expect(t, false, "cannot start storage"); return}
	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !sdl.CreateWindowAndRenderer(
		"stuff-drag-test",
		960,
		640,
		{.BORDERLESS},
		&window,
		&renderer,
	) {testing.expect(t, false, string(sdl.GetError())); return}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	sdl_check(sdl.SetRenderDrawColor(renderer, 32, 32, 32, 255))
	sdl_check(sdl.RenderClear(renderer))
	sdl_check(sdl.RenderPresent(renderer))
	sdl_check(sdl.SyncWindow(window))
	b.file_drag = file_drag_init(window)
	if b.file_drag ==
	   nil {testing.expect(t, false, "native drag backend did not initialize"); return}
	defer {file_drag_destroy(b.file_drag); b.file_drag = nil}
	g := geometry(960, 640, 1)
	selection_single(&b, 1)
	selection_click(&b, 2, true, false)
	sdl_check(sdl.SetClipboardText("drag clipboard sentinel"))
	state: Drag_Test_Pointer
	registry := wl_registry_new(b.file_drag.display)
	defer wl_proxy_destroy(registry)
	assert(wl_proxy_add_listener(registry, &DRAG_TEST_REGISTRY_LISTENER, &state) == 0)
	_ = wl_display_roundtrip(b.file_drag.display)
	if state.manager ==
	   nil {testing.expect(t, false, "headless compositor has no virtual pointer"); return}
	defer wl_request_destroy(state.manager, 1)
	state.pointer = wl_proxy_marshal_flags(
		state.manager,
		0,
		&TEST_POINTER_INTERFACE,
		1,
		0,
		rawptr(nil),
		rawptr(nil),
	)
	defer wl_request_destroy(state.pointer, 8)
	_ = wl_display_roundtrip(b.file_drag.display)
	_ = wl_display_roundtrip(b.file_drag.display)
	for _ in 0 ..< 10 {drag_test_pump(&b, g, renderer); time.sleep(10 * time.Millisecond)}
	drag_test_point(state.pointer, 400, 115)
	_ = wl_display_roundtrip(b.file_drag.display)
	drag_test_pump(&b, g, renderer)
	_ = wl_proxy_marshal_flags(
		state.pointer,
		2,
		nil,
		1,
		0,
		u32(sdl.GetTicks()),
		u32(0x110),
		u32(1),
	)
	_ = wl_proxy_marshal_flags(state.pointer, 4, nil, 1, 0)
	_ = wl_display_roundtrip(b.file_drag.display)
	drag_test_pump(&b, g, renderer)
	testing.expect(t, b.file_drag.armed, "pointer press must arm the selected file")
	testing.expect_value(t, len(b.file_drag.paths), 2)
	drag_test_point(state.pointer, 420, 115)
	_ = wl_display_roundtrip(b.file_drag.display)
	drag_test_pump(&b, g, renderer)
	testing.expect(t, b.file_drag.source != nil, "pointer motion must start a native drag")
	drag_test_point(state.pointer, 450, 85)
	_ = wl_display_roundtrip(b.file_drag.display)
	drag_test_pump(&b, g, renderer)
	testing.expect_value(t, b.file_drag.target, fmt.tprintf("%s/dest", files))
	_ = wl_proxy_marshal_flags(
		state.pointer,
		2,
		nil,
		1,
		0,
		u32(sdl.GetTicks()),
		u32(0x110),
		u32(0),
	)
	_ = wl_proxy_marshal_flags(state.pointer, 4, nil, 1, 0)
	_ = wl_display_flush(b.file_drag.display)
	copied := fmt.aprintf("%s/dest/source.txt", files)
	defer delete(copied)
	deadline := sdl.GetTicks() + 5000
	for sdl.GetTicks() < deadline &&
	    (!os.exists(copied) ||
			    b.pending_files !=
				    nil) {drag_test_pump(&b, g, renderer); time.sleep(time.Millisecond)}
	testing.expect(t, os.exists(copied))
	testing.expect(t, os.exists(fmt.tprintf("%s/source.txt", files)))
	testing.expect_value(t, len(b.undo_files), 1)
	testing.expect(t, os.exists(fmt.tprintf("%s/dest/source two.txt", files)))
	clipboard := sdl.GetClipboardText()
	testing.expect_value(t, string(cast(cstring)clipboard), "drag clipboard sentinel")
	sdl.free(clipboard)
	testing.expect_value(t, b.status_error, "")
	// A second process uses SDL's unmodified receiving backend.
	peer := drag_test_spawn_peer("receive", root)
	if peer == nil {testing.expect(t, false, "cannot start external receiving client"); return}
	defer drag_test_stop_peer(peer)
	deadline = sdl.GetTicks() + 3000
	for !os.exists(fmt.tprintf("%s/peer-receive-ready", root)) &&
	    sdl.GetTicks() < deadline {drag_test_pump(&b, g, renderer); time.sleep(time.Millisecond)}
	testing.expect(t, os.exists(fmt.tprintf("%s/peer-receive-ready", root)))
	drag_test_gesture(&b, g, renderer, state.pointer, 400, 115, 1110, 100)
	deadline = sdl.GetTicks() + 3000
	for !os.exists(fmt.tprintf("%s/peer-received", root)) &&
	    sdl.GetTicks() < deadline {drag_test_pump(&b, g, renderer); time.sleep(time.Millisecond)}
	received, read_err := os.read_entire_file(
		fmt.tprintf("%s/peer-received", root),
		context.allocator,
	)
	testing.expect(t, read_err == nil)
	received_paths, valid := file_uri_paths(string(received), false)
	first, second := false, false
	for path in received_paths {
		first = first || path == fmt.tprintf("%s/source.txt", files)
		second = second || path == fmt.tprintf("%s/source two.txt", files)
	}
	testing.expect(t, valid && len(received_paths) == 2 && first && second)
	file_paths_destroy(received_paths)
	delete(received)
	// Now a separate client starts a drag into this client's folder.
	testing.expect(t, os.make_directory(fmt.tprintf("%s/peer-files", root)) == nil)
	testing.expect(
		t,
		os.write_entire_file(
			fmt.tprintf("%s/peer-files/incoming.txt", root),
			"external content",
		) ==
		nil,
	)
	sender := drag_test_spawn_peer("send", root)
	if sender == nil {testing.expect(t, false, "cannot start external sending client"); return}
	defer drag_test_stop_peer(sender)
	deadline = sdl.GetTicks() + 3000
	for !os.exists(fmt.tprintf("%s/peer-send-ready", root)) &&
	    sdl.GetTicks() < deadline {drag_test_pump(&b, g, renderer); time.sleep(time.Millisecond)}
	testing.expect(t, os.exists(fmt.tprintf("%s/peer-send-ready", root)))
	drag_test_gesture(&b, g, renderer, state.pointer, 1200, 85, 450, 85)
	deadline = sdl.GetTicks() + 3000
	for (!os.exists(fmt.tprintf("%s/dest/incoming.txt", files)) || b.pending_files != nil) &&
	    sdl.GetTicks() < deadline {drag_test_pump(&b, g, renderer); time.sleep(time.Millisecond)}
	testing.expect(t, os.exists(fmt.tprintf("%s/dest/incoming.txt", files)))
	testing.expect(t, os.exists(fmt.tprintf("%s/peer-files/incoming.txt", root)))
	testing.expect_value(t, len(b.undo_files), 2)
	testing.expect_value(t, b.status_error, "")
	content, content_err := os.read_entire_file(
		fmt.tprintf("%s/dest/incoming.txt", files),
		context.allocator,
	)
	testing.expect(t, content_err == nil)
	testing.expect_value(t, string(content), "external content")
	delete(content)
	// Reverse the actual incoming drop with an isolated trash directory.
	home := fmt.tprintf("%s/data/Trash", root)
	testing.expect_value(t, file_history_test_step(t, &b, home, false), 0)
	testing.expect(t, !os.exists(fmt.tprintf("%s/dest/incoming.txt", files)))
	testing.expect(t, os.exists(fmt.tprintf("%s/peer-files/incoming.txt", root)))
	testing.expect_value(t, file_history_test_step(t, &b, home, true), 0)
	testing.expect(t, os.exists(fmt.tprintf("%s/dest/incoming.txt", files)))
	// Dropping outside every window cancels without changing files or history.
	drag_test_gesture(&b, g, renderer, state.pointer, 400, 115, 40, 700)
	deadline = sdl.GetTicks() + 3000
	for b.file_drag.source != nil &&
	    sdl.GetTicks() < deadline {drag_test_pump(&b, g, renderer); time.sleep(time.Millisecond)}
	testing.expect(t, b.file_drag.source == nil)
	testing.expect(t, b.pending_files == nil)
	testing.expect_value(t, len(b.undo_files), 2)
	testing.expect(t, os.exists(fmt.tprintf("%s/source.txt", files)))
	testing.expect(t, os.exists(fmt.tprintf("%s/source two.txt", files)))
}
