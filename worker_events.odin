package main

import "core:fmt"
import linux "core:sys/linux"
import sdl "vendor:sdl3"

// Wake a worker-polled pipe without losing a signal to EINTR.
wake_fd :: proc(fd: linux.Fd) {
	byte := [1]u8{1}
	for {
		_, err := linux.write(fd, byte[:])
		if err != .EINTR {break}
	}
}

// Wake the UI through SDL. Services use one registered event each.
notify_ui :: proc(event: sdl.EventType, description: string) {
	e := sdl.Event {
		type = event,
	}
	if !sdl.PushEvent(&e) {
		fmt.eprintfln("cannot deliver %s: %s", description, string(sdl.GetError()))
	}
}
