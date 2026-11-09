package main

Edit_Snapshot :: struct {
	value:          string,
	cursor, anchor: int,
}

edit_history_clear :: proc(history: ^[dynamic]Edit_Snapshot) {
	for state in history^ {delete(state.value)}
	delete(history^)
	history^ = nil
}

edit_history_push :: proc(history: ^[dynamic]Edit_Snapshot, state: Edit_Snapshot) {
	if len(history^) == 100 {
		delete(history^[0].value)
		ordered_remove(history, 0)
	}
	append(history, state)
}

path_edit_undo :: proc(edit: ^Path_Edit, redo: bool) {
	from, to := &edit.undo, &edit.redo
	if redo {from, to = to, from}
	if len(from^) == 0 {return}
	state := pop(from)
	edit_history_push(to, {edit.value, edit.cursor, edit.anchor})
	delete(edit.composition)
	edit.value, edit.cursor, edit.anchor = state.value, state.cursor, state.anchor
	edit.composition = ""
}
