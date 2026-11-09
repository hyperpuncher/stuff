package main

import "core:fmt"
import "core:time"
import clay "vendor/clay"
import sdl "vendor:sdl3"

SIDEBAR_WIDTH :: 192
MIN_WINDOW_WIDTH :: SIDEBAR_WIDTH + 480
MIN_WINDOW_HEIGHT :: 240

Geometry :: struct {
	width, height, scale, header, footer, row, list_top: f32,
	padding, gap, sidebar, list_padding, font_size:      f32,
	columns:                                             [Column]f32,
	rows:                                                int,
}

geometry :: proc(
	width, height: i32,
	scale: f32,
	font_size: f32 = 14,
	font_height: f32 = 0,
) -> Geometry {
	g := Geometry {
		width        = f32(width),
		height       = f32(height),
		scale        = scale,
		header       = max(36, font_height + 12) * scale,
		footer       = max(40, font_height + 12) * scale,
		row          = max(30, font_height + 8) * scale,
		font_size    = font_size * scale,
		padding      = 16 * scale,
		gap          = 24 * scale,
		sidebar      = SIDEBAR_WIDTH * scale,
		list_padding = 4 * scale,
	}
	g.list_top = g.header + g.row + g.list_padding
	g.columns[.Size] = 112 * scale
	g.columns[.Modified] = 184 * scale
	g.columns[.Name] = max(
		0,
		g.width - g.sidebar - 2 * g.padding - 2 * g.gap - g.columns[.Size] - g.columns[.Modified],
	)
	g.rows = max(1, int((g.height - g.list_top - g.footer - g.list_padding) / g.row))
	return g
}

list_layout :: proc(g: Geometry) -> clay.LayoutConfig {
	return {
		sizing = {clay.SizingGrow(), clay.SizingGrow()},
		padding = {top = u16(g.list_padding), bottom = u16(g.list_padding)},
		layoutDirection = .TopToBottom,
	}
}

column_at :: proc(g: Geometry, x: f32) -> (Column, bool) {
	left := g.sidebar + g.padding
	for width, column in g.columns {
		if x >= left && x < left + width {return column, true}
		left += width + g.gap
	}
	return .Name, false
}

list_bottom :: proc(g: Geometry) -> f32 {return g.height - g.footer - g.list_padding}

viewport_config :: proc() -> clay.ElementDeclaration {
	return {
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		clip = {horizontal = true, vertical = true},
	}
}

row_at :: proc(g: Geometry, y: f32, first, count: int) -> int {
	if y < g.list_top || y >= list_bottom(g) {return -1}
	index := first + int((y - g.list_top) / g.row)
	return index < count ? index : -1
}

row_layout :: proc(g: Geometry) -> clay.LayoutConfig {
	return {
		sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
		padding = {left = u16(g.padding), right = u16(g.padding)},
		childGap = u16(g.gap),
		childAlignment = {y = .Center},
	}
}

column_layout :: proc(g: Geometry, column: Column) -> clay.LayoutConfig {
	align: clay.LayoutAlignmentX = .Left
	if column == .Size {align = .Right}
	return {
		sizing = {clay.SizingFixed(g.columns[column]), clay.SizingGrow()},
		childGap = u16(12 * g.scale),
		childAlignment = {x = align, y = .Center},
	}
}

label :: proc(value: string, color: clay.Color, font_size: f32) {
	clay.Text(value, {textColor = color, fontSize = u16(font_size), wrapMode = .None})
}

icon_size :: proc(kind: Icon) -> f32 {return kind == .Unmount ? 12 : 18}

icon_element :: proc(p: ^Painter, kind: Icon, scale: f32) {
	size := icon_size(kind) * scale
	if clay.UI()(
	{
		layout = {sizing = {clay.SizingFixed(size), clay.SizingFixed(size)}},
		image = {imageData = p.icons[kind]},
	},
	) {}
}

format_modified :: proc(stamp: time.Time) -> string {
	date: sdl.DateTime
	if !sdl.TimeToDateTime(sdl.Time(time.to_unix_nanoseconds(stamp)), &date, true) {return "—"}
	return fmt.tprintf(
		"%02d.%02d.%04d %02d:%02d",
		date.day,
		date.month,
		date.year,
		date.hour,
		date.minute,
	)
}

table_header :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	if clay.UI()({layout = row_layout(g), backgroundColor = theme.panel}) {
		names := [Column]string {
			.Name     = "name",
			.Size     = "size",
			.Modified = "modified",
		}
		for name, column in names {
			id := clay.ID("column", u32(column))
			if clay.UI(id)({layout = column_layout(g, column)}) {
				if column == .Name {
					// Align the heading with filenames, after the file icon.
					if clay.UI()({layout = {sizing = {width = clay.SizingFixed(18 * g.scale)}}}) {}
				}
				color := theme.muted
				if column == b.sort_column || b.hovered == id.id {color = theme.text}
				label(name, color, g.font_size)
				if column == b.sort_column {
					kind: Icon = .SortAscending
					if b.descending {kind = .SortDescending}
					icon_element(p, kind, g.scale)
				}
			}
		}
	}
}

