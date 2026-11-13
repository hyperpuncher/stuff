package main

import "core:strings"

// replace_owned clones before releasing the old bytes, so value may alias dst^.
replace_owned :: proc(dst: ^string, value: string, allocator := context.allocator) {
	if dst^ == value {return}
	replacement := strings.clone(value, allocator)
	delete(dst^, allocator)
	dst^ = replacement
}
