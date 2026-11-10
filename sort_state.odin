package main

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"

Sort_Spec :: struct {
	column:     Column,
	descending: bool,
}

// View state, not configuration: it changes from normal use.
sort_state_path :: proc(allocator := context.allocator) -> string {
	base, err := os.user_state_dir(allocator)
	if err != nil {return ""}
	defer delete(base, allocator)
	path, join_err := filepath.join({base, "stuff", "sort"}, allocator)
	if join_err != .None {return ""}
	return path
}

sort_state_load :: proc(b: ^Browser) {
	if b.sorts_path == "" {return}
	data, err := os.read_entire_file(b.sorts_path, context.allocator)
	if err != nil {return}
	defer delete(data)
	loaded: map[string]Sort_Spec
	if json.unmarshal_string(string(data), &loaded, allocator = context.allocator) != nil {
		sort_state_destroy(loaded)
		return
	}
	sort_state_destroy(b.sorts)
	b.sorts = loaded
}

sort_state_save :: proc(b: ^Browser) {
	if b.sorts_path == "" {return}
	data, err := json.marshal(
		b.sorts,
		{use_enum_names = true, sort_maps_by_key = true},
		context.allocator,
	)
	if err != nil {return}
	defer delete(data)
	if os.make_directory_all(filepath.dir(b.sorts_path)) != nil {return}
	temporary := strings.concatenate({b.sorts_path, ".tmp"})
	defer delete(temporary)
	if os.write_entire_file(temporary, data) != nil {
		_ = os.remove(temporary)
		return
	}
	if os.rename(temporary, b.sorts_path) != nil {_ = os.remove(temporary)}
}

sort_state_destroy :: proc(sorts: map[string]Sort_Spec) {
	for path in sorts {delete(path)}
	delete(sorts)
}

// An exact folder match wins; other folders keep the sort that is already active.
sort_restore :: proc(b: ^Browser) {
	if spec, ok := b.sorts[b.path]; ok {
		b.sort_column, b.descending = spec.column, spec.descending
	}
}

sort_remember :: proc(b: ^Browser) {
	if b.path == "" || b.path == TRASH_PATH {return}
	spec := Sort_Spec {
		column     = b.sort_column,
		descending = b.descending,
	}
	if b.path in b.sorts {b.sorts[b.path] = spec} else {b.sorts[strings.clone(b.path)] = spec}
	sort_state_save(b)
}
