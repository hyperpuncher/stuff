package main

import "core:fmt"
import "core:os"
import "core:strings"
import text_edit "core:text/edit"
import clay "vendor/clay"

archive_extract_start :: proc(b: ^Browser, source, target: string, password: string = "") -> bool {
	if b.storage == nil ||
	   b.path == TRASH_PATH ||
	   target ==
		   TRASH_PATH {browser_message(b, "archive operations are unavailable"); return false}
	op := new(File_Operation)
	op.kind = .Extract
	op.target = strings.clone(target)
	op.archive_password = strings.clone(password)
	append(&op.sources, strings.clone(source))
	if !file_operation_launch(b, op) {file_operation_destroy(op); return false}
	return true
}

archive_selection_can_extract :: proc(b: ^Browser) -> bool {
	if b.path == TRASH_PATH || len(b.marks) == 0 {return false}
	for index in b.marks {
		entry := b.entries[index]
		if entry.type != .Regular && entry.type != .Symlink {return false}
		if _, archive := archive_stem(entry.name); !archive {return false}
		if entry_is_directory(entry) {return false}
	}
	return true
}

// Each archive has its own worker, destination, cancellation, and history entry.
archive_extract_selection :: proc(b: ^Browser) -> bool {
	if !archive_selection_can_extract(b) {return false}
	for index in b.visible {
		if !b.marks[index] {continue}
		if !archive_extract_start(b, b.entries[index].fullpath, b.path) {break}
	}
	return true
}

archive_dialog_start :: proc(b: ^Browser) {
	if b.path == TRASH_PATH || b.storage == nil || len(b.marks) == 0 {return}
	sources := selection_paths(b)
	search_end(b)
	edit := &b.header.edit
	path_edit_end(edit)
	edit.mode, edit.source, edit.sources = .Compress, strings.clone(b.path), sources
	name := "archive"
	if len(edit.sources) == 1 {name = os.base(edit.sources[0])}
	path_edit_init(b, fmt.tprintf("%s.zip", name))
	text_edit.perform_command(&edit.text, .Select_All)
	edit.text.selection[0] = len(name)
	edit.active = true
	b.menu.active, b.places.focused, b.drag = false, false, {}
	browser_message(b, "")
}

archive_name_format :: proc(name: string) -> (Archive_Format, bool) {
	for suffix, format in ARCHIVE_SUFFIX {if archive_has_suffix(name, suffix) {return format, true}}
	return .Zip, false
}

archive_dialog_format :: proc(b: ^Browser, format: Archive_Format) {
	edit := &b.header.edit
	value := strings.to_string(edit.buffer)
	stem := value
	if previous, valid := archive_name_format(value);
	   valid {stem = value[:len(value) - len(ARCHIVE_SUFFIX[previous])]}
	text_edit.perform_command(&edit.text, .Select_All)
	path_edit_replace(b, fmt.tprintf("%s%s", stem, ARCHIVE_SUFFIX[format]))
	edit.text.selection = {len(stem), 0}
}

archive_dialog_submit :: proc(b: ^Browser) {
	edit := &b.header.edit
	if edit.mode == .Password {
		password := strings.to_string(edit.buffer)
		if password == "" {browser_message(b, "enter the archive password"); return}
		if archive_extract_start(b, edit.source, edit.parent, password) {path_edit_end(edit)}
		return
	}
	name := strings.to_string(edit.buffer)
	format, valid := archive_name_format(name)
	if !valid {browser_message(b, "use .zip, .7z, or .tar.zst"); return}
	op := new(File_Operation)
	op.kind, op.archive_format = .Compress, format
	op.target = strings.clone(edit.source)
	op.destination = fmt.aprintf("%s/%s", strings.trim_suffix(edit.source, "/"), name)
	op.sources, edit.sources = edit.sources, nil
	if file_operation_launch(b, op) {path_edit_end(edit)} else {
		edit.sources, op.sources = op.sources, nil
		file_operation_destroy(op)
	}
}

// Results queue only password requests, not archive jobs. Each attempt finishes
// and removes its private staging directory before the next password is entered.
archive_prompt_update :: proc(b: ^Browser) -> bool {
	edit := &b.header.edit
	if len(b.archive_requests) == 0 || edit.active || b.menu.active {return false}
	request := pop_front(&b.archive_requests)
	search_end(b)
	path_edit_end(edit)
	edit.mode, edit.source, edit.parent = .Password, request.source, request.target
	path_edit_init(b, "")
	edit.active = true
	b.places.focused, b.drag = false, {}
	return true
}

archive_format_target :: proc(b: ^Browser, x, y: f32) -> int {
	if !b.header.edit.active || b.header.edit.mode != .Compress {return -1}
	for format in Archive_Format {if header_hit(clay.ID("archive-format", u32(format)), x, y) {return int(format)}}
	return -1
}

archive_format_layout :: proc(b: ^Browser, g: Geometry) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
			childGap = u16(2 * g.scale),
		},
	},
	) {
		for suffix, format in ARCHIVE_SUFFIX {
			id := clay.ID("archive-format", u32(format))
			corners := clay.CornerRadiusAll(2 * g.scale)
			if format == .Zip {corners.topLeft, corners.bottomLeft = 5 * g.scale, 5 * g.scale}
			if format ==
			   .Tar_Zstd {corners.topRight, corners.bottomRight = 5 * g.scale, 5 * g.scale}
			if clay.UI(id)(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					childAlignment = {x = .Center, y = .Center},
				},
				backgroundColor = hover_color(
					b,
					id,
					b.header.edit.archive_format == format ? theme.selected : theme.inactive_selection,
				),
				cornerRadius = corners,
			},
			) {label(suffix, theme.text, g.font_size)}
		}
	}
}
