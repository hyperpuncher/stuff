package main

import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import sdl "vendor:sdl3"

File_Manager_Group :: struct {
	folder: string,
	paths:  [dynamic]string,
}

file_manager_groups_destroy :: proc(groups: [dynamic]File_Manager_Group) {
	for group in groups {delete(group.folder); file_paths_destroy(group.paths)}
	delete(groups)
}

file_manager_groups :: proc(
	paths: []string,
	items: bool,
) -> (
	[dynamic]File_Manager_Group,
	os.Error,
) {
	groups: [dynamic]File_Manager_Group
	ok := false
	defer if !ok {file_manager_groups_destroy(groups)}
	for raw_path in paths {
		path := strings.trim_right(raw_path, "/")
		if path == "" {path = "/"}
		folder, name := path, ""
		if items && path != "/" {
			folder, name = os.split_path(path)
			if name == "." || name == ".." {return nil, .Invalid_Path}
		}
		if folder == "" {folder = "."}
		dir, open_err := directory_open(folder)
		if open_err != nil {return nil, open_err}
		canonical := strings.clone(os.name(dir))
		os.close(dir)
		index := -1
		for group, i in groups {if group.folder == canonical {index = i; break}}
		if index <
		   0 {index = len(groups); append(&groups, File_Manager_Group{folder = canonical})} else {delete(canonical)}
		if name !=
		   "" {append(&groups[index].paths, fmt.aprintf("%s/%s", strings.trim_suffix(groups[index].folder, "/"), name))}
	}
	ok = true
	return groups, nil
}

file_manager_select :: proc(b: ^Browser, paths: []string) -> os.Error {
	if len(paths) == 0 {return nil}
	for path in paths {
		_, name := os.split_path(path)
		if strings.has_prefix(name, ".") {b.show_hidden = true}
	}
	browser_filter(b)
	selection_clear(b)
	first := -1
	missing := false
	for path in paths {
		_, name := os.split_path(path)
		found := false
		for source, row in b.visible {
			if b.entries[source].name != name {continue}
			selection_mark(b, row, true)
			if first < 0 {first = row}
			found = true
			break
		}
		missing = missing || !found
	}
	if first >= 0 {b.selected, b.anchor, b.first = first, first, first}
	if missing {return linux.Errno.ENOENT}
	return nil
}

file_manager_show :: proc(b: ^Browser, group: File_Manager_Group) -> os.Error {
	search_end(b)
	path_edit_end(&b.header.edit)
	if group.folder !=
	   b.path {browser_navigate(b, group.folder) or_return} else {browser_load(b, group.folder) or_return}
	b.places.focused = false
	return file_manager_select(b, group.paths[:])
}

file_manager_spawn :: proc(group: File_Manager_Group) -> bool {
	executable, err := os.get_executable_path(context.temp_allocator)
	if err != nil {sdl.SetError("cannot find the stuff executable"); return false}
	args := make([dynamic]cstring, 0, len(group.paths) + 3, context.temp_allocator)
	append(&args, strings.clone_to_cstring(executable, context.temp_allocator))
	if len(group.paths) == 0 {
		append(&args, strings.clone_to_cstring(group.folder, context.temp_allocator))
	} else {
		append(&args, "--select")
		for path in group.paths {append(&args, strings.clone_to_cstring(path, context.temp_allocator))}
	}
	append(&args, nil)
	props := sdl.CreateProperties()
	defer sdl.DestroyProperties(props)
	sdl_check(
		sdl.SetPointerProperty(props, sdl.PROP_PROCESS_CREATE_ARGS_POINTER, raw_data(args[:])),
	)
	sdl_check(sdl.SetBooleanProperty(props, sdl.PROP_PROCESS_CREATE_BACKGROUND_BOOLEAN, true))
	process := sdl.CreateProcessWithProperties(props)
	if process == nil {return false}
	sdl.DestroyProcess(process)
	return true
}
