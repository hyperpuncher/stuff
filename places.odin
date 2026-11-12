package main

import "core:os"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Place :: struct {
	label:         string, // Owned.
	path:          string, // Owned; empty for an unmounted disk.
	device:        string, // Owned for disks; empty for XDG places.
	icon:          Icon,
	disk, section: bool,
	space:         Space_Info,
}

Places :: struct {
	entries:         [dynamic]Place,
	selected, first: int,
	focused:         bool,
}

places_add :: proc(p: ^Places, place: Place) {
	if place.path == "" {return}
	if place.path == TRASH_PATH {
		append(
			&p.entries,
			Place {
				label = strings.clone(place.label),
				path = strings.clone(TRASH_PATH),
				icon = .Trash,
			},
		)
		return
	}
	dir, err := directory_open(place.path)
	if err != nil {return}
	defer os.close(dir)
	path := os.name(dir)
	for existing in p.entries {
		if existing.path == path {return}
	}
	owned := place
	owned.label, owned.path = strings.clone(place.label), strings.clone(path)
	append(&p.entries, owned)
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
	places_add(p, {label = "trash", path = TRASH_PATH, icon = .Trash})
	append(&p.entries, Place{section = true})
	places_add(p, {label = "filesystem", path = "/", icon = .PlaceFilesystem, disk = true})
}

places_destroy :: proc(p: ^Places) {
	for place in p.entries {place_destroy(place)}
	delete(p.entries)
}

// Choose the most specific place containing the current folder.
places_active :: proc(p: ^Places, path: string) -> int {
	active, length := -1, 0
	for place, i in p.entries {
		parent := place.path
		matches := path_contains(parent, path)
		if matches && len(parent) > length {active, length = i, len(parent)}
	}
	return active
}

places_reveal :: proc(p: ^Places, rows: int) {
	reveal_rows(&p.selected, &p.first, len(p.entries), rows)
}

places_geometry :: proc(g: Geometry) -> Geometry {
	result := g
	result.horizontal_bar = 0
	result.list_top -= g.row
	result.height -= g.transfers
	result.rows = max(1, int((list_bottom(result) - result.list_top) / result.row))
	return result
}

places_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	// Center leading icons under the root breadcrumb, including font width.
	icon_left :=
		f32(u16(12 * g.scale)) +
		f32(u16(6 * g.scale)) +
		(f32(text_width(p.font, "/")) - 18 * g.scale) / 2
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingFixed(g.sidebar), clay.SizingGrow()},
			layoutDirection = .TopToBottom,
		},
		backgroundColor = theme.panel,
	},
	) {
		if clay.UI()({layout = list_layout(g)}) {
			if clay.UI(clay.ID("places-viewport"))(viewport_config()) {
				active := places_active(&b.places, b.path)
				inset := u16(6 * g.scale)
				right_inset := inset
				if len(b.places.entries) > g.rows {right_inset = u16(7 * g.scale)}
				for i in b.places.first ..< min(b.places.first + g.rows + 1, len(b.places.entries)) {
					place := b.places.entries[i]
					if place.section {
						if clay.UI()(
						{layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)}}},
						) {}
						continue
					}
					color: clay.Color
					if i == active {color = theme.selected}
					color = hover_color(b, clay.ID("place", u32(i)), color)
					if clay.UI(clay.ID("place", u32(i)))(
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
							layout = {
								sizing = {clay.SizingGrow(), clay.SizingGrow()},
								padding = {
									left = u16(icon_left) - inset,
									right = u16(8 * g.scale) - right_inset,
								},
								childGap = u16(8 * g.scale),
								childAlignment = {y = .Center},
							},
							backgroundColor = color,
							cornerRadius = clay.CornerRadiusAll(6 * g.scale),
						},
						) {
							focused := b.places.focused && i == b.places.selected
							text_color := i == active || focused ? theme.text : theme.muted
							if focused {
								if clay.UI()(
								{
									layout = {
										sizing = {
											clay.SizingFixed(2 * g.scale),
											clay.SizingFixed(16 * g.scale),
										},
									},
									floating = {
										attachTo = .Parent,
										clipTo = .AttachedParent,
										attachment = {element = .LeftCenter, parent = .LeftCenter},
										offset = {2 * g.scale, 0},
										zIndex = 1,
										pointerCaptureMode = .Passthrough,
									},
									backgroundColor = theme.text,
								},
								) {}
							}
							icon_element(p, place.icon, g.scale)
							width :=
								g.sidebar -
								f32(u16(icon_left)) -
								18 * g.scale -
								2 * f32(u16(8 * g.scale))
							if place_can_unmount(place) {width -= 26 * g.scale}
							if clay.UI()(
							{
								layout = {
									sizing = {width = clay.SizingGrow()},
									layoutDirection = .TopToBottom,
									childGap = u16(3 * g.scale),
								},
							},
							) {
								label(
									fit_label(p.font, place.label, width),
									text_color,
									g.font_size,
								)
								if place.disk && place.space.valid && place.space.total > 0 {
									progress_line(
										clay.ID("disk-usage", u32(i)),
										disk_used_fraction(place.space),
										g.scale,
										max(0, width - 8 * g.scale),
									)
								}
							}
							if place_can_unmount(place) {
								id := place_unmount_id(i)
								if clay.UI(id)(
								{
									layout = {
										sizing = {
											clay.SizingFixed(18 * g.scale),
											clay.SizingFixed(18 * g.scale),
										},
										childAlignment = {x = .Center, y = .Center},
									},
									backgroundColor = hover_color(b, id, {}),
									cornerRadius = clay.CornerRadiusAll(9 * g.scale),
								},
								) {icon_element(p, .Unmount, g.scale)}
							}
						}
					}
				}
			}
		}
		file_transfers_layout(b, g, p, icon_left)
	}
}
