package main

import "core:fmt"
import "core:os"
import "core:strings"
import text_edit "core:text/edit"
import "core:unicode"
import "core:unicode/utf8"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Edit_Mode :: enum {
	Path,
	Search,
	Rename,
	New_Folder,
}

edit_is_dialog :: proc(mode: Edit_Mode) -> bool {return mode == .Rename || mode == .New_Folder}

Path_Edit :: struct {
	active, dragging:    bool,
	mode:                Edit_Mode,
	source, composition: string, // Owned; core edits the separate builder.
	waiting:             ^File_Operation,
	buffer:              strings.Builder,
	text:                text_edit.State, // Borrows buffer. Keep the active editor at a stable address.
	offset:              f32,
	font:                ^ttf.Font, // Borrowed for pointer hit testing on the UI thread.
}

path_edit_end :: proc(edit: ^Path_Edit) {
	text_edit.destroy(&edit.text)
	strings.builder_destroy(&edit.buffer)
	delete(edit.source)
	delete(edit.composition)
	font := edit.font
	edit^ = {
		font = font,
	}
}

path_edit_init :: proc(b: ^Browser, value: string) {
	edit := &b.header.edit
	strings.builder_init(&edit.buffer)
	strings.write_string(&edit.buffer, value)
	text_edit.init(&edit.text, context.allocator, context.allocator)
	text_edit.setup_once(&edit.text, &edit.buffer)
	edit.text.translate_by_grapheme = true
	edit.text.set_clipboard, edit.text.get_clipboard =
		path_edit_clipboard_set, path_edit_clipboard_get
	edit.text.clipboard_user_data = b
}

path_edit_start :: proc(b: ^Browser) {
	search_end(b)
	edit := &b.header.edit
	if edit.mode != .Path {path_edit_end(edit)}
	if !edit.active {path_edit_init(b, b.path)}
	edit.active = true
	text_edit.perform_command(&edit.text, .End)
	b.menu.active, b.places.focused, b.drag = false, false, {}
	browser_message(b, "")
}

path_edit_box :: proc(g: Geometry, mode: Edit_Mode = .Path) -> clay.BoundingBox {
	if edit_is_dialog(mode) {
		box := file_dialog_box(g)
		return {
			box.x + 8 * g.scale,
			box.y + 8 * g.scale,
			box.width - 16 * g.scale,
			g.header - 8 * g.scale,
		}
	}
	return {4 * g.scale, 4 * g.scale, g.width - 8 * g.scale, g.header - 8 * g.scale}
}

path_edit_single_line :: proc(b: ^Browser, value: string) -> bool {
	if strings.contains_any(
		value,
		"\r\n\x00",
	) {browser_message(b, "a path must fit on one line"); return false}
	return true
}

path_edit_changed :: proc(b: ^Browser) {
	edit := &b.header.edit
	// Core owns the snapshots. Keep only the application's history bound.
	if len(edit.text.undo) > 100 {free(pop_front(&edit.text.undo), edit.text.undo_text_allocator)}
	delete(edit.composition)
	edit.composition = ""
	search_update(b)
}

path_edit_replace :: proc(b: ^Browser, value: string) {
	if !path_edit_single_line(b, value) {return}
	text_edit.update_time(&b.header.edit.text)
	text_edit.input_text(&b.header.edit.text, value)
	path_edit_changed(b)
}

path_edit_clipboard_set :: proc(data: rawptr, value: string) -> bool {
	b := cast(^Browser)data
	if !sdl.SetClipboardText(
		strings.clone_to_cstring(value, context.temp_allocator),
	) {browser_message(b, string(sdl.GetError())); return false}
	return true
}

path_edit_clipboard_get :: proc(data: rawptr) -> (string, bool) {
	b := cast(^Browser)data
	if !sdl.HasClipboardText() {return "", false}
	value := sdl.GetClipboardText()
	if value == nil {browser_message(b, string(sdl.GetError())); return "", false}
	defer sdl.free(value)
	text := string(cast(cstring)value)
	if !path_edit_single_line(b, text) {return "", false}
	return strings.clone(text, context.temp_allocator), true
}

