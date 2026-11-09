package main

import "core:os"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Place :: struct {
	label: string, // Static label.
	path:  string, // Owned, canonical directory path.
	icon:  Icon,
}

Places :: struct {
	entries:         [dynamic]Place,
	selected, first: int,
	focused:         bool,
}

places_add :: proc(p: ^Places, place: Place) {
	if place.path == "" {return}
	path, err := os.get_absolute_path(place.path, context.allocator)
	if err != nil {return}
	if !os.is_dir(path) {delete(path); return}
	for existing in p.entries {
		if existing.path == path {delete(path); return}
	}
	append(&p.entries, Place{label = place.label, path = path, icon = place.icon})
}

places_init :: proc(p: ^Places) {
	folders := [?]struct {
		folder: sdl.Folder,
		label:  string,
		icon:   Icon,
	} {
		{.HOME, "home", .PlaceHome},
		{.DESKTOP, "desktop", .PlaceDesktop},
		{.DOCUMENTS, "documents", .Document},
		{.DOWNLOADS, "downloads", .PlaceDownloads},
		{.PICTURES, "pictures", .PlacePictures},
		{.MUSIC, "music", .PlaceMusic},
		{.VIDEOS, "videos", .PlaceVideos},
	}
	for folder in folders {
		path := sdl.GetUserFolder(folder.folder)
		if path !=
		   nil {places_add(p, {label = folder.label, path = string(path), icon = folder.icon})}
	}
	places_add(p, {label = "filesystem", path = "/", icon = .PlaceFilesystem})
}

places_destroy :: proc(p: ^Places) {
	for place in p.entries {delete(place.path)}
	delete(p.entries)
}

// Choose the most specific place containing the current folder.
places_active :: proc(p: ^Places, path: string) -> int {
	active, length := -1, 0
	for place, i in p.entries {
		parent := place.path
		matches :=
			path == parent ||
			parent == "/" ||
			(len(path) > len(parent) &&
					strings.has_prefix(path, parent) &&
					path[len(parent)] == '/')
		if matches && len(parent) > length {active, length = i, len(parent)}
	}
	return active
}

places_reveal :: proc(p: ^Places, rows: int) {
	reveal_rows(&p.selected, &p.first, len(p.entries), rows)
}

places_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingFixed(g.sidebar), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = theme.panel,
	},
	) {
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
				padding = {left = u16(g.padding)},
				childAlignment = {y = .Center},
			},
		},
		) {label("places", theme.muted, g.scale)}
		if clay.UI()({layout = list_layout(g)}) {
			active := places_active(&b.places, b.path)
			inset := u16(6 * g.scale)
			for i in b.places.first ..< min(b.places.first + g.rows, len(b.places.entries)) {
				place := b.places.entries[i]
				color: clay.Color
				if i == active {color = theme.selected}
				color = hover_color(b, clay.ID("place", u32(i)), color)
				if clay.UI(clay.ID("place", u32(i)))(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
						padding = {
							left = inset,
							right = inset,
							top = u16(2 * g.scale),
							bottom = u16(2 * g.scale),
						},
					},
				},
				) {
					if clay.UI()(
					{
						layout = {
							sizing = {clay.SizingGrow(), clay.SizingGrow()},
							padding = {
								left = u16(8 * g.scale) - inset,
								right = u16(8 * g.scale) - inset,
							},
							childGap = u16(8 * g.scale),
							childAlignment = {y = .Center},
						},
						backgroundColor = color,
						cornerRadius = clay.CornerRadiusAll(6 * g.scale),
					},
					) {
						cursor_color: clay.Color
						text_color := theme.muted
						if i == active {text_color = theme.text}
						if b.places.focused &&
						   i ==
							   b.places.selected {cursor_color, text_color = theme.text, theme.text}
						if clay.UI()(
						{
							layout = {
								sizing = {
									clay.SizingFixed(2 * g.scale),
									clay.SizingFixed(16 * g.scale),
								},
							},
							backgroundColor = cursor_color,
						},
						) {}
						icon_element(p, place.icon, g.scale)
						label(
							fit_label(p.font, place.label, g.sidebar - 52 * g.scale),
							text_color,
							g.scale,
						)
					}
				}
			}
		}
	}
}
