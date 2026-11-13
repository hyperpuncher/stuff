package main

import "core:math"

import clay "vendor/clay"

// first and rows remain item indices/counts in both views.
view_last :: proc(g: Geometry, count: int) -> int {
	stride := max(1, g.stride)
	return max(0, (count + stride - 1) / stride - g.rows / stride) * stride
}

view_first :: proc(g: Geometry, first, count: int) -> int {
	stride := max(1, g.stride)
	return clamp(first / stride * stride, 0, view_last(g, count))
}

item_box :: proc(g: Geometry, index, first: int) -> clay.BoundingBox {
	if !g.grid {return {g.sidebar, g.list_top + f32(index - first) * g.row, g.width - g.sidebar, g.row}}
	local := index - first
	inset := 4 * g.scale
	return {
		g.sidebar + g.padding + f32(local % g.stride) * g.cell_width + inset,
		g.list_top + f32(local / g.stride) * g.cell_height + inset,
		g.cell_width - 2 * inset,
		g.cell_height - 2 * inset,
	}
}

item_at :: proc(g: Geometry, x, y: f32, first, count: int) -> int {
	if x < g.sidebar || x >= g.width || y < g.list_top || y >= list_bottom(g) {return -1}
	if !g.grid {return row_at(g, y, first, count)}
	column := int(math.floor((x - g.sidebar - g.padding) / g.cell_width))
	if column < 0 || column >= g.stride {return -1}
	index := first + int((y - g.list_top) / g.cell_height) * g.stride + column
	if index >= count {return -1}
	return box_contains(item_box(g, index, first), x, y) ? index : -1
}

view_reveal :: proc(b: ^Browser, g: Geometry) {
	stride := max(1, g.stride)
	b.selected = clamp(b.selected, 0, max(0, len(b.visible) - 1))
	selected, first := b.selected / stride, b.first / stride
	reveal_rows(&selected, &first, (len(b.visible) + stride - 1) / stride, max(1, g.rows / stride))
	b.first = first * stride
}

view_set_icons :: proc(b: ^Browser, icons: bool) -> bool {
	if b.icons == icons {return false}
	file_drag_cancel_press(b)
	b.icons, b.first, b.scroll_x = icons, b.selected, 0
	b.drag, b.autoscroll, b.selection_drag, b.menu = {}, {}, {}, {}
	b.pointer.active, b.hovered = false, 0
	return true
}

view_button_hit :: proc(b: ^Browser, x, y: f32) -> bool {
	return(
		!b.header.edit.active &&
		b.header.edit.mode != .Search &&
		header_hit(clay.ID("view-mode"), x, y) \
	)
}

view_button :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	id := clay.ID("view-mode")
	if clay.UI(id)(
	{
		layout = {
			sizing = {clay.SizingFixed(28 * g.scale), clay.SizingFixed(28 * g.scale)},
			childAlignment = {x = .Center, y = .Center},
		},
		backgroundColor = hover_color(b, id, {}),
		cornerRadius = clay.CornerRadiusAll(5 * g.scale),
	},
	) {icon_element(p, b.icons ? .ListView : .IconView, g.scale)}
}

grid_rows :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	for start := b.first;
	    start < min(b.first + g.rows + g.stride, len(b.visible));
	    start += g.stride {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(g.cell_height)},
				padding = {left = u16(g.padding), right = u16(g.padding + 12 * g.scale)},
			},
		},
		) {
			for index in start ..< min(start + g.stride, len(b.visible)) {
				source := b.visible[index]
				entry := b.entries[source]
				color: clay.Color
				if b.marks[source] {color = b.places.focused ? theme.inactive_selection : theme.selected}
				if clay.UI()(
				{
					layout = {
						sizing = {clay.SizingFixed(g.cell_width), clay.SizingFixed(g.cell_height)},
						padding = clay.PaddingAll(u16(4 * g.scale)),
					},
				},
				) {
					if clay.UI(clay.ID("row", u32(source)))(
					{
						layout = {
							sizing = {clay.SizingGrow(), clay.SizingGrow()},
							padding = clay.PaddingAll(u16(4 * g.scale)),
							childGap = u16(4 * g.scale),
							layoutDirection = .TopToBottom,
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = hover_color(b, clay.ID("row", u32(source)), color),
						cornerRadius = clay.CornerRadiusAll(6 * g.scale),
					},
					) {
						if clay.UI()(
						{
							layout = {
								sizing = {
									clay.SizingFixed(THUMBNAIL_LOGICAL * g.scale),
									clay.SizingFixed(THUMBNAIL_LOGICAL * g.scale),
								},
								childAlignment = {x = .Center, y = .Center},
							},
						},
						) {
							texture := preview_texture(b.previews, entry.fullpath)
							width, height := 48 * g.scale, 48 * g.scale
							if texture != nil {
								ratio := min(
									THUMBNAIL_LOGICAL * g.scale / f32(texture.w),
									THUMBNAIL_LOGICAL * g.scale / f32(texture.h),
								)
								width, height = f32(texture.w) * ratio, f32(texture.h) * ratio
							} else {texture = p.large_icons[entry_icon(entry)]}
							if clay.UI()(
							{
								layout = {
									sizing = {clay.SizingFixed(width), clay.SizingFixed(height)},
								},
								image = {imageData = texture},
							},
							) {}
						}
						lines := fit_label_lines(p.font, entry.name, g.cell_width - 16 * g.scale)
						label(lines.first, theme.text, g.font_size)
						if lines.count > 1 {label(lines.second, theme.text, g.font_size)}
					}
				}
			}
		}
	}
}
