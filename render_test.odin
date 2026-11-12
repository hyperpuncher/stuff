package main

import "core:os"
import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

@(test)
size_labels :: proc(t: ^testing.T) {
	testing.expect_value(t, format_size(0), "0 B")
	testing.expect_value(t, format_size(1023), "1023 B")
	testing.expect_value(t, format_size(1024), "1.0 KiB")
	testing.expect_value(t, format_size(1536), "1.5 KiB")
	testing.expect_value(t, format_size(1024 * 1024), "1.0 MiB")
}

@(test)
file_type_icons :: proc(t: ^testing.T) {
	cases := [?]struct {
		name: string,
		icon: Icon,
	} {
		{"README", .Document},
		{"photo.PNG", .Image},
		{"backup.tar.gz", .Archive},
		{"config.JSON", .Code},
		{"Makefile", .Code},
		{".gitignore", .Code},
		{".bashrc", .Terminal},
		{"unknown.data", .File},
		{"", .File},
	}
	for item in cases {
		testing.expect_value(t, entry_icon({name = item.name, type = .Regular}), item.icon)
	}
	testing.expect_value(t, entry_icon({name = "folder.zip", type = .Directory}), Icon.Folder)
	testing.expect_value(t, entry_icon({name = "link.png", type = .Symlink}), Icon.Symlink)
	testing.expect_value(t, entry_icon({name = "pipe.mp3", type = .Named_Pipe}), Icon.File)
}

verify_label_fitting :: proc(t: ^testing.T, font: ^ttf.Font) {
	testing.expect_value(t, fit_label(font, "", 100), "")
	testing.expect_value(t, fit_label(font, "text", 0), "")
	ellipsis_width := text_width(font, "…")
	testing.expect_value(t, fit_label(font, "long filename.txt", f32(ellipsis_width - 1)), "")
	testing.expect_value(t, fit_label(font, "long filename.txt", f32(ellipsis_width)), "…")
	values := [?]string {
		"a long filename that does not fit inside a narrow name column.txt",
		"a\u0301a\u0301a\u0301a\u0301a\u0301a\u0301a\u0301a\u0301.txt",
		"👩‍💻👩‍💻👩‍💻👩‍💻👩‍💻.txt",
	}
	for value in values {
		full_width := text_width(font, value)
		testing.expect_value(t, fit_label(font, value, f32(full_width)), value)
		widths := [?]f32{f32(ellipsis_width), 50.5, 100.25, f32(full_width - 1)}
		for width in widths {
			fitted := fit_label(font, value, width)
			testing.expect(t, f32(text_width(font, fitted)) <= width)
			if fitted == value || fitted == "" {continue}
			testing.expect(t, strings.has_suffix(fitted, "…"))
			prefix := strings.trim_suffix(fitted, "…")
			testing.expect(t, strings.has_prefix(value, prefix))
			boundary := len(prefix) == 0
			it := utf8.decode_grapheme_iterator_make(value)
			for _, cluster in utf8.decode_grapheme_iterate(&it) {
				if cluster.byte_index + len(cluster.text) == len(prefix) {boundary = true}
			}
			testing.expect(t, boundary, "fitting must not split a grapheme")
		}
	}
}

