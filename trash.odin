package main

import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import "core:time"
import sdl "vendor:sdl3"

TRASH_PATH :: "trash:///"

trash_home_path :: proc() -> string {
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if strings.has_prefix(data, "/") {return fmt.aprintf("%s/Trash", data)}
	home := os.get_env("HOME", context.temp_allocator)
	if !strings.has_prefix(home, "/") {return ""}
	return fmt.aprintf("%s/.local/share/Trash", home)
}

// Private trash directories must belong to this user. Never follow a link in
// place of a trash directory. Subsequent access stays relative to the open fd.
trash_private_at :: proc(parent: linux.Fd, name: cstring) -> (fd: linux.Fd, err: os.Error) {
	mkdir_err := linux.mkdirat(parent, name, transmute(linux.Mode)u32(0o700))
	if mkdir_err != .NONE && mkdir_err != .EEXIST {return -1, mkdir_err}
	return trash_private_open_at(parent, name)
}

trash_private_open_at :: proc(parent: linux.Fd, name: cstring) -> (fd: linux.Fd, err: os.Error) {
	open_err: linux.Errno
	fd, open_err = linux.openat(parent, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if open_err != .NONE {return -1, open_err}
	st: linux.Stat
	stat_err := linux.fstat(fd, &st)
	if stat_err != .NONE {linux.close(fd); return -1, stat_err}
	if st.uid != linux.getuid() || transmute(u32)st.mode & 0o777 != 0o700 {
		linux.close(fd)
		return -1, linux.Errno.EACCES
	}
	return fd, nil
}

trash_home_open :: proc(home: string) -> (linux.Fd, os.Error) {
	if home == "" {return -1, .No_HOME_Variable}
	parent, _ := os.split_path(home)
	err := os.make_directory_all(parent, os.perm(0o700))
	if err != nil && err != .Exist {return -1, err}
	path_c := strings.clone_to_cstring(parent)
	defer delete(path_c)
	fd, open_err := linux.open(path_c, {.DIRECTORY, .CLOEXEC})
	if open_err != .NONE {return -1, open_err}
	defer linux.close(fd)
	return trash_private_at(fd, "Trash")
}

trash_local_open :: proc(top: string) -> (linux.Fd, os.Error) {
	path_c := strings.clone_to_cstring(top)
	defer delete(path_c)
	fd, open_err := linux.open(path_c, {.DIRECTORY, .CLOEXEC})
	if open_err != .NONE {return -1, open_err}
	defer linux.close(fd)
	uid := fmt.tprintf("%d", linux.getuid())
	shared, shared_err := linux.openat(fd, ".Trash", {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if shared_err == .NONE {
		defer linux.close(shared)
		st: linux.Stat
		if linux.fstat(shared, &st) == .NONE && transmute(u32)st.mode & 0o1000 != 0 {
			name := strings.clone_to_cstring(uid)
			defer delete(name)
			if user, err := trash_private_at(shared, name); err == nil {return user, nil}
		}
	}
	name := strings.clone_to_cstring(fmt.tprintf(".Trash-%s", uid))
	defer delete(name)
	return trash_private_at(fd, name)
}

// Freedesktop trash format: a same-filesystem rename and a .trashinfo record.
// If trash is unavailable, leave the source in place. There is no permanent-delete fallback.
trash_file :: proc(source, home: string, mounts: []Mount, record: ^File_Change = nil) -> os.Error {
	parent, name := os.split_path(source)
	if name == "" || name == "." || name == ".." {return .Invalid_Path}
	absolute := os.get_absolute_path(parent, context.allocator) or_return
	defer delete(absolute)
	path := fmt.aprintf("%s/%s", strings.trim_suffix(absolute, "/"), name)
	defer delete(path)
	info := os.lstat(path, context.allocator) or_return
	defer os.file_info_delete(info, context.allocator)
	if home != "" &&
	   (path_contains(home, path) || path_contains(path, home)) {return .Invalid_Path}
	top := "/"
	for mount in mounts {
		if path_contains(mount.path, path) && len(mount.path) > len(top) {top = mount.path}
	}
	if path == top {return linux.Errno.EBUSY}
	root, home_err := trash_home_open(home)
	local := home_err != nil
	if root >= 0 {
		st: linux.Stat
		local = linux.fstat(root, &st) != .NONE || u64(st.dev) != info.device
		if local {linux.close(root); root = -1}
	}
	if local {
		// A local trash contains paths relative to the mount root.
		shared := fmt.tprintf("%s/.Trash", strings.trim_suffix(top, "/"))
		private := fmt.tprintf("%s/.Trash-%d", strings.trim_suffix(top, "/"), linux.getuid())
		if path_contains(shared, path) ||
		   path_contains(private, path) ||
		   path_contains(path, shared) ||
		   path_contains(path, private) {return .Invalid_Path}
		err: os.Error
		root, err = trash_local_open(top)
		if err != nil {return err}
	}
	defer linux.close(root)
	st: linux.Stat
	if stat_err := linux.fstat(root, &st); stat_err != .NONE {return stat_err}
	if u64(st.dev) != info.device {return linux.Errno.EXDEV}
	files := trash_private_at(root, "files") or_return
	defer linux.close(files)
	infos := trash_private_at(root, "info") or_return
	defer linux.close(infos)
	files_path, infos_path: string
	defer delete(files_path)
	defer delete(infos_path)
	if record != nil {
		files_path = os.read_link(
			fmt.tprintf("/proc/self/fd/%d", files),
			context.allocator,
		) or_return
		infos_path = os.read_link(
			fmt.tprintf("/proc/self/fd/%d", infos),
			context.allocator,
		) or_return
	}
	restore := path
	if local {restore = strings.trim_prefix(strings.trim_prefix(path, top), "/")}
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	strings.write_string(&out, "[Trash Info]\nPath=")
	file_uri_path(restore, &out)
	date: sdl.DateTime
	now := time.to_unix_nanoseconds(time.now())
	if !sdl.TimeToDateTime(sdl.Time(now), &date, true) {return .Invalid_File}
	strings.write_string(
		&out,
		fmt.tprintf(
			"\nDeletionDate=%04d-%02d-%02dT%02d:%02d:%02d\n",
			date.year,
			date.month,
			date.day,
			date.hour,
			date.minute,
			date.second,
		),
	)
	source_c := strings.clone_to_cstring(path)
	defer delete(source_c)
	for i := 0;; i += 1 {
		// Internal names need not match the original name. Fixed-size identifiers
		// also leave room for .trashinfo when the original name is 255 bytes long.
		base := fmt.tprintf("stuff-%d-%d-%d", linux.getpid(), now, i)
		base_c := strings.clone_to_cstring(base)
		defer delete(base_c)
		info_c := strings.clone_to_cstring(fmt.tprintf("%s.trashinfo", base))
		defer delete(info_c)
		fd, open_err := linux.openat(
			infos,
			info_c,
			{.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC},
			transmute(linux.Mode)u32(0o600),
		)
		if open_err == .EEXIST {continue}
		if open_err != .NONE {return open_err}
		file := os.new_file(uintptr(fd), string(info_c))
		_, err := os.write(file, transmute([]u8)strings.to_string(out))
		if err == nil {err = os.sync(file)}
		close_err := os.close(file)
		if err == nil {err = close_err}
		if err ==
		   nil {err = linux.renameat2(linux.AT_FDCWD, source_c, files, base_c, {.NOREPLACE})}
		if err == nil {
			if record != nil {
				record^ = {
					path       = strings.clone(path),
					alternate  = fmt.aprintf("%s/%s", files_path, base),
					trash_info = fmt.aprintf("%s/%s", infos_path, string(info_c)),
					device     = info.device,
					inode      = info.inode,
				}
			}
			return nil
		}
		linux.unlinkat(infos, info_c, {})
		if err != linux.Errno.EEXIST {return err}
	}
}
