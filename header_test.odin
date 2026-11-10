package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import clay "vendor/clay"
import sdl "vendor:sdl3"

click_header_element :: proc(t: ^testing.T, b: ^Browser, g: Geometry, id: clay.ElementId) {
	element := clay.GetElementData(id)
	if !element.found {testing.fail_now(t, "header element is missing")}
	box := element.boundingBox
	event := sdl.Event {
		button = {
			type = .MOUSE_BUTTON_DOWN,
			button = sdl.BUTTON_LEFT,
			x = box.x + box.width / 2,
			y = box.y + box.height / 2,
		},
	}

	running := true
	testing.expect(t, handle_event(b, &event, g, &running))
	testing.expect(t, b.status_error == "")
}

verify_header_actions :: proc(t: ^testing.T, p: ^Painter) {
	root, err := os.make_directory_temp("/tmp", "stuff-header-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create header fixture")}
	defer delete(root)
	defer os.remove_all(root)
	parent := fmt.aprintf("%s/parent space", root)
	defer delete(parent)
	child := fmt.aprintf("%s/child 雪", parent)
	defer delete(child)
	testing.expect(t, os.make_directory(parent) == nil)
	testing.expect(t, os.make_directory(child) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, child) == nil)
	g := geometry(960, 640, 1)
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect_value(t, b.header.path, child)
	testing.expect_value(t, b.header.path[:b.header.crumbs[0].end], "/")
	last_initial :=
		clay.GetElementData(clay.ID("crumb", u32(len(b.header.crumbs) - 1))).boundingBox
	copy_box := clay.GetElementData(clay.ID("copy_path")).boundingBox
	event := sdl.Event {
		motion = {
			type = .MOUSE_MOTION,
			x = copy_box.x + copy_box.width / 2,
			y = copy_box.y + copy_box.height / 2,
		},
	}

	running := true
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.hovered, clay.ID("copy_path").id)
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.POINTER)
	event.motion.x += 1
	testing.expect(
		t,
		!handle_event(&b, &event, g, &running),
		"movement inside one button must not trigger more frames",
	)
	event.motion.x = last_initial.x + last_initial.width / 2
	event.motion.y = last_initial.y + last_initial.height / 2
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, pointer_cursor(&b, g), sdl.SystemCursor.POINTER)
	// Copy feedback replaces a previous error.
	browser_message(&b, "cannot read folder: missing")
	click_header_element(t, &b, g, clay.ID("copy_path"))
	clipboard := sdl.GetClipboardText()
	testing.expect_value(t, string(cast(cstring)clipboard), child)
	sdl.free(clipboard)
	testing.expect(t, b.header.copied_until != 0)
	commands := layout(&b, g, p)
	check_visible := false
	for i in 0 ..< commands.length {
		cmd := commands.internalArray[i]
		if cmd.commandType == .Image &&
		   cmd.renderData.image.imageData == p.icons[.Check] {check_visible = true}
	}
	testing.expect(t, check_visible, "a successful copy must display the check icon")
	paint(p, commands, 960, 640)
	deadline := b.header.copied_until
	testing.expect(t, deadline != 0)
	testing.expect(t, browser_load(&b, b.path) == nil)
	testing.expect_value(t, b.header.copied_until, deadline)
	testing.expect_value(t, ui_wait_timeout(&b, deadline - 1), i32(1))
	testing.expect(t, !header_update(&b.header, deadline - 1))
	testing.expect(t, header_update(&b.header, deadline))
	testing.expect_value(t, b.header.copied_until, u64(0))
	testing.expect_value(t, ui_wait_timeout(&b, deadline), i32(-1))
	testing.expect(
		t,
		!header_update(&b.header, deadline + 1),
		"expiry should request only one redraw",
	)
	commands = layout(&b, g, p)
	copy_visible := false
	for i in 0 ..< commands.length {
		cmd := commands.internalArray[i]
		if cmd.commandType == .Image &&
		   cmd.renderData.image.imageData == p.icons[.CopyPath] {copy_visible = true}
	}
	testing.expect(t, copy_visible, "expiry must restore the copy icon")
	paint(p, commands, 960, 640)
	click_header_element(t, &b, g, clay.ID("copy_path"))
	parent_index := -1
	for crumb, i in b.header.crumbs {if crumb.end == len(parent) {parent_index = i}}
	if parent_index < 0 {testing.fail_now(t, "the parent breadcrumb is missing")}
	click_header_element(t, &b, g, clay.ID("crumb", u32(parent_index)))
	testing.expect_value(t, b.path, parent)
	testing.expect_value(t, len(b.back), 1)
	testing.expect_value(t, b.header.copied_until, u64(0))
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect_value(t, b.header.copied_until, u64(0))
	testing.expect(t, browser_history(&b, true) == nil)
	testing.expect_value(t, b.path, child)
	// Copying after navigation but before layout must keep the check feedback.
	header_copy(&b)
	deadline = b.header.copied_until
	paint(p, layout(&b, g, p), 960, 640)
	testing.expect(t, deadline != 0)
	testing.expect_value(t, b.header.copied_until, deadline)

	deep := strings.clone(child)
	defer delete(deep)
	for i in 0 ..< 12 {
		next := fmt.aprintf("%s/long-ancestor-%02d", deep, i)
		testing.expect(t, os.make_directory(next) == nil)
		delete(deep)
		deep = next
	}
	testing.expect(t, browser_load(&b, deep) == nil)
	g = geometry(MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT, 1)
	paint(p, layout(&b, g, p), MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT)
	view := clay.GetElementData(clay.ID("breadcrumbs")).boundingBox
	first := clay.GetElementData(clay.ID("crumb", 0)).boundingBox
	last := clay.GetElementData(clay.ID("crumb", u32(len(b.header.crumbs) - 1))).boundingBox
	testing.expect(t, first.x < view.x)
	testing.expect(
		t,
		last.x >= view.x && last.x + last.width <= view.x + view.width + 0.01,
		"the current folder must remain visible in a long path",
	)
	handled, click_err := header_click(&b, first.x + first.width / 2, first.y + first.height / 2)
	testing.expect(t, !handled && click_err == nil, "clipped ancestors must not receive clicks")
	testing.expect_value(t, b.path, deep)
	click_header_element(t, &b, g, clay.ID("copy_path"))
	clipboard = sdl.GetClipboardText()
	testing.expect_value(t, string(cast(cstring)clipboard), deep)
	sdl.free(clipboard)
}

verify_column_hover :: proc(t: ^testing.T, p: ^Painter) {
	b: Browser
	defer browser_destroy(&b)
	g := geometry(960, 640, 1)
	names := [Column]string {
		.Name     = "name",
		.Size     = "size",
		.Modified = "modified",
	}
	for name, column in names {
		b.hovered = clay.ID("column", u32(column)).id
		commands := layout(&b, g, p)
		found := false
		for i in 0 ..< commands.length {
			cmd := commands.internalArray[i]
			if cmd.boundingBox.y < g.header || cmd.boundingBox.y >= g.header + g.row {continue}
			if cmd.commandType == .Rectangle {
				testing.expect(
					t,
					cmd.renderData.rectangle.backgroundColor != theme.hover,
					"column hover must not draw a full-width background",
				)
			}
			if cmd.commandType != .Text {continue}
			data := cmd.renderData.text
			value := string(data.stringContents.chars[:data.stringContents.length])
			if value == name {
				found = true
				testing.expect_value(t, data.textColor, theme.text)
			}
		}
		testing.expect(t, found, "the hovered column label must remain visible")
		paint(p, commands, 960, 640)
	}
}
