package main

import "core:fmt"
import "core:os"
import "core:strings"
import clay "vendor/clay"

Edit_Mode :: enum {
	Path,
	Rename,
	New_Folder,
}

file_dialog_box :: proc(g: Geometry) -> clay.BoundingBox {
	width, height := min(480 * g.scale, g.width - 32 * g.scale), g.row + g.header + 24 * g.scale
	return {(g.width - width) / 2, (g.height - height) / 2, width, height}
}

file_dialog_start :: proc(b: ^Browser, rename: bool) {
	if b.pending_files != nil || b.path == TRASH_PATH {return}
	edit := &b.header.edit
	path_edit_end(edit)
	edit.mode = rename ? .Rename : .New_Folder
	if rename {
		if len(b.marks) != 1 {browser_message(b, "select one item to rename"); return}
		for index in b.marks {
			entry := b.entries[index]
			edit.source, edit.value = strings.clone(entry.fullpath), strings.clone(entry.name)
			edit.cursor = len(edit.value)
			if entry.type != .Directory {
				if dot := strings.last_index_byte(edit.value, '.'); dot > 0 {edit.cursor = dot}
			}
		}
	} else {
		edit.source, edit.value = strings.clone(b.path), strings.clone("new folder")
		edit.cursor = len(edit.value)
	}
	edit.active = true
	b.menu.active, b.places.focused, b.drag = false, false, {}
	browser_message(b, "")
}

file_dialog_submit :: proc(b: ^Browser) {
	edit := &b.header.edit
	if edit.waiting != nil {return}
	name := edit.value
	if name == "" || name == "." || name == ".." || strings.contains_any(name, "/\r\n\x00") {
		browser_message(b, "enter a name without slashes")
		return
	}
	if edit.mode == .Rename {
		_, old := os.split_path(edit.source)
		if name == old {path_edit_end(edit); return}
	}
	if b.storage == nil {browser_message(b, "file operations are unavailable"); return}
	parent := edit.source
	if edit.mode == .Rename {parent, _ = os.split_path(edit.source)}
	op := new(File_Operation)
	op.kind = edit.mode == .Rename ? .Rename : .New_Folder
	op.target = strings.clone(strings.trim_suffix(parent, "/"))
	if op.target == "" {op.target = strings.clone("/")}
	op.destination = fmt.aprintf("%s/%s", strings.trim_suffix(parent, "/"), name)
	append(&op.sources, strings.clone(edit.source))
	if file_operation_launch(b, op) {edit.waiting = op} else {file_operation_destroy(op)}
}

file_dialog_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	edit := &b.header.edit
	if !edit.active || edit.mode == .Path {return}
	box := file_dialog_box(g)
	popup_shadow_layout(box, g.scale, p)
	if clay.UI(clay.ID("file-dialog"))(
	{
		layout = {
			sizing = {clay.SizingFixed(box.width), clay.SizingFixed(box.height)},
			padding = clay.PaddingAll(u16(8 * g.scale)),
			layoutDirection = .TopToBottom,
		},
		floating = {attachTo = .Root, offset = {box.x, box.y}, zIndex = 5},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8 * g.scale),
	},
	) {
		path_edit_layout(b, g, p)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(8 * g.scale)}}}) {}
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
				childAlignment = {x = .Right},
				childGap = u16(8 * g.scale),
			},
		},
		) {
			for i in 0 ..< 2 {
				id := clay.ID(i == 0 ? "file-dialog-cancel" : "file-dialog-submit")
				if clay.UI(id)(
				{
					layout = {
						sizing = {clay.SizingFixed(88 * g.scale), clay.SizingGrow()},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = hover_color(b, id, theme.inactive_selection),
					cornerRadius = clay.CornerRadiusAll(5 * g.scale),
				},
				) {
					label(
						i == 0 ? "cancel" : edit.waiting != nil ? "working…" : edit.mode == .Rename ? "rename" : "create",
						theme.text,
						g.font_size,
					)
				}
			}
		}
	}
}
