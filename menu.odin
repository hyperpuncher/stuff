package main

import "core:math"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Menu_Action :: enum {
	Copy,
	Paste,
	Rename,
	New_Folder,
	Open_With,
	Compress,
	Extract,
	Restore,
	Empty_Trash,
	Trash,
	Select_All,
}
Context_Menu :: struct {
	active, paste, places: bool,
	x, y, width:           f32,
	selected, first:       int,
}

menu_visible :: proc(b: ^Browser, action: Menu_Action) -> bool {
	if b.menu.places {return action == .Empty_Trash}
	if action == .Compress {return b.path != TRASH_PATH && len(b.marks) > 0}
	if action == .Extract {return archive_selection_can_extract(b)}
	if action == .Open_With {
		if len(b.marks) != 1 {return false}
		for index in b.marks {return b.entries[index].type == .Regular || b.entries[index].type == .Symlink}
	}
	if action == .Restore || action == .Empty_Trash {return b.path == TRASH_PATH}
	if action == .Trash {return b.path != TRASH_PATH}
	if action == .Paste {return b.menu.paste && b.path != TRASH_PATH}
	if action == .Rename {return len(b.marks) == 1 && b.path != TRASH_PATH}
	if action == .New_Folder {return b.path != TRASH_PATH}
	return true
}

menu_rows :: proc(b: ^Browser, g: Geometry) -> int {
	count := 0
	for action in Menu_Action {if menu_visible(b, action) {count += 1}}
	return min(count, max(1, int((g.height - 8 * g.scale) / g.row)))
}

menu_reveal :: proc(b: ^Browser, g: Geometry) {
	count, selected := 0, 0
	for action in Menu_Action {
		if !menu_visible(b, action) {continue}
		if int(action) == b.menu.selected {selected = count}
		count += 1
	}
	rows := menu_rows(b, g)
	if b.menu.selected >= 0 {reveal_rows(&selected, &b.menu.first, count, rows)}
	b.menu.first = clamp(b.menu.first, 0, max(0, count - rows))
}

menu_box :: proc(b: ^Browser, g: Geometry) -> clay.BoundingBox {
	menu := b.menu
	width, height := menu.width, f32(menu_rows(b, g)) * g.row + 8 * g.scale
	margin := 24 * g.scale
	vertical_margin := min(margin, max(0, (g.height - height) / 2))
	return {
		clamp(menu.x, margin, g.width - width - margin),
		clamp(menu.y, vertical_margin, g.height - height - vertical_margin),
		width,
		height,
	}
}

menu_enabled :: proc(b: ^Browser, action: Menu_Action) -> bool {
	if !menu_visible(b, action) {return false}
	if b.menu.places {return len(b.transfers) == 0 && b.pending_trash == nil}
	switch action {
	case .Rename, .New_Folder, .Open_With:
		return len(b.transfers) == 0
	case .Copy, .Compress, .Extract:
		return len(b.marks) > 0
	case .Paste:
		return b.menu.paste
	case .Trash, .Restore:
		return len(b.marks) > 0 && len(b.transfers) == 0
	case .Empty_Trash:
		return len(b.visible) > 0 && len(b.transfers) == 0 && b.pending_trash == nil
	case .Select_All:
		return len(b.visible) > 0
	}
	unreachable()
}

menu_action_at :: proc(b: ^Browser, g: Geometry, x, y: f32) -> int {
	box := menu_box(b, g)
	inner := box
	inner.y += 4 * g.scale
	inner.height -= 8 * g.scale
	if !box_contains(inner, x, y) {return -1}
	row := b.menu.first + int((y - inner.y) / g.row)
	for action in Menu_Action {
		if !menu_visible(b, action) {continue}
		if row == 0 {return int(action)}
		row -= 1
	}
	return -1
}

menu_show :: proc(b: ^Browser, x, y: f32) {
	b.menu = {
		active   = true,
		x        = x,
		y        = y,
		selected = -1,
		width    = b.menu.width,
	}
}

menu_open :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	if x < g.sidebar || x >= g.width || y < g.list_top || y >= list_bottom(g) {return false}
	row := item_at(g, x, y, b.first, len(b.visible))
	if row < 0 {selection_clear(b)} else if !b.marks[b.visible[row]] {selection_single(b, row)}
	b.places.focused = false
	b.drag = {}
	menu_show(b, x, y)
	b.menu.paste = file_clipboard_has_files()
	return true
}