path_edit_key :: proc(key: sdl.Keycode, ctrl, shift: bool) -> text_edit.Command {
	switch key {
	case sdl.K_Z:
		if ctrl {return shift ? .Redo : .Undo}
	case sdl.K_A:
		if ctrl {return .Select_All}
	case sdl.K_C:
		if ctrl {return .Copy}
	case sdl.K_X:
		if ctrl {return .Cut}
	case sdl.K_V:
		if ctrl {return .Paste}
	case sdl.K_INSERT:
		if ctrl && !shift {return .Copy}
		if shift && !ctrl {return .Paste}
	case sdl.K_LEFT:
		return shift ? (ctrl ? .Select_Word_Left : .Select_Left) : (ctrl ? .Word_Left : .Left)
	case sdl.K_RIGHT:
		return shift ? (ctrl ? .Select_Word_Right : .Select_Right) : (ctrl ? .Word_Right : .Right)
	case sdl.K_HOME:
		return shift ? .Select_Start : .Start
	case sdl.K_END:
		return shift ? .Select_End : .End
	case sdl.K_BACKSPACE:
		return ctrl ? .Delete_Word_Left : .Backspace
	case sdl.K_DELETE:
		return shift && !ctrl ? .Cut : ctrl ? .Delete_Word_Right : .Delete
	}
	return .None
}

// Core supplies editing and undo. Word shortcuts also stop at punctuation.
path_edit_word_position :: proc(state: ^text_edit.State, forward: bool) -> int {
	value := strings.to_string(state.builder^)
	cursor := state.selection[0]
	start, in_word, spaces := 0, false, false
	it := utf8.decode_grapheme_iterator_make(value)
	for _, cluster in utf8.decode_grapheme_iterate(&it) {
		r, _ := utf8.decode_rune_in_string(cluster.text)
		space := unicode.is_space(r)
		separator := space || unicode.is_punct(r) && r != '_'
		if forward {
			if cluster.byte_index < cursor {continue}
			if space {spaces = true; continue}
			if spaces || separator && in_word {return cluster.byte_index}
			if !separator {in_word = true}
		} else {
			if cluster.byte_index >= cursor {break}
			if !separator && !in_word {start = cluster.byte_index}
			in_word = !separator
		}
	}
	return forward ? len(value) : start
}

path_edit_command :: proc(state: ^text_edit.State, command: text_edit.Command) {
	#partial switch command {
	case .Word_Left,
	     .Word_Right,
	     .Select_Word_Left,
	     .Select_Word_Right,
	     .Delete_Word_Left,
	     .Delete_Word_Right:
		forward :=
			command in text_edit.Command_Set{.Word_Right, .Select_Word_Right, .Delete_Word_Right}
		position := path_edit_word_position(state, forward)
		#partial switch command {
		case .Word_Left, .Word_Right:
			state.selection = {position, position}
		case .Select_Word_Left, .Select_Word_Right:
			state.selection[0] = position
		case .Delete_Word_Left, .Delete_Word_Right:
			if text_edit.has_selection(state) {text_edit.selection_delete(state)} else {
				low, high := min(state.selection[0], position), max(state.selection[0], position)
				text_edit.remove(state, low, high)
				state.selection = {low, low}
			}
		}
	case:
		text_edit.perform_command(state, command)
	}
}

path_edit_click :: proc(edit: ^Path_Edit, g: Geometry, x: f32, extend: bool) {
	if edit.font == nil {return}
	target := x - path_edit_box(g, edit.mode).x - 8 * g.scale + edit.offset
	cursor, previous_width := 0, f32(0)
	value := strings.to_string(edit.buffer)
	it := utf8.decode_grapheme_iterator_make(value)
	for _, cluster in utf8.decode_grapheme_iterate(&it) {
		next := cluster.byte_index + len(cluster.text)
		width := f32(text_width(edit.font, value[:next]))
		if target < (previous_width + width) / 2 {break}
		cursor, previous_width = next, width
	}
	edit.text.selection[0] = cursor
	if !extend {edit.text.selection[1] = cursor}
}

