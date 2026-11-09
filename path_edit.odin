package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Path_Edit :: struct {
	active, dragging:   bool,
	mode:               Edit_Mode,
	source:             string,
	waiting:            ^File_Operation,
	value, composition: string, // Owned. Cursor and anchor are grapheme byte boundaries.
	cursor, anchor:     int,
	offset:             f32,
	font:               ^ttf.Font, // Borrowed for pointer hit testing on the UI thread.
	undo, redo:         [dynamic]Edit_Snapshot,
}

path_edit_end :: proc(edit: ^Path_Edit) {
	delete(edit.value)
	delete(edit.source)
	delete(edit.composition)
	edit_history_clear(&edit.undo)
	edit_history_clear(&edit.redo)
	font := edit.font
	edit^ = {
		font = font,
	}
}

path_edit_start :: proc(b: ^Browser) {
	edit := &b.header.edit
	if edit.mode != .Path {path_edit_end(edit)}
	if !edit.active {edit.value = strings.clone(b.path)}
	edit.active = true
	edit.anchor, edit.cursor = 0, len(edit.value)
	b.menu.active, b.places.focused = false, false
	b.drag = {}
	browser_message(b, "")
}

path_edit_box :: proc(g: Geometry, mode: Edit_Mode = .Path) -> clay.BoundingBox {
	if mode != .Path {
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

path_edit_boundary :: proc(value: string, cursor: int, forward: bool, word := false) -> int {
	if word {return path_edit_word_boundary(value, cursor, forward)}
	previous := 0
	it := utf8.decode_grapheme_iterator_make(value)
	for _, cluster in utf8.decode_grapheme_iterate(&it) {
		next := cluster.byte_index + len(cluster.text)
		if forward && next > cursor {return next}
		if !forward && next >= cursor {return previous}
		previous = next
	}
	return forward ? len(value) : 0
}

// Move to a word end going forward, or a word start going backward. Keep
// underscores in words; punctuation and whitespace separate path components.
path_edit_word_boundary :: proc(value: string, cursor: int, forward: bool) -> int {
	start, in_word := 0, false
	it := utf8.decode_grapheme_iterator_make(value)
	for _, cluster in utf8.decode_grapheme_iterate(&it) {
		r, _ := utf8.decode_rune_in_string(cluster.text)
		separator := unicode.is_space(r) || unicode.is_punct(r) && r != '_'
		if forward {
			if cluster.byte_index < cursor {continue}
			if separator && in_word {return cluster.byte_index}
			if !separator {in_word = true}
		} else {
			if cluster.byte_index >= cursor {break}
			if !separator && !in_word {start = cluster.byte_index}
			in_word = !separator
		}
	}
	return forward ? len(value) : start
}

path_edit_replace :: proc(b: ^Browser, value: string) {
	edit := &b.header.edit
	path_edit_replace_range(b, value, min(edit.cursor, edit.anchor), max(edit.cursor, edit.anchor))
}

path_edit_replace_range :: proc(b: ^Browser, value: string, low, high: int) {
	if strings.contains_any(
		value,
		"\r\n\x00",
	) {browser_message(b, "a path must fit on one line"); return}
	edit := &b.header.edit
	next := fmt.aprintf("%s%s%s", edit.value[:low], value, edit.value[high:])
	if next != edit.value {
		edit_history_push(&edit.undo, {edit.value, edit.cursor, edit.anchor})
		edit_history_clear(&edit.redo)
	} else {delete(next); next = edit.value}
	delete(edit.composition)
	edit.value, edit.composition = next, ""
	edit.cursor, edit.anchor = low + len(value), low + len(value)
}

path_edit_copy :: proc(b: ^Browser) -> bool {
	edit := &b.header.edit
	low, high := min(edit.cursor, edit.anchor), max(edit.cursor, edit.anchor)
	if low == high {return false}
	value := strings.clone_to_cstring(edit.value[low:high])
	defer delete(value)
	if !sdl.SetClipboardText(value) {browser_message(b, string(sdl.GetError())); return false}
	return true
}

path_edit_click :: proc(edit: ^Path_Edit, g: Geometry, x: f32, extend: bool) {
	if edit.font == nil {return}
	target := x - path_edit_box(g, edit.mode).x - 8 * g.scale + edit.offset
	cursor, previous_width := 0, f32(0)
	it := utf8.decode_grapheme_iterator_make(edit.value)
	for _, cluster in utf8.decode_grapheme_iterate(&it) {
		next := cluster.byte_index + len(cluster.text)
		width := f32(text_width(edit.font, edit.value[:next]))
		if target < (previous_width + width) / 2 {break}
		cursor, previous_width = next, width
	}
	edit.cursor = cursor
	if !extend {edit.anchor = cursor}
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
	   (!edit.active || edit.mode == .Path) {
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
		if edit.mode != .Path {return true, nil}
	case .MOUSE_BUTTON_DOWN:
		if edit.mode != .Path {
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
		if edit.mode != .Path {
			if !header_hit(
				clay.ID("file-dialog"),
				event.button.x,
				event.button.y,
			) {path_edit_end(edit)}
			return true, nil
		}
		path_edit_end(edit)
	case .KEY_DOWN:
		ctrl, shift := event.key.mod & sdl.KMOD_CTRL != {}, event.key.mod & sdl.KMOD_SHIFT != {}
		key := event.key.key
		if ctrl && key == sdl.K_Z {path_edit_undo(edit, shift); return true, nil}
		if ctrl && key == sdl.K_A {edit.anchor, edit.cursor = 0, len(edit.value); return true, nil}
		copy := ctrl && key == sdl.K_C || ctrl && !shift && key == sdl.K_INSERT
		cut := ctrl && key == sdl.K_X || shift && !ctrl && key == sdl.K_DELETE
		paste := ctrl && key == sdl.K_V || shift && !ctrl && key == sdl.K_INSERT
		if copy || cut {if path_edit_copy(b) && cut {path_edit_replace(b, "")}; return true, nil}
		if paste {
			if !sdl.HasClipboardText() {return true, nil}
			value := sdl.GetClipboardText()
			defer sdl.free(value)
			path_edit_replace(b, string(cast(cstring)value))
			return true, nil
		}
		switch key {
		case sdl.K_ESCAPE:
			path_edit_end(edit)
		case sdl.K_RETURN, sdl.K_KP_ENTER:
			if event.key.repeat || edit.composition != "" {return true, nil}
			if edit.mode != .Path {file_dialog_submit(b); return true, nil}
			if edit.value == "" {browser_message(b, "enter a folder path"); return true, nil}
			target := edit.value
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
		case sdl.K_LEFT, sdl.K_RIGHT, sdl.K_HOME, sdl.K_END:
			if key ==
			   sdl.K_HOME {edit.cursor = 0} else if key == sdl.K_END {edit.cursor = len(edit.value)} else if !shift && edit.cursor != edit.anchor {edit.cursor = key == sdl.K_LEFT ? min(edit.cursor, edit.anchor) : max(edit.cursor, edit.anchor)} else {edit.cursor = path_edit_boundary(edit.value, edit.cursor, key == sdl.K_RIGHT, ctrl)}
			if !shift {edit.anchor = edit.cursor}
		case sdl.K_BACKSPACE, sdl.K_DELETE:
			anchor := edit.anchor
			if edit.cursor ==
			   anchor {anchor = path_edit_boundary(edit.value, edit.cursor, key == sdl.K_DELETE, ctrl)}
			path_edit_replace_range(b, "", min(edit.cursor, anchor), max(edit.cursor, anchor))
		}
		return true, nil // File actions and navigation stay inactive while editing.
	}
	return false, nil
}

path_edit_caret :: proc(edit: ^Path_Edit) -> f32 {
	if edit.composition != "" {
		low := min(edit.cursor, edit.anchor)
		return f32(
			text_width(edit.font, edit.value[:low]) + text_width(edit.font, edit.composition),
		)
	}
	return f32(text_width(edit.font, edit.value[:edit.cursor]))
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
	low, high := min(edit.cursor, edit.anchor), max(edit.cursor, edit.anchor)
	cursor := path_edit_caret(edit)
	width := box.width - 16 * g.scale
	edit.offset = max(0, clamp(edit.offset, cursor - width + 2 * g.scale, cursor))
	display := edit.value
	selection_color := theme.selected
	if edit.composition != "" {
		display = fmt.tprintf("%s%s%s", edit.value[:low], edit.composition, edit.value[high:])
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
				clay.SizingFixed(edit.mode == .Path ? g.header : g.header - 8 * g.scale),
			},
			padding = clay.PaddingAll(edit.mode == .Path ? u16(4 * g.scale) : 0),
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
						zIndex = edit.mode == .Path ? 1 : 6,
						attachment = {element = .LeftCenter, parent = .LeftCenter},
						pointerCaptureMode = .Passthrough,
					},
				},
				) {label(display, theme.text, g.font_size)}
				if low == high || edit.composition != "" {
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
							zIndex = edit.mode == .Path ? 2 : 7,
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
