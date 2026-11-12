package main

import "core:os"
import linux "core:sys/linux"

// Private directories belong to this user and are not writable by other users.
// FAT/exFAT can report 0755 for a requested 0700 directory. Never follow a link
// in place of the directory. Access stays relative to the open fd.
private_dir_at :: proc(parent: linux.Fd, name: cstring) -> (fd: linux.Fd, err: os.Error) {
	mkdir_err := linux.mkdirat(parent, name, transmute(linux.Mode)u32(0o700))
	if mkdir_err != .NONE && mkdir_err != .EEXIST {return -1, mkdir_err}
	return private_dir_open_at(parent, name)
}

private_dir_open_at :: proc(parent: linux.Fd, name: cstring) -> (fd: linux.Fd, err: os.Error) {
	open_err: linux.Errno
	fd, open_err = linux.openat(parent, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if open_err != .NONE {return -1, open_err}
	st: linux.Stat
	stat_err := linux.fstat(fd, &st)
	if stat_err != .NONE {linux.close(fd); return -1, stat_err}
	if st.uid != linux.getuid() || transmute(u32)st.mode & 0o022 != 0 {
		linux.close(fd)
		return -1, linux.Errno.EACCES
	}
	return fd, nil
}
