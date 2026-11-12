package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import clay "vendor/clay"

path_contains :: proc(parent, path: string) -> bool {
	if path == TRASH_PATH {return parent == TRASH_PATH}
	return(
		parent != "" &&
		(path == parent ||
				parent == "/" ||
				(len(path) > len(parent) &&
						strings.has_prefix(path, parent) &&
						path[len(parent)] == '/')) \
	)
}

place_destroy :: proc(place: Place) {
	delete(place.path)
	delete(place.label)
	delete(place.device)
}

places_disks :: proc(p: ^Places, disks: []Disk) -> bool {
	// Space-only updates keep owned labels, selection, and scroll unchanged.
	start := len(p.entries) - len(disks)
	same := start > 0 && p.entries[start - 1].section
	if same {
		for disk, i in disks {
			place := p.entries[start + i]
			if !place.disk ||
			   place.device != disk.device ||
			   place.path != disk.path ||
			   place.label != disk.label {same = false; break}
		}
	}
	if same {
		changed := false
		for disk, i in disks {
			if p.entries[start + i].space != disk.space {
				p.entries[start + i].space = disk.space
				changed = true
			}
		}
		return changed
	}
	selected := ""
	if p.selected >= 0 && p.selected < len(p.entries) {
		place := p.entries[p.selected]
		selected = strings.clone(
			place.device != "" ? place.device : place.path,
			context.temp_allocator,
		)
	}
	#reverse for place, i in p.entries {
		if place.disk || place.section {place_destroy(place); ordered_remove(&p.entries, i)}
	}
	if len(disks) > 0 {append(&p.entries, Place{section = true})}
	for disk in disks {
		append(
			&p.entries,
			Place {
				label = strings.clone(disk.label),
				path = strings.clone(disk.path),
				device = strings.clone(disk.device),
				icon = .PlaceFilesystem,
				disk = true,
				space = disk.space,
			},
		)
	}
	p.selected = clamp(p.selected, 0, max(0, len(p.entries) - 1))
	for place, i in p.entries {
		if (place.device != "" ? place.device : place.path) == selected {p.selected = i; break}
	}
	return true
}

place_can_unmount :: proc(place: Place) -> bool {
	return place.device != "" && place.path != "" && place.path != "/"
}

place_unmount_at :: proc(place: Place, g: Geometry, x: f32) -> bool {
	return place_can_unmount(place) && x >= g.sidebar - 32 * g.scale
}

place_open :: proc(b: ^Browser, index: int, unmount := false) -> os.Error {
	if index < 0 || index >= len(b.places.entries) {return nil}
	place := b.places.entries[index]
	if place.section {return nil}
	if !unmount && place.path != "" {return browser_navigate(b, place.path)}
	if unmount && !place_can_unmount(place) {return nil}
	if b.pending_disk != nil {return nil}
	if b.storage == nil {browser_message(b, "disk mounting is unavailable"); return nil}
	browser_message(b, "")
	op := new(Disk_Operation)
	op.device, op.origin, op.mountpoint =
		strings.clone(place.device), strings.clone(b.path), strings.clone(place.path)
	op.unmount = unmount
	b.pending_disk = op
	storage_submit(b.storage, op)
	return nil
}

storage_apply :: proc(b: ^Browser, result: Storage_Result) -> bool {
	switch result.kind {
	case .Watch_Reset:
		watch_refresh(b.watch, reset = true)
		return false
	case .Progress:
		for &job in b.transfers {
			if job.op != result.files || sync.atomic_load(&job.op.cancel) {continue}
			changed :=
				job.progress.phase != result.progress.phase ||
				file_progress_percent(job.progress) != file_progress_percent(result.progress)
			job.progress = result.progress
			return changed
		}
		return false
	case .Files:
		return file_operation_apply(b, result.files)
	case .Space:
		if result.path != b.path || result.space == b.space {return false}
		b.space = result.space
	case .Disks:
		if result.error != "" {browser_message(b, result.error); return true}
		lost := false
		for place in b.places.entries {
			if place.device == "" || !path_contains(place.path, b.path) {continue}
			found := false
			for disk in result.disks {
				if disk.device == place.device && disk.path == place.path {found = true; break}
			}
			if !found {lost = true; break}
		}
		changed := places_disks(&b.places, result.disks[:])
		if lost {
			if err := browser_navigate(b, "/");
			   err != nil {browser_message(b, fmt.tprintf("cannot read folder: %v", err))}
		}
		return changed || lost
	case .Operation:
		op := result.op
		if op != b.pending_disk {return false}
		b.pending_disk = nil
		if op.error != "" {
			verb := op.unmount ? "unmount" : "mount"
			browser_message(b, fmt.tprintf("cannot %s %s: %s", verb, op.device, op.error))
		} else if b.path == op.origin {
			target := op.mountpoint
			if op.unmount {target = "/"}
			if !op.unmount || path_contains(op.mountpoint, b.path) {
				if err := browser_navigate(b, target);
				   err != nil {browser_message(b, fmt.tprintf("cannot read folder: %v", err))}
			}
		}
	}
	return true
}

storage_poll :: proc(b: ^Browser) -> (changed: bool) {
	if b.storage == nil {return}
	results := storage_take(b.storage)
	defer delete(results)
	for result in results {
		changed = storage_apply(b, result) || changed
		storage_result_destroy(result)
	}
	return
}

place_unmount_id :: proc(index: int) -> clay.ElementId {return clay.ID("unmount", u32(index))}
