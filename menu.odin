package main

import "core:math"
import clay "vendor/clay"
import sdl "vendor:sdl3"

Menu_Action :: enum {
	Copy,
	Paste,
	Trash,
	Select_All,
}
Context_Menu :: struct {
	active, paste: bool,
	x, y, width:   f32,
	selected:      int,
}

menu_box :: proc(menu: Context_Menu, g: Geometry) -> clay.BoundingBox {
	rows := menu.paste ? 4 : 3
	width, height := menu.width, f32(rows) * g.row + 8 * g.scale
	margin := 24 * g.scale
	return {
		clamp(menu.x, margin, g.width - width - margin),
		clamp(menu.y, margin, g.height - height - margin),
		width,
		height,
	}
}

menu_enabled :: proc(b: ^Browser, action: Menu_Action) -> bool {
	switch action {
	case .Copy:
		return len(b.marks) > 0
	case .Paste:
		return b.menu.paste && b.pending_files == nil
	case .Trash:
		return len(b.marks) > 0 && b.pending_files == nil
	case .Select_All:
		return len(b.visible) > 0
	}
	unreachable()
}

menu_action_at :: proc(b: ^Browser, g: Geometry, x, y: f32) -> int {
	box := menu_box(b.menu, g)
	if x < box.x ||
	   x >= box.x + box.width ||
	   y < box.y + 4 * g.scale ||
	   y >= box.y + box.height - 4 * g.scale {return -1}
	row := int((y - box.y - 4 * g.scale) / g.row)
	for action in Menu_Action {
		if action == .Paste && !b.menu.paste {continue}
		if row == 0 {return int(action)}
		row -= 1
	}
	return -1
}

menu_open :: proc(b: ^Browser, g: Geometry, x, y: f32) -> bool {
	if x < g.sidebar || x >= g.width || y < g.list_top || y >= list_bottom(g) {return false}
	row := row_at(g, y, b.first, len(b.visible))
	if row < 0 {selection_clear(b)} else if !b.marks[b.visible[row]] {selection_single(b, row)}
	b.places.focused = false
	b.drag = {}
	b.menu = {
		active   = true,
		paste    = b.pending_files == nil && file_clipboard_has_files(),
		x        = x,
		y        = y,
		selected = -1,
		width    = b.menu.width,
	}
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
		b.menu.active = false
		return true
	case .KEY_DOWN:
		switch event.key.key {
		case sdl.K_ESCAPE:
			b.menu.active = false
		case sdl.K_UP, sdl.K_DOWN, sdl.K_HOME, sdl.K_END:
			i := b.menu.selected
			direction := event.key.key == sdl.K_UP || event.key.key == sdl.K_END ? -1 : 1
			if event.key.key == sdl.K_HOME {i = -1}
			if event.key.key == sdl.K_END || i < 0 && direction < 0 {i = 4}
			for _ in 0 ..< 4 {
				i = (i + direction + 4) % 4
				if menu_enabled(b, Menu_Action(i)) {b.menu.selected = i; break}
			}
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

menu_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter) {
	names := [Menu_Action]string {
		.Copy       = "copy",
		.Paste      = "paste",
		.Trash      = "move to trash",
		.Select_All = "select all",
	}
	// Keep measured geometry available for input before the popup's first frame.
	b.menu.width = 0
	for name in names {b.menu.width = max(b.menu.width, f32(text_width(p.font, name)))}
	b.menu.width += 32 * g.scale
	if !b.menu.active {return}
	box := menu_box(b.menu, g)
	padding := 21 * g.scale
	shadow := menu_shadow_texture(p, box, g.scale)
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
			offset = {box.x - padding, box.y + 4 * g.scale - padding},
			zIndex = 4,
			pointerCaptureMode = .Passthrough,
		},
		image = {imageData = shadow},
	},
	) {}
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
		for name, action in names {
			if action == .Paste && !b.menu.paste {continue}
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
					childAlignment = {y = .Center},
				},
				backgroundColor = background,
				cornerRadius = clay.CornerRadiusAll(4 * g.scale),
			},
			) {
				label(name, enabled ? theme.text : theme.muted, g.scale)
			}
		}
	}
}
