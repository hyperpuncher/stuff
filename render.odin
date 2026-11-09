package main

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import clay "vendor/clay"
import sdl "vendor:sdl3"
import image "vendor:sdl3/image"
import ttf "vendor:sdl3/ttf"

Icon :: enum {
	File,
	Folder,
	Symlink,
	Document,
	Code,
	Image,
	Audio,
	Video,
	Archive,
	Spreadsheet,
	Font,
	Terminal,
	Database,
	PlaceHome,
	PlaceDesktop,
	PlaceDownloads,
	PlacePictures,
	PlaceMusic,
	PlaceVideos,
	PlaceFilesystem,
	CopyPath,
	Check,
	ChevronRight,
	SortAscending,
	SortDescending,
}

ICON_SOURCES :: [Icon]string {
	.File            = #load("vendor/lucide/file.svg"),
	.Folder          = #load("vendor/lucide/folder.svg"),
	.Symlink         = #load("vendor/lucide/file-symlink.svg"),
	.Document        = #load("vendor/lucide/file-text.svg"),
	.Code            = #load("vendor/lucide/file-code.svg"),
	.Image           = #load("vendor/lucide/file-image.svg"),
	.Audio           = #load("vendor/lucide/file-music.svg"),
	.Video           = #load("vendor/lucide/file-video-camera.svg"),
	.Archive         = #load("vendor/lucide/file-archive.svg"),
	.Spreadsheet     = #load("vendor/lucide/file-spreadsheet.svg"),
	.Font            = #load("vendor/lucide/file-type.svg"),
	.Terminal        = #load("vendor/lucide/file-terminal.svg"),
	.Database        = #load("vendor/lucide/file-database.svg"),
	.PlaceHome       = #load("vendor/lucide/house.svg"),
	.PlaceDesktop    = #load("vendor/lucide/monitor.svg"),
	.PlaceDownloads  = #load("vendor/lucide/folder-down.svg"),
	.PlacePictures   = #load("vendor/lucide/image.svg"),
	.PlaceMusic      = #load("vendor/lucide/audio-lines.svg"),
	.PlaceVideos     = #load("vendor/lucide/video.svg"),
	.PlaceFilesystem = #load("vendor/lucide/hard-drive.svg"),
	.CopyPath        = #load("vendor/lucide/copy.svg"),
	.Check           = #load("vendor/lucide/check.svg"),
	.ChevronRight    = #load("vendor/lucide/chevron-right.svg"),
	.SortAscending   = #load("vendor/lucide/chevron-up.svg"),
	.SortDescending  = #load("vendor/lucide/chevron-down.svg"),
}

entry_icon :: proc(entry: os.File_Info) -> Icon {
	if entry.type == .Directory {return .Folder}
	if entry.type == .Symlink {return .Symlink}
	if entry.type != .Regular {return .File}
	name := strings.to_lower(entry.name, context.temp_allocator)
	switch name {
	case "justfile",
	     "makefile",
	     "gnumakefile",
	     "dockerfile",
	     "containerfile",
	     ".gitignore",
	     ".gitattributes":
		return .Code
	case "readme", "license", "copying", "changelog":
		return .Document
	case ".bashrc", ".zshrc", ".profile":
		return .Terminal
	}
	ext := os.ext(name)
	switch ext {
	case ".txt",
	     ".md",
	     ".markdown",
	     ".rst",
	     ".adoc",
	     ".log",
	     ".pdf",
	     ".doc",
	     ".docx",
	     ".odt",
	     ".rtf",
	     ".tex":
		return .Document
	case ".odin",
	     ".c",
	     ".h",
	     ".cc",
	     ".cpp",
	     ".hpp",
	     ".rs",
	     ".go",
	     ".py",
	     ".js",
	     ".jsx",
	     ".ts",
	     ".tsx",
	     ".html",
	     ".css",
	     ".scss",
	     ".java",
	     ".kt",
	     ".lua",
	     ".rb",
	     ".php",
	     ".swift",
	     ".zig",
	     ".json",
	     ".jsonc",
	     ".toml",
	     ".yaml",
	     ".yml",
	     ".xml",
	     ".ini",
	     ".conf",
	     ".nix",
	     ".desktop",
	     ".service":
		return .Code
	case ".png",
	     ".jpg",
	     ".jpeg",
	     ".gif",
	     ".webp",
	     ".avif",
	     ".heic",
	     ".bmp",
	     ".tif",
	     ".tiff",
	     ".svg",
	     ".ico",
	     ".jxl":
		return .Image
	case ".mp3", ".flac", ".wav", ".ogg", ".opus", ".m4a", ".aac", ".aiff":
		return .Audio
	case ".mp4", ".mkv", ".webm", ".mov", ".avi", ".m4v", ".mpeg", ".mpg":
		return .Video
	case ".zip",
	     ".tar",
	     ".gz",
	     ".bz2",
	     ".xz",
	     ".zst",
	     ".7z",
	     ".rar",
	     ".tgz",
	     ".txz",
	     ".deb",
	     ".rpm",
	     ".iso":
		return .Archive
	case ".csv", ".tsv", ".xls", ".xlsx", ".ods":
		return .Spreadsheet
	case ".ttf", ".otf", ".woff", ".woff2":
		return .Font
	case ".sh", ".bash", ".zsh", ".fish", ".bat", ".cmd", ".ps1", ".exe", ".appimage":
		return .Terminal
	case ".db", ".sqlite", ".sqlite3":
		return .Database
	}
	return .File
}

