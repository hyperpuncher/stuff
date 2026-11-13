package main

import "core:sync"
import clay "vendor/clay"
import sdl "vendor:sdl3"

File_Progress :: struct {
	phase:       enum {
		Working,
		Preparing,
	},
	done, total: u64,
}

File_Transfer :: struct {
	op:       ^File_Operation,
	progress: File_Progress, // UI-owned snapshot; never read the worker's counters.
}

// The worker sends value snapshots. The UI never reads its mutable counters.
file_progress_publish :: proc(op: ^File_Operation, force := false) {
	if op.storage == nil ||
	   op.progress.phase == .Preparing ||
	   sync.atomic_load(&op.cancel) {return}
	now := sdl.GetTicks()
	if !force && now < op.progress_due {return}
	op.progress_due = now + 100
	storage_publish(op.storage, {kind = .Progress, files = op, progress = op.progress})
}

file_progress_advance :: proc(op: ^File_Operation) {
	op.progress.done += 1
	file_progress_publish(op)
}

file_progress_percent :: proc(progress: File_Progress) -> int {
	if progress.total == 0 {return 0}
	// Do not claim completion while data is still being flushed or published.
	return int(min(99.0, f64(progress.done) * 100 / f64(progress.total)))
}

file_transfers_height :: proc(b: ^Browser, g: Geometry) -> f32 {
	count := len(b.transfers)
	if count == 0 {return 0}
	body := max(0, g.height - g.header - g.footer)
	// Use the empty space below places. Many transfers can use up to half
	// of the sidebar when places already fill it. Each region scrolls separately.
	blank := max(0, body - f32(len(b.places.entries)) * g.row - 2 * g.list_padding)
	return max(blank, min(f32(count + 1) * g.row, body / 2))
}

file_transfers_rows :: proc(g: Geometry) -> int {
	return max(1, int((g.transfers - g.row) / g.row))
}

file_transfer_hit :: proc(b: ^Browser, g: Geometry, x, y: f32) -> int {
	if b.header.edit.active &&
	   edit_is_dialog(b.header.edit.mode) &&
	   header_hit(clay.ID("file-dialog"), x, y) {return -1}
	if g.transfers <= 0 || !header_hit(clay.ID("transfers-viewport"), x, y) {return -1}
	last := min(len(b.transfers), b.transfer_first + file_transfers_rows(g) + 1)
	for i in b.transfer_first ..< last {
		if sync.atomic_load(&b.transfers[i].op.cancel) {continue}
		if header_hit(clay.ID("transfer-cancel", u32(i)), x, y) {return i}
	}
	return -1
}

file_transfer_cancel :: proc(b: ^Browser, index: int) {
	if index < 0 || index >= len(b.transfers) {return}
	job := &b.transfers[index]
	sync.atomic_store(&job.op.cancel, true)
}

file_progress_input :: proc(b: ^Browser, event: ^sdl.Event, g: Geometry) -> bool {
	if g.transfers <= 0 {return false}
	#partial switch event.type {
	case .MOUSE_WHEEL:
		if !header_hit(
			clay.ID("transfers-viewport"),
			event.wheel.mouse_x,
			event.wheel.mouse_y,
		) {return false}
		amount := event.wheel.y
		if event.wheel.direction == .FLIPPED {amount = -amount}
		b.transfer_first = clamp(
			b.transfer_first - int(amount),
			0,
			max(0, len(b.transfers) - file_transfers_rows(g)),
		)
		return true
	case .MOUSE_BUTTON_DOWN:
		if event.button.button != sdl.BUTTON_LEFT {return false}
		index := file_transfer_hit(b, g, event.button.x, event.button.y)
		if index < 0 {return false}
		file_transfer_cancel(b, index)
		return true
	}
	return false
}

// Icons for transfer rows, indexed like FILE_ACTION_VERBS.
@(rodata)
FILE_ACTION_ICONS := [File_Action]Icon {
	.Copy        = .CopyPath,
	.Compress    = .Archive,
	.Extract     = .Archive,
	.Trash       = .Trash,
	.List_Trash  = .Trash,
	.Empty_Trash = .Trash,
	.Rename      = .Rename,
	.New_Folder  = .NewFolder,
	.Restore     = .Restore,
	.Open_With   = .OpenWith,
}

file_transfers_layout :: proc(b: ^Browser, g: Geometry, p: ^Painter, icon_left: f32) {
	if g.transfers <= 0 {return}
	count := len(b.transfers)
	rows := file_transfers_rows(g)
	b.transfer_first = clamp(b.transfer_first, 0, max(0, count - rows))
	if clay.UI()(
	{
		layout = {
			sizing = {clay.SizingGrow(), clay.SizingFixed(g.transfers)},
			padding = {bottom = u16(g.list_padding)},
			layoutDirection = .TopToBottom,
		},
	},
	) {
		// Together with the places list's bottom padding, this is one full row.
		if clay.UI()(
		{
			layout = {
				sizing = {clay.SizingGrow(), clay.SizingFixed(g.row - f32(u16(g.list_padding)))},
			},
		},
		) {}
		if clay.UI(clay.ID("transfers-viewport"))(viewport_config()) {
			for i in b.transfer_first ..< min(count, b.transfer_first + rows + 1) {
				job := b.transfers[i]
				cancelling := sync.atomic_load(&job.op.cancel)
				gap := u16(8 * g.scale)
				left, right := u16(icon_left), u16(8 * g.scale)
				width := g.sidebar - f32(left + right + 2 * gap) - (18 + 24) * g.scale
				if clay.UI(clay.ID("transfer-row", u32(i)))(
				{
					layout = {
						sizing = {clay.SizingGrow(), clay.SizingFixed(g.row)},
						padding = {
							left = left,
							right = right,
							top = u16(1.5 * g.scale),
							bottom = u16(1.5 * g.scale),
						},
						childGap = gap,
						childAlignment = {y = .Center},
					},
				},
				) {
					icon_element(p, FILE_ACTION_ICONS[job.op.kind], g.scale)
					if clay.UI()(
					{
						layout = {
							sizing = {width = clay.SizingGrow()},
							layoutDirection = .TopToBottom,
							childGap = u16(3 * g.scale),
						},
					},
					) {
						label(
							fit_label(p.font, job.op.label, width, middle = true),
							theme.text,
							g.font_size,
						)
						progress_line(
							clay.ID("transfer-track", u32(i)),
							f32(file_progress_percent(job.progress)) / 100,
							g.scale,
						)
					}
					id := clay.ID("transfer-cancel", u32(i))
					if clay.UI(id)(
					{
						layout = {
							sizing = {
								clay.SizingFixed(24 * g.scale),
								clay.SizingFixed(24 * g.scale),
							},
							childAlignment = {x = .Center, y = .Center},
						},
						backgroundColor = cancelling ? clay.Color{} : hover_color(b, id, {}),
						cornerRadius = clay.CornerRadiusAll(6 * g.scale),
					},
					) {icon_element(p, .Close, g.scale)}
				}
			}
		}
	}
}
