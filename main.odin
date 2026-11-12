package main

import "base:runtime"
import "core:c"
import "core:flags"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

handle_event :: proc(b: ^Browser, event: ^sdl.Event, g: Geometry, running: ^bool) -> bool {
	autoscroll_stopped := false
	if b.autoscroll.active || b.autoscroll.folder > 0 {
		#partial switch event.type {
		case .MOUSE_MOTION:
			autoscroll_motion(b, g, event.motion.x, event.motion.y)
			return false
		case .MOUSE_BUTTON_UP:
			if event.button.button == sdl.BUTTON_MIDDLE {
				click := b.autoscroll
				b.autoscroll = {}
				if click.folder > 0 && sdl.GetTicks() - click.pressed < 250 {
					if err := tab_open(b, b.entries[click.folder - 1].fullpath, activate = false);
					   err != nil {
						browser_message(b, fmt.tprintf("cannot read folder: %v", err))
					}
				}
				return true
			}
			return false
		case .KEY_DOWN,
		     .MOUSE_BUTTON_DOWN,
		     .MOUSE_WHEEL,
		     .WINDOW_MOUSE_LEAVE,
		     .WINDOW_FOCUS_LOST,
		     .WINDOW_HIDDEN,
		     .WINDOW_MINIMIZED,
		     .WINDOW_PIXEL_SIZE_CHANGED,
		     .WINDOW_DISPLAY_SCALE_CHANGED,
		     .DROP_BEGIN:
			b.autoscroll = {}
			autoscroll_stopped = true
			// A stop click must not select or open the row underneath it.
			if event.type == .MOUSE_BUTTON_DOWN ||
			   event.type == .KEY_DOWN && event.key.key == sdl.K_ESCAPE {return true}
		}
	}
	selection_cancelled := b.selection_drag.active
	if selection_drag_input(b, event, g) {return true}
	selection_cancelled = selection_cancelled && !b.selection_drag.active
	if file_drop_input(b, event, g) {return true}
	pointer_changed := false
	#partial switch event.type {
	case .MOUSE_MOTION:
		if file_drag_motion(b, g, event.motion.x, event.motion.y) {return true}
		menu_changed := b.menu.active && b.menu.selected >= 0
		if b.menu.active {b.menu.selected = -1}
		changed := pointer_move(b, g, event.motion.x, event.motion.y)
		if b.header.edit.dragging {path_edit_click(&b.header.edit, g, event.motion.x, true); return true}
		return scrollbar_motion(b, g, event.motion.x, event.motion.y) || changed || menu_changed
	case .WINDOW_MOUSE_LEAVE, .WINDOW_FOCUS_LOST:
		if event.type == .WINDOW_FOCUS_LOST {file_drag_cancel_press(b)}
		cancelled := event.type == .WINDOW_FOCUS_LOST && (b.drag.active || b.menu.active)
		if cancelled {b.drag = {}; b.menu.active = false}
		if event.type == .WINDOW_FOCUS_LOST {b.header.edit.dragging = false}
		b.pointer.active = false
		return hover_update(b, g) || cancelled || autoscroll_stopped || selection_cancelled
	case .KEY_DOWN:
		file_drag_cancel_press(b)
		pointer_changed = b.drag.active
		b.drag = {}
		b.pointer.active = false
		pointer_changed = hover_update(b, g) || pointer_changed
	case .MOUSE_BUTTON_DOWN:
		pointer_changed = pointer_move(b, g, event.button.x, event.button.y)
	case .MOUSE_WHEEL:
		pointer_changed = pointer_move(b, g, event.wheel.mouse_x, event.wheel.mouse_y)
	}
	changed, err := handle_input(b, event, g, running)
	if err != nil {browser_message(b, fmt.tprintf("cannot read folder: %v", err))}
	return changed || pointer_changed || autoscroll_stopped || selection_cancelled
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
	if file_progress_input(b, event, g) {return true, nil}
	if handled, tab_err := tabs_input(b, event, g, running); handled {return true, tab_err}
	if handled, edit_err := path_edit_input(b, event, g); handled {return true, edit_err}
	if menu_input(b, event, g) {return true, nil}
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
		ctrl := event.key.mod & sdl.KMOD_CTRL != {}
		shift := event.key.mod & sdl.KMOD_SHIFT != {}
		if ctrl && event.key.key == sdl.K_Z {
			if event.key.repeat {return false, nil}
			file_history_start(b, shift)
			return true, nil
		}
		if !b.places.focused {
			key := event.key.key
			copy := ctrl && (key == sdl.K_C || key == sdl.K_INSERT && !shift)
			paste := ctrl && key == sdl.K_V || shift && !ctrl && key == sdl.K_INSERT
			all := ctrl && key == sdl.K_A
			trash := key == sdl.K_DELETE
			if copy || paste || all || trash {
				if event.key.repeat {return false, nil}
				if copy {file_clipboard_copy(b)}
				if paste {file_operation_start(b, false)}
				if all {selection_all(b)}
				if trash {file_operation_start(b, true)}
				return true, nil
			}
			if key == sdl.K_ESCAPE {selection_clear(b); return true, nil}
		}
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
			if !b.places.focused {
				if shift {selection_extend(b, b.selected, ctrl)} else if ctrl {b.anchor = b.selected} else {selection_single(b, b.selected)}
			}
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
				b.places.focused = false
				return true, place_open(b, b.places.selected)
			}
			if !archive_extract_selection(b) {err = browser_enter(b)}
		case sdl.K_BACKSPACE:
			err = browser_parent(b)
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
	case .MOUSE_BUTTON_UP:
		if event.button.button == sdl.BUTTON_LEFT && file_drag_release(b) {return true, nil}
		if event.button.button == sdl.BUTTON_LEFT && b.drag.active {b.drag = {}; return true, nil}
		return false, nil
	case .MOUSE_WHEEL:
		changed = b.drag.active
		b.drag = {}
		dx, dy := event.wheel.x, event.wheel.y
		if event.wheel.direction == .FLIPPED {dx, dy = -dx, -dy}
		x, y := event.wheel.mouse_x, event.wheel.mouse_y
		if x < 0 || x >= g.width || y < g.header || y >= g.height - g.footer {return changed, nil}
		if x < g.sidebar {
			b.places.first = clamp(
				b.places.first - int(dy * 3),
				0,
				max(0, len(b.places.entries) - places_geometry(g).rows),
			)
			return true, nil
		}
		if sdl.GetModState() & sdl.KMOD_SHIFT != {} {
			if dx == 0 {dx = -dy}
			dy = 0
		}
		if dx != 0 {changed = table_scroll_by(b, g, dx * 3 * g.row) || changed}
		if dy != 0 {
			b.first = clamp(b.first - int(dy * 3), 0, max(0, len(b.visible) - g.rows))
			changed = true
		}
		return changed, nil
	case .MOUSE_BUTTON_DOWN:
		switch event.button.button {
		case sdl.BUTTON_X1:
			return true, browser_history(b, true)
		case sdl.BUTTON_X2:
			return true, browser_history(b, false)
		case sdl.BUTTON_MIDDLE:
			return autoscroll_begin(b, g, event.button.x, event.button.y), nil
		case sdl.BUTTON_RIGHT:
			return menu_open_places(b, g, event.button.x, event.button.y) ||
				menu_open(b, g, event.button.x, event.button.y),
				nil
		case sdl.BUTTON_LEFT:
		case:
			return false, nil
		}
		x, y := event.button.x, event.button.y
		if x < 0 || x >= g.width {return false, nil}
		if y >= 0 && y < g.header {return header_click(b, x, y)}
		if table_scrollbar_hit(b, g, x, y) {
			table_scrollbar_press(b, g, x, y)
			return true, nil
		}
		if places, hit := scrollbar_hit(b, g, x, y); hit {
			scrollbar_press(b, g, places, y)
			return true, nil
		}
		if x < g.sidebar {
			index := row_at(places_geometry(g), y, b.places.first, len(b.places.entries))
			if index < 0 || b.places.entries[index].section {return false, nil}
			unmount := place_unmount_at(b.places.entries[index], g, x)
			// opening a place hands the keyboard to its files; unmounting stays in the sidebar.
			b.places.focused = unmount
			b.places.selected = index
			return true, place_open(b, index, unmount)
		}
		if y >= g.header && y < g.header + g.row {
			if column, ok := column_at(g, x, table_scroll_offset(b, g)); ok {
				b.places.focused = false
				browser_set_sort(b, column)
				return true, nil
			}
			return false, nil
		}
		index := row_at(g, y, b.first, len(b.visible))
		if index < 0 {return selection_drag_begin(b, g, x, y), nil}
		b.places.focused = false
		mods := sdl.GetModState()
		file_drag_press(b, index, event, mods)
		if event.button.clicks == 2 &&
		   mods & (sdl.KMOD_CTRL | sdl.KMOD_SHIFT) == {} {err = browser_enter(b)}
		return true, err
	case:
		return false, nil
	}
}