verify_middle_fitting :: proc(t: ^testing.T, font: ^ttf.Font) {
	ellipsis_width := text_width(font, "…")
	testing.expect_value(t, fit_label(font, "", 100, middle = true), "")
	testing.expect_value(
		t,
		fit_label(font, "long filename.txt", f32(ellipsis_width - 1), middle = true),
		"",
	)
	testing.expect_value(
		t,
		fit_label(font, "long filename.txt", f32(ellipsis_width), middle = true),
		"…",
	)
	values := [?]string {
		"Scott Arthur Jones complete collection (2025).pdf",
		"an especially long folder name without an extension",
		".a-very-long-hidden-filename",
		"a\u0301a\u0301a\u0301a\u0301a\u0301a\u0301a\u0301a\u0301.txt",
		"👩‍💻👩‍💻👩‍💻👩‍💻👩‍💻.txt",
	}
	for value in values {
		full_width := text_width(font, value)
		testing.expect_value(t, fit_label(font, value, f32(full_width), middle = true), value)
		widths := [?]f32{f32(ellipsis_width), 50.5, 100.25, f32(full_width - 1)}
		for width in widths {
			fitted := fit_label(font, value, width, middle = true)
			testing.expect(t, f32(text_width(font, fitted)) <= width)
			if fitted == value || fitted == "" {continue}
			index := strings.index(fitted, "…")
			if index < 0 {testing.fail_now(t, "a shortened name must contain an ellipsis")}
			prefix, suffix := fitted[:index], fitted[index + len("…"):]
			testing.expect(
				t,
				strings.has_prefix(value, prefix) && strings.has_suffix(value, suffix),
			)
			prefix_boundary, suffix_boundary := len(prefix) == 0, len(suffix) == len(value)
			it := utf8.decode_grapheme_iterator_make(value)
			for _, cluster in utf8.decode_grapheme_iterate(&it) {
				boundary := cluster.byte_index + len(cluster.text)
				if boundary == len(prefix) {prefix_boundary = true}
				if boundary == len(value) - len(suffix) {suffix_boundary = true}
			}
			testing.expect(
				t,
				prefix_boundary && suffix_boundary,
				"both cuts must preserve complete graphemes",
			)
		}
	}
	// Keep the whole extension even when it needs more than half the width.
	narrow_width := f32(text_width(font, "a….jpeg"))
	testing.expect_value(
		t,
		fit_label(font, "a very long photograph.jpeg", narrow_width, middle = true),
		"a….jpeg",
	)
	width := f32(text_width(font, "Scott Arthur J…on (2025).pdf"))
	a := fit_label(font, "Scott Arthur Jones complete collection (2023).pdf", width, middle = true)
	b := fit_label(font, "Scott Arthur Jones complete collection (2025).pdf", width, middle = true)
	testing.expect(t, strings.has_prefix(a, "Scott") && strings.has_suffix(a, "(2023).pdf"))
	testing.expect(t, strings.has_prefix(b, "Scott") && strings.has_suffix(b, "(2025).pdf"))
	testing.expect(t, a != b, "the ending must distinguish these filenames")
}

verify_rounded_corners :: proc(t: ^testing.T, renderer: ^sdl.Renderer) {
	for corners in ([?]clay.CornerRadius{clay.CornerRadiusAll(2), clay.CornerRadiusAll(8), {topLeft = 5, bottomLeft = 5, topRight = 2, bottomRight = 2}, clay.CornerRadiusAll(15)}) {
		for offset in ([?]f32{0, 0.25, 0.5, 0.75}) {
			sdl_check(sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255))
			sdl_check(sdl.RenderClear(renderer))
			paint_rounded_rectangle(
				renderer,
				{20 + offset, 20 + offset, 40, 30},
				{backgroundColor = {255, 255, 255, 255}, cornerRadius = corners},
			)
			region := sdl.Rect{48, 20, 14, 31}
			surface := sdl.RenderReadPixels(renderer, &region)
			if surface == nil {testing.fail_now(t, string(sdl.GetError()))}
			for start in ([?]i32{0, 19}) {
				smooth := false
				for y in start ..< start + 12 {
					for x in 0 ..< 14 {
						r, green, blue, alpha: u8
						sdl_check(
							sdl.ReadSurfacePixel(surface, i32(x), y, &r, &green, &blue, &alpha),
						)
						if r > 0 && r < 255 {smooth = true}
					}
				}
				testing.expect(
					t,
					smooth,
					"top and bottom rounded corners must have smooth coverage",
				)
			}
			sdl.DestroySurface(surface)
		}
	}
}

