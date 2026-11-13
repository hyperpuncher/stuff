package main

import "core:strings"
import sdl "vendor:sdl3"

// The worker owns this request until it transfers it back in a result.
// The UI borrows device/origin/unmount for pending feedback; these never change.
Disk_Operation :: struct {
	device, origin, mountpoint: string,
	unmount:                    bool,
	error:                      string,
}

Disk_Call :: struct {
	bus:       ^Bus,
	pending:   ^Bus_Pending,
	resolving: bool,
	deadline:  u64,
	op:        ^Disk_Operation,
}

disk_operation_destroy :: proc(op: ^Disk_Operation) {
	if op == nil {return}
	delete(op.device)
	delete(op.origin)
	delete(op.mountpoint)
	delete(op.error)
	free(op)
}

bus_options :: proc(iter: ^Bus_Iter, device: cstring = nil) {
	array, entry, variant: Bus_Iter
	assert(dbus_message_iter_open_container(iter, 'a', "{sv}", &array) != 0)
	if device != nil {
		key: cstring = "path"
		assert(dbus_message_iter_open_container(&array, 'e', nil, &entry) != 0)
		assert(dbus_message_iter_append_basic(&entry, 's', &key) != 0)
		assert(dbus_message_iter_open_container(&entry, 'v', "s", &variant) != 0)
		value := device
		assert(dbus_message_iter_append_basic(&variant, 's', &value) != 0)
		assert(dbus_message_iter_close_container(&entry, &variant) != 0)
		assert(dbus_message_iter_close_container(&array, &entry) != 0)
	}
	assert(dbus_message_iter_close_container(iter, &array) != 0)
}

bus_send :: proc(call: ^Disk_Call, message: ^Bus_Message) -> bool {
	defer dbus_message_unref(message)
	dbus_message_set_allow_interactive_authorization(message, 1)
	if dbus_connection_send_with_reply(call.bus, message, &call.pending, 120_000) == 0 ||
	   call.pending == nil {return false}
	dbus_connection_flush(call.bus)
	call.deadline = sdl.GetTicks() + 120_000
	return true
}

disk_call_start :: proc(call: ^Disk_Call, op: ^Disk_Operation) {
	call.op = op
	if call.bus == nil {call.bus = dbus_bus_get_private(1, nil)} 	// System bus; worker-owned.
	if call.bus == nil {
		op.error = strings.clone("system D-Bus is unavailable")
		return
	}
	dbus_connection_set_exit_on_disconnect(call.bus, 0)
	message := dbus_message_new_method_call(
		"org.freedesktop.UDisks2",
		"/org/freedesktop/UDisks2/Manager",
		"org.freedesktop.UDisks2.Manager",
		"ResolveDevice",
	)
	if message == nil {op.error = strings.clone("cannot create disk request"); return}
	iter: Bus_Iter
	dbus_message_iter_init_append(message, &iter)
	device := strings.clone_to_cstring(op.device, context.temp_allocator)
	bus_options(&iter, device)
	bus_options(&iter)
	call.resolving = true
	if !bus_send(call, message) {op.error = strings.clone("cannot send disk request")}
}

disk_call_poll :: proc(call: ^Disk_Call) -> bool {
	if call.op == nil {return false}
	if call.op.error != "" {return true}
	if sdl.GetTicks() >= call.deadline {
		return disk_call_fail(call, "disk operation timed out")
	}
	if dbus_connection_read_write(call.bus, 0) == 0 {
		return disk_call_fail(call, "system D-Bus disconnected")
	}
	for dbus_connection_get_dispatch_status(call.bus) == 0 {dbus_connection_dispatch(call.bus)}
	if dbus_pending_call_get_completed(call.pending) == 0 {return false}
	reply := dbus_pending_call_steal_reply(call.pending)
	dbus_pending_call_unref(call.pending)
	call.pending = nil
	if reply == nil {return disk_call_fail(call, "no response from UDisks2")}
	defer dbus_message_unref(reply)
	iter: Bus_Iter
	dbus_message_iter_init(reply, &iter)
	if dbus_message_get_type(reply) == 3 {
		text: cstring
		if dbus_message_iter_get_arg_type(&iter) == 's' {dbus_message_iter_get_basic(&iter, &text)}
		return disk_call_fail(call, text == nil ? "UDisks2 request failed" : string(text))
	}
	signature := string(dbus_message_get_signature(reply))
	if call.resolving {
		if signature != "ao" {return disk_call_fail(call, "invalid device response from UDisks2")}
		child: Bus_Iter
		dbus_message_iter_recurse(&iter, &child)
		if dbus_message_iter_get_arg_type(&child) !=
		   'o' {return disk_call_fail(call, "disk is no longer available")}
		path: cstring
		dbus_message_iter_get_basic(&child, &path)
		method: cstring = call.op.unmount ? "Unmount" : "Mount"
		message := dbus_message_new_method_call(
			"org.freedesktop.UDisks2",
			path,
			"org.freedesktop.UDisks2.Filesystem",
			method,
		)
		if message == nil {return disk_call_fail(call, "cannot create disk request")}
		args: Bus_Iter
		dbus_message_iter_init_append(message, &args)
		bus_options(&args)
		call.resolving = false
		if !bus_send(call, message) {return disk_call_fail(call, "cannot send disk request")}
		return false
	}
	if !call.op.unmount {
		if signature != "s" {return disk_call_fail(call, "invalid mount response from UDisks2")}
		path: cstring
		dbus_message_iter_get_basic(&iter, &path)
		replace_owned(&call.op.mountpoint, string(path))
	} else if signature != "" {
		return disk_call_fail(call, "invalid unmount response from UDisks2")
	}
	return true
}

disk_call_fail :: proc(call: ^Disk_Call, message: string) -> bool {
	if call.op.error == "" {call.op.error = strings.clone(message)}
	return true
}

disk_call_destroy :: proc(call: ^Disk_Call) {
	if call.pending != nil {
		dbus_pending_call_cancel(call.pending)
		dbus_pending_call_unref(call.pending)
	}
	if call.bus != nil {dbus_connection_close(call.bus); dbus_connection_unref(call.bus)}
	call^ = {}
}