ui_wait_timeout :: proc(b: ^Browser, now: u64) -> i32 {
	timeout := i32(-1)
	if len(b.opens) > 0 {timeout = 100}
	if b.autoscroll.active && (b.autoscroll.rate_x != 0 || b.autoscroll.rate_y != 0) {timeout = 16}
	for deadline in ([2]u64{b.header.copied_until, b.status_until}) {
		if deadline == 0 {continue}
		remaining := deadline > now ? i32(deadline - now) : 0
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
	Options :: struct {
		path:     string `args:"pos=0" usage:"folder to browse"`,
		smoke:    bool `usage:"draw one frame and exit"`,
		service:  bool `args:"name=dbus-service,hidden"`,
		selected: [dynamic]string `args:"name=select,manifold" usage:"reveal files from one folder; must be the last option"`,
	}
	using options := Options {
		path = ".",
	}
	flags.parse_or_exit(&options, os.args, .Unix)
	defer delete(selected)
	if service && path == "." {
		home, home_err := os.user_home_dir(context.temp_allocator)
		path = home
		if home_err != nil {path = "/"}
	}
	_ = sdl.SetAppMetadata("stuff", nil, "stuff")
	b: Browser
	defer {
		browser_destroy(&b)
		sdl.Quit()
	}
	b.sorts_path = sort_state_path(context.allocator)
	defer delete(b.sorts_path)
	sort_state_load(&b)
	if len(selected) > 0 {
		groups, err := file_manager_groups(selected[:], true)
		defer file_manager_groups_destroy(groups)
		if err != nil ||
		   len(groups) !=
			   1 {fmt.eprintln("--select requires items from one readable folder"); return 1}
		if err = browser_load(&b, groups[0].folder);
		   err == nil {err = file_manager_select(&b, groups[0].paths[:])}
		if err != nil {fmt.eprintfln("cannot select requested items: %v", err); return 1}
	} else if err := browser_load(&b, path); err != nil {
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
	if !smoke {b.size_service = size_start()}
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
	text_cursor := sdl.CreateSystemCursor(.TEXT)
	defer if text_cursor != nil {sdl.DestroyCursor(text_cursor)}
	font_c := strings.clone_to_cstring(font_path)
	defer delete(font_c)
	font_points := desktop_font_points()
	font := ttf.OpenFont(font_c, font_points)
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
	b.file_drag = file_drag_init(window)
	defer {file_drag_destroy(b.file_drag); b.file_drag = nil}
	manager: ^File_Manager
	if !smoke &&
	   dbus_threads_init_default() !=
		   0 {manager = file_manager_start(dbus_bus_get_private(0, nil))}
	defer file_manager_destroy(manager)
	if service &&
	   manager ==
		   nil {fmt.eprintln("cannot own org.freedesktop.FileManager1; another provider may be running"); return 1}

	running, dirty := true, true
	shown := false
	last_scale: f32 = 0
	g: Geometry
	password_input := false
	for running {
		dirty = file_manager_poll(manager, &b, window) || dirty
		dirty = file_drag_poll(&b) || dirty
		dirty = storage_poll(&b) || dirty
		dirty = size_poll(&b) || dirty
		dirty = autoscroll_update(&b, g, sdl.GetTicks()) || dirty
		dirty = file_open_poll(&b) || dirty
		dirty = header_update(&b.header, sdl.GetTicks()) || dirty
		dirty = browser_message_update(&b, sdl.GetTicks()) || dirty
		dirty = archive_prompt_update(&b) || dirty
		path_edit_sync_input(&b.header.edit, window, &password_input)
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
				sdl_check(ttf.SetFontSizeDPI(font, font_points * scale, 96, 96))
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
			g = geometry(
				width,
				height,
				scale,
				font_points * (96.0 / 72.0),
				f32(ttf.GetFontHeight(font)) / scale,
				tab_count(&b),
			)
			g.transfers = file_transfers_height(&b, g)
			commands := layout(&b, g, &painter)
			if hover_update(&b, g) {commands = layout(&b, g, &painter)}
			cursor_update(hand, &b, g, text_cursor)
			if b.header.edit.active {path_edit_ime_area(&b.header.edit, g, window)}
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
					"rendered %dx%d at scale %.2f with %s; vsync=%d; %d visible text slots; font=%.2fpt",
					width,
					height,
					scale,
					string(sdl.GetRendererName(renderer)),
					vsync,
					len(painter.slots),
					font_points,
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
			path_edit_sync_input(&b.header.edit, window, &password_input)
			cursor_update(hand, &b, g, text_cursor)
			if !sdl.PollEvent(&event) {break}
		}
	}
	return 0
}

main :: proc() {os.exit(run())}
