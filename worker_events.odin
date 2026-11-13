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

// Empty a nonblocking wake pipe after a signal, before waiting again.
wake_drain :: proc(fd: linux.Fd) {
	buffer: [256]u8
	for {
		n, err := linux.read(fd, buffer[:])
		if err != .NONE || n == 0 {break}
	}
}

// A ppoll wait built from a millisecond deadline; zero returns immediately.
poll_timeout :: proc(ms: u64) -> linux.Time_Spec {
	return {time_sec = uint(ms / 1000), time_nsec = uint(ms % 1000) * 1_000_000}
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
