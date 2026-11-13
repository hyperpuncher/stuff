package main

import "core:os"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"

view_destroy :: proc(view: ^Folder_View) {
	os.file_info_slice_delete(view.entries, context.allocator)
	trash_records_destroy(view.trash_records)
	delete(view.visible)
	delete(view.marks)
	delete(view.path)
	delete(view.search)
	for entry in view.back {history_entry_destroy(entry)}
	for entry in view.forward {history_entry_destroy(entry)}
	delete(view.back)
	delete(view.forward)
	view^ = {}
}

tab_count :: proc(b: ^Browser) -> int {return max(1, len(b.tabs))}

tab_view :: proc(b: ^Browser, index: int) -> ^Folder_View {
	return index == b.active_tab ? &b.view : &b.tabs[index]
}

// Read the folder again on activation. Keep selection and scroll by name, not
// by old entry indices, so changes made while the tab was inactive are safe.
tab_refresh :: proc(b: ^Browser) -> os.Error {
	if b.path == TRASH_PATH {
		if !trash_view_request(b) {return .Unsupported}
		return nil
	}
	dir := directory_open(b.path) or_return
	defer os.close(dir)
	entries := list_entries(dir, b.path) or_return
	browser_replace_entries(b, entries)
	return nil
}

tab_switch :: proc(b: ^Browser, index: int, refresh := true) -> os.Error {
	if index < 0 || index >= tab_count(b) || index == b.active_tab {return nil}
	file_drag_cancel_press(b)
	path_edit_end(&b.header.edit)
	b.header.copied_until = 0
	b.drag, b.autoscroll, b.menu, b.selection_drag = {}, {}, {}, {}
	b.pointer.active, b.places.focused = false, false
	b.hovered = 0
	b.tabs[b.active_tab] = b.view
	b.view = b.tabs[index]
	b.tabs[index] = {}
	b.active_tab = index
	browser_message(b, "")
	err: os.Error
	if refresh || b.path == TRASH_PATH {err = tab_refresh(b)}
	size_refresh_stale(b)
	watch_sync(b, refresh = true)
	storage_path(b.storage, b.path == TRASH_PATH ? "" : b.path)
	if b.search != "" {search_start(b); search_blur(&b.header.edit)}
	return err
}

tab_open :: proc(b: ^Browser, path: string, activate := true) -> os.Error {
	// This temporary browser only loads a view. It borrows read-only caches and
	// has no workers, so opening a background tab cannot change active requests.
	preview: Browser
	preview.sorts, preview.sizes = b.sorts, b.sizes
	preview.show_hidden, preview.icons = b.show_hidden, b.icons
	preview.sort_column, preview.descending = b.sort_column, b.descending
	preview.space, preview.space_device = b.space, b.space_device
	defer view_destroy(&preview.view)
	if path == TRASH_PATH {
		if b.storage == nil {return .Unsupported}
		preview.path = strings.clone(TRASH_PATH)
		preview.space = {}
	} else {browser_read(&preview, path) or_return}
	if len(b.tabs) == 0 {append(&b.tabs, Folder_View{})}
	append(&b.tabs, preview.view)
	preview.view = {}
	if activate {return tab_switch(b, len(b.tabs) - 1, refresh = false)}
	return nil
}

tab_close :: proc(b: ^Browser, index: int, running: ^bool) -> os.Error {
	if index < 0 || index >= tab_count(b) {return nil}
	if tab_count(b) == 1 {running^ = false; return nil}
	err: os.Error
	if index == b.active_tab {err = tab_switch(b, index > 0 ? index - 1 : 1)}
	view_destroy(&b.tabs[index])
	ordered_remove(&b.tabs, index)
	if b.active_tab > index {b.active_tab -= 1}
	return err
}

tab_step :: proc(b: ^Browser, backward: bool) -> os.Error {
	count := tab_count(b)
	return tab_switch(b, (b.active_tab + (backward ? count - 1 : 1)) % count)
}

