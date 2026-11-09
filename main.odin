package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

handle_event :: proc(b: ^Browser, event: ^sdl.Event, g: Geometry, running: ^bool) -> bool {
	pointer_changed := false
	#partial switch event.type {
	case .MOUSE_MOTION:
		return pointer_move(b, g, event.motion.x, event.motion.y)
	case .WINDOW_MOUSE_LEAVE, .WINDOW_FOCUS_LOST:
		b.pointer.active = false
		return hover_update(b, g)
	case .KEY_DOWN:
		b.pointer.active = false
		pointer_changed = hover_update(b, g)
	case .MOUSE_BUTTON_DOWN:
		pointer_changed = pointer_move(b, g, event.button.x, event.button.y)
	case .MOUSE_WHEEL:
		pointer_changed = pointer_move(b, g, event.wheel.mouse_x, event.wheel.mouse_y)
	}
	changed, err := handle_input(b, event, g, running)
	if err != nil {browser_message(b, fmt.tprintf("cannot read folder: %v", err))}
	return changed || pointer_changed
}

selection_key :: proc(key: sdl.Keycode, selected, first: ^int, count, rows: int) -> bool {
	switch key {
	case sdl.K_UP, sdl.K_K:
		selected^ -= 1
	case sdl.K_DOWN, sdl.K_J:
		selected^ += 1
	case sdl.K_HOME:
		selected^ = 0
	case sdl.K_END:
		selected^ = count - 1
	case sdl.K_PAGEUP:
		selected^ -= rows
	case sdl.K_PAGEDOWN:
		selected^ += rows
	case:
		return false
	}
	reveal_rows(selected, first, count, rows)
	return true
}

handle_input :: proc(
	b: ^Browser,
	event: ^sdl.Event,
	g: Geometry,
	running: ^bool,
) -> (
	changed: bool,
	err: os.Error,
) {
	#partial switch event.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		running^ = false
		return false, nil
	case .WINDOW_HIDDEN, .WINDOW_MINIMIZED:
		storage_visible(b.storage, false)
		return false, nil
	case .WINDOW_SHOWN, .WINDOW_RESTORED:
		storage_visible(b.storage, true)
		return true, nil
	case .WINDOW_EXPOSED, .WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_DISPLAY_SCALE_CHANGED:
		return true, nil
	case .KEY_DOWN:
		if event.key.repeat &&
		   (event.key.key == sdl.K_TAB ||
				   event.key.key == sdl.K_RETURN ||
				   event.key.key == sdl.K_L) {return false, nil}
		if event.key.key == sdl.K_TAB {
			b.places.focused = !b.places.focused
			if b.places.focused {
				active := places_active(&b.places, b.path)
				if active >= 0 {b.places.selected = active}
				places_reveal(&b.places, places_geometry(g).rows)
			}
			return true, nil
		}
		if b.places.focused && event.key.key == sdl.K_E && event.key.mod & sdl.KMOD_CTRL != {} {
			return true, place_open(b, b.places.selected, true)
		}
		selected, first, count, rows := &b.selected, &b.first, len(b.visible), g.rows
		if b.places.focused {
			selected, first, count = &b.places.selected, &b.places.first, len(b.places.entries)
			rows = places_geometry(g).rows
		}
		if selection_key(event.key.key, selected, first, count, rows) {
			if b.places.focused && count > 0 && b.places.entries[selected^].section {
				backward :=
					event.key.key == sdl.K_UP ||
					event.key.key == sdl.K_K ||
					event.key.key == sdl.K_PAGEUP
				direction := backward ? -1 : 1
				next := selected^ + direction
				if next < 0 || next >= count {next = selected^ - direction}
				selected^ = next
				places_reveal(&b.places, rows)
			}
			return true, nil
		}
		switch event.key.key {
		case sdl.K_RETURN, sdl.K_L:
			if b.places.focused {
				if len(b.places.entries) == 0 {return true, nil}
				return true, place_open(b, b.places.selected)
			}
			err = browser_enter(b)
		case sdl.K_BACKSPACE:
			err = browser_parent(b)
		case sdl.K_F5:
			err = browser_load(b, b.path)
			storage_refresh(b.storage)
		case sdl.K_H:
			if event.key.mod & sdl.KMOD_CTRL != {} {
				b.show_hidden = !b.show_hidden
				browser_filter(b)
			} else {
				err = browser_parent(b)
			}
		case:
			return false, nil
		}
		browser_reveal(b, g.rows)
		return true, err
	case .MOUSE_WHEEL:
		amount := event.wheel.y
		if event.wheel.direction == .FLIPPED {amount = -amount}
		x, y := event.wheel.mouse_x, event.wheel.mouse_y
		if x < 0 || x >= g.width || y < g.header || y >= g.height - g.footer {return false, nil}
		if x < g.sidebar {
			b.places.first = clamp(
				b.places.first - int(amount * 3),
				0,
				max(0, len(b.places.entries) - places_geometry(g).rows),
			)
		} else {
			b.first = clamp(b.first - int(amount * 3), 0, max(0, len(b.visible) - g.rows))
		}
		return true, nil
	case .MOUSE_BUTTON_DOWN:
		switch event.button.button {
		case sdl.BUTTON_X1:
			return true, browser_history(b, true)
		case sdl.BUTTON_X2:
			return true, browser_history(b, false)
		case sdl.BUTTON_LEFT:
		case:
			return false, nil
		}
		x, y := event.button.x, event.button.y
		if x < 0 || x >= g.width {return false, nil}
		if y >= 0 && y < g.header {return header_click(b, x, y)}
		if x < g.sidebar {
			index := row_at(places_geometry(g), y, b.places.first, len(b.places.entries))
			if index < 0 || b.places.entries[index].section {return false, nil}
			b.places.focused = true
			b.places.selected = index
			return true, place_open(b, index, place_unmount_at(b.places.entries[index], g, x))
		}
		if y >= g.header && y < g.header + g.row {
			if column, ok := column_at(g, x); ok {
				b.places.focused = false
				browser_set_sort(b, column)
				return true, nil
			}
			return false, nil
		}
		index := row_at(g, y, b.first, len(b.visible))
		if index < 0 {return false, nil}
		b.places.focused = false
		b.selected = index
		if event.button.clicks == 2 {err = browser_enter(b)}
		return true, err
	case:
		return false, nil
	}
}

