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
import sdl "vendor:sdl3"

foreign import chooser_test_bus "system:dbus-1"

@(default_calling_convention = "c")
foreign chooser_test_bus {
	dbus_message_new_signal :: proc(path, interface, name: cstring) -> ^Bus_Message ---
}

Chooser_Test_Job :: struct {
	op:        ^File_Operation,
	bus:       ^Bus,
	fd:        linux.Fd,
	allocator: mem.Allocator,
	done:      bool,
}

chooser_test_worker :: proc(data: rawptr) {
	job := cast(^Chooser_Test_Job)data
	context.allocator = job.allocator
	job.op.error = chooser_wait(job.op, job.bus, job.fd, false)
	sync.atomic_store(&job.done, true)
}

@(test)
application_chooser_uses_private_bus_fd_and_explicit_choice :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	fixture, ok := test_bus_start("org.freedesktop.portal.Desktop")
	if !ok {testing.fail_now(t, "cannot start private chooser test bus")}
	defer test_bus_destroy(fixture)
	server, address := fixture.connection, fixture.address
	root, err := os.make_directory_temp("/tmp", "stuff-chooser-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create chooser fixture")}
	defer delete(root)
	defer os.remove_all(root)
	path := fmt.aprintf("%s/file", root)
	defer delete(path)
	testing.expect(t, os.write_entire_file(path, "chooser fixture") == nil)
	path_c := strings.clone_to_cstring(path)
	defer delete(path_c)
	fd, fd_err := linux.open(path_c, {.CLOEXEC})
	if fd_err != .NONE {testing.fail_now(t, "cannot open chooser fixture")}
	defer linux.close(fd)
	expected: linux.Stat
	testing.expect(t, linux.fstat(fd, &expected) == .NONE)
	for scenario in 0 ..< 4 {
		op := new(File_Operation)
		defer file_operation_destroy(op)
		client := dbus_connection_open_private(address, nil)
		if client == nil {testing.fail_now(t, "cannot open chooser client")}
		defer {dbus_connection_close(client); dbus_connection_unref(client)}
		testing.expect(t, dbus_bus_register(client, nil) != 0)
		dbus_connection_set_exit_on_disconnect(client, 0)
		job := Chooser_Test_Job {
			op        = op,
			bus       = client,
			fd        = fd,
			allocator = context.allocator,
		}
		worker := thread.create_and_start_with_data(&job, chooser_test_worker)
		if worker == nil {testing.fail_now(t, "cannot start chooser test")}
		acted := false
		deadline := sdl.GetTicks() + 3000
		for sdl.GetTicks() < deadline && !sync.atomic_load(&job.done) {
			_ = dbus_connection_read_write(server, 0)
			for {
				request := dbus_connection_pop_message(server)
				if request == nil {break}
				defer dbus_message_unref(request)
				if dbus_message_get_type(request) != 1 {continue}
				testing.expect_value(t, string(dbus_message_get_member(request)), "OpenFile")
				testing.expect_value(t, string(dbus_message_get_signature(request)), "sha{sv}")
				iter, array, entry, variant: Bus_Iter
				dbus_message_iter_init(request, &iter)
				dbus_message_iter_next(&iter)
				received: linux.Fd
				dbus_message_iter_get_basic(&iter, &received)
				actual: linux.Stat
				testing.expect(t, linux.fstat(received, &actual) == .NONE)
				testing.expect_value(t, actual.ino, expected.ino)
				linux.close(received)
				dbus_message_iter_next(&iter)
				dbus_message_iter_recurse(&iter, &array)
				asked := false
				token: cstring
				for dbus_message_iter_get_arg_type(&array) != 0 {
					dbus_message_iter_recurse(&array, &entry)
					key: cstring
					dbus_message_iter_get_basic(&entry, &key)
					dbus_message_iter_next(&entry)
					dbus_message_iter_recurse(&entry, &variant)
					if string(key) ==
					   "ask" {value: u32; dbus_message_iter_get_basic(&variant, &value); asked = value == 1}
					if string(key) ==
					   "handle_token" {dbus_message_iter_get_basic(&variant, &token)}
					dbus_message_iter_next(&array)
				}
				testing.expect(t, asked && len(string(token)) > 16)
				handle := chooser_handle(client, token)
				defer delete(handle)
				handle_c := strings.clone_to_cstring(handle)
				defer delete(handle_c)
				acted = true
				if scenario == 3 {sync.atomic_store(&op.cancel, true); continue}
				reply :=
					scenario == 2 ? dbus_message_new_error(request, "org.freedesktop.portal.Error.Failed", "fixture chooser error") : dbus_message_new_method_return(request)
				if scenario != 2 {
					dbus_message_iter_init_append(reply, &iter)
					assert(dbus_message_iter_append_basic(&iter, 'o', &handle_c) != 0)
					// A response can arrive before the method acknowledgement.
					signal := dbus_message_new_signal(
						handle_c,
						"org.freedesktop.portal.Request",
						"Response",
					)
					dbus_message_iter_init_append(signal, &iter)
					code := u32(scenario)
					assert(dbus_message_iter_append_basic(&iter, 'u', &code) != 0)
					assert(dbus_message_iter_open_container(&iter, 'a', "{sv}", &array) != 0)
					assert(dbus_message_iter_close_container(&iter, &array) != 0)
					assert(dbus_connection_send(server, signal, nil) != 0)
					dbus_message_unref(signal)
				}
				assert(dbus_connection_send(server, reply, nil) != 0)
				dbus_message_unref(reply)
				dbus_connection_flush(server)
			}
			time.sleep(time.Millisecond)
		}
		finished := sync.atomic_load(&job.done)
		sync.atomic_store(&op.cancel, true)
		thread.destroy(worker)
		testing.expect(t, acted && finished)
		if scenario ==
		   2 {testing.expect(t, strings.contains(op.error, "fixture chooser error"))} else {testing.expect_value(t, op.error, "")}
	}
}
