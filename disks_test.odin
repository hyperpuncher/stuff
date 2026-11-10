package main

import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:testing"
import "core:time"
import clay "vendor/clay"
import sdl "vendor:sdl3"

@(test)
mount_table_paths_and_device_selection :: proc(t: ^testing.T) {
	fixture := `41 1 8:17 /sub /m rw shared:4 unknown:value - ext4 /dev/sdb1 rw
42 1 8:17 / /run/media/My\040Disk rw - ext4 /dev/sdb1 rw
43 1 8:17 /sub /bind rw - ext4 /dev/sdb1 rw
44 1 0:31 /@ / rw shared:1 - btrfs /dev/mapper/system rw
45 1 8:18 / /mnt/a\134b\011c rw - ext4 /dev/sdb2 rw
bad line
46 1 bad / /invalid rw - ext4 none rw
`
	mounts := mounts_parse(fixture)
	defer mounts_destroy(mounts)
	testing.expect_value(t, len(mounts), 5)
	if len(mounts) != 5 {return}
	testing.expect_value(t, mount_path(mounts[:], linux.makedev(8, 17)), "/run/media/My Disk")
	testing.expect_value(t, mount_path(mounts[:], linux.makedev(0, 31)), "/")
	testing.expect_value(t, mount_path(mounts[:], linux.makedev(8, 18)), "/mnt/a\\b\tc")
	testing.expect_value(t, mount_path(mounts[:], linux.makedev(8, 99)), "")
	label := escaped_decode(`Work\x20Disk\x20\xd0\x94`, true)
	defer delete(label)
	testing.expect_value(t, label, "Work Disk Д")
}

@(test)
disk_sections_usage_and_keyboard_navigation :: proc(t: ^testing.T) {
	b: Browser
	defer browser_destroy(&b)
	places_add(&b.places, {label = "root", path = "/"})
	disks := [?]Disk {
		{
			device = "/dev/fixture-a",
			label = "work",
			path = "/media/work",
			space = {available = 25, total = 100, valid = true},
		},
		{device = "/dev/fixture-b", label = "backup"},
	}
	places_disks(&b.places, disks[:])
	testing.expect_value(t, len(b.places.entries), 4)
	testing.expect(t, b.places.entries[1].section)
	testing.expect_value(t, disk_used_fraction(b.places.entries[2].space), f32(0.75))
	testing.expect_value(
		t,
		disk_used_fraction({available = 100, total = 100, valid = true}),
		f32(0),
	)
	testing.expect_value(t, disk_used_fraction({total = 100, valid = true}), f32(1))
	testing.expect_value(t, disk_used_fraction({}), f32(0))
	testing.expect_value(t, places_active(&b.places, "/elsewhere"), 0)
	testing.expect_value(t, places_active(&b.places, "/media/work/file"), 2)
	b.places.focused = true
	g := geometry(960, 640, 1)
	running := true
	event := sdl.Event {
		key = {type = .KEY_DOWN, key = sdl.K_J},
	}
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.places.selected, 2)
	event.key.key = sdl.K_K
	testing.expect(t, handle_event(&b, &event, g, &running))
	testing.expect_value(t, b.places.selected, 0)
	b.pointer = {
		x      = 20,
		y      = places_geometry(g).list_top + g.row + 1,
		active = true,
	}
	testing.expect_value(t, hover_target(&b, g), u32(0))
	// Device identity, rather than list position, preserves the selection.
	b.places.selected = 3
	reversed := [?]Disk{disks[1], disks[0]}
	places_disks(&b.places, reversed[:])
	testing.expect_value(t, b.places.selected, 2)
	testing.expect(t, !place_can_unmount(b.places.entries[2]))
	testing.expect(t, place_can_unmount(b.places.entries[3]))
	testing.expect(t, !places_disks(&b.places, reversed[:]))
	reversed[1].space.available = 50
	testing.expect(t, places_disks(&b.places, reversed[:]))
	testing.expect_value(t, b.places.entries[3].space.available, i64(50))
	testing.expect_value(t, b.places.selected, 2)
	places_disks(&b.places, nil)
	testing.expect_value(t, len(b.places.entries), 1)
	testing.expect_value(t, b.places.selected, 0)
}

@(test)
storage_results_do_not_replace_later_navigation :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("/tmp", "stuff-storage-results-", context.allocator)
	if err != nil {testing.fail_now(t, "cannot create storage fixture")}
	defer delete(root)
	defer os.remove_all(root)
	mounted := fmt.aprintf("%s/mounted", root)
	defer delete(mounted)
	elsewhere := fmt.aprintf("%s/elsewhere", root)
	defer delete(elsewhere)
	testing.expect(t, os.make_directory(mounted) == nil)
	testing.expect(t, os.make_directory(elsewhere) == nil)
	b: Browser
	defer browser_destroy(&b)
	testing.expect(t, browser_load(&b, root) == nil)
	space := Space_Info {
		available = 123,
		total     = 456,
		valid     = true,
	}
	testing.expect(t, storage_apply(&b, {kind = .Space, path = root, space = space}))
	op := new(Disk_Operation)
	defer disk_operation_destroy(op)
	op.device, op.origin, op.mountpoint =
		strings.clone("/dev/fixture"), strings.clone(root), strings.clone(mounted)
	b.pending_disk = op
	testing.expect(t, browser_navigate(&b, elsewhere) == nil)
	// Keep the footer value while the same filesystem is refreshed.
	testing.expect_value(t, b.space, space)
	// An old folder's result must not clear the retained footer value.
	testing.expect(t, !storage_apply(&b, {kind = .Space, path = root}))
	testing.expect_value(t, b.space, space)
	testing.expect(t, storage_apply(&b, {kind = .Operation, op = op}))
	testing.expect_value(t, b.path, elsewhere)
	testing.expect(t, b.pending_disk == nil)
	// A failed unmount must retain the current location and show the error.
	op.unmount = true
	op.error = strings.clone("volume is busy")
	b.pending_disk = op
	testing.expect(t, storage_apply(&b, {kind = .Operation, op = op}))
	testing.expect_value(t, b.path, elsewhere)
	testing.expect(t, strings.contains(b.status_error, "volume is busy"))
	// Do not carry the previous filesystem's value into another filesystem.
	testing.expect(t, browser_navigate(&b, "/proc") == nil)
	testing.expect(t, !b.space.valid)
}

