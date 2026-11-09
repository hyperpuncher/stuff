package main

import "core:math"
import "core:strconv"
import "core:strings"

// Desktop descriptions use points unless the size has an explicit px suffix.
// Convert absolute pixels at 96 logical DPI; SDL_ttf handles font rasterization.
font_description_points :: proc(description: string) -> f32 {
	size := description
	if space := strings.last_index_byte(size, ' '); space >= 0 {size = size[space + 1:]}
	pixels := strings.has_suffix(size, "px")
	if pixels {size = strings.trim_suffix(size, "px")}
	value, ok := strconv.parse_f32(size)
	if !ok || value <= 0 || math.is_nan(value) || math.is_inf(value) {return 0}
	return pixels ? value * (72.0 / 96.0) : value
}

// Portal queries are bounded and only run at startup. A returned message owns
// its variant data and must stay alive while the value is read.
font_setting :: proc(bus: ^Bus, key: cstring) -> ^Bus_Message {
	message := dbus_message_new_method_call(
		"org.freedesktop.portal.Desktop",
		"/org/freedesktop/portal/desktop",
		"org.freedesktop.portal.Settings",
		"ReadOne",
	)
	if message == nil {return nil}
	defer dbus_message_unref(message)
	iter: Bus_Iter
	dbus_message_iter_init_append(message, &iter)
	namespace: cstring = "org.gnome.desktop.interface"
	name := key
	if dbus_message_iter_append_basic(&iter, 's', &namespace) == 0 ||
	   dbus_message_iter_append_basic(&iter, 's', &name) == 0 {return nil}
	return dbus_connection_send_with_reply_and_block(bus, message, 500, nil)
}

font_setting_variant :: proc(message: ^Bus_Message) -> (value: Bus_Iter, ok: bool) {
	iter: Bus_Iter
	if message == nil ||
	   dbus_message_iter_init(message, &iter) == 0 ||
	   dbus_message_iter_get_arg_type(&iter) != 'v' {return}
	dbus_message_iter_recurse(&iter, &value)
	return value, true
}

desktop_font_points :: proc() -> f32 {
	DEFAULT :: 14 * (72.0 / 96.0) // 14 logical pixels, expressed as points.
	if dbus_threads_init_default() == 0 {return DEFAULT}
	bus := dbus_bus_get_private(0, nil) // Session bus, not the storage system bus.
	if bus == nil {return DEFAULT}
	defer {dbus_connection_close(bus); dbus_connection_unref(bus)}
	dbus_connection_set_exit_on_disconnect(bus, 0)
	message := font_setting(bus, "monospace-font-name")
	if message == nil {return DEFAULT}
	defer dbus_message_unref(message)
	value, valid := font_setting_variant(message)
	if !valid || dbus_message_iter_get_arg_type(&value) != 's' {return DEFAULT}
	description: cstring
	dbus_message_iter_get_basic(&value, &description)
	points := font_description_points(string(description))
	if points == 0 {return DEFAULT}
	scaling := font_setting(bus, "text-scaling-factor")
	if scaling != nil {
		defer dbus_message_unref(scaling)
		factor, exists := font_setting_variant(scaling)
		if exists && dbus_message_iter_get_arg_type(&factor) == 'd' {
			scale: f64
			dbus_message_iter_get_basic(&factor, &scale)
			if scale > 0 && !math.is_nan(scale) && !math.is_inf(scale) {points *= f32(scale)}
		}
	}
	return points
}
