package main

import "core:fmt"
import "core:os"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Breadcrumb :: struct {
	start, end: int,
}

Header :: struct {
	path:         string, // Owned; matches the most recent layout.
	crumbs:       [dynamic]Breadcrumb,
	copied_until: u64,
	edit:         Path_Edit,
}

header_destroy :: proc(h: ^Header) {
	path_edit_end(&h.edit)
	delete(h.path)
	delete(h.crumbs)
}

header_sync :: proc(h: ^Header, path: string) {
	if h.path == path {return}
	replace_owned(&h.path, path)
	clear(&h.crumbs)
	if path == "" {return}
	append(&h.crumbs, Breadcrumb{0, 1})
	start := 1
	for i in 1 ..< len(path) {
		if path[i] == '/' {append(&h.crumbs, Breadcrumb{start, i}); start = i + 1}
	}
	if start < len(path) {append(&h.crumbs, Breadcrumb{start, len(path)})}
}

header_copy :: proc(b: ^Browser) {
	b.header.copied_until = 0
	path := strings.clone_to_cstring(b.path)
	defer delete(path)
	if !sdl.SetClipboardText(path) {
		browser_message(b, fmt.tprintf("cannot copy path: %s", string(sdl.GetError())))
		return
	}
	b.header.copied_until = sdl.GetTicks() + 1500
	browser_message(b, "")
}

header_update :: proc(h: ^Header, now: u64) -> bool {
	if h.copied_until == 0 || now < h.copied_until {return false}
	h.copied_until = 0
	return true
}

header_hit :: proc(id: clay.ElementId, x, y: f32) -> bool {
	if clay.GetCurrentContext() == nil {return false}
	element := clay.GetElementData(id)
	box := element.boundingBox
	return(
		element.found &&
		x >= box.x &&
		y >= box.y &&
		x < box.x + box.width &&
		y < box.y + box.height \
	)
}

header_target :: proc(h: ^Header, x, y: f32) -> u32 {
	if h.edit.active || h.edit.mode == .Search || h.path == "" || h.path == TRASH_PATH {return 0}
	if header_hit(clay.ID("copy_path"), x, y) {return clay.ID("copy_path").id}
	if !header_hit(clay.ID("breadcrumbs"), x, y) {return 0}
	for _, i in h.crumbs {
		id := clay.ID("crumb", u32(i))
		if header_hit(id, x, y) {return id.id}
	}
	return 0
}

header_click :: proc(b: ^Browser, x, y: f32) -> (handled: bool, err: os.Error) {
	h := &b.header
	if view_button_hit(b, x, y) {return view_set_icons(b, !b.icons), nil}
	target := header_target(h, x, y)
	if target == 0 {return false, nil}
	if target == clay.ID("copy_path").id {header_copy(b); return true, nil}
	for crumb, i in h.crumbs {
		if target == clay.ID("crumb", u32(i)).id {
			b.places.focused = false
			return true, browser_navigate(b, h.path[:crumb.end])
		}
	}
	return false, nil
}

header_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	h := &b.header
	h.edit.font = p.font
	if h.edit.mode == .Search ||
	   h.edit.active && !edit_is_dialog(h.edit.mode) {path_edit_layout(b, g, p); return}
	header_sync(h, b.path)
	right_padding := u16((g.header - g.tabs - 28 * g.scale) / 2)
	if b.path == TRASH_PATH {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(g.header - g.tabs)},
				padding = {left = u16(16 * g.scale), right = right_padding},
				childAlignment = {y = .Center},
			},
		},
		) {
			label("trash", theme.text, g.font_size)
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
			view_button(b, g, p)
		}
		return
	}
	available :=
		g.width -
		f32(u16(12 * g.scale)) -
		f32(right_padding) -
		3 * f32(u16(8 * g.scale)) -
		56 * g.scale
	labels := make([]struct {
			value: string,
			width: f32,
		}, len(h.crumbs), context.temp_allocator)
	content_width := f32(max(0, len(h.crumbs) - 1)) * (18 * g.scale + 2 * f32(u16(2 * g.scale)))
	for crumb, i in h.crumbs {
		labels[i].value = fit_label(
			p.font,
			h.path[crumb.start:crumb.end],
			available - 12 * g.scale,
			middle = true,
		)
		labels[i].width = f32(text_width(p.font, labels[i].value)) + 12 * g.scale
		content_width += labels[i].width
	}
	view_width := min(content_width, available)
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(g.header - g.tabs)},
			padding = {left = u16(12 * g.scale), right = right_padding},
			childGap = u16(8 * g.scale),
			childAlignment = {y = .Center},
		},
		backgroundColor = theme.panel,
	},
	) {
		if clay.UI(clay.ID("breadcrumbs"))(
		{
			layout = {
				sizing = {clay.SizingFixed(view_width), clay.SizingGrow()},
				childGap = u16(2 * g.scale),
				childAlignment = {y = .Center},
			},
			clip = {horizontal = true, childOffset = {-max(0, content_width - view_width), 0}},
		},
		) {
			for item, i in labels {
				if i > 0 {icon_element(p, .ChevronRight, g.scale)}
				color := theme.muted
				if i == len(h.crumbs) - 1 {color = theme.text}
				if clay.UI(clay.ID("crumb", u32(i)))(
				{
					layout = {
						sizing = {
							clay.SizingFixed(item.width),
							clay.SizingFixed(g.header - g.tabs - 8 * g.scale),
						},
						padding = {left = u16(6 * g.scale), right = u16(6 * g.scale)},
						childAlignment = {y = .Center},
					},
					backgroundColor = hover_color(b, clay.ID("crumb", u32(i)), {}),
					cornerRadius = clay.CornerRadiusAll(5 * g.scale),
				},
				) {label(item.value, color, g.font_size)}
			}
		}
		if clay.UI(clay.ID("copy_path"))(
		{
			layout = {
				sizing = {clay.SizingFixed(28 * g.scale), clay.SizingFixed(28 * g.scale)},
				childAlignment = {x = .Center, y = .Center},
			},
			backgroundColor = hover_color(b, clay.ID("copy_path"), {}),
			cornerRadius = clay.CornerRadiusAll(5 * g.scale),
		},
		) {
			kind: Icon = .CopyPath
			if h.copied_until != 0 {kind = .Check}
			icon_element(p, kind, g.scale)
		}
		if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {}
		view_button(b, g, p)
	}
}
