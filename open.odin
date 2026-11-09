package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import linux "core:sys/linux"
import sdl "vendor:sdl3"

File_Open :: struct {
	process: ^sdl.Process,
	path:    string, // Owned; the directory listing may be replaced while this runs.
}

file_open :: proc(b: ^Browser, path: string) {
	browser_message(b, "")
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	info: linux.Stat
	err := linux.stat(cpath, &info)
	if err != .NONE {
		browser_message(b, fmt.tprintf("cannot open %s: %v", os.base(path), err))
		return
	}
	if info.mode & linux.S_IFMT != linux.S_IFREG {
		browser_message(b, fmt.tprintf("cannot open %s: not a regular file", os.base(path)))
		return
	}

	args := [?]cstring{"xdg-open", cpath, nil}
	process := sdl.CreateProcess(raw_data(args[:]), false)
	if process == nil {
		browser_message(
			b,
			fmt.tprintf("cannot open %s: %s", os.base(path), string(sdl.GetError())),
		)
		return
	}
	append(&b.opens, File_Open{process = process, path = strings.clone(path)})
}

// Poll only while launches are pending. Successful completion needs no redraw.
file_open_poll :: proc(b: ^Browser) -> (changed: bool) {
	#reverse for job, i in b.opens {
		exit_code: c.int
		sdl.ClearError()
		exited := sdl.WaitProcess(job.process, false, &exit_code)
		if !exited && string(sdl.GetError()) == "" {continue}
		if !exited {
			browser_message(
				b,
				fmt.tprintf("cannot check %s: %s", os.base(job.path), string(sdl.GetError())),
			)
			changed = true
		} else if exit_code != 0 {
			browser_message(
				b,
				fmt.tprintf(
					"cannot open %s: xdg-open exited with code %d",
					os.base(job.path),
					exit_code,
				),
			)
			changed = true
		}
		sdl.DestroyProcess(job.process)
		delete(job.path)
		unordered_remove(&b.opens, i)
	}
	return
}

file_open_destroy :: proc(b: ^Browser) {
	for job in b.opens {
		// Do not wait for or terminate an application when the browser closes.
		sdl.DestroyProcess(job.process)
		delete(job.path)
	}
	delete(b.opens)
}