verify_disk_usage_layout :: proc(t: ^testing.T, p: ^Painter) {
	previous: sdl.SystemTheme = theme == LIGHT_THEME ? .LIGHT : .DARK
	defer _ = theme_apply(p, previous)
	b: Browser
	defer browser_destroy(&b)
	b.path = strings.clone("/tmp")
	places_add(&b.places, {label = "home", path = "/tmp", icon = .PlaceHome})
	disks := [?]Disk {
		{label = "filesystem", path = "/", space = {available = 25, total = 100, valid = true}},
		{device = "/dev/fixture", label = "unmounted backup"},
	}
	places_disks(&b.places, disks[:])
	b.space = {
		available = 123456789,
		total     = 987654321,
		valid     = true,
	}
	browser_message(
		&b,
		"a long error message that must not overlap the free-space value in the footer",
	)
	systems := [?]sdl.SystemTheme{.DARK, .LIGHT}
	sizes := [?][2]i32{{960, 640}, {MIN_WINDOW_WIDTH, MIN_WINDOW_HEIGHT}}
	samples := [?]struct {
		fraction: f32,
		color:    clay.Color,
	}{{0.25, {}}, {0.9, {}}}
	for system in systems {
		_ = theme_apply(p, system)
		samples[0].color, samples[1].color = theme.muted, theme.inactive_selection
		for size in sizes {
			g := geometry(size[0], size[1], 1)
			commands := layout(&b, g, p)
			track, filled: clay.BoundingBox
			for i in 0 ..< commands.length {
				cmd := commands.internalArray[i]
				box := cmd.boundingBox
				if cmd.commandType == .Text {
					if box.x < g.sidebar && box.y >= g.list_top && box.y < g.height - g.footer {
						testing.expect(t, box.x + box.width <= g.sidebar)
					}
					if box.y >=
					   g.height -
						   g.footer {testing.expect(t, box.x + box.width <= g.width - g.padding + 0.01)}
				}
				if cmd.commandType != .Rectangle ||
				   box.x >= g.sidebar ||
				   box.height != 2 {continue}
				color := cmd.renderData.rectangle.backgroundColor
				if color == theme.muted {filled = box}
				if color == theme.inactive_selection {track = box}
			}
			testing.expect(t, track.width > 0 && filled.width > 0)
			testing.expect(t, track.x + track.width <= g.sidebar - 16 * g.scale)
			testing.expect_value(t, filled.width, track.width * 0.75)
			paint(p, commands, size[0], size[1])
			for sample in samples {
				rect := sdl.Rect{i32(track.x + track.width * sample.fraction), i32(track.y), 1, 1}
				surface := sdl.RenderReadPixels(p.renderer, &rect)
				if surface == nil {testing.fail_now(t, string(sdl.GetError()))}
				r, green, blue, alpha: u8
				sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &r, &green, &blue, &alpha))
				sdl.DestroySurface(surface)
				testing.expect_value(t, r, u8(sample.color[0]))
				testing.expect_value(t, green, u8(sample.color[1]))
				testing.expect_value(t, blue, u8(sample.color[2]))
			}
			// A rounded end must blend into the track, not end in a hard cut.
			corner := sdl.Rect{i32(filled.x + filled.width) - 1, i32(filled.y), 1, 1}
			surface := sdl.RenderReadPixels(p.renderer, &corner)
			if surface == nil {testing.fail_now(t, string(sdl.GetError()))}
			r, green, blue, alpha: u8
			sdl_check(sdl.ReadSurfacePixel(surface, 0, 0, &r, &green, &blue, &alpha))
			sdl.DestroySurface(surface)
			testing.expect(t, r != u8(theme.muted[0]) && r != u8(theme.inactive_selection[0]))
		}
	}
}

@(test)
storage_worker_reads_and_stops :: proc(t: ^testing.T) {
	if !sdl.Init({.EVENTS}) {testing.fail_now(t, string(sdl.GetError()))}
	defer sdl.Quit()
	s := storage_start("/tmp")
	if s == nil {testing.fail_now(t, "cannot start storage worker")}
	defer storage_destroy(s)
	got_space, got_disks := false, false
	deadline := sdl.GetTicks() + 3000
	for sdl.GetTicks() < deadline && (!got_space || !got_disks) {
		results := storage_take(s)
		for result in results {
			switch result.kind {
			case .Space:
				got_space = result.path == "/tmp" && result.space.valid && result.space.total > 0
			case .Disks:
				got_disks =
					result.error == "" && len(result.disks) > 0 && result.disks[0].path == "/"
			case .Operation, .Files:
				testing.expect(t, false, "unexpected operation")
			}
			storage_result_destroy(result)
		}
		delete(results)
		time.sleep(time.Millisecond)
	}
	testing.expect(t, got_space)
	testing.expect(t, got_disks)
	storage_visible(s, false)
	storage_refresh(s)
}