tabs_input :: proc(
	b: ^Browser,
	event: ^sdl.Event,
	g: Geometry,
	running: ^bool,
) -> (
	handled: bool,
	err: os.Error,
) {
	if event.type == .KEY_DOWN && event.key.mod & sdl.KMOD_CTRL != {} {
		key := event.key.key
		if key == sdl.K_T || key == sdl.K_W || key == sdl.K_TAB {
			if event.key.repeat {return true, nil}
			if key == sdl.K_T {return true, tab_open(b, b.path)}
			if key == sdl.K_W {return true, tab_close(b, b.active_tab, running)}
			return true, tab_step(b, event.key.mod & sdl.KMOD_SHIFT != {})
		}
	}
	if event.type == .MOUSE_WHEEL &&
	   event.wheel.mouse_x >= 0 &&
	   event.wheel.mouse_x < g.width &&
	   event.wheel.mouse_y >= 0 &&
	   event.wheel.mouse_y < g.tabs {
		amount := event.wheel.y != 0 ? event.wheel.y : -event.wheel.x
		if event.wheel.direction == .FLIPPED {amount = -amount}
		if amount != 0 {return true, tab_step(b, amount > 0)}
		return true, nil
	}
	if event.type != .MOUSE_BUTTON_DOWN ||
	   event.button.y < 0 ||
	   event.button.y >= g.tabs {return false, nil}
	if event.button.button != sdl.BUTTON_LEFT &&
	   event.button.button != sdl.BUTTON_MIDDLE {return false, nil}
	target := tabs_target(b, g, event.button.x, event.button.y)
	if event.button.button == sdl.BUTTON_LEFT &&
	   target == clay.ID("tab-new").id {return true, tab_open(b, b.path)}
	first, last, _ := tabs_range(b, g)
	for i in first ..< last {
		close := target == clay.ID("tab-close", u32(i)).id
		if target != clay.ID("tab", u32(i)).id && !close {continue}
		if event.button.button == sdl.BUTTON_MIDDLE || close {
			return true, tab_close(b, i, running)
		}
		return true, tab_switch(b, i)
	}
	return true, nil
}

tabs_range :: proc(b: ^Browser, g: Geometry) -> (first, last: int, width: f32) {
	count := tab_count(b)
	gap := g.row_gap
	available := g.width - g.row - 3 * gap
	visible := min(count, max(1, int(available / (140 * g.scale + gap))))
	first = clamp(b.active_tab - visible + 1, 0, count - visible)
	last = first + visible
	width = min(220 * g.scale, (available - f32(visible) * gap) / f32(visible))
	return
}

tabs_target :: proc(b: ^Browser, g: Geometry, x, y: f32) -> u32 {
	gap := g.row_gap
	if x < gap || x >= g.width - gap || y < gap || y >= g.tabs - gap {return 0}
	if x >= g.width - gap - g.row {return clay.ID("tab-new").id}
	first, last, width := tabs_range(b, g)
	i := first + int((x - gap) / (width + gap))
	local := x - gap - f32(i - first) * (width + gap)
	if i >= last || local >= width {return 0}
	close := local >= width - g.row
	return clay.ID(close ? "tab-close" : "tab", u32(i)).id
}

tabs_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	if g.tabs <= 0 {return}
	first, last, width := tabs_range(b, g)
	if clay.UI(clay.ID("tabs"))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(g.tabs)},
			padding = clay.PaddingAll(u16(g.row_gap)),
			childGap = u16(g.row_gap),
		},
	},
	) {
		for i in first ..< last {
			id := clay.ID("tab", u32(i))
			color := theme.inactive_selection
			if i == b.active_tab {color = theme.selected}
			if clay.UI(id)(
			{
				layout = {
					sizing = {clay.SizingFixed(width), clay.SizingGrow()},
					padding = {left = u16(10 * g.scale)},
					childAlignment = {y = .Center},
				},
				backgroundColor = hover_color(b, id, color),
				cornerRadius = clay.CornerRadiusAll(6 * g.scale),
			},
			) {
				path := tab_view(b, i).path
				_, name := os.split_path(strings.trim_right(path, "/"))
				if path == "/" {name = "/"}
				if path == TRASH_PATH {name = "trash"}
				if clay.UI()(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingGrow()},
						childAlignment = {y = .Center},
					},
				},
				) {
					label(
						fit_label(p.font, name, width - g.row - 10 * g.scale, middle = true),
						theme.text,
						g.font_size,
					)
				}
				close := clay.ID("tab-close", u32(i))
				if clay.UI(close)(
				{
					layout = {
						sizing = {clay.SizingFixed(g.row), clay.SizingGrow()},
						childAlignment = {x = .Center, y = .Center},
					},
					backgroundColor = hover_color(b, close, {}),
					cornerRadius = clay.CornerRadiusAll(6 * g.scale),
				},
				) {icon_element(p, .Close, g.scale)}
			}
		}
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {}
		id := clay.ID("tab-new")
		if clay.UI(id)(
		{
			layout = {
				sizing = {clay.SizingFixed(g.row), clay.SizingGrow()},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = hover_color(b, id, {}),
			cornerRadius = clay.CornerRadiusAll(6 * g.scale),
		},
		) {
			@(static) rotation: f64 = 45
			icon_element(p, .Close, g.scale, &rotation)
		}
	}
}
