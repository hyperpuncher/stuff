#+build linux
package main

import "core:c"

// Public libudev and libdbus APIs used by the native workers.
foreign import udev_lib "system:udev"
foreign import dbus_lib "system:dbus-1"

Udev :: struct {}
Udev_Device :: struct {}
Udev_List :: struct {}
Udev_Enumeration :: struct {}
Udev_Monitor :: struct {}

@(default_calling_convention = "c")
foreign udev_lib {
	udev_new :: proc() -> ^Udev ---
	udev_unref :: proc(u: ^Udev) -> ^Udev ---
	udev_enumerate_new :: proc(u: ^Udev) -> ^Udev_Enumeration ---
	udev_enumerate_unref :: proc(e: ^Udev_Enumeration) -> ^Udev_Enumeration ---
	udev_enumerate_add_match_subsystem :: proc(e: ^Udev_Enumeration, name: cstring) -> c.int ---
	udev_enumerate_add_match_property :: proc(e: ^Udev_Enumeration, name, value: cstring) -> c.int ---
	udev_enumerate_scan_devices :: proc(e: ^Udev_Enumeration) -> c.int ---
	udev_enumerate_get_list_entry :: proc(e: ^Udev_Enumeration) -> ^Udev_List ---
	udev_list_entry_get_next :: proc(e: ^Udev_List) -> ^Udev_List ---
	udev_list_entry_get_name :: proc(e: ^Udev_List) -> cstring ---
	udev_device_new_from_syspath :: proc(u: ^Udev, path: cstring) -> ^Udev_Device ---
	udev_device_unref :: proc(d: ^Udev_Device) -> ^Udev_Device ---
	udev_device_get_devnode :: proc(d: ^Udev_Device) -> cstring ---
	udev_device_get_devnum :: proc(d: ^Udev_Device) -> u64 ---
	udev_device_get_sysname :: proc(d: ^Udev_Device) -> cstring ---
	udev_device_get_property_value :: proc(d: ^Udev_Device, key: cstring) -> cstring ---
	udev_monitor_new_from_netlink :: proc(u: ^Udev, name: cstring) -> ^Udev_Monitor ---
	udev_monitor_unref :: proc(m: ^Udev_Monitor) -> ^Udev_Monitor ---
	udev_monitor_filter_add_match_subsystem_devtype :: proc(m: ^Udev_Monitor, subsystem, devtype: cstring) -> c.int ---
	udev_monitor_enable_receiving :: proc(m: ^Udev_Monitor) -> c.int ---
	udev_monitor_get_fd :: proc(m: ^Udev_Monitor) -> c.int ---
	udev_monitor_receive_device :: proc(m: ^Udev_Monitor) -> ^Udev_Device ---
}

Bus :: struct {}
Bus_Message :: struct {}
Bus_Pending :: struct {}

// Public DBusMessageIter layout from dbus-message.h. No fields are accessed.
Bus_Iter :: struct {
	pointers: [2]rawptr,
	values:   [10]u32,
	padding:  [2]rawptr,
}
#assert(size_of(Bus_Iter) == 72)

