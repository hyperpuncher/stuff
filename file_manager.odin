package main

import "core:c"
import "core:fmt"
import "core:mem"
import "core:sync"
import linux "core:sys/linux"
import "core:thread"
import sdl "vendor:sdl3"

FILE_MANAGER_NAME :: "org.freedesktop.FileManager1"
FILE_MANAGER_PATH :: "/org/freedesktop/FileManager1"
FILE_MANAGER_XML :: `<node>
<interface name="org.freedesktop.FileManager1">
<method name="ShowFolders"><arg type="as" direction="in"/><arg type="s" direction="in"/></method>
<method name="ShowItems"><arg type="as" direction="in"/><arg type="s" direction="in"/></method>
<method name="ShowItemProperties"><arg type="as" direction="in"/><arg type="s" direction="in"/></method>
</interface>
<interface name="org.freedesktop.DBus.Introspectable"><method name="Introspect"><arg type="s" direction="out"/></method></interface>
<interface name="org.freedesktop.DBus.Peer"><method name="Ping"/></interface>
</node>`

File_Manager_Request :: struct {
	items: bool,
	paths: [dynamic]string,
}

// The worker owns bus I/O. Only the request handoff uses the mutex.
File_Manager :: struct {
	bus:       ^Bus,
	worker:    ^thread.Thread,
	allocator: mem.Allocator,
	stop_fd:   linux.Fd,
	event:     sdl.EventType,
	mutex:     sync.Mutex,
	requests:  [dynamic]File_Manager_Request,
}

// Takes ownership of a private, registered connection, even on failure.
// Do not replace or queue behind another file manager.
file_manager_start :: proc(bus: ^Bus) -> ^File_Manager {
	if bus == nil {return nil}
	manager := new(File_Manager)
	manager.bus, manager.allocator, manager.stop_fd = bus, context.allocator, -1
	ok := false
	defer if !ok {file_manager_destroy(manager)}
	dbus_connection_set_exit_on_disconnect(bus, 0)
	if dbus_bus_request_name(bus, FILE_MANAGER_NAME, 4, nil) != 1 {return nil}
	fd, err := linux.eventfd(0, {.CLOEXEC, .NONBLOCK})
	if err != .NONE {return nil}
	manager.stop_fd = fd
	event := sdl.RegisterEvents(1)
	if event == 0 {return nil}
	manager.event = sdl.EventType(event)
	manager.worker = thread.create_and_start_with_poly_data(
		manager,
		file_manager_worker,
		name = "stuff-file-manager",
	)
	if manager.worker == nil {return nil}
	ok = true
	return manager
}

file_manager_destroy :: proc(manager: ^File_Manager) {
	if manager == nil {return}
	if manager.worker != nil {
		value: u64 = 1
		for {
			_, err := linux.write(manager.stop_fd, mem.ptr_to_bytes(&value))
			if err != .EINTR {break}
		}
		thread.destroy(manager.worker)
	}
	for request in manager.requests {file_paths_destroy(request.paths)}
	delete(manager.requests)
	if manager.stop_fd >= 0 {linux.close(manager.stop_fd)}
	dbus_connection_close(manager.bus)
	dbus_connection_unref(manager.bus)
	free(manager)
}

