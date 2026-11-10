package main

import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

foreign import test_dbus_lib "system:dbus-1"

@(default_calling_convention = "c")
foreign test_dbus_lib {
	dbus_connection_open_private :: proc(address: cstring, error: rawptr) -> ^Bus ---
	dbus_bus_register :: proc(bus: ^Bus, error: rawptr) -> u32 ---
	dbus_message_get_error_name :: proc(message: ^Bus_Message) -> cstring ---
}

Test_Bus :: struct {
	process:    ^sdl.Process,
	connection: ^Bus,
	address:    cstring,
}

test_bus_start :: proc(service: cstring) -> (fixture: Test_Bus, ok: bool) {
	defer if !ok {test_bus_destroy(fixture)}
	if dbus_threads_init_default() == 0 {return}
	args := [?]cstring{"dbus-daemon", "--session", "--nofork", "--print-address=1", nil}
	fixture.process = sdl.CreateProcess(raw_data(args[:]), true)
	if fixture.process == nil {return}
	output: [dynamic]u8
	defer delete(output)
	deadline := sdl.GetTicks() + 3000
	for sdl.GetTicks() < deadline && !strings.contains(string(output[:]), "\n") {
		buffer: [512]u8
		n := sdl.ReadIO(sdl.GetProcessOutput(fixture.process), &buffer[0], len(buffer))
		append(&output, ..buffer[:n])
		time.sleep(time.Millisecond)
	}
	if !strings.contains(string(output[:]), "\n") {return}
	fixture.address = strings.clone_to_cstring(strings.trim_space(string(output[:])))
	fixture.connection = dbus_connection_open_private(fixture.address, nil)
	if fixture.connection == nil {return}
	dbus_connection_set_exit_on_disconnect(fixture.connection, 0)
	if dbus_bus_register(fixture.connection, nil) == 0 {return}
	ok = dbus_bus_request_name(fixture.connection, service, 4, nil) == 1
	return
}

test_bus_destroy :: proc(fixture: Test_Bus) {
	if fixture.connection !=
	   nil {dbus_connection_close(fixture.connection); dbus_connection_unref(fixture.connection)}
	if fixture.process != nil {
		_ = sdl.KillProcess(fixture.process, true)
		_ = sdl.WaitProcess(fixture.process, true, nil)
		sdl.DestroyProcess(fixture.process)
	}
	delete(fixture.address)
}

@(test)
udisks_calls_use_an_isolated_bus :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	fixture, ok := test_bus_start("org.freedesktop.UDisks2")
	if !ok {testing.fail_now(t, "cannot start private UDisks test bus")}
	defer test_bus_destroy(fixture)
	server, address := fixture.connection, fixture.address

	for scenario in 0 ..< 3 {
		op := new(Disk_Operation)
		defer disk_operation_destroy(op)
		op.device = strings.clone("/dev/fixture;not-a-command")
		op.unmount = scenario != 0
		client := dbus_connection_open_private(address, nil)
		if client == nil {testing.fail_now(t, "cannot open test client")}
		testing.expect(t, dbus_bus_register(client, nil) != 0)
		call := Disk_Call {
			bus = client,
		}
		defer disk_call_destroy(&call)
		disk_call_start(&call, op)
		deadline := sdl.GetTicks() + 3000
		resolved, acted, done := false, false, false
		for sdl.GetTicks() < deadline && !done {
			_ = dbus_connection_read_write(server, 0)
			for {
				request := dbus_connection_pop_message(server)
				if request == nil {break}
				defer dbus_message_unref(request)
				if dbus_message_get_type(request) != 1 {continue}
				member := string(dbus_message_get_member(request))
				iter: Bus_Iter
				reply: ^Bus_Message
				if member == "ResolveDevice" {
					testing.expect_value(
						t,
						string(dbus_message_get_signature(request)),
						"a{sv}a{sv}",
					)
					// Read the actual dictionary and variant sent over D-Bus.
					array, entry, variant: Bus_Iter
					dbus_message_iter_init(request, &iter)
					dbus_message_iter_recurse(&iter, &array)
					dbus_message_iter_recurse(&array, &entry)
					key, device: cstring
					dbus_message_iter_get_basic(&entry, &key)
					testing.expect_value(t, string(key), "path")
					dbus_message_iter_next(&entry)
					dbus_message_iter_recurse(&entry, &variant)
					dbus_message_iter_get_basic(&variant, &device)
					testing.expect_value(t, string(device), op.device)
					reply = dbus_message_new_method_return(request)
					dbus_message_iter_init_append(reply, &iter)
					assert(dbus_message_iter_open_container(&iter, 'a', "o", &array) != 0)
					path: cstring = "/org/freedesktop/UDisks2/block_devices/fixture"
					assert(dbus_message_iter_append_basic(&array, 'o', &path) != 0)
					assert(dbus_message_iter_close_container(&iter, &array) != 0)
					resolved = true
				} else {
					testing.expect(t, resolved)
					testing.expect_value(t, member, op.unmount ? "Unmount" : "Mount")
					testing.expect_value(t, string(dbus_message_get_signature(request)), "a{sv}")
					acted = true
					if scenario == 2 {continue} 	// No reply: cancellation must not block.
					if scenario == 1 {
						reply = dbus_message_new_error(
							request,
							"org.freedesktop.UDisks2.Error.DeviceBusy",
							"fixture volume is busy",
						)
					} else {
						reply = dbus_message_new_method_return(request)
						dbus_message_iter_init_append(reply, &iter)
						path: cstring = "/tmp/mount point Д"
						assert(dbus_message_iter_append_basic(&iter, 's', &path) != 0)
					}
				}
				assert(reply != nil)
				testing.expect(t, dbus_connection_send(server, reply, nil) != 0)
				dbus_message_unref(reply)
				dbus_connection_flush(server)
			}
			if scenario == 2 && acted {break}
			done = disk_call_poll(&call)
			time.sleep(time.Millisecond)
		}
		testing.expect(t, resolved && acted)
		if scenario == 0 {
			testing.expect(t, done && op.error == "")
			testing.expect_value(t, op.mountpoint, "/tmp/mount point Д")
		} else if scenario == 1 {
			testing.expect(t, done && op.error == "fixture volume is busy")
		} else {testing.expect(t, !done)}
	}
}