@(default_calling_convention = "c")
foreign dbus_lib {
	dbus_threads_init_default :: proc() -> u32 ---
	dbus_bus_get_private :: proc(kind: c.int, error: rawptr) -> ^Bus ---
	dbus_bus_request_name :: proc(bus: ^Bus, name: cstring, flags: u32, error: rawptr) -> c.int ---
	dbus_connection_pop_message :: proc(bus: ^Bus) -> ^Bus_Message ---
	dbus_connection_send :: proc(bus: ^Bus, message: ^Bus_Message, serial: ^u32) -> u32 ---
	dbus_message_get_member :: proc(message: ^Bus_Message) -> cstring ---
	dbus_message_new_method_return :: proc(message: ^Bus_Message) -> ^Bus_Message ---
	dbus_message_new_error :: proc(message: ^Bus_Message, name, text: cstring) -> ^Bus_Message ---
	dbus_message_iter_next :: proc(iter: ^Bus_Iter) -> u32 ---
	dbus_message_get_interface :: proc(message: ^Bus_Message) -> cstring ---
	dbus_connection_get_outgoing_size :: proc(bus: ^Bus) -> c.long ---
	dbus_bus_get_unique_name :: proc(bus: ^Bus) -> cstring ---
	dbus_bus_add_match :: proc(bus: ^Bus, rule: cstring, error: rawptr) ---
	dbus_connection_add_filter :: proc(bus: ^Bus, callback: proc "c" (bus: ^Bus, message: ^Bus_Message, data: rawptr) -> c.int, data, free_data: rawptr) -> u32 ---
	dbus_connection_remove_filter :: proc(bus: ^Bus, callback: proc "c" (bus: ^Bus, message: ^Bus_Message, data: rawptr) -> c.int, data: rawptr) ---
	dbus_message_is_signal :: proc(message: ^Bus_Message, interface, name: cstring) -> u32 ---
	dbus_message_get_path :: proc(message: ^Bus_Message) -> cstring ---
	dbus_connection_set_exit_on_disconnect :: proc(bus: ^Bus, exit: u32) ---
	dbus_connection_close :: proc(bus: ^Bus) ---
	dbus_connection_unref :: proc(bus: ^Bus) ---
	dbus_connection_get_unix_fd :: proc(bus: ^Bus, fd: ^c.int) -> u32 ---
	dbus_connection_read_write :: proc(bus: ^Bus, timeout: c.int) -> u32 ---
	dbus_connection_get_dispatch_status :: proc(bus: ^Bus) -> c.int ---
	dbus_connection_dispatch :: proc(bus: ^Bus) -> c.int ---
	dbus_connection_send_with_reply_and_block :: proc(bus: ^Bus, message: ^Bus_Message, timeout: c.int, error: rawptr) -> ^Bus_Message ---
	dbus_connection_send_with_reply :: proc(bus: ^Bus, message: ^Bus_Message, pending: ^^Bus_Pending, timeout: c.int) -> u32 ---
	dbus_connection_flush :: proc(bus: ^Bus) ---
	dbus_pending_call_cancel :: proc(pending: ^Bus_Pending) ---
	dbus_pending_call_unref :: proc(pending: ^Bus_Pending) ---
	dbus_pending_call_get_completed :: proc(pending: ^Bus_Pending) -> u32 ---
	dbus_pending_call_steal_reply :: proc(pending: ^Bus_Pending) -> ^Bus_Message ---
	dbus_message_new_method_call :: proc(destination, path, iface, method: cstring) -> ^Bus_Message ---
	dbus_message_unref :: proc(message: ^Bus_Message) ---
	dbus_message_set_allow_interactive_authorization :: proc(message: ^Bus_Message, allow: u32) ---
	dbus_message_get_type :: proc(message: ^Bus_Message) -> c.int ---
	dbus_message_get_signature :: proc(message: ^Bus_Message) -> cstring ---
	dbus_message_iter_init :: proc(message: ^Bus_Message, iter: ^Bus_Iter) -> u32 ---
	dbus_message_iter_init_append :: proc(message: ^Bus_Message, iter: ^Bus_Iter) ---
	dbus_message_iter_recurse :: proc(iter, child: ^Bus_Iter) ---
	dbus_message_iter_get_arg_type :: proc(iter: ^Bus_Iter) -> c.int ---
	dbus_message_iter_get_basic :: proc(iter: ^Bus_Iter, value: rawptr) ---
	dbus_message_iter_append_basic :: proc(iter: ^Bus_Iter, kind: c.int, value: rawptr) -> u32 ---
	dbus_message_iter_open_container :: proc(iter: ^Bus_Iter, kind: c.int, signature: cstring, child: ^Bus_Iter) -> u32 ---
	dbus_message_iter_close_container :: proc(iter, child: ^Bus_Iter) -> u32 ---
}