file_manager_message :: proc(manager: ^File_Manager, message: ^Bus_Message) -> ^Bus_Message {
	if string(dbus_message_get_path(message)) != FILE_MANAGER_PATH {
		return dbus_message_new_error(
			message,
			"org.freedesktop.DBus.Error.UnknownObject",
			"unknown object",
		)
	}
	interface, member, signature :=
		string(dbus_message_get_interface(message)),
		string(dbus_message_get_member(message)),
		string(dbus_message_get_signature(message))
	if interface == "org.freedesktop.DBus.Introspectable" &&
	   member == "Introspect" &&
	   signature == "" {
		reply := dbus_message_new_method_return(message)
		if reply != nil {
			iter: Bus_Iter
			dbus_message_iter_init_append(reply, &iter)
			xml: cstring = FILE_MANAGER_XML
			if dbus_message_iter_append_basic(&iter, 's', &xml) ==
			   0 {dbus_message_unref(reply); return nil}
		}
		return reply
	}
	if interface == "org.freedesktop.DBus.Peer" &&
	   member == "Ping" &&
	   signature == "" {return dbus_message_new_method_return(message)}
	if interface != FILE_MANAGER_NAME ||
	   member != "ShowItems" && member != "ShowFolders" && member != "ShowItemProperties" {
		return dbus_message_new_error(
			message,
			"org.freedesktop.DBus.Error.UnknownMethod",
			"unknown method",
		)
	}
	if signature !=
	   "ass" {return dbus_message_new_error(message, "org.freedesktop.DBus.Error.InvalidArgs", "expected an array of URIs and a startup id")}
	if member ==
	   "ShowItemProperties" {return dbus_message_new_error(message, "org.freedesktop.DBus.Error.NotSupported", "stuff has no properties dialog")}
	request := File_Manager_Request {
		items = member == "ShowItems",
	}
	iter, array: Bus_Iter
	dbus_message_iter_init(message, &iter)
	dbus_message_iter_recurse(&iter, &array)
	for dbus_message_iter_get_arg_type(&array) != 0 {
		uri: cstring
		dbus_message_iter_get_basic(&array, &uri)
		path, valid := file_uri_parse(string(uri))
		if !valid {
			file_paths_destroy(request.paths)
			return dbus_message_new_error(
				message,
				"org.freedesktop.DBus.Error.InvalidArgs",
				"only local file URIs are supported",
			)
		}
		append(&request.paths, path)
		dbus_message_iter_next(&array)
	}
	if len(request.paths) > 0 {
		sync.mutex_lock(&manager.mutex)
		wake := len(manager.requests) == 0
		append(&manager.requests, request)
		sync.mutex_unlock(&manager.mutex)
		if wake {
			notify_ui(manager.event, "file manager request")
		}
	} else {file_paths_destroy(request.paths)}
	// Acknowledge accepted requests; filesystem errors are shown by the UI.
	return dbus_message_new_method_return(message)
}

file_manager_worker :: proc(manager: ^File_Manager) {
	context.allocator = manager.allocator
	fd: c.int
	if dbus_connection_get_unix_fd(manager.bus, &fd) == 0 {return}
	for dbus_connection_read_write(manager.bus, 0) != 0 {
		for {
			message := dbus_connection_pop_message(manager.bus)
			if message == nil {break}
			if dbus_message_get_type(message) == 1 {
				reply := file_manager_message(manager, message)
				if reply != nil {
					_ = dbus_connection_send(manager.bus, reply, nil)
					dbus_message_unref(reply)
				}
			}
			dbus_message_unref(message)
		}
		fds := [2]linux.Poll_Fd {
			{fd = linux.Fd(fd), events = {.IN}},
			{fd = manager.stop_fd, events = {.IN}},
		}
		if dbus_connection_get_outgoing_size(manager.bus) > 0 {fds[0].events |= {.OUT}}
		// core:sys/linux turns an infinite `poll` timeout into an invalid ppoll
		// timespec on arm64, so wait without a timeout here.
		_, err := linux.ppoll(fds[:], nil, nil)
		if err == .EINTR {continue}
		if err != .NONE {fmt.eprintfln("cannot wait for file manager requests: %v", err); return}
		if fds[1].revents != {} {return}
	}
}

file_manager_take :: proc(manager: ^File_Manager) -> [dynamic]File_Manager_Request {
	sync.mutex_guard(&manager.mutex)
	requests := manager.requests
	manager.requests = nil
	return requests
}

file_manager_poll :: proc(manager: ^File_Manager, b: ^Browser, window: ^sdl.Window) -> bool {
	if manager == nil {return false}
	requests := file_manager_take(manager)
	defer delete(requests)
	for request in requests {
		defer file_paths_destroy(request.paths)
		groups, err := file_manager_groups(request.paths[:], request.items)
		defer file_manager_groups_destroy(groups)
		if err !=
		   nil {browser_message(b, fmt.tprintf("cannot show requested folder: %v", err)); continue}
		for group, i in groups {
			if i == 0 {
				if show_err := file_manager_show(b, group);
				   show_err !=
				   nil {browser_message(b, fmt.tprintf("cannot show %s: %v", group.folder, show_err))}
			} else if !file_manager_spawn(
				group,
			) {browser_message(b, fmt.tprintf("cannot open %s: %s", group.folder, string(sdl.GetError())))}
		}
	}
	if len(requests) > 0 && window != nil {_ = sdl.RaiseWindow(window)}
	return len(requests) > 0
}
