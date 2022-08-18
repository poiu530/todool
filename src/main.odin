package src

import "core:image"
import "core:image/png"
import "core:os"
import "core:encoding/json"
import "core:mem"
import "core:math"
import "core:time"
import "core:strings"
import "core:fmt"
import "core:log"
import "core:math/rand"
import sdl "vendor:sdl2"
import "../fontstash"

// import "../notify"

// main :: proc() {
// 	notify.init("todool")
// 	defer notify.uninit()

// 	notify.run("Todool Pomodoro Timer Finished", "", "dialog-information")
// }

// import "../nfd"
// main2 :: proc() {
// 	fmt.eprintln("start")
// 	defer fmt.eprintln("end")

// 	out_path: cstring = "*.c"
// 	res := nfd.OpenDialog("", "", &out_path)
// 	fmt.eprintln(res, out_path)

// 	// res := nfd.SaveDialog("", "", &out_path)
// 	// fmt.eprintln(res, out_path)
// }

@(deferred_out=arena_scoped_end)
arena_scoped :: proc(cap: int) -> (arena: mem.Arena, backing: []byte) {
	backing = make([]byte, cap)
	mem.arena_init(&arena, backing)
	return
}

arena_scoped_end :: proc(arena: mem.Arena, backing: []byte) {
	delete(backing)
}

// mapping from key shortcut -> key command
// mapping from key command -> command execution

todool_command_execute :: proc(command: string) {
	switch command {
		// case "move_right"
	}
}

main :: proc() {
	gs_init()
	context.logger = gs.logger

	task_data_init()
	defer task_data_destroy()

	window := window_init("Todool", 900, 900, mem.Megabyte * 10)
	window.name = "main"
	window_main = window
	window.element.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		window := cast(^Window) element

		#partial switch msg {
			case .Key_Combination: {
				handled := true
				combo := (cast(^string) dp)^

				if window_focused_shown(window) {
					return 0
				}

				s := &window.shortcut_state

				task_head_tail_clamp()
				if task_head != -1 && !task_has_selection() && len(tasks_visible) > 0 {
					box := tasks_visible[task_head].box
					
					if element_message(box, msg, di, dp) == 1 {
						return 1
					}
				}

				if command, ok := s.general[combo]; ok {
					shortcuts_command_execute_todool(command)
				}
				return 1
			}

			case .Unicode_Insertion: {
				if window_focused_shown(window) {
					return 0
				}

				if task_head != -1 {
					task_focused := tasks_visible[task_head]
					res := element_message(task_focused.box, msg, di, dp)
					if res == 1 {
						task_tail = task_head
					}
					return res
				}
			}

			case .Window_Close: {
				if options_autosave() {
					editor_save("save.todool")
				} else if dirty != dirty_saved {
					res := dialog_spawn(
						window, 
						"Leave without saving progress?\n%l\n%f%b%C%B",
						"Close Without Saving",
						"Cancel",
						"Save",
					)
					
					switch res {
						case "Save": {
							editor_save("save.todool")
						}

						case "Cancel": {
							return 1
						}

						case "Close Without Saving": {}
					}
				}
			}

			case .Dropped_Files: {
				old_indice: int
				manager := mode_panel_manager_begin()
				had_imports := false

				for indice in element.window.drop_indices {
					file_path := string(element.window.drop_file_name_builder.buf[old_indice:indice])

					// image dropping
					if strings.has_suffix(file_path, ".png") {
						if task_head != -1 {
							task := tasks_visible[task_head]
							handle := image_load_push(file_path)
							task.image_display.img = handle
						}
					} else {
						if !had_imports {
							task_head_tail_push(manager)
						}
						had_imports = true

						// import from code
						content, ok := os.read_entire_file(file_path)
						defer delete(content)

						if ok {
							pattern_load_content(manager, string(content))
						}
					}

					old_indice = indice
				}

				if had_imports {
					undo_group_end(manager)
				}

				element_repaint(mode_panel)
			}
		}

		return 0
	} 

	window.update = proc(window: ^Window) {
		task_set_children_info()
		task_set_visible_tasks()
		task_check_parent_states(nil)
		
		// find dragging index at
		if dragging {
			for task, i in tasks_visible {
				if task.bounds.t < task.window.cursor_y && task.window.cursor_y < task.bounds.b {
					drag_index_at = task.visible_index
					break
				}
			}
		}

		// set bookmarks
		{
			clear(&bookmarks)
			for task, i in tasks_visible {
				if task.bookmarked {
					append(&bookmarks, i)
				}
			}
		}

		// log.info("dirty", dirty, dirty_saved)
		window_title_build(window, dirty != dirty_saved ? "Todool*" : "Todool")
		task_head_tail_clamp()

		// NOTE forces the first task to indentation == 0
		{
			if len(tasks_visible) != 0 {
				task := tasks_visible[0]

				if task.indentation != 0 {
					manager := mode_panel_manager_scoped()
					// NOTE continue the first group
					undo_group_continue(manager) 

					item := Undo_Item_Task_Indentation_Set {
						task = task,
						set = task.indentation,
					}	
					undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

					task.indentation = 0
					task.indentation_animating = true
					element_animation_start(task)
				}
			}
		}

		// line changed
		if old_task_head != task_head || old_task_tail != task_tail {
			// call box changes immediatly when leaving task head / tail 
			if len(tasks_visible) != 0 && old_task_head != -1 && old_task_head < len(tasks_visible) {
				cam := mode_panel_cam()
				cam.freehand = false

				task := tasks_visible[old_task_head]
				manager := mode_panel_manager_begin()
				box_force_changes(manager, task.box)
			}
		}

		old_task_head = task_head
		old_task_tail = task_tail

		pomodoro_update()
		image_load_process_texture_handles(window)

		// update visual indices of archive buttons, to not do lookups
		if (.Hide not_in sb.enum_panel.flags) && sb.mode == .Archive {
			sb.archive.head = clamp(sb.archive.head, 0, len(sb.archive.buttons.children) - 1)
			sb.archive.tail = clamp(sb.archive.tail, 0, len(sb.archive.buttons.children) - 1)

			for e, i in sb.archive.buttons.children {
				button := cast(^Archive_Button) e
				button.visual_index = len(sb.archive.buttons.children) - 1 - i
 			}
		}
	}

	shortcuts_push_todool(window)
	shortcuts_push_box_default(window)

	// add_shortcuts(window)
	panel := panel_init(&window.element, { .Panel_Horizontal, .Tab_Movement_Allowed })

	{
		rect := window_rect(window)
		split := split_pane_init(panel, { .Split_Pane_Hidable, .Split_Pane_Reversed, .VF, .HF, .Tab_Movement_Allowed }, rect.r - 300, 300)
		split.pixel_based = true
		sb.split = split
	}	

	sidebar_enum_panel_init(sb.split)
	task_panel_init(sb.split)
	sidebar_panel_init(panel)

	goto_init(window) 
	drag_init(window)

	tasks_load_file()
	json_load_misc("save.sjson")

	gs_message_loop()
}