// Right-clicking the trash place offers the only action that belongs to it.
menu_open_places :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	if x < 0 || x >= g.sidebar {return false}
	index := row_at(places_geometry(g), y, b.places.first, len(b.places.entries))
	if index < 0 ||
	   b.places.entries[index].section ||
	   b.places.entries[index].path != TRASH_PATH {return false}
	menu_show(b, x, y)
	b.menu.places = true
	return true
}

menu_execute :: proc(b: ^Browser, action: Menu_Action) {
	enabled := menu_enabled(b, action)
	b.menu.active = false
	if !enabled {return}
	switch action {
	case .Copy:
		file_clipboard_copy(b)
	case .Paste:
		file_operation_start(b, false)
	case .Rename, .New_Folder:
		file_dialog_start(b, action == .Rename)
	case .Open_With:
		open_with_start(b)
	case .Compress:
		archive_dialog_start(b)
	case .Extract:
		archive_extract_selection(b)
	case .Restore:
		file_restore_start(b)
	case .Empty_Trash:
		trash_empty_start(b)
	case .Trash:
		file_operation_start(b, true)
	case .Select_All:
		selection_all(b)
	}
}

menu_input :: proc(b: ^Browser, event: ^sdl.Event, g: Geometry) -> bool {
	if !b.menu.active {return false}
	#partial switch event.type {
	case .MOUSE_BUTTON_DOWN:
		row := menu_action_at(b, g, event.button.x, event.button.y)
		if event.button.button == sdl.BUTTON_RIGHT {
			b.menu.active = false
			_ = menu_open(b, g, event.button.x, event.button.y)
		} else if event.button.button == sdl.BUTTON_LEFT &&
		   row >= 0 {menu_execute(b, Menu_Action(row))} else {b.menu.active = false}
		return true
	case .MOUSE_WHEEL:
		if header_hit(clay.ID("context-menu"), event.wheel.mouse_x, event.wheel.mouse_y) {
			amount := event.wheel.direction == .FLIPPED ? -event.wheel.y : event.wheel.y
			b.menu.first -= int(amount)
			b.menu.selected = -1
			menu_reveal(b, g)
		} else {b.menu.active = false}
		return true
	case .KEY_DOWN:
		switch event.key.key {
		case sdl.K_ESCAPE:
			b.menu.active = false
		case sdl.K_UP, sdl.K_DOWN, sdl.K_HOME, sdl.K_END:
			i := b.menu.selected
			count := len([Menu_Action]bool{})
			direction := event.key.key == sdl.K_UP || event.key.key == sdl.K_END ? -1 : 1
			if event.key.key == sdl.K_HOME {i = -1}
			if event.key.key == sdl.K_END || i < 0 && direction < 0 {i = count}
			for _ in 0 ..< count {
				i = (i + direction + count) % count
				if menu_enabled(b, Menu_Action(i)) {b.menu.selected = i; break}
			}
			menu_reveal(b, g)
		case sdl.K_RETURN:
			if !event.key.repeat &&
			   b.menu.selected >= 0 {menu_execute(b, Menu_Action(b.menu.selected))}
		case:
			b.menu.active = false
			return false
		}
		return true
	}
	return false
}

// Build the soft alpha gradient once per size and scale. One blended texture
// avoids the visible bands produced by overlapping low-alpha rectangles.
menu_shadow_texture :: proc(p: ^Painter, box: clay.BoundingBox, scale: f32) -> ^sdl.Texture {
	padding, radius, sigma := 21 * scale, 8 * scale, 7 * scale
	size := [2]i32 {
		i32(math.ceil(box.width + 2 * padding)),
		i32(math.ceil(box.height + 2 * padding)),
	}
	if p.menu_shadow != nil &&
	   p.menu_shadow_size == size &&
	   p.menu_shadow_scale == scale {return p.menu_shadow}
	surface := sdl.CreateSurface(size[0], size[1], .RGBA32)
	assert(surface != nil, string(sdl.GetError()))
	defer sdl.DestroySurface(surface)
	pixels := cast([^]u8)surface.pixels
	for y in 0 ..< int(size[1]) {
		for x in 0 ..< int(size[0]) {
			qx := abs(f32(x) + 0.5 - padding - box.width / 2) - box.width / 2 + radius
			qy := abs(f32(y) + 0.5 - padding - box.height / 2) - box.height / 2 + radius
			outside_x, outside_y := max(qx, 0), max(qy, 0)
			distance :=
				math.sqrt(outside_x * outside_x + outside_y * outside_y) +
				min(max(qx, qy), 0) -
				radius
			alpha := 28 * math.erfc(distance / (sigma * math.sqrt(f32(2))))
			pixels[y * int(surface.pitch) + x * 4 + 3] = u8(math.round(alpha))
		}
	}
	texture := sdl.CreateTextureFromSurface(p.renderer, surface)
	assert(texture != nil, string(sdl.GetError()))
	sdl_check(sdl.SetTextureBlendMode(texture, sdl.BLENDMODE_BLEND))
	if p.menu_shadow != nil {sdl.DestroyTexture(p.menu_shadow)}
	p.menu_shadow, p.menu_shadow_size, p.menu_shadow_scale = texture, size, scale
	return texture
}