Painter :: struct {
	renderer: ^sdl.Renderer,
	engine:   ^ttf.TextEngine,
	font:     ^ttf.Font,
	slots:    [dynamic]^ttf.Text,
	icons:    [Icon]^sdl.Texture,
}

// The returned path is owned. No font data is copied into the executable.
system_monospace_path :: proc() -> string {
	state, output, errors, err := os.process_exec(
		{command = {"fc-match", "--format=%{file}", "monospace"}},
		context.allocator,
	)
	defer delete(errors)
	if err != nil || state.exit_code != 0 || len(output) == 0 {
		fmt.eprintln("cannot find the system monospace font; check fontconfig and fc-match")
		delete(output)
		return ""
	}
	return string(output)
}

sdl_check :: proc(ok: bool) {
	if !ok {panic(string(sdl.GetError()))}
}

painter_load_icons :: proc(p: ^Painter, scale: f32) {
	for source, kind in ICON_SOURCES {
		if p.icons[kind] != nil {sdl.DestroyTexture(p.icons[kind])}
		// Keep upstream geometry unchanged; provide a neutral stroke color.
		svg, _ := strings.replace_all(source, "currentColor", "#ffffff", context.temp_allocator)
		stream := sdl.IOFromConstMem(raw_data(svg), uint(len(svg)))
		assert(stream != nil, string(sdl.GetError()))
		defer sdl.CloseIO(stream)
		surface := image.LoadSizedSVG_IO(stream, i32(18 * scale), i32(18 * scale))
		assert(surface != nil, string(sdl.GetError()))
		defer sdl.DestroySurface(surface)
		texture := sdl.CreateTextureFromSurface(p.renderer, surface)
		assert(texture != nil, string(sdl.GetError()))
		sdl_check(
			sdl.SetTextureColorMod(
				texture,
				u8(theme.muted[0]),
				u8(theme.muted[1]),
				u8(theme.muted[2]),
			),
		)
		p.icons[kind] = texture
	}
}

painter_destroy :: proc(p: ^Painter) {
	for icon in p.icons {
		if icon != nil {sdl.DestroyTexture(icon)}
	}
	for text in p.slots {ttf.DestroyText(text)}
	delete(p.slots)
}

text_width :: proc(font: ^ttf.Font, value: string) -> i32 {
	if value == "" {return 0}
	width, height: c.int
	sdl_check(ttf.GetStringSize(font, raw_data(value), uint(len(value)), &width, &height))
	return width
}

