package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import linux "core:sys/linux"

Chooser_Response :: struct {
	handle: string,
	done:   bool,
	code:   u32,
}

chooser_response :: proc "c" (bus: ^Bus, message: ^Bus_Message, data: rawptr) -> c.int {
	state := cast(^Chooser_Response)data
	if dbus_message_is_signal(message, "org.freedesktop.portal.Request", "Response") == 0 ||
	   string(dbus_message_get_path(message)) != state.handle {return 1}
	if string(dbus_message_get_signature(message)) != "ua{sv}" {return 1}
	iter: Bus_Iter
	dbus_message_iter_init(message, &iter)
	dbus_message_iter_get_basic(&iter, &state.code)
	state.done = true
	return 0
}

chooser_handle :: proc(bus: ^Bus, token: cstring) -> string {
	unique := string(dbus_bus_get_unique_name(bus))
	sender, _ := strings.replace_all(unique[1:], ".", "_", context.temp_allocator)
	return fmt.aprintf("/org/freedesktop/portal/desktop/request/%s/%s", sender, string(token))
}

chooser_message :: proc(fd: linux.Fd, writable: bool, token: cstring) -> ^Bus_Message {
	message := dbus_message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.OpenURI",
		"OpenFile",
	)
	if message == nil {return nil}
	iter, array, entry, variant: Bus_Iter
	dbus_message_iter_init_append(message, &iter)
	parent: cstring = "" // The portal permits an unparented chooser on Wayland.
	assert(dbus_message_iter_append_basic(&iter, 's', &parent) != 0)
	descriptor := fd
	assert(dbus_message_iter_append_basic(&iter, 'h', &descriptor) != 0)
	assert(dbus_message_iter_open_container(&iter, 'a', "{sv}", &array) != 0)
	for option in 0 ..< 3 {
		key: cstring = option == 0 ? "handle_token" : option == 1 ? "ask" : "writable"
		assert(dbus_message_iter_open_container(&array, 'e', nil, &entry) != 0)
		assert(dbus_message_iter_append_basic(&entry, 's', &key) != 0)
		assert(
			dbus_message_iter_open_container(&entry, 'v', option == 0 ? "s" : "b", &variant) != 0,
		)
		if option == 0 {
			value := token
			assert(dbus_message_iter_append_basic(&variant, 's', &value) != 0)
		} else {
			value: u32 = option == 1 || writable ? 1 : 0
			assert(dbus_message_iter_append_basic(&variant, 'b', &value) != 0)
		}
		assert(dbus_message_iter_close_container(&entry, &variant) != 0)
		assert(dbus_message_iter_close_container(&array, &entry) != 0)
	}
	assert(dbus_message_iter_close_container(&iter, &array) != 0)
	return message
}

// This runs on the file worker. The private connection stays alive until the
// response, so closing a method reply cannot cancel the chooser prematurely.
chooser_wait :: proc(op: ^File_Operation, bus: ^Bus, fd: linux.Fd, writable: bool) -> string {
	random: [16]u8
	n, random_error := linux.getrandom(random[:], {})
	if random_error != .NONE ||
	   n != len(random) {return strings.clone("cannot create application chooser token")}
	words := transmute([2]u64)random
	token := fmt.caprintf("stuff_%016x%016x", words[0], words[1])
	defer delete(token)
	state := Chooser_Response {
		handle = chooser_handle(bus, token),
	}
	defer delete(state.handle)
	if dbus_connection_add_filter(bus, chooser_response, &state, nil) ==
	   0 {return strings.clone("cannot watch application chooser")}
	defer dbus_connection_remove_filter(bus, chooser_response, &state)
	dbus_bus_add_match(
		bus,
		"type='signal',interface='org.freedesktop.portal.Request',member='Response'",
		nil,
	)
	message := chooser_message(fd, writable, token)
	if message == nil {return strings.clone("cannot create application chooser request")}
	defer dbus_message_unref(message)
	pending: ^Bus_Pending
	if dbus_connection_send_with_reply(bus, message, &pending, 5000) == 0 ||
	   pending == nil {return strings.clone("cannot send application chooser request")}
	defer {dbus_pending_call_cancel(pending); dbus_pending_call_unref(pending)}
	dbus_connection_flush(bus)
	accepted := false
	for !sync.atomic_load(&op.cancel) {
		if dbus_connection_read_write(bus, 50) ==
		   0 {return strings.clone("application chooser disconnected")}
		for dbus_connection_get_dispatch_status(bus) == 0 {dbus_connection_dispatch(bus)}
		if !accepted && dbus_pending_call_get_completed(pending) != 0 {
			reply := dbus_pending_call_steal_reply(pending)
			if reply == nil {return strings.clone("application chooser did not reply")}
			defer dbus_message_unref(reply)
			iter: Bus_Iter
			dbus_message_iter_init(reply, &iter)
			if dbus_message_get_type(reply) == 3 {
				text: cstring
				if dbus_message_iter_get_arg_type(&iter) ==
				   's' {dbus_message_iter_get_basic(&iter, &text)}
				return fmt.aprintf("application chooser: %s", string(text))
			}
			if string(dbus_message_get_signature(reply)) !=
			   "o" {return strings.clone("invalid application chooser reply")}
			returned: cstring
			dbus_message_iter_get_basic(&iter, &returned)
			if string(returned) !=
			   state.handle {return strings.clone("unexpected application chooser handle")}
			accepted = true
		}
		if accepted &&
		   state.done {return state.code <= 1 ? "" : strings.clone("application chooser failed")}
	}
	return ""
}

open_with_run :: proc(op: ^File_Operation) -> string {
	path := strings.clone_to_cstring(op.sources[0])
	defer delete(path)
	original, err := linux.open(path, {.PATH, .CLOEXEC})
	if err != .NONE {return strings.clone(os.error_string(err))}
	defer linux.close(original)
	st: linux.Stat
	if err = linux.fstat(original, &st); err != .NONE {return strings.clone(os.error_string(err))}
	if st.mode & linux.S_IFMT != linux.S_IFREG {return strings.clone("choose a regular file")}
	// Reopen the verified object, not a pathname that could now name a device.
	fd_path := fmt.caprintf("/proc/self/fd/%d", original)
	defer delete(fd_path)
	fd, open_err := linux.open(fd_path, {.RDWR, .NONBLOCK, .CLOEXEC})
	writable := open_err == .NONE
	if open_err == .EACCES ||
	   open_err == .EROFS ||
	   open_err == .ETXTBSY {fd, open_err = linux.open(fd_path, {.NONBLOCK, .CLOEXEC})}
	if open_err != .NONE {return strings.clone(os.error_string(open_err))}
	defer linux.close(fd)
	bus := dbus_bus_get_private(0, nil)
	if bus == nil {return strings.clone("the desktop application chooser is unavailable")}
	defer {dbus_connection_close(bus); dbus_connection_unref(bus)}
	dbus_connection_set_exit_on_disconnect(bus, 0)
	return chooser_wait(op, bus, fd, writable)
}

open_with_start :: proc(b: ^Browser) {
	if len(b.marks) != 1 || b.pending_files != nil || b.storage == nil {return}
	op := new(File_Operation)
	op.kind, op.sources = .Open_With, selection_paths(b)
	op.target = strings.clone(b.path)
	if !file_operation_launch(b, op) {file_operation_destroy(op)}
}