ui_wait_timeout :: proc(b: ^Browser, now: u64) -> i32 {
	timeout := i32(-1)
	if len(b.opens) > 0 {timeout = 100}
	if b.header.copied_until != 0 {
		remaining := b.header.copied_until > now ? i32(b.header.copied_until - now) : 0
		timeout = timeout < 0 ? remaining : min(timeout, remaining)
	}
	return timeout
}

clay_error :: proc "c" (data: clay.ErrorData) {
	context = runtime.default_context()
	message := string(data.errorText.chars[:data.errorText.length])
	panic(message)
}

run :: proc() -> int {
	path := "."
	smoke := false
	for arg in os.args[1:] {
		if arg == "--smoke" {smoke = true; continue}
		if arg == "--help" {
			fmt.println(
				"usage: stuff [folder] [--smoke]\nuses the system monospace font. this version is read-only.",
			)
			return 0
		}
		path = arg
	}
	_ = sdl.SetAppMetadata("stuff", nil, "stuff")
	b: Browser
	defer {
		browser_destroy(&b)
		sdl.Quit()
	}
	if err := browser_load(&b, path); err != nil {
		fmt.eprintfln("cannot read %s: %v", path, err)
		return 1
	}
	font_path := system_monospace_path()
	defer delete(font_path)
	if font_path == "" {return 1}
	if !sdl.Init({.VIDEO}) {fmt.eprintln(string(sdl.GetError())); return 1}
	places_init(&b.places)
	b.storage = storage_start(b.path)
	if b.storage == nil {fmt.eprintln("cannot start the storage worker")}
	active := places_active(&b.places, b.path)
	if active >= 0 {b.places.selected = active}
	if !ttf.Init() {fmt.eprintln(string(sdl.GetError())); return 1}
	defer ttf.Quit()
	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !sdl.CreateWindowAndRenderer(
		"stuff",
		960,
		640,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY, .HIDDEN},
		&window,
		&renderer,
	) {
		fmt.eprintln(string(sdl.GetError()))
		return 1
	}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	window_icon(window)
	hand := sdl.CreateSystemCursor(.POINTER)
	defer if hand != nil {sdl.DestroyCursor(hand)}
	font_c := strings.clone_to_cstring(font_path)
	defer delete(font_c)
	font := ttf.OpenFont(font_c, 16)
	if font ==
	   nil {fmt.eprintfln("cannot load font %s: %s", font_path, string(sdl.GetError())); return 1}
	defer ttf.CloseFont(font)
	engine := ttf.CreateRendererTextEngine(renderer)
	if engine == nil {fmt.eprintln(string(sdl.GetError())); return 1}
	defer ttf.DestroyRendererTextEngine(engine)
	painter := Painter {
		renderer = renderer,
		engine   = engine,
		font     = font,
	}
	defer painter_destroy(&painter)

	clay.SetMaxElementCount(4096)
	memory := make([]u8, clay.MinMemorySize())
	defer delete(memory)
	clay.Initialize(
		clay.CreateArenaWithCapacityAndMemory(uint(len(memory)), raw_data(memory)),
		{960, 640},
		{handler = clay_error},
	)
	defer clay.SetCurrentContext(nil)
	clay.SetMeasureTextFunction(measure_text, font)

	running, dirty := true, true
	shown := false
	last_scale: f32 = 0
	g: Geometry
	for running {
		dirty = storage_poll(&b) || dirty
		dirty = file_open_poll(&b) || dirty
		dirty = header_update(&b.header, sdl.GetTicks()) || dirty
		if dirty {
			width, height: c.int
			scale := sdl.GetWindowDisplayScale(window)
			if scale <= 0 {scale = 1}
			if scale != last_scale {
				density := sdl.GetWindowPixelDensity(window)
				sdl_check(density > 0)
				sdl_check(
					sdl.SetWindowMinimumSize(
						window,
						i32(math.ceil(MIN_WINDOW_WIDTH * scale / density)),
						i32(math.ceil(MIN_WINDOW_HEIGHT * scale / density)),
					),
				)
				sdl_check(ttf.SetFontSize(font, f32(u16(16 * scale))))
				clay.ResetMeasureTextCache()
				painter_load_icons(&painter, scale)
				last_scale = scale
			}
			if !shown {
				sdl_check(sdl.ShowWindow(window))
				if !sdl.SyncWindow(
					window,
				) {fmt.eprintfln("window sizing is still pending: %s", string(sdl.GetError()))}
				sdl.PumpEvents()
				_ = theme_apply(&painter, sdl.GetSystemTheme())
				if !sdl.SetRenderVSync(renderer, 1) {
					fmt.eprintfln("cannot enable vsync: %s", string(sdl.GetError()))
				}
				shown = true
				continue // Query the configured size and scale before the first frame.
			}
			sdl_check(sdl.GetRenderOutputSize(renderer, &width, &height))
			g = geometry(width, height, scale)
			b.first = clamp(b.first, 0, max(0, len(b.visible) - g.rows))
			b.places.first = clamp(
				b.places.first,
				0,
				max(0, len(b.places.entries) - places_geometry(g).rows),
			)
			commands := layout(&b, g, &painter)
			if hover_update(&b, g) {commands = layout(&b, g, &painter)}
			cursor_update(hand, &b, g)
			paint(&painter, commands, width, height)
			free_all(context.temp_allocator)
			dirty = false
			if smoke {
				vsync: c.int
				sdl_check(sdl.GetRenderVSync(renderer, &vsync))
				// SDL's software renderer can forward vsync to the window surface.
				if vsync == 0 && string(sdl.GetRendererName(renderer)) == "software" {
					surface_vsync: c.int
					if sdl.GetWindowSurfaceVSync(window, &surface_vsync) {vsync = surface_vsync}
				}
				fmt.printfln(
					"rendered %dx%d at scale %.2f with %s; vsync=%d; %d visible text slots",
					width,
					height,
					scale,
					string(sdl.GetRendererName(renderer)),
					vsync,
					len(painter.slots),
				)
				break
			}
		}
		event: sdl.Event
		timeout := ui_wait_timeout(&b, sdl.GetTicks())
		sdl.ClearError()
		if !sdl.WaitEventTimeout(&event, timeout) {
			if string(sdl.GetError()) != "" {fmt.eprintln(string(sdl.GetError())); return 1}
			continue
		}
		for {
			sdl_check(sdl.ConvertEventToRenderCoordinates(renderer, &event))
			if event.type == .SYSTEM_THEME_CHANGED {
				dirty = theme_apply(&painter, sdl.GetSystemTheme()) || dirty
			} else {
				dirty = handle_event(&b, &event, g, &running) || dirty
			}
			cursor_update(hand, &b, g)
			if !sdl.PollEvent(&event) {break}
		}
	}
	return 0
}

main :: proc() {os.exit(run())}
