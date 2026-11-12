package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
grid_navigation_selection_and_folder_targets :: proc(t: ^testing.T) {
	if !testing.expect(t, sdl.Init({.EVENTS})) {return}
	defer sdl.Quit()
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/grid")
	b.icons = true
	b.entries = make([]os.File_Info, 23)
	for &entry, i in b.entries {
		entry.fullpath = fmt.aprintf("/grid/%02d", i)
		entry.name = os.base(entry.fullpath)
		entry.type = .Directory
	}
	browser_filter(&b)
	g := geometry(960, 640, 1, icons = true)
	running := true
	for key in ([?]sdl.Keycode{sdl.K_DOWN, sdl.K_RIGHT}) {
		event := sdl.Event {
			key = {type = .KEY_DOWN, key = key},
		}
		_ = handle_event(&b, &event, g, &running)
	}
	testing.expect_value(t, b.selected, g.stride + 1)
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_END},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.selected, 22)
	testing.expect_value(t, b.first, view_last(g, len(b.visible)))
	event.key.key = sdl.K_UP
	_ = handle_event(&b, &event, g, &running)
	testing.expect(
		t,
		b.first == view_last(g, len(b.visible)),
		"do not move the viewport while the cursor is still visible",
	)
	testing.expect_value(t, item_at(g, g.width - 1, g.list_top + 10, b.first, len(b.visible)), -1)
	// The last partial row must remain reachable by wheel and scrollbar.
	bar := scrollbar_for(&b, g, false)
	scrollbar_press(&b, g, false, bar.track.y + bar.track.height - 1)
	testing.expect_value(t, b.first, view_last(g, len(b.visible)))
	b.drag = {}
	b.first = 0
	box := item_box(g, 1, b.first)
	event = {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = box.x + box.width / 2,
			y = box.y + 8,
		},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, b.selected, 1)
	storage: Storage
	b.storage = &storage
	defer b.storage = nil
	path, id := drag_target(&b, g, event.button.x, event.button.y)
	testing.expect_value(t, path, b.entries[b.visible[1]].fullpath)
	testing.expect_value(t, id, clay.ID("row", u32(b.visible[1])).id)
	// Start in the gap, then select two cards in one row, not every column.
	testing.expect(t, selection_drag_begin(&b, g, g.sidebar + g.padding + 1, g.list_top + 1))
	event = {
		motion = {type = .MOUSE_MOTION, x = box.x + box.width, y = box.y + box.height},
	}
	_ = handle_event(&b, &event, g, &running)
	testing.expect_value(t, len(b.marks), 2)
	testing.expect(t, b.marks[b.visible[0]] && b.marks[b.visible[1]])
	testing.expect(t, view_set_icons(&b, false))
	testing.expect_value(t, len(b.marks), 2)
	testing.expect(t, !b.selection_drag.active)
}

verify_grid_rendering :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	defer browser_destroy(&b)
	b.path, b.icons = strings.clone("/grid"), true
	b.entries = make([]os.File_Info, 100_000)
	resize(&b.visible, len(b.entries))
	for &entry, i in b.entries {
		entry.name, entry.type = "sample image.png", .Regular
		b.visible[i] = i
	}
	b.entries[0].fullpath = strings.clone("/grid/photo.png")
	source := sdl.CreateSurface(4, 2, .RGBA32)
	if !testing.expect(t, source != nil) {return}
	defer sdl.DestroySurface(source)
	sdl_check(sdl.FillSurfaceRect(source, nil, sdl.MapSurfaceRGBA(source, 255, 0, 0, 255)))
	texture := sdl.CreateTextureFromSurface(p.renderer, source)
	if !testing.expect(t, texture != nil) {return}
	previews: Preview_Service
	previews.cache[strings.clone(b.entries[0].fullpath)] = {
		texture = texture,
	}
	defer {
		for path in previews.cache {preview_forget(&previews, path)}
		delete(previews.cache)
	}
	b.previews = &previews
	defer b.previews = nil
	for scale in ([?]f32{1, 1.5, 2}) {
		painter_load_large_icons(p, scale)
		g := geometry(
			960,
			640,
			scale,
			font_height = f32(ttf.GetFontHeight(p.font)) / scale,
			icons = true,
		)
		for selected in ([?]int{0, 50_000, 99_999}) {
			selection_single(&b, selected)
			view_reveal(&b, g)
			commands := layout(&b, g, p)
			viewport := clay.GetElementData(clay.ID("files-viewport")).boundingBox
			testing.expect_value(t, viewport.y, g.header + g.list_padding)
			toggle := clay.GetElementData(clay.ID("view-mode")).boundingBox
			testing.expect(t, abs((g.width - toggle.x - toggle.width) - (toggle.y - g.tabs)) < 1)
			box := item_box(g, selected, b.first)
			actual := clay.GetElementData(clay.ID("row", u32(selected)))
			testing.expect(t, actual.found)
			testing.expect(
				t,
				abs(actual.boundingBox.x - box.x) < 0.1 && abs(actual.boundingBox.y - box.y) < 0.1,
			)
			testing.expect(t, int(commands.length) < 6 * (g.rows + g.stride) + 32)
			paint(p, commands, 960, 640)
			found_preview := false
			for i in 0 ..< commands.length {
				cmd := commands.internalArray[i]
				if cmd.commandType != .Image ||
				   cmd.renderData.image.imageData != texture {continue}
				found_preview = true
				image_box := cmd.boundingBox
				testing.expect(t, abs(image_box.width / image_box.height - 2) < 0.01)
				sample := sdl.Rect {
					i32(image_box.x + image_box.width / 2),
					i32(image_box.y + image_box.height / 2),
					1,
					1,
				}
				pixels := sdl.RenderReadPixels(p.renderer, &sample)
				if !testing.expect(t, pixels != nil) {return}
				color: [4]u8
				sdl_check(
					sdl.ReadSurfacePixel(pixels, 0, 0, &color[0], &color[1], &color[2], &color[3]),
				)
				testing.expect_value(t, color, [4]u8{255, 0, 0, 255})
				sdl.DestroySurface(pixels)
			}
			testing.expect_value(t, found_preview, selected == 0)
			region := sdl.Rect{i32(box.x + box.width / 2), i32(box.y + 3 * scale), 1, 1}
			surface := sdl.RenderReadPixels(p.renderer, &region)
			if !testing.expect(t, surface != nil) {return}
			r, green, blue, alpha: u8
			sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &r, &green, &blue, &alpha))
			testing.expect_value(t, r, u8(theme.selected[0]))
			sdl.DestroySurface(surface)
		}
	}
	// The top-bar control must switch views without changing selection.
	g := geometry(960, 640, 1, icons = true)
	_ = layout(&b, g, p)
	button := clay.GetElementData(clay.ID("view-mode")).boundingBox
	handled, err := header_click(&b, button.x + 1, button.y + 1)
	testing.expect(t, handled && err == nil && !b.icons)
	testing.expect_value(t, b.selected, 99_999)
}
