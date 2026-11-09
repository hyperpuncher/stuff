package main

import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

// Input tests alone do not detect unsupported painter commands from a popup.
verify_context_menu_rendering :: proc(t: ^testing.T, p: ^Painter) {
	previous: sdl.SystemTheme = theme == LIGHT_THEME ? .LIGHT : .DARK
	defer _ = theme_apply(p, previous)
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp")
	b.entries = make([]os.File_Info, 1)
	b.entries[0] = {
		name = "menu sample",
		type = .Regular,
	}
	browser_filter(&b)
	g := geometry(960, 640, 1)
	for mode in ([?]sdl.SystemTheme{.DARK, .LIGHT}) {
		_ = theme_apply(p, mode)
		event := sdl.Event {
			button = {
				type = .MOUSE_BUTTON_DOWN,
				button = sdl.BUTTON_RIGHT,
				x = g.width - 2,
				y = g.list_top + 1,
			},
		}
		running := true
		_ = handle_event(&b, &event, g, &running)
		testing.expect(t, b.menu.active)
		commands := layout(&b, g, p)
		menu := clay.GetElementData(clay.ID("context-menu"))
		testing.expect(t, menu.found)
		testing.expect(t, menu.boundingBox.x + menu.boundingBox.width <= g.width)
		text_width := f32(text_width(p.font, "move to trash"))
		testing.expect(
			t,
			menu.boundingBox.width > text_width &&
			menu.boundingBox.width < text_width + 80 * g.scale,
		)
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType != .Text {continue}
			text := cmd.renderData.text.stringContents
			value := string(text.chars[:text.length])
			testing.expect(
				t,
				value != "ctrl+c" && value != "ctrl+v" && value != "ctrl+a" && value != "delete",
			)
			testing.expect(t, b.menu.paste || value != "paste")
		}
		for action in Menu_Action {
			row := clay.GetElementData(clay.ID("menu-item", u32(action)))
			if !menu_visible(&b, action) {testing.expect(t, !row.found); continue}
			testing.expect(t, row.found)
			x, y :=
				row.boundingBox.x +
				row.boundingBox.width / 2,
				row.boundingBox.y +
				row.boundingBox.height / 2
			testing.expect_value(t, menu_action_at(&b, g, x, y), int(action))
		}
		before, after: sdl.BlendMode
		sdl_check(sdl.GetRenderDrawBlendMode(p.renderer, &before))
		paint(p, commands, 960, 640)
		sdl_check(sdl.GetRenderDrawBlendMode(p.renderer, &after))
		testing.expect_value(t, after, before)
		// The shadow must fade over several pixels, not end as a dark ring.
		levels: [4]u8
		for distance, i in ([?]i32{3, 10, 18, 28}) {
			pixel := sdl.Rect {
				i32(menu.boundingBox.x + menu.boundingBox.width / 2),
				i32(menu.boundingBox.y + menu.boundingBox.height) + distance,
				1,
				1,
			}
			surface := sdl.RenderReadPixels(p.renderer, &pixel)
			if surface == nil {testing.fail_now(t, string(sdl.GetError()))}
			r, green, blue, alpha: u8
			sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &r, &green, &blue, &alpha))
			sdl.DestroySurface(surface)
			levels[i] = r
		}
		testing.expect(t, levels[0] > 0 && levels[0] < levels[1])
		testing.expect(t, levels[1] <= levels[2] && levels[2] <= levels[3])
		testing.expect_value(t, levels[3], u8(theme.background[0]))
		cached := p.menu_shadow
		_ = layout(&b, g, p)
		testing.expect_value(t, p.menu_shadow, cached)
		b.menu.paste = true
		small := geometry(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, 1)
		bounds := menu_box(&b, small)
		testing.expect(t, bounds.y >= 0 && bounds.y + bounds.height <= small.height)
		b.menu.active = false
	}
}
