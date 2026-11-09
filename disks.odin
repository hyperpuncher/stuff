package main

import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import linux "core:sys/linux"
import "core:sys/posix"

Disk :: struct {
	device, label, path: string, // Owned; an empty path means unmounted.
	space:               Space_Info,
}

Space_Info :: struct {
	available, total: i64,
	valid:            bool,
}

Mount :: struct {
	device:             linux.Dev,
	root, path, source: string,
}

// Mount tables use octal escapes; udev labels use hexadecimal escapes.
escaped_decode :: proc(value: string, hexadecimal := false) -> string {
	out := make([dynamic]u8, 0, len(value))
	for i := 0; i < len(value); i += 1 {
		if value[i] == '\\' && i + 3 < len(value) {
			digits, base := value[i + 1:i + 4], 8
			if hexadecimal {
				if value[i + 1] != 'x' {append(&out, value[i]); continue}
				digits, base = value[i + 2:i + 4], 16
			}
			if byte, ok := strconv.parse_u64(digits, base); ok && byte > 0 && byte <= 255 {
				append(&out, u8(byte))
				i += 3
				continue
			}
		}
		append(&out, value[i])
	}
	return string(out[:])
}

mounts_parse :: proc(data: string) -> [dynamic]Mount {
	mounts: [dynamic]Mount
	for line in strings.split(data, "\n", context.temp_allocator) {
		separator := strings.index(line, " - ")
		if separator < 0 {continue}
		head := strings.fields(line[:separator], context.temp_allocator)
		tail := strings.fields(line[separator + 3:], context.temp_allocator)
		if len(head) < 6 || len(tail) < 3 {continue}
		colon := strings.index(head[2], ":")
		if colon < 0 {continue}
		ma, ma_ok := strconv.parse_u64(head[2][:colon], 10)
		mi, mi_ok := strconv.parse_u64(head[2][colon + 1:], 10)
		if !ma_ok || !mi_ok || ma > u64(max(u32)) || mi > u64(max(u32)) {continue}
		append(
			&mounts,
			Mount {
				device = linux.makedev(u32(ma), u32(mi)),
				root = escaped_decode(head[3]),
				path = escaped_decode(head[4]),
				source = escaped_decode(tail[1]),
			},
		)
	}
	return mounts
}

mounts_destroy :: proc(mounts: [dynamic]Mount) {
	for mount in mounts {delete(mount.root); delete(mount.path); delete(mount.source)}
	delete(mounts)
}

mounts_read :: proc() -> ([dynamic]Mount, os.Error) {
	data, err := os.read_entire_file("/proc/self/mountinfo", context.temp_allocator)
	if err != nil {return nil, err}
	mounts := mounts_parse(string(data))
	for &mount in mounts {
		// Btrfs st_dev is not the block device number. Device aliases also occur.
		if strings.has_prefix(mount.source, "/dev/") {
			name := strings.clone_to_cstring(mount.source, context.temp_allocator)
			stat: linux.Stat
			if linux.stat(name, &stat) == .NONE {mount.device = stat.rdev}
		}
	}
	return mounts, nil
}

mount_path :: proc(mounts: []Mount, device: linux.Dev) -> string {
	chosen := -1
	for mount, i in mounts {
		if mount.device != device {continue}
		if chosen < 0 ||
		   mount.path == "/" ||
		   (mounts[chosen].path != "/" &&
				   ((mount.root == "/" && mounts[chosen].root != "/") ||
						   (mount.root == mounts[chosen].root &&
								   len(mount.path) < len(mounts[chosen].path)))) {
			chosen = i
		}
	}
	return chosen < 0 ? "" : mounts[chosen].path
}

disk_used_fraction :: proc(space: Space_Info) -> f32 {
	if !space.valid || space.total <= 0 {return 0}
	return f32(clamp(1 - f64(space.available) / f64(space.total), 0, 1))
}

space_query :: proc(path: string) -> Space_Info {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	info: posix.statvfs_t
	if posix.statvfs(name, &info) != .OK {return {}}
	blocks, size := u64(info.f_bavail), u64(info.f_frsize)
	if size == 0 || blocks > u64(max(i64)) / size {return {}}
	total := u64(info.f_blocks)
	if total > u64(max(i64)) / size {return {}}
	return {available = i64(blocks * size), total = i64(total * size), valid = true}
}

disks_destroy :: proc(disks: [dynamic]Disk) {
	for disk in disks {delete(disk.device); delete(disk.label); delete(disk.path)}
	delete(disks)
}

disks_read :: proc(udev: ^Udev) -> (disks: [dynamic]Disk, err: string) {
	mounts, mount_err := mounts_read()
	if mount_err != nil {return nil, "cannot read mounted filesystems"}
	defer mounts_destroy(mounts)
	e := udev_enumerate_new(udev)
	if e == nil {return nil, "cannot list disks"}
	defer udev_enumerate_unref(e)
	if udev_enumerate_add_match_subsystem(e, "block") < 0 ||
	   udev_enumerate_add_match_property(e, "ID_FS_USAGE", "filesystem") < 0 ||
	   udev_enumerate_scan_devices(e) < 0 {return nil, "cannot list disks"}
	append(&disks, Disk{label = strings.clone("filesystem"), path = strings.clone("/")})
	for item := udev_enumerate_get_list_entry(e);
	    item != nil;
	    item = udev_list_entry_get_next(item) {
		device := udev_device_new_from_syspath(udev, udev_list_entry_get_name(item))
		if device == nil {continue}
		defer udev_device_unref(device)
		if string(udev_device_get_property_value(device, "UDISKS_IGNORE")) == "1" {continue}
		name := string(udev_device_get_devnode(device))
		if name == "" {continue}
		path := mount_path(mounts[:], linux.Dev(udev_device_get_devnum(device)))
		if path == "/" {continue} 	// The existing filesystem place covers this volume.
		label := string(udev_device_get_property_value(device, "ID_FS_LABEL_ENC"))
		owned_label := escaped_decode(label, true)
		if owned_label == "" {
			delete(owned_label)
			owned_label = strings.clone(string(udev_device_get_sysname(device)))
		}
		append(
			&disks,
			Disk{device = strings.clone(name), label = owned_label, path = strings.clone(path)},
		)
	}
	slice.sort_by(disks[1:], proc(a, b: Disk) -> bool {
		if a.label != b.label {return a.label < b.label}
		return a.device < b.device
	})
	return
}