table_row :: proc(b: ^Browser, index: int, g: Geometry, p: ^Painter) {
	source := b.visible[index]
	entry := b.entries[source]
	color: clay.Color
	if b.marks[source] {
		color = theme.selected
		if b.places.focused {color = theme.inactive_selection}
	}
	color = hover_color(b, clay.ID("row", u32(source)), color)
	inset := u16(6 * g.scale)
	right_inset := inset
	if len(b.visible) > g.rows {right_inset = u16(7 * g.scale)}
	inner := row_layout(g)
	inner.sizing.height = clay.SizingGrow()
	inner.padding.left -= inset
	inner.padding.right -= right_inset
	if clay.UI(clay.ID("row", u32(source)))(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
			padding = {
				left = inset,
				right = right_inset,
				top = u16(1.5 * g.scale),
				bottom = u16(1.5 * g.scale),
			},
		},
	},
	) {
		if clay.UI()(
		{
			layout = inner,
			backgroundColor = color,
			cornerRadius = clay.CornerRadiusAll(6 * g.scale),
		},
		) {
			if clay.UI()({layout = column_layout(g, .Name)}) {
				icon_element(p, entry_icon(entry), g.scale)
				label(
					fit_label(p.font, entry.name, g.columns[.Name] - 30 * g.scale, middle = true),
					theme.text,
					g.font_size,
				)
			}
			if clay.UI()({layout = column_layout(g, .Size)}) {
				value := "—"
				if entry.type == .Regular {value = format_size(entry.size)}
				label(fit_label(p.font, value, g.columns[.Size]), theme.muted, g.font_size)
			}
			if clay.UI()({layout = column_layout(g, .Modified)}) {
				label(
					fit_label(
						p.font,
						format_modified(entry.modification_time),
						g.columns[.Modified],
					),
					theme.muted,
					g.font_size,
				)
			}
		}
	}
}

layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) -> clay.ClayArray(clay.RenderCommand) {
	b.first = clamp(b.first, 0, max(0, len(b.visible) - g.rows))
	b.places.first = clamp(
		b.places.first,
		0,
		max(0, len(b.places.entries) - places_geometry(g).rows),
	)
	clay.SetLayoutDimensions({g.width, g.height})
	clay.BeginLayout()
	if clay.UI(clay.ID("window"))(
	{
		layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}, layoutDirection = .TopToBottom},
		backgroundColor = theme.panel,
	},
	) {
		header_layout(b, g, p)
		if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingGrow()}}}) {
			places_layout(b, places_geometry(g), p)
			if clay.UI()(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingGrow()},
					layoutDirection = .TopToBottom,
				},
			},
			) {
				table_header(b, g, p)
				if clay.UI()(
				{
					layout = list_layout(g),
					backgroundColor = hover_color(b, clay.ID("files-viewport"), theme.background),
					cornerRadius = {topLeft = 10 * g.scale, bottomLeft = 10 * g.scale},
				},
				) {
					if clay.UI(clay.ID("files-viewport"))(viewport_config()) {
						if len(b.visible) == 0 {
							message :=
								b.path == TRASH_PATH ? "trash is empty" : "this folder is empty"
							if b.search != "" {message = "no matching items"}
							if b.path == TRASH_PATH &&
							   b.pending_trash != nil {message = "loading trash…"}
							if clay.UI()({layout = {padding = clay.PaddingAll(u16(g.padding))}}) {
								label(message, theme.muted, g.font_size)
							}
						}
						for i in b.first ..< min(b.first + g.rows + 1, len(b.visible)) {table_row(b, i, g, p)}
					}
				}
			}
		}
		scrollbar_layout(b, g, false)
		scrollbar_layout(b, g, true)
		if clay.UI(clay.ID("footer"))(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(g.footer)},
				padding = {left = u16(g.padding), right = u16(g.padding)},
				childGap = u16(g.gap),
				childAlignment = {y = .Center},
			},
			backgroundColor = theme.panel,
		},
		) {
			summary, color := browser_summary(b), theme.muted
			if b.path == TRASH_PATH && b.pending_trash != nil {summary = "loading trash…"}
			if b.pending_disk != nil {
				verb := b.pending_disk.unmount ? "unmounting" : "mounting"
				summary = fmt.tprintf("%s %s…", verb, b.pending_disk.device)
			}
			if b.pending_files != nil {
				op := b.pending_files
				verb :=
					op.kind == .Copy ? "copying" : op.kind == .Rename ? "renaming" : op.kind == .New_Folder ? "creating" : op.kind == .Restore ? "restoring" : op.kind == .Open_With ? "opening" : "moving to trash:"
				if op.history != .Record {verb = op.history == .Undo ? "undoing" : "redoing"}
				summary = fmt.tprintf("%s %d items…", verb, op.count)
			}
			if b.status_error != "" {summary, color = b.status_error, theme.text}
			free_space := ""
			width := g.width - 2 * g.padding
			if b.space.valid {
				free_space = fmt.tprintf("%s free", format_size(b.space.available))
				width -= f32(text_width(p.font, free_space)) + g.gap
			}
			if clay.UI()({layout = {sizing = {width = clay.SizingGrow()}}}) {
				label(fit_label(p.font, summary, width), color, g.font_size)
			}
			if free_space != "" {label(free_space, theme.muted, g.font_size)}
		}
	}
	menu_layout(b, g, p)
	file_dialog_layout(b, g, p)
	return clay.EndLayout(0)
}