path_edit_input :: proc(
	b: ^Browser,
	event: ^sdl.Event,
	g: Geometry,
) -> (
	handled: bool,
	err: os.Error,
) {
	edit := &b.header.edit
	if event.type == .KEY_DOWN &&
	   event.key.key == sdl.K_N &&
	   event.key.mod & sdl.KMOD_CTRL != {} &&
	   event.key.mod & sdl.KMOD_SHIFT != {} &&
	   !edit.active {
		if !event.key.repeat {file_dialog_start(b, false)}
		return true, nil
	}
	if event.type == .KEY_DOWN && !edit_is_dialog(edit.mode) {
		ctrl := event.key.mod & sdl.KMOD_CTRL != {}
		slash :=
			event.key.key == sdl.K_SLASH &&
			event.key.mod & (sdl.KMOD_CTRL | sdl.KMOD_ALT | sdl.KMOD_GUI) == {} &&
			!edit.active
		if ctrl && event.key.key == sdl.K_F || slash {
			if !event.key.repeat {search_start(b)}
			return true, nil
		}
		if edit.mode == .Search &&
		   event.key.key == sdl.K_ESCAPE &&
		   !b.menu.active {search_end(b); return true, nil}
	}
	if event.type == .MOUSE_BUTTON_DOWN &&
	   edit.mode == .Search &&
	   !edit.active &&
	   event.button.button == sdl.BUTTON_LEFT {
		box := path_edit_box(g)
		if event.button.x >= box.x &&
		   event.button.x < box.x + box.width &&
		   event.button.y >= box.y &&
		   event.button.y < box.y + box.height {edit.active = true}
	}
	if event.type == .KEY_DOWN &&
	   event.key.key == sdl.K_R &&
	   event.key.mod & sdl.KMOD_CTRL != {} &&
	   !edit.active &&
	   !b.places.focused {
		if !event.key.repeat {file_dialog_start(b, true)}
		return true, nil
	}
	if event.type == .KEY_DOWN &&
	   event.key.key == sdl.K_L &&
	   event.key.mod & sdl.KMOD_CTRL != {} &&
	   (!edit.active || !edit_is_dialog(edit.mode)) {
		if !event.key.repeat {path_edit_start(b)}
		return true, nil
	}
	if !edit.active {return}
	if edit.waiting != nil {
		#partial switch event.type {
		case .KEY_DOWN,
		     .TEXT_INPUT,
		     .TEXT_EDITING,
		     .MOUSE_BUTTON_DOWN,
		     .MOUSE_BUTTON_UP,
		     .MOUSE_WHEEL:
			return true, nil
		}
	}
	#partial switch event.type {
	case .TEXT_INPUT:
		path_edit_replace(b, string(event.text.text))
		return true, nil
	case .TEXT_EDITING:
		delete(edit.composition)
		edit.composition = strings.clone(string(event.edit.text))
		return true, nil
	case .MOUSE_BUTTON_UP:
		edit.dragging = false
	case .MOUSE_WHEEL:
		if edit_is_dialog(edit.mode) {return true, nil}
	case .MOUSE_BUTTON_DOWN:
		if edit_is_dialog(edit.mode) {
			if header_hit(
				clay.ID("file-dialog-cancel"),
				event.button.x,
				event.button.y,
			) {path_edit_end(edit); return true, nil}
			if header_hit(
				clay.ID("file-dialog-submit"),
				event.button.x,
				event.button.y,
			) {file_dialog_submit(b); return true, nil}
		}
		box := path_edit_box(g, edit.mode)
		if event.button.x >= box.x &&
		   event.button.x < box.x + box.width &&
		   event.button.y >= box.y &&
		   event.button.y < box.y + box.height {
			if event.button.button == sdl.BUTTON_LEFT {
				path_edit_click(edit, g, event.button.x, sdl.GetModState() & sdl.KMOD_SHIFT != {})
				edit.dragging = true
			}
			return true, nil
		}
		if edit_is_dialog(edit.mode) {
			if !header_hit(
				clay.ID("file-dialog"),
				event.button.x,
				event.button.y,
			) {path_edit_end(edit)}
			return true, nil
		}
		if edit.mode == .Search {search_blur(edit)} else {path_edit_end(edit)}
	case .KEY_DOWN:
		ctrl, shift := event.key.mod & sdl.KMOD_CTRL != {}, event.key.mod & sdl.KMOD_SHIFT != {}
		key := event.key.key
		command := path_edit_key(key, ctrl, shift)
		if command != .None {
			text_edit.update_time(&edit.text)
			path_edit_command(&edit.text, command)
			path_edit_changed(b)
			return true, nil
		}
		switch key {
		case sdl.K_ESCAPE:
			path_edit_end(edit)
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			if event.key.repeat || edit.composition != "" {return true, nil}
			if edit.mode == .Search {search_blur(edit); return true, nil}
			if edit_is_dialog(edit.mode) {file_dialog_submit(b); return true, nil}
			target := strings.to_string(edit.buffer)
			if target == "" {browser_message(b, "enter a folder path"); return true, nil}
			if target ==
			   TRASH_PATH {err = browser_navigate(b, target); if err == nil {path_edit_end(edit)}; return true, err}
			if target == "~" || strings.has_prefix(target, "~/") {
				home := sdl.GetUserFolder(.HOME)
				if home != nil {target = fmt.tprintf("%s%s", string(home), target[1:])}
			} else if !strings.has_prefix(target, "/") {base := b.path
				if base ==
				   TRASH_PATH {home := sdl.GetUserFolder(.HOME); if home != nil {base = string(home)}}
				target = fmt.tprintf("%s/%s", base, target)}
			err = browser_navigate(b, target)
			if err == nil {path_edit_end(edit)}
			return true, err
		}
		return true, nil // File actions and navigation stay inactive while editing.
	}
	return false, nil
}