// Returns the input, a static ellipsis, or a temporary string. No ownership transfers.
fit_label :: proc(font: ^ttf.Font, value: string, max_width: f32, middle := false) -> string {
	width := i32(math.floor(max_width))
	if width <= 0 || value == "" {return ""}
	if text_width(font, value) <= width {return value}
	ellipsis :: "…"
	ellipsis_width := text_width(font, ellipsis)
	if width < ellipsis_width {return ""}
	if width == ellipsis_width {return ellipsis}
	if middle {
		boundaries := make([dynamic]int, context.temp_allocator)
		append(&boundaries, 0)
		clusters := utf8.decode_grapheme_iterator_make(value)
		for _, cluster in utf8.decode_grapheme_iterate(&clusters) {
			append(&boundaries, cluster.byte_index + len(cluster.text))
		}
		count := len(boundaries) - 1
		minimum_suffix := 0
		extension := os.ext(value)
		if extension != "" && text_width(font, fmt.tprintf("%s%s", ellipsis, extension)) <= width {
			for boundary, i in boundaries {
				if boundary == len(value) - len(extension) {minimum_suffix = count - i; break}
			}
		}
		// Find how many complete graphemes fit, balanced around the ellipsis.
		// Keep the full extension when it fits, even if that needs a longer suffix.
		low, high := 0, count - 1
		result := ellipsis
		for low <= high {
			kept := low + (high - low) / 2
			suffix := max(kept / 2, min(kept, minimum_suffix))
			prefix := kept - suffix
			candidate := fmt.tprintf(
				"%s%s%s",
				value[:boundaries[prefix]],
				ellipsis,
				value[boundaries[count - suffix]:],
			)
			if text_width(font, candidate) <= width {
				result = candidate
				low = kept + 1
			} else {
				high = kept - 1
			}
		}
		return result
	}
	measured_width: c.int
	measured_length: c.size_t
	sdl_check(
		ttf.MeasureString(
			font,
			raw_data(value),
			uint(len(value)),
			width - ellipsis_width,
			&measured_width,
			&measured_length,
		),
	)
	end := 0
	it := utf8.decode_grapheme_iterator_make(value)
	for _, cluster in utf8.decode_grapheme_iterate(&it) {
		boundary := cluster.byte_index + len(cluster.text)
		if boundary > int(measured_length) {break}
		end = boundary
	}
	if end == 0 {return ellipsis}
	return fmt.tprintf("%s%s", value[:end], ellipsis)
}

measure_text :: proc "c" (
	text: clay.StringSlice,
	config: ^clay.TextElementConfig,
	data: rawptr,
) -> clay.Dimensions {
	w, h: c.int
	if !ttf.GetStringSize(cast(^ttf.Font)data, text.chars, uint(text.length), &w, &h) {
		return {}
	}
	return {f32(w), f32(h)}
}

paint_rounded_rectangle :: proc(
	renderer: ^sdl.Renderer,
	box: clay.BoundingBox,
	data: clay.RectangleRenderData,
) {
	if box.width <= 0 || box.height <= 0 {return}
	limit := min(box.width, box.height) / 2
	r := data.cornerRadius
	radii := [4]f32 {
		clamp(r.topLeft, 0, limit),
		clamp(r.topRight, 0, limit),
		clamp(r.bottomRight, 0, limit),
		clamp(r.bottomLeft, 0, limit),
	}
	centers := [4]sdl.FPoint {
		{box.x + radii[0], box.y + radii[0]},
		{box.x + box.width - radii[1], box.y + radii[1]},
		{box.x + box.width - radii[2], box.y + box.height - radii[2]},
		{box.x + radii[3], box.y + box.height - radii[3]},
	}
	angles := [4]f32{math.PI, 1.5 * math.PI, 0, 0.5 * math.PI}
	color := data.backgroundColor
	tint := sdl.FColor{color[0] / 255, color[1] / 255, color[2] / 255, color[3] / 255}
	vertices: [37]sdl.Vertex
	indices: [108]i32
	vertices[0] = {
		position = {box.x + box.width / 2, box.y + box.height / 2},
		color    = tint,
	}
	for center, corner in centers {
		for step in 0 ..< 9 {
			angle := angles[corner] + f32(step) * (0.5 * math.PI / 8)
			vertices[1 + corner * 9 + step] = {
				position = {
					center.x + math.cos(angle) * radii[corner],
					center.y + math.sin(angle) * radii[corner],
				},
				color    = tint,
			}
		}
	}
	for i in 0 ..< 36 {
		indices[i * 3 + 0] = 0
		indices[i * 3 + 1] = i32(i + 1)
		indices[i * 3 + 2] = i32((i + 1) % 36 + 1)
	}
	sdl_check(
		sdl.RenderGeometry(
			renderer,
			nil,
			raw_data(vertices[:]),
			i32(len(vertices)),
			raw_data(indices[:]),
			i32(len(indices)),
		),
	)
}