popup_shadow_layout :: proc(box: clay.BoundingBox, scale: f32, p: ^Painter) {
	padding := 21 * scale
	shadow := menu_shadow_texture(p, box, scale)
	if clay.UI()(
	{
		layout = {
			sizing = {
				clay.SizingFixed(f32(p.menu_shadow_size[0])),
				clay.SizingFixed(f32(p.menu_shadow_size[1])),
			},
		},
		floating = {
			attachTo = .Root,
			offset = {box.x - padding, box.y + 4 * scale - padding},
			zIndex = 4,
			pointerCaptureMode = .Passthrough,
		},
		image = {imageData = shadow},
	},
	) {}
}

menu_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	names := [Menu_Action]string {
		.Copy        = "copy",
		.Paste       = "paste",
		.Rename      = "rename",
		.New_Folder  = "new folder",
		.Trash       = "move to trash",
		.Restore     = "restore",
		.Empty_Trash = "empty trash",
		.Open_With   = "open with…",
		.Compress    = "compress…",
		.Extract     = "extract",
		.Select_All  = "select all",
	}
	// Keep measured geometry available for input before the popup's first frame.
	widest := b.menu.places ? names[.Empty_Trash] : names[.Trash]
	b.menu.width = f32(text_width(p.font, widest)) + 60 * g.scale
	icons := [Menu_Action]Icon {
		.Copy        = .CopyPath,
		.Paste       = .Paste,
		.Rename      = .Rename,
		.New_Folder  = .NewFolder,
		.Trash       = .Trash,
		.Restore     = .Restore,
		.Empty_Trash = .Trash,
		.Open_With   = .OpenWith,
		.Compress    = .Archive,
		.Extract     = .Archive,
		.Select_All  = .SelectAll,
	}
	if !b.menu.active {return}
	menu_reveal(b, g)
	box := menu_box(b, g)
	popup_shadow_layout(box, g.scale, p)
	if clay.UI(clay.ID("context-menu"))(
	{
		layout = {
			sizing = {clay.SizingFixed(box.width), clay.SizingFixed(box.height)},
			padding = clay.PaddingAll(u16(4 * g.scale)),
			layoutDirection = .TopToBottom,
		},
		floating = {attachTo = .Root, offset = {box.x, box.y}, zIndex = 5},
		backgroundColor = theme.panel,
		cornerRadius = clay.CornerRadiusAll(8 * g.scale),
	},
	) {
		rows := menu_rows(b, g)
		row := -1
		for name, action in names {
			if !menu_visible(b, action) {continue}
			row += 1
			if row < b.menu.first || row >= b.menu.first + rows {continue}
			id := clay.ID("menu-item", u32(action))
			enabled := menu_enabled(b, action)
			background: clay.Color
			if enabled &&
			   (b.hovered == id.id || b.menu.selected == int(action)) {background = theme.hover}
			if clay.UI(id)(
			{
				layout = {
					sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
					padding = {left = u16(12 * g.scale), right = u16(12 * g.scale)},
					childGap = u16(10 * g.scale),
					childAlignment = {y = .Center},
				},
				backgroundColor = background,
				cornerRadius = clay.CornerRadiusAll(4 * g.scale),
			},
			) {
				icon_element(p, icons[action], g.scale)
				label(name, enabled ? theme.text : theme.muted, g.font_size)
			}
		}
	}
}