path_edit_caret :: proc(edit: ^Path_Edit) -> f32 {
	value := strings.to_string(edit.buffer)
	if edit.composition != "" {
		low, _ := text_edit.sorted_selection(&edit.text)
		return f32(text_width(edit.font, value[:low]) + text_width(edit.font, edit.composition))
	}
	return f32(text_width(edit.font, value[:edit.text.selection[0]]))
}

path_edit_ime_area :: proc(edit: ^Path_Edit, g: Geometry, window: ^sdl.Window) {
	box := path_edit_box(g, edit.mode)
	density := sdl.GetWindowPixelDensity(window)
	area := sdl.Rect {
		i32(box.x / density),
		i32(box.y / density),
		i32(box.width / density),
		i32(box.height / density),
	}
	cursor := i32((8 * g.scale + path_edit_caret(edit) - edit.offset) / density)
	sdl_check(sdl.SetTextInputArea(window, &area, cursor))
}

path_edit_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	edit := &b.header.edit
	box := path_edit_box(g, edit.mode)
	low, high := text_edit.sorted_selection(&edit.text)
	cursor := path_edit_caret(edit)
	width := box.width - 16 * g.scale
	edit.offset = max(0, clamp(edit.offset, cursor - width + 2 * g.scale, cursor))
	display := strings.to_string(edit.buffer)
	selection_color := theme.selected
	if edit.composition != "" {
		display = fmt.tprintf("%s%s%s", display[:low], edit.composition, display[high:])
		high = low + len(edit.composition)
		selection_color = theme.inactive_selection
	}
	prefix := f32(text_width(p.font, display[:low]))
	selection_width := f32(text_width(p.font, display[:high])) - prefix
	if clay.UI()(
	{
		layout = {
			sizing = {
				clay.SizingGrow(),
				clay.SizingFixed(edit_is_dialog(edit.mode) ? g.header - 8 * g.scale : g.header),
			},
			padding = clay.PaddingAll(edit_is_dialog(edit.mode) ? 0 : u16(4 * g.scale)),
		},
	},
	) {
		if clay.UI(clay.ID("path-edit"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingGrow()},
				padding = {left = u16(8 * g.scale), right = u16(8 * g.scale)},
			},
			backgroundColor = theme.background,
			cornerRadius = clay.CornerRadiusAll(5 * g.scale),
			clip = {horizontal = true, vertical = true, childOffset = {-edit.offset, 0}},
		},
		) {
			if clay.UI()(
			{
				layout = {
					sizing = {
						clay.SizingFixed(max(width, f32(text_width(p.font, display)))),
						clay.SizingGrow(),
					},
					childAlignment = {y = .Center},
				},
			},
			) {
				if low != high {
					if clay.UI()(
					{layout = {sizing = {clay.SizingFixed(prefix), clay.SizingFixed(1)}}},
					) {}
					if clay.UI()(
					{
						layout = {
							sizing = {
								clay.SizingFixed(selection_width),
								clay.SizingFixed(f32(ttf.GetFontHeight(p.font))),
							},
						},
						backgroundColor = selection_color,
					},
					) {}
				}
				// Shape the complete line once. Selection and caret never split or move it.
				if clay.UI(clay.ID("path-edit-text"))(
				{
					floating = {
						attachTo = .Parent,
						clipTo = .AttachedParent,
						zIndex = edit_is_dialog(edit.mode) ? 6 : 1,
						attachment = {element = .LeftCenter, parent = .LeftCenter},
						pointerCaptureMode = .Passthrough,
					},
				},
				) {label(display == "" && edit.mode == .Search ? "search" : display, display == "" && edit.mode == .Search ? theme.muted : theme.text, g.font_size)}
				if edit.active && (low == high || edit.composition != "") {
					if clay.UI(clay.ID("path-edit-caret"))(
					{
						layout = {
							sizing = {
								clay.SizingFixed(1),
								clay.SizingFixed(g.font_size + 2 * g.scale),
							},
						},
						floating = {
							attachTo = .Parent,
							clipTo = .AttachedParent,
							zIndex = edit_is_dialog(edit.mode) ? 7 : 2,
							offset = {cursor, 0},
							attachment = {element = .LeftCenter, parent = .LeftCenter},
							pointerCaptureMode = .Passthrough,
						},
						backgroundColor = theme.text,
					},
					) {}
				}
			}
		}
	}
}
