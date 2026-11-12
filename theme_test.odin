package main

import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

verify_theme_switch :: proc(t: ^testing.T, p: ^Painter) {
	previous: sdl.SystemTheme = theme == LIGHT_THEME ? .LIGHT : .DARK
	defer _ = theme_apply(p, previous)
	_ = theme_apply(p, .DARK)
	icons := p.icons
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp")
	b.entries = make([]os.File_Info, 1)
	b.entries[0] = {
		name = "theme sample.txt",
		type = .Regular,
		size = 512,
	}
	browser_filter(&b)
	g := geometry(960, 640, 1)
	cases := [?]struct {
		system:   sdl.SystemTheme,
		expected: Theme,
		changed:  bool,
	}{{.LIGHT, LIGHT_THEME, true}, {.DARK, DARK_THEME, true}, {.UNKNOWN, DARK_THEME, false}}
	for item in cases {
		testing.expect_value(t, theme_apply(p, item.system), item.changed)
		commands := layout(&b, g, p)
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.boundingBox.y < g.height - g.footer {continue}
			if cmd.commandType ==
			   .Rectangle {testing.expect_value(t, cmd.renderData.rectangle.backgroundColor, theme.panel)}
			if cmd.commandType != .Text {continue}
			data := cmd.renderData.text
			testing.expect_value(t, data.textColor, theme.muted)
		}
		paint(p, commands, 960, 640)
		for icon, kind in p.icons {
			testing.expect_value(t, icon, icons[kind])
			r, green, blue: u8
			sdl_check(sdl.GetTextureColorMod(icon, &r, &green, &blue))
			color := item.expected.muted
			if kind == .Move ||
			   kind == .MoveHorizontal ||
			   kind == .MoveVertical {color = item.expected.background}
			testing.expect_value(t, r, u8(color[0]))
			testing.expect_value(t, green, u8(color[1]))
			testing.expect_value(t, blue, u8(color[2]))
		}
		pixels := [?]struct {
			x, y:  i32,
			color: clay.Color,
		} {
			{950, 400, item.expected.background},
			{950, i32(g.list_top + g.row / 2), item.expected.selected},
			// Only the left pane corners expose the surrounding panel.
			{i32(g.sidebar), i32(g.header + g.row), item.expected.panel},
			{i32(g.sidebar), i32(g.height - g.footer) - 1, item.expected.panel},
			{i32(g.sidebar) + 10, i32(g.header + g.row), item.expected.background},
			{i32(g.sidebar), 400, item.expected.background},
			{959, i32(g.header + g.row), item.expected.background},
			{959, i32(g.height - g.footer) - 1, item.expected.background},
		}
		for pixel in pixels {
			rect := sdl.Rect{pixel.x, pixel.y, 1, 1}
			surface := sdl.RenderReadPixels(p.renderer, &rect)
			if surface == nil {testing.fail_now(t, string(sdl.GetError()))}
			r, green, blue, alpha: u8
			sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &r, &green, &blue, &alpha))
			sdl.DestroySurface(surface)
			testing.expect_value(t, r, u8(pixel.color[0]))
			testing.expect_value(t, green, u8(pixel.color[1]))
			testing.expect_value(t, blue, u8(pixel.color[2]))
		}
		verify_column_hover(t, p)
		testing.expect(
			t,
			!theme_apply(p, item.system),
			"an unchanged theme must not request another frame",
		)
	}
}
