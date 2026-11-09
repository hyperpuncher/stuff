package main

import "core:testing"

@(test)
desktop_font_description_sizes :: proc(t: ^testing.T) {
	cases := [?]struct {
		description: string,
		points:      f32,
	} {
		{"CaskaydiaMono Nerd Font 11", 11},
		{"Mono Bold 11.5", 11.5},
		{"Mono 14px", 10.5},
		{"Mono 14.5px", 10.875},
		{"", 0},
		{"Mono Bold", 0},
		{"Mono 0", 0},
		{"Mono -12", 0},
		{"Mono NaN", 0},
		{"Mono Inf", 0},
	}
	for item in cases {testing.expect_value(t, font_description_points(item.description), item.points)}
}