paint :: proc(p: ^Painter, commands: clay.ClayArray(clay.RenderCommand), width, height: i32) {
	sdl_check(
		sdl.SetRenderDrawColor(
			p.renderer,
			u8(theme.background[0]),
			u8(theme.background[1]),
			u8(theme.background[2]),
			255,
		),
	)
	sdl_check(sdl.RenderClear(p.renderer))
	used := 0
	clips := make([dynamic]sdl.Rect, context.temp_allocator)
	for i in 0 ..< commands.length {
		cmd := commands.internalArray[i]
		b := cmd.boundingBox
		#partial switch cmd.commandType {
		case .Rectangle:
			data := cmd.renderData.rectangle
			radius := data.cornerRadius
			if radius.topLeft > 0 ||
			   radius.topRight > 0 ||
			   radius.bottomLeft > 0 ||
			   radius.bottomRight > 0 {
				paint_rounded_rectangle(p.renderer, b, data)
				continue
			}
			color := data.backgroundColor
			sdl_check(
				sdl.SetRenderDrawColor(
					p.renderer,
					u8(color[0]),
					u8(color[1]),
					u8(color[2]),
					u8(color[3]),
				),
			)
			r := sdl.FRect{b.x, b.y, b.width, b.height}
			sdl_check(sdl.RenderFillRect(p.renderer, &r))
		case .Image:
			r := sdl.FRect{math.round(b.x), math.round(b.y), b.width, b.height}
			sdl_check(
				sdl.RenderTexture(
					p.renderer,
					cast(^sdl.Texture)cmd.renderData.image.imageData,
					nil,
					&r,
				),
			)
		case .Text:
			data := cmd.renderData.text
			value := string(data.stringContents.chars[:data.stringContents.length])
			if used == len(p.slots) {
				text := ttf.CreateText(p.engine, p.font, raw_data(value), uint(len(value)))
				assert(text != nil, string(sdl.GetError()))
				append(&p.slots, text)
			} else {
				sdl_check(ttf.SetTextString(p.slots[used], raw_data(value), uint(len(value))))
			}
			color := data.textColor
			sdl_check(
				ttf.SetTextColor(
					p.slots[used],
					u8(color[0]),
					u8(color[1]),
					u8(color[2]),
					u8(color[3]),
				),
			)
			sdl_check(ttf.DrawRendererText(p.slots[used], math.round(b.x), math.round(b.y)))
			used += 1
		case .ScissorStart:
			parent := sdl.Rect{0, 0, width, height}
			if len(clips) > 0 {parent = clips[len(clips) - 1]}
			left, top := parent.x, parent.y
			right, bottom := parent.x + parent.w, parent.y + parent.h
			if cmd.renderData.clip.horizontal {
				left = max(left, i32(math.floor(b.x)))
				right = min(right, i32(math.ceil(b.x + b.width)))
			}
			if cmd.renderData.clip.vertical {
				top = max(top, i32(math.floor(b.y)))
				bottom = min(bottom, i32(math.ceil(b.y + b.height)))
			}
			r := sdl.Rect{left, top, max(0, right - left), max(0, bottom - top)}
			append(&clips, r)
			sdl_check(sdl.SetRenderClipRect(p.renderer, &r))
		case .ScissorEnd:
			assert(len(clips) > 0)
			pop(&clips)
			if len(clips) == 0 {
				sdl_check(sdl.SetRenderClipRect(p.renderer, nil))
			} else {
				sdl_check(sdl.SetRenderClipRect(p.renderer, &clips[len(clips) - 1]))
			}
		case:
			panic("unsupported Clay render command")
		}
	}
	assert(len(clips) == 0)
	for used < len(p.slots) {
		ttf.DestroyText(pop(&p.slots))
	}
	sdl_check(sdl.RenderPresent(p.renderer))
}
