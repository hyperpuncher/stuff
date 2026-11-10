package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import sdl "vendor:sdl3"

file_manager_test_call :: proc(
	t: ^testing.T,
	client: ^Bus,
	manager: ^File_Manager,
	b: ^Browser,
	interface, member: cstring,
	paths: []string,
	valid_signature := true,
	apply := true,
) -> ^Bus_Message {
	request := dbus_message_new_method_call(
		FILE_MANAGER_NAME,
		FILE_MANAGER_PATH,
		interface,
		member,
	)
	if !testing.expect(t, request != nil, "cannot create file manager request") {return nil}
	defer dbus_message_unref(request)
	if paths != nil {
		iter, array: Bus_Iter
		dbus_message_iter_init_append(request, &iter)
		if valid_signature {
			assert(dbus_message_iter_open_container(&iter, 'a', "s", &array) != 0)
			for path in paths {
				uri := file_uri_list([]string{path})
				value := strings.clone_to_cstring(
					strings.trim_suffix(uri, "\r\n"),
					context.temp_allocator,
				)
				assert(dbus_message_iter_append_basic(&array, 's', &value) != 0)
				delete(uri)
			}
			assert(dbus_message_iter_close_container(&iter, &array) != 0)
		}
		startup: cstring = ""
		assert(dbus_message_iter_append_basic(&iter, 's', &startup) != 0)
	}
	pending: ^Bus_Pending
	sent := dbus_connection_send_with_reply(client, request, &pending, 3000) != 0 && pending != nil
	if !testing.expect(t, sent, "cannot send file manager request") {return nil}
	defer dbus_pending_call_unref(pending)
	deadline := sdl.GetTicks() + 3000
	for sdl.GetTicks() < deadline {
		_ = dbus_connection_read_write(client, 0)
		for dbus_connection_get_dispatch_status(client) == 0 {_ = dbus_connection_dispatch(client)}
		if apply {_ = file_manager_poll(manager, b, nil)}
		if dbus_pending_call_get_completed(pending) !=
		   0 {return dbus_pending_call_steal_reply(pending)}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, false, "file manager request timed out")
	return nil
}