@(test)
large_directory_layout :: proc(t: ^testing.T) {
	if !sdl.Init({.VIDEO}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	if !ttf.Init() {testing.fail_now(t, string(sdl.GetError()))}
	defer ttf.Quit()
	window: ^sdl.Window
	renderer: ^sdl.Renderer
	if !sdl.CreateWindowAndRenderer("stuff test", 960, 640, {.HIDDEN}, &window, &renderer) {
		testing.fail_now(t, string(sdl.GetError()))
	}
	defer sdl.DestroyWindow(window)
	defer sdl.DestroyRenderer(renderer)
	verify_rounded_corners(t, renderer)
	path := system_monospace_path()
	defer delete(path)
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	font := ttf.OpenFont(cpath, 14)
	if font == nil {testing.fail_now(t, string(sdl.GetError()))}
	defer ttf.CloseFont(font)
	verify_label_fitting(t, font)
	verify_middle_fitting(t, font)
	engine := ttf.CreateRendererTextEngine(renderer)
	if engine == nil {testing.fail_now(t, string(sdl.GetError()))}
	defer ttf.DestroyRendererTextEngine(engine)
	p := Painter {
		renderer = renderer,
		engine   = engine,
		font     = font,
	}
	defer painter_destroy(&p)
	painter_load_icons(&p, 1)

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
	verify_theme_switch(t, &p)
	verify_header_actions(t, &p)
	verify_context_menu_rendering(t, &p)
	verify_path_editor_rendering(t, &p)
	verify_file_dialog_rendering(t, &p)
	verify_archive_dialog_rendering(t, &p)
	verify_search_rendering(t, &p)
	verify_tabs_layout(t, &p)
	verify_file_progress_layout(t, &p)
	verify_selection_drag_rendering(t, &p)

	b: Browser
	defer browser_destroy(&b)
	places_init(&b.places)
	b.entries = make([]os.File_Info, 100_000)
	resize(&b.visible, len(b.entries))
	for &entry, i in b.entries {
		// Only name is borrowed; fullpath remains empty for normal cleanup.
		entry.name = "sample β file.TXT"
		entry.type = .Regular
		b.visible[i] = i
	}
	g := geometry(960, 640, 1)
	selections := [?]int{0, 50_000, 99_999}
	for selected in selections {
		selection_single(&b, selected)
		browser_reveal(&b, g.rows)
		commands := layout(&b, g, &p)
		testing.expect(t, int(commands.length) <= 7 * g.rows + 32)
		file_selection := false
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType != .Rectangle ||
			   cmd.renderData.rectangle.backgroundColor != theme.selected {continue}
			if cmd.boundingBox.x >= g.sidebar {file_selection = true}
		}
		testing.expect(t, file_selection, "the selected file must have a visible highlight")
		paint(&p, commands, 960, 640)
		testing.expect(t, len(p.slots) <= 4 * g.rows + min(g.rows, len(b.places.entries)) + 11)
	}
	// Reusing text slots after content changes must not retain old labels.
	b.entries[b.visible[b.first]].name = "changed.txt"
	paint(&p, layout(&b, g, &p), 960, 640)
	found := false
	for slot in p.slots {
		if string(cast(cstring)slot.text) == "changed.txt" {found = true}
	}
	testing.expect(t, found, "the changed filename must appear in the rendered text")

	// The autoscroll marker stays at the click point without moving the list.
	x, y := g.sidebar + 100, g.list_top + 100
	testing.expect(t, autoscroll_begin(&b, g, x, y))
	paint(&p, layout(&b, g, &p), 960, 640)
	marker := clay.GetElementData(clay.ID("autoscroll"))
	testing.expect(t, marker.found)
	testing.expect_value(t, marker.boundingBox.x + marker.boundingBox.width / 2, x)
	testing.expect_value(t, marker.boundingBox.y + marker.boundingBox.height / 2, y)
	running := true
	event := sdl.Event {
		button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_MIDDLE},
	}
	_ = handle_event(&b, &event, g, &running)
	paint(&p, layout(&b, g, &p), 960, 640)
	testing.expect(t, !clay.GetElementData(clay.ID("autoscroll")).found)
	verify_autoscroll_icons(t, &p)

	// Names must not overlap the metadata columns, even in a narrow or tall window.
	sizes := [?][2]i32{{MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT}, {960, 4096}, {1920, 1080}}
	for size in sizes {
		sdl_check(sdl.SetWindowSize(window, size[0], size[1]))
		g = geometry(size[0], size[1], 1)
		browser_reveal(&b, g.rows)
		commands := layout(&b, g, &p)
		testing.expect(t, int(commands.length) <= 7 * g.rows + 32)
		has_file_name, has_type := false, false
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.commandType != .Text {continue}
			box := cmd.boundingBox
			if box.y < g.list_top || box.y >= g.height - g.footer {continue}
			if box.x < g.sidebar {testing.expect(t, box.x + box.width <= g.sidebar); continue}
			column, ok := column_at(g, box.x)
			testing.expect(t, ok, "row text must start inside a column")
			if !ok {continue}
			right := g.sidebar + g.padding
			for width, current in g.columns {
				right += width
				if current == column {break}
				right += g.gap
			}
			testing.expect(t, box.x + box.width <= right + 0.01)
			text := cmd.renderData.text.stringContents
			if column == .Name {has_file_name = has_file_name || text.length > 0}
			if column == .Type {has_type = has_type || string(text.chars[:text.length]) == "txt"}
		}
		testing.expect(t, has_file_name, "file names must remain visible in a narrow window")
		testing.expect(t, has_type, "file types must appear in their own column")
		paint(&p, commands, size[0], size[1])
		testing.expect(t, len(p.slots) <= 4 * g.rows + min(g.rows, len(b.places.entries)) + 11)
	}
	verify_disk_usage_layout(t, &p)
	// Extra rows must not change the viewport or move the footer.
	viewports := [?]struct {
		width, height: i32,
		scale:         f32,
	} {
		{960, 640, 1},
		{600, 480, 1},
		{900, 720, 1.5},
		{1200, 800, 1.25},
		{1892, 1080, 1.5},
		{2 * MIN_WINDOW_WIDTH, 480, 2},
		{MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, 1},
	}
	for viewport in viewports {
		g = geometry(viewport.width, viewport.height, viewport.scale)
		positions := [?]int{0, 50_000, len(b.visible) - g.rows}
		for first, step in positions {
			b.first = first
			b.scroll_x = step == 1 ? table_scroll_max(g) / g.scale : 0
			places_g := places_geometry(g)
			b.places.first = min(first, max(0, len(b.places.entries) - places_g.rows))
			_ = layout(&b, g, &p)
			heading := clay.GetElementData(clay.ID("column", u32(Column.Name))).boundingBox
			row := clay.GetElementData(clay.ID("row", u32(b.visible[b.first]))).boundingBox
			testing.expect(t, heading.width >= 200 * g.scale)
			testing.expect_value(t, heading.x, g.sidebar + g.padding - table_scroll_offset(&b, g))
			testing.expect_value(t, row.x + g.padding, heading.x)
			testing.expect_value(t, row.width, g.table_width)
			bar := clay.GetElementData(clay.ID("table-scrollbar"))
			testing.expect_value(t, bar.found, table_scroll_max(g) > 0)
			if bar.found {
				testing.expect(t, bar.boundingBox.x >= g.sidebar)
				testing.expect(t, bar.boundingBox.y >= list_bottom(g))
				testing.expect(
					t,
					bar.boundingBox.y + bar.boundingBox.height <= g.height - g.footer,
				)
			}
			footer := clay.GetElementData(clay.ID("footer"))
			list := clay.GetElementData(clay.ID("files-viewport"))
			places := clay.GetElementData(clay.ID("places-viewport"))
			testing.expect(t, footer.found && list.found && places.found)
			testing.expect_value(t, footer.boundingBox.y, g.height - g.footer)
			testing.expect_value(t, footer.boundingBox.height, g.footer)
			testing.expect_value(t, list.boundingBox.y, g.list_top)
			testing.expect_value(t, list.boundingBox.height, list_bottom(g) - g.list_top)
			testing.expect_value(t, places.boundingBox.y, places_g.list_top)
			testing.expect_value(
				t,
				places.boundingBox.height,
				list_bottom(places_g) - places_g.list_top,
			)
		}
	}
	b.scroll_x = 200
	_ = layout(&b, geometry(1280, 640, 1), &p)
	testing.expect_value(t, b.scroll_x, f32(0))
}
