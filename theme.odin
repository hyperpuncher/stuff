package main

import clay "vendor/clay"
import sdl "vendor:sdl3"

Theme :: struct {
	background, panel, text, muted:                      clay.Color,
	selected, inactive_selection, hover, hover_selected: clay.Color,
}

DARK_THEME :: Theme {
	background         = {20, 20, 20, 255},
	panel              = {28, 28, 28, 255},
	text               = {224, 224, 224, 255},
	muted              = {150, 150, 150, 255},
	selected           = {52, 52, 52, 255},
	inactive_selection = {36, 36, 36, 255},
	hover              = {42, 42, 42, 255},
	hover_selected     = {62, 62, 62, 255},
}

LIGHT_THEME :: Theme {
	background         = {248, 248, 248, 255},
	panel              = {240, 240, 240, 255},
	text               = {32, 32, 32, 255},
	muted              = {88, 88, 88, 255},
	selected           = {220, 220, 220, 255},
	inactive_selection = {232, 232, 232, 255},
	hover              = {228, 228, 228, 255},
	hover_selected     = {208, 208, 208, 255},
}

// Preserve the dark default when the desktop reports no preference.
theme := DARK_THEME

theme_apply :: proc(p: ^Painter, system: sdl.SystemTheme) -> bool {
	next := DARK_THEME
	if system == .LIGHT {next = LIGHT_THEME}
	if theme == next {return false}
	theme = next
	for icon in p.icons {
		if icon == nil {continue}
		sdl_check(
			sdl.SetTextureColorMod(
				icon,
				u8(theme.muted[0]),
				u8(theme.muted[1]),
				u8(theme.muted[2]),
			),
		)
	}
	return true
}