@(test)
file_manager_reveals_local_items_over_an_isolated_bus :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS}), string(sdl.GetError())) {return}
	defer sdl.Quit()
	fixture, ok := test_bus_start("org.example.FileManagerTest")
	if !testing.expect(t, ok, "cannot start private file manager bus") {return}
	defer test_bus_destroy(fixture)
	bus := dbus_connection_open_private(fixture.address, nil)
	if !testing.expect(t, bus != nil, "cannot open file manager connection") {return}
	assert(dbus_bus_register(bus, nil) != 0)
	manager := file_manager_start(bus)
	if !testing.expect(t, manager != nil, "cannot own private file manager name") {return}
	defer file_manager_destroy(manager)
	root, err := os.make_directory_temp("/tmp", "stuff-file-manager-", context.allocator)
	if !testing.expect(t, err == nil, "cannot create file manager fixture") {return}
	defer delete(root)
	defer os.remove_all(root)
	folder := fmt.tprintf("%s/folder", root)
	testing.expect(t, os.make_directory(folder) == nil)
	first, hidden := fmt.tprintf("%s/a file #.txt", folder), fmt.tprintf("%s/.hidden", folder)
	testing.expect(t, os.write_entire_file(first, "first") == nil)
	testing.expect(t, os.write_entire_file(hidden, "hidden") == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	search_start(&b)
	path_edit_replace(&b, "does not match")

	items := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		FILE_MANAGER_NAME,
		"ShowItems",
		[]string{first, hidden, first},
	)
	if items == nil {return}
	defer dbus_message_unref(items)
	if !testing.expect_value(t, dbus_message_get_type(items), 2) {return}
	testing.expect_value(t, b.path, folder)
	testing.expect_value(t, b.search, "")
	testing.expect(t, !b.header.edit.active && b.show_hidden && !b.places.focused)
	testing.expect_value(t, len(b.marks), 2)
	testing.expect_value(t, b.marked_bytes, i64(11))
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "a file #.txt")

	// A reveal in the current folder must refresh a newly created entry.
	created := fmt.tprintf("%s/new download.txt", folder)
	testing.expect(t, os.write_entire_file(created, "download") == nil)
	refresh := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		FILE_MANAGER_NAME,
		"ShowItems",
		[]string{created},
	)
	if refresh == nil {return}
	defer dbus_message_unref(refresh)
	if !testing.expect_value(t, dbus_message_get_type(refresh), 2) {return}
	testing.expect_value(t, b.entries[b.visible[b.selected]].name, "new download.txt")

	folders := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		FILE_MANAGER_NAME,
		"ShowFolders",
		[]string{root},
	)
	if folders == nil {return}
	defer dbus_message_unref(folders)
	testing.expect_value(t, dbus_message_get_type(folders), 2)
	testing.expect_value(t, b.path, root)

	invalid := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		FILE_MANAGER_NAME,
		"ShowItems",
		[]string{first, "relative"},
	)
	if invalid == nil {return}
	defer dbus_message_unref(invalid)
	testing.expect_value(
		t,
		string(dbus_message_get_error_name(invalid)),
		"org.freedesktop.DBus.Error.InvalidArgs",
	)
	testing.expect_value(t, b.path, root)

	for item in ([?]struct {
			member: cstring,
			valid:  bool,
			error:  string,
		}{{"ShowItems", false, "org.freedesktop.DBus.Error.InvalidArgs"}, {"ShowItemProperties", true, "org.freedesktop.DBus.Error.NotSupported"}, {"Unknown", true, "org.freedesktop.DBus.Error.UnknownMethod"}}) {
		reply := file_manager_test_call(
			t,
			fixture.connection,
			manager,
			&b,
			FILE_MANAGER_NAME,
			item.member,
			[]string{first},
			item.valid,
		)
		if reply == nil {return}
		defer dbus_message_unref(reply)
		testing.expect_value(t, dbus_message_get_type(reply), 3)
		testing.expect_value(t, string(dbus_message_get_error_name(reply)), item.error)
		testing.expect_value(t, b.path, root)
	}
	info := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		"org.freedesktop.DBus.Introspectable",
		"Introspect",
		nil,
	)
	if info == nil {return}
	defer dbus_message_unref(info)
	if !testing.expect_value(t, string(dbus_message_get_signature(info)), "s") {return}
	iter: Bus_Iter
	dbus_message_iter_init(info, &iter)
	xml: cstring
	dbus_message_iter_get_basic(&iter, &xml)
	testing.expect(t, strings.contains(string(xml), "ShowItems"))

	// Another instance must not replace or queue behind the current provider.
	other := dbus_connection_open_private(fixture.address, nil)
	if !testing.expect(t, other != nil, "cannot open competing file manager connection") {return}
	assert(dbus_bus_register(other, nil) != 0)
	contender := file_manager_start(other)
	defer file_manager_destroy(contender)
	testing.expect(t, contender == nil)
	ping := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		"org.freedesktop.DBus.Peer",
		"Ping",
		nil,
	)
	if ping == nil {return}
	defer dbus_message_unref(ping)
	testing.expect_value(t, dbus_message_get_type(ping), 2)
	// Leave an accepted request queued; shutdown must free its owned paths.
	queued := file_manager_test_call(
		t,
		fixture.connection,
		manager,
		&b,
		FILE_MANAGER_NAME,
		"ShowItems",
		[]string{first},
		apply = false,
	)
	if queued == nil {return}
	defer dbus_message_unref(queued)
	testing.expect_value(t, dbus_message_get_type(queued), 2)
	testing.expect_value(t, b.path, root)
}

@(test)
file_manager_groups_preserve_symlinks_and_canonicalize_parent_folders :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-reveal-groups-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create reveal fixture")}
	defer delete(root)
	defer os.remove_all(root)
	folder, alias, other :=
		fmt.tprintf("%s/folder", root),
		fmt.tprintf("%s/alias", root),
		fmt.tprintf("%s/other", root)
	testing.expect(t, os.make_directory(folder) == nil)
	testing.expect(t, os.make_directory(other) == nil)
	testing.expect(t, os.symlink("folder", alias) == nil)
	testing.expect(t, os.symlink("missing", fmt.tprintf("%s/link", folder)) == nil)
	testing.expect(t, os.write_entire_file(fmt.tprintf("%s/second", folder), "second") == nil)
	groups, group_err := file_manager_groups(
		[]string {
			fmt.tprintf("%s/link", alias),
			fmt.tprintf("%s/second", folder),
			fmt.tprintf("%s/item", other),
		},
		true,
	)
	defer file_manager_groups_destroy(groups)
	testing.expect(t, group_err == nil)
	testing.expect_value(t, len(groups), 2)
	if len(groups) != 2 {return}
	testing.expect_value(t, groups[0].folder, folder)
	testing.expect_value(t, len(groups[0].paths), 2)
	testing.expect_value(t, groups[0].paths[0], fmt.tprintf("%s/link", folder))
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, file_manager_show(&b, groups[0]) == nil)
	testing.expect_value(t, b.entries[b.visible[b.selected]].type, os.File_Type.Symlink)

	bad, bad_err := file_manager_groups(
		[]string{folder, fmt.tprintf("%s/missing/item", root)},
		true,
	)
	defer file_manager_groups_destroy(bad)
	testing.expect(t, bad_err != nil && len(bad) == 0)
}
