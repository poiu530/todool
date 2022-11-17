package src

import "core:c/libc"
import "core:io"
import "core:mem"
import "core:strconv"
import "core:fmt"
import "core:unicode"
import "core:strings"
import "core:log"
import "core:math"
import "core:intrinsics"
import "core:slice"
import "core:reflect"
import "core:time"
import "core:thread"
import "../cutf8"
import "../fontstash"
import "../spall"

Task_State_Progression :: enum {
	Idle,
	Update_Instant,
	Update_Animated,
}

task_menu_bar: ^Menu_Bar
task_state_progression: Task_State_Progression = .Update_Instant
progressbars_alpha: f32 // animation

// focus
focusing: bool
focus_head: int
focus_tail: int

// rax
main_thread_running := true

// keymap special
keymap_vim_normal: Keymap
keymap_vim_insert: Keymap

Vim_State :: struct {
	insert_mode: bool,
	
	// return to same task if still waiting for move break
	// left /right
	rep_task: ^Task,
	rep_direction: int, // direction -1 = left, 1 = right
	rep_cam_x: f32,
	rep_cam_y: f32,
}
vim: Vim_State

// last save
last_save_location: string

TAB_WIDTH :: 200
TASK_DRAG_SIZE :: 80

um_task: Undo_Manager
um_search: Undo_Manager
um_goto: Undo_Manager
um_sidebar_tags: Undo_Manager

panel_info: ^Panel
mode_panel: ^Mode_Panel
custom_split: ^Custom_Split
window_main: ^Window
caret_rect: RectI
caret_lerp_speed_y := f32(1)
caret_lerp_speed_x := f32(1)
last_was_task_copy := false
task_clear_checking: map[^Task]u8
task_highlight: ^Task

// move state
task_move_stack: []^Task

// goto state
panel_goto: ^Panel_Floaty
goto_saved_task_head: int
goto_saved_task_tail: int
goto_transition_animating: bool
goto_transition_unit: f32
goto_transition_hide: bool

// copy state
copy_text_data: strings.Builder
copy_task_data: [dynamic]Copy_Task

// font options used
font_options_header: Font_Options
font_options_bold: Font_Options

// works in visible line space!
// gets used in key combs
task_head := 0
task_tail := 0
old_task_head := 0
old_task_tail := 0
tasks_visible: [dynamic]^Task
task_multi_context: bool

// shadowing
TASK_SHADOW_ALPHA :: 0.5
task_shadow_alpha: f32

// drag state
drag_list: [dynamic]^Task
drag_running: bool
drag_index_at: int
drag_goals: [3][2]f32
drag_rect_lerp: RectF = RECT_LERP_INIT
drag_circle: bool
drag_circle_pos: [2]int
DRAG_CIRCLE :: 30

// dirty file
dirty := 0
dirty_saved := 0

// bookmark data
bookmark_index := -1
bookmarks: [dynamic]int

// line numbering
builder_line_number: strings.Builder

// global storage instead of per task/box
rendered_glyphs: [dynamic]Rendered_Glyph
rendered_glyphs_start: int
wrapped_lines: [dynamic]string

// simple split from mode_panel to search bar
Custom_Split :: struct {
	using element: Element,
	
	image_display: ^Image_Display, // fullscreen display
	vscrollbar: ^Scrollbar,
	hscrollbar: ^Scrollbar,
}

// simply write task text with indentation into a builder
task_write_text_indentation :: proc(b: ^strings.Builder, task: ^Task, indentation: int) {
	for i in 0..<indentation {
		strings.write_byte(b, '\t')
	}

	strings.write_string(b, ss_string(&task.box.ss))
	strings.write_byte(b, '\n')
}

task_head_tail_call_all :: proc(
	data: rawptr,
	call: proc(task: ^Task, data: rawptr), 
) {
	// empty
	if task_head == -1 {
		return
	}

	low, high := task_low_and_high()
	for i in low..<high + 1 {
		task := tasks_visible[i]
		call(task, data)
	}
}

// just clamp for safety here instead of everywhere
task_head_tail_clamp :: proc() {
	task_head = clamp(task_head, 0, len(tasks_visible) - 1)
	task_tail = clamp(task_tail, 0, len(tasks_visible) - 1)
}

task_head_tail_call :: proc(
	data: rawptr,
	call: proc(task: ^Task, data: rawptr), 
) {
	// empty
	if task_head == -1 || task_head == task_tail {
		return
	}

	low, high := task_low_and_high()
	for i in low..<high + 1 {
		task := tasks_visible[i]
		call(task, data)
	}
}

task_data_init :: proc() {
	keymap_init_comments()
	keymap_init(&keymap_vim_normal, 64, 256)
	keymap_init(&keymap_vim_insert, 32, 32)

	power_mode_init()

	undo_manager_init(&um_task)
	undo_manager_init(&um_search)
	undo_manager_init(&um_goto)
	undo_manager_init(&um_sidebar_tags)

	task_clear_checking = make(map[^Task]u8, 128)
	tasks_visible = make([dynamic]^Task, 0, 128)
	task_move_stack = make([]^Task, 256)
	bookmarks = make([dynamic]int, 0, 32)
	search_state_init()

	font_options_header = {
		font = font_bold,
		size = 30,
	}
	font_options_bold = {
		font = font_bold,
		size = DEFAULT_FONT_SIZE + 5,
	}

	strings.builder_init(&copy_text_data, 0, mem.Kilobyte * 10)
	copy_task_data = make([dynamic]Copy_Task, 0, 128)

	drag_list = make([dynamic]^Task, 0, 64)

	pomodoro_init()
	spell_check_init()

	strings.builder_init(&builder_line_number, 0, 32)

	rendered_glyphs = make([dynamic]Rendered_Glyph, 0, 1028 * 2)
	wrapped_lines = make([dynamic]string, 0, 1028)
}

last_save_set :: proc(next: string = "") {
	if last_save_location != "" {
		delete(last_save_location)
	}
	
	last_save_location = strings.clone(next)
}

task_data_destroy :: proc() {
	keymap_destroy_comments()
	keymap_destroy(&keymap_vim_normal)
	keymap_destroy(&keymap_vim_insert)

	delete(task_clear_checking)
	delete(task_move_stack)

	power_mode_destroy()
	pomodoro_destroy()
	search_state_destroy()
	delete(tasks_visible)
	delete(bookmarks)
	delete(copy_text_data.buf)
	delete(copy_task_data)
	delete(drag_list)
	delete(last_save_location)

	undo_manager_destroy(&um_task)
	undo_manager_destroy(&um_search)
	undo_manager_destroy(&um_goto)
	undo_manager_destroy(&um_sidebar_tags)

	spell_check_destroy()

	delete(builder_line_number.buf)
	delete(rendered_glyphs)
	delete(wrapped_lines)
}

// reset copy data
copy_reset :: proc() {
	strings.builder_reset(&copy_text_data)
	clear(&copy_task_data)
}

// just push text, e.g. from archive
copy_push_empty :: proc(text: string) {
	text_byte_start := len(copy_text_data.buf)
	strings.write_string(&copy_text_data, text)
	text_byte_end := len(copy_text_data.buf)

	// copy crucial info of task
	append(&copy_task_data, Copy_Task {
		text_byte_start = u32(text_byte_start),
		text_byte_end = u32(text_byte_end),
	})
}

// push a task to copy list
copy_push_task :: proc(task: ^Task) {
	// NOTE works with utf8 :) copies task text
	text_byte_start := len(copy_text_data.buf)
	strings.write_string(&copy_text_data, ss_string(&task.box.ss))
	text_byte_end := len(copy_text_data.buf)

	// copy crucial info of task
	append(&copy_task_data, Copy_Task {
		u32(text_byte_start),
		u32(text_byte_end),
		u8(task.indentation),
		task.state,
		task.tags,
		task.folded,
		task_bookmark_is_valid(task),
		task_time_date_is_valid(task) ? task.time_date.stamp : {},
		task.image_display == nil ? nil : task.image_display.img,
	})
}

copy_empty :: proc() -> bool {
	return len(copy_task_data) == 0
}

copy_paste_at :: proc(
	manager: ^Undo_Manager, 
	real_index: int, 
	indentation: int,
) {
	full_text := strings.to_string(copy_text_data)
	index_at := real_index

	// find lowest indentation
	lowest_indentation := 255
	for t, i in copy_task_data {
		lowest_indentation = min(lowest_indentation, int(t.indentation))
	}

	// copy into index range
	for t, i in copy_task_data {
		text := full_text[t.text_byte_start:t.text_byte_end]
		relative_indentation := indentation + int(t.indentation) - lowest_indentation
		
		task := task_push_undoable(manager, relative_indentation, text, index_at + i)
		task.folded = t.folded
		task.state = t.state
		task_set_bookmark(task, t.bookmarked)
		task.tags = t.tags

		if t.timestamp != {} {
			task_set_time_date(task)
			task.time_date.stamp = t.timestamp
		}

		if t.stored_image != nil {
			task_set_img(task, t.stored_image)
		}
	}
}

bookmark_nearest_index :: proc(backward: bool) -> int {
	// on reset set to closest from current
	if task_head != -1 {
		// look for anything higher than the current index
		visible_index := tasks_visible[task_head].visible_index
		found: bool

		if backward {
			// backward
			for i := len(bookmarks) - 1; i >= 0; i -= 1 {
				index := bookmarks[i]

				if index < visible_index {
					return i
				}
			}
		} else {
			// forward
			for index, i in bookmarks {
				if index > visible_index {
					return i
				}
			}
		}
	}	

	return -1
}

// advance bookmark or jump to closest on reset
bookmark_advance :: proc(backward: bool) {
	if task_head == -1 {
		return
	}

	if bookmark_index == -1 {
		nearest := bookmark_nearest_index(backward)
		
		if nearest != -1 {
			bookmark_index = nearest
			return
		}
	}

	// just normally set
	range_advance_index(&bookmark_index, len(bookmarks) - 1, backward)
}

// advance index in a looping fashion, backwards can be easily used
range_advance_index :: proc(index: ^int, high: int, backwards := false) {
	if backwards {
		if index^ > 0 {
			index^ -= 1
		} else {
			index^ = high
		}
	} else {
		if index^ < high {
			index^ += 1
		} else {
			index^ = 0
		}
	}
}

Task_State :: enum u8 {
	Normal,
	Done,
	Canceled,
} 

// Bare data to copy task from
Copy_Task :: struct #packed {
	text_byte_start: u32, // offset into text_list
	text_byte_end: u32, // offset into text_list
	indentation: u8,
	state: Task_State,
	tags: u8,
	folded: bool,
	bookmarked: bool,
	timestamp: time.Time,
	stored_image: ^Stored_Image,
}

Task :: struct {
	using element: Element,
	
	// NOTE set in update
	index: int, 
	visible_index: int, 
	visible_parent: ^Task,
	visible: bool,

	// elements
	box: ^Task_Box,
	button_fold: ^Icon_Button,
	
	// optional elements
	button_bookmark: ^Element,
	button_link: ^Button,
	image_display: ^Image_Display,
	seperator: ^Task_Seperator,
	time_date: ^Time_Date,

	// state
	indentation: int,
	indentation_smooth: f32,
	indentation_animating: bool,
	state: Task_State,
	state_unit: f32,
	state_last: Task_State,
	
	// tags state
	tags: u8,
	tags_rect: [8]RectI,
	tag_hovered: int,

	// top animation
	top_offset: f32, 
	top_old: int,
	top_animation_start: bool,
	top_animating: bool,

	folded: bool,
	has_children: bool,
	children_count: u16, // exclusive count
	state_count: [Task_State]int,

	// visible kanban outline - used for bounds check by kanban 
	kanban_rect: RectI,
	progress_animation: [Task_State]f32,
}

Mode :: enum {
	List,
	Kanban,
	// Agenda,
}

// element to custom layout based on internal mode
Mode_Panel :: struct {
	using element: Element,
	mode: Mode,
	cam: [Mode]Pan_Camera,
	zoom_highlight: f32,
}

// scoped version so you dont forget to call
@(deferred_out=mode_panel_manager_end)
mode_panel_manager_scoped :: #force_inline proc() -> ^Undo_Manager {
	return mode_panel_manager_begin()
}

mode_panel_manager_begin :: #force_inline proc() -> ^Undo_Manager {
	return &um_task
}

mode_panel_manager_end :: #force_inline proc(manager: ^Undo_Manager) {
	undo_group_end(manager)
}

mode_panel_zoom_animate :: proc() {
	if mode_panel != nil {
		mode_panel.zoom_highlight = 2
		window_animate(window_main, &mode_panel.zoom_highlight, 0, .Quadratic_Out, time.Second)
	} 
	
	power_mode_clear()
}

// line has selection
task_has_selection :: #force_inline proc() -> bool {
	return task_head != task_tail
}

// low and high from selection
task_low_and_high :: #force_inline proc() -> (low, high: int) {
	low = min(task_head, task_tail)
	high = max(task_head, task_tail)
	return
}

task_xy_to_real :: proc(low, high: int) -> (x, y: int) #no_bounds_check {
	return tasks_visible[low].index, tasks_visible[high].index
}

// returns index / indentation if possible from head
task_head_safe_index_indentation :: proc(init := -1) -> (index, indentation: int) {
	index = init
	if task_head != -1 {
		task := tasks_visible[task_head]
		index = task.index
		indentation = task.indentation
	}
	return
}

// step through real values from hidden

Task_Iter :: struct {
	// real
	offset: int,
	index: int,
	range: int,

	// visual
	low, high: int,
}

ti_init :: proc() -> (res: Task_Iter) {
	res.low, res.high = task_low_and_high()
	a := tasks_visible[res.low].index
	b := tasks_visible[res.high].index
	res.offset = a
	res.range = b - a + 1
	return
}

ti_init_children_included :: proc() -> (res: Task_Iter) {
	res.low, res.high = task_low_and_high()
	a := tasks_visible[res.low]
	aa := a.index
	aa_count := task_children_count(a)
	
	// need to jump further till the children end
	b := cast(^Task) mode_panel.children[aa + aa_count + 1]
	bb := b.index
	bb_count := task_children_count(b)

	res.offset = aa
	res.range = bb_count + aa_count + 2
	return
}

ti_step :: proc(ti: ^Task_Iter) -> (res: ^Task, index: int, ok: bool) {
	if ti.index < ti.range && ti.offset + ti.index < len(mode_panel.children) {
		res = cast(^Task) mode_panel.children[ti.offset + ti.index]
		index = ti.offset + ti.index
		ti.index += 1
		ok = true
	}

	return
}

task_head_tail_check_begin :: proc(shift: bool) ->  bool {
	if !shift && task_head != task_tail {
		task_tail = task_head
		return false
	}

	return true
}

// set line selection to head when no shift
task_head_tail_check_end :: #force_inline proc(shift: bool) {
	if !shift {
		task_tail = task_head
	}
}

bookmark_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	#partial switch msg {
		case .Paint_Recursive: {
			render_rect(element.window.target, element.bounds, theme.text_default, ROUNDNESS)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Clicked: {
			element_hide_toggle(element)
		}
	}

	return 0
}

task_image_display_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	display := cast(^Image_Display) element

	#partial switch msg {
		case .Right_Down: {
			display.img = nil
			display.clip = {}
			display.bounds = {}
			element_repaint(display)
		}

		case .Clicked: {
			custom_split.image_display.img = display.img
			element_repaint(display)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}
	}

	return 0
}

// set img or init display element
task_set_img :: proc(task: ^Task, handle: ^Stored_Image) {
	if task.image_display == nil {
		task.image_display = image_display_init(task, {}, handle, task_image_display_message, context.allocator)
	} else {
		task.image_display.img = handle
	}
}

task_button_fold_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element
	task := cast(^Task) button.parent

	#partial switch msg {
		case .Clicked: {
			manager := mode_panel_manager_scoped()
			task_head_tail_push(manager)
			item := Undo_Item_Bool_Toggle { &task.folded }
			undo_bool_toggle(manager, &item)

			task_head = task.visible_index
			task_tail = task.visible_index

			element_message(element, .Update)
		}

		case .Paint_Recursive: {
			// NOTE only change
			button.icon = task.folded ? .Simple_Right : .Simple_Down

			pressed := button.window.pressed == button
			hovered := button.window.hovered == button
			target := button.window.target

			text_color := hovered || pressed ? theme.text_default : theme.text_blank

			if element_message(button, .Button_Highlight, 0, &text_color) == 1 {
				rect := button.bounds
				rect.r = rect.l + int(4 * TASK_SCALE)
				render_rect(target, rect, text_color, 0)
			}

			if hovered || pressed {
				render_rect_outline(target, button.bounds, text_color)
				render_hovered_highlight(target, button.bounds)
			}

			fcs_icon(TASK_SCALE)
			fcs_ahv()
			fcs_color(text_color)
			render_icon_rect(target, button.bounds, button.icon)
		}

		case .Get_Width: {
			w := icon_width(button.icon, TASK_SCALE)
			return int(w + TEXT_MARGIN_HORIZONTAL * TASK_SCALE)
		}

		case .Get_Height: {
			return task_font_size(element) + int(TEXT_MARGIN_VERTICAL * TASK_SCALE)
		}
	}

	return 0
}

// button with link text
task_button_link_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element

	#partial switch msg {
		case .Left_Up: {
			text := strings.to_string(button.builder)

			b := &gs.cstring_builder
			strings.builder_reset(b)

			when ODIN_OS == .Linux {
				strings.write_string(b, "xdg-open")
			} else when ODIN_OS == .Windows {
				strings.write_string(b, "start")
			}

			strings.write_byte(b, ' ')
			strings.write_string(b, text)
			strings.write_byte(b, '\x00')
			libc.system(cstring(raw_data(b.buf)))
			
			element_repaint(element)
		}

		case .Right_Up: {
			strings.builder_reset(&button.builder)
			element_repaint(element)
		}

		case .Get_Width: {
			fcs_task(element)
			text := strings.to_string(button.builder)
			width := max(int(50 * TASK_SCALE), string_width(text) + int(TEXT_MARGIN_HORIZONTAL * TASK_SCALE))
			return int(width)
		}

		case .Get_Height: {
			return task_font_size(element) + int(TEXT_MARGIN_VERTICAL * TASK_SCALE)
		}

		case .Paint_Recursive: {
			target := element.window.target
			pressed := element.window.pressed == element
			hovered := element.window.hovered == element
			color := theme.text_link

			fcs_color(color)
			fcs_task(button)
			fcs_ahv(.Left, .Middle)
			text := strings.to_string(button.builder)
			text_render := text

			// cut of string text
			if mode_panel.mode == .Kanban {
				task := cast(^Task) element.parent
				actual_width := rect_width(task.bounds) - 30
				iter := fontstash.text_iter_init(&gs.fc, text)
				q: fontstash.Quad

				for fontstash.text_iter_step(&gs.fc, &iter, &q) {
					if actual_width < int(iter.x) {
						text_render = fmt.tprintf("%s...", text[:iter.byte_offset])
						break
					}
				}
			}

			xadv := render_string_rect(target, element.bounds, text_render)
			if hovered || pressed {
				rect := element.bounds
				rect.r = int(xadv)
				render_underline(target, rect, color)
			}

			return 1
		}
	}

	return 0
}

// set link text or init link button
task_set_link :: proc(task: ^Task, link: string) {
	if task.button_link == nil {
		task.button_link = button_init(task, {}, link, task_button_link_message, context.allocator)
	} else {
		b := &task.button_link.builder
		strings.builder_reset(b)
		strings.write_string(b, link)
	}
}

// valid link 
task_link_is_valid :: proc(task: ^Task) -> bool {
	return task.button_link != nil && (.Hide not_in task.button_link.flags) && len(task.button_link.builder.buf) > 0
}

task_set_time_date :: proc(task: ^Task) {
	if task.time_date == nil {
		task.time_date = time_date_init(task, {}, true)
	} else {
		if .Hide in task.time_date.flags {
			task.time_date.spawn_particles = true
			excl(&task.time_date.flags, Element_Flag.Hide)
		} else {
			if !time_date_update(task.time_date) {
				task.time_date.spawn_particles = true
			} else {
				incl(&task.time_date.flags, Element_Flag.Hide)
			}
		}
	}
}

task_time_date_is_valid :: proc(task: ^Task) -> bool {
	return task.time_date != nil && (.Hide not_in task.time_date.flags)
}

// init bookmark if not yet
task_bookmark_init_check :: proc(task: ^Task) {
	if task.button_bookmark == nil {
		task.button_bookmark = element_init(Element, task, {}, bookmark_message, context.allocator)
	} 
}

// init the bookmark and set hide flag
task_set_bookmark :: proc(task: ^Task, show: bool) {
	task_bookmark_init_check(task)
	element_hide(task.button_bookmark, !show)
}

// check validity
task_bookmark_is_valid :: proc(task: ^Task) -> bool {
	return task.button_bookmark != nil && (.Hide not_in task.button_bookmark.flags)
}

// TODO speedup or cache?
task_total_bounds :: proc() -> (bounds: RectI) {
	bounds = RECT_INF
	for task in tasks_visible {
		rect_inf_push(&bounds, task.bounds)
	}
	return
}

Task_Seperator :: struct {
	using element: Element,
}

task_seperator_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	sep := cast(^Task_Seperator) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			rect := element.bounds
			line_width := int(max(2 * TASK_SCALE, 2))
			rect.t += int(rect_heightf_halfed(rect))
			rect.b = rect.t + line_width

			render_rect(target, rect, theme.text_default, ROUNDNESS)
		}

		case .Get_Cursor: {
			return int(Cursor.Hand)
		}

		case .Right_Up, .Left_Up: {
			task := cast(^Task) sep.parent
			task_set_seperator(task, false)
			element_repaint(task)
			// fmt.eprintln("right")
		}
	}

	return 0
}

task_set_seperator :: proc(task: ^Task, show: bool) {
	if task.seperator == nil {
		task.seperator = element_init(Task_Seperator, task, {}, task_seperator_message, context.allocator)
	} 

	element_hide(task.seperator, !show)
}

task_seperator_is_valid :: proc(task: ^Task) -> bool {
	return task.seperator != nil && (.Hide not_in task.seperator.flags)
}

// raw creationg of a task
// NOTE: need to set the parent afterward!
task_init :: proc(
	indentation: int,
	text: string,
) -> (res: ^Task) { 
	allocator := context.allocator
	res = new(Task, allocator)
	element := cast(^Element) res
	element.message_class = task_message
	element.allocator = allocator

	// just assign parent already
	parent := mode_panel	
	element.window = parent.window
	element.parent = parent

	// insert task results
	res.indentation = indentation
	res.indentation_smooth = f32(indentation)
	
	// TODO find better way to change scaling for elements in general?
	// this is pretty much duplicate of normal icon rendering
	res.button_fold = icon_button_init(res, {}, .Simple_Down, task_button_fold_message, allocator)

	res.box = task_box_init(res, {}, text, allocator)
	res.box.message_user = task_box_message_custom

	return
}

// push line element to panel middle with indentation
task_push :: proc(
	indentation: int, 
	text := "", 
	index_at := -1,
) -> (res: ^Task) {
	res = task_init(indentation, text)

	parent := res.parent
	if index_at == -1 || index_at == len(parent.children) {
		append(&parent.children, res)
	} else {
		inject_at(&parent.children, index_at, res)
	}	

	return
}

// insert a task undoable to a region
task_insert_at :: proc(manager: ^Undo_Manager, index_at: int, res: ^Task) {
	if index_at == -1 || index_at == len(mode_panel.children) {
		item := Undo_Item_Task_Append { res }
		undo_task_append(manager, &item)
	} else {
		item := Undo_Item_Task_Insert_At { index_at, res }
		undo_task_insert_at(manager, &item)
	}	
}

// push line element to panel middle with indentation
task_push_undoable :: proc(
	manager: ^Undo_Manager,
	indentation: int, 
	text := "", 
	index_at := -1,
) -> (res: ^Task) {
	res = task_init(indentation, text)
	task_insert_at(manager, index_at, res)
	return
}

// format to lines or append a single line only
task_box_format_to_lines :: proc(box: ^Task_Box, width: int) {
	fcs_task(box)
	fcs_ahv(.Left, .Top)
	wrapped_lines_push(ss_string(&box.ss), max(f32(width), 200), &box.wrapped_lines)
}

// iter through visible children
task_all_children_iter :: proc(
	indentation: int,
	index: ^int,
) -> (res: ^Task, ok: bool) {
	if index^ > len(mode_panel.children) - 1 {
		return
	}

	res = cast(^Task) mode_panel.children[index^]
	ok = indentation <= res.indentation
	index^ += 1
	return
}

// iter through visible children
task_visible_children_iter :: proc(
	indentation: int,
	index: ^int,
) -> (res: ^Task, ok: bool) {
	if index^ > len(tasks_visible) - 1 {
		return
	}

	res = tasks_visible[index^]
	ok = indentation <= res.indentation
	index^ += 1
	return
}

// init panel with data
mode_panel_init :: proc(
	parent: ^Element, 
	flags: Element_Flags,
	allocator := context.allocator,
) -> (res: ^Mode_Panel) {
	res = element_init(Mode_Panel, parent, flags, mode_panel_message, allocator)

	cam_init(&res.cam[.List], 25, 50)
	cam_init(&res.cam[.Kanban], 25, 50)

	return
}

mode_panel_draw_verticals :: proc(target: ^Render_Target) {
	if task_head < 1 {
		return
	}

	tab := int(visuals_tab() * TAB_WIDTH * TASK_SCALE)
	p := tasks_visible[task_head]
	color := theme.text_default

	for p != nil {
		if p.visible_parent != nil {
			index := p.visible_parent.visible_index + 1
			bound_rect: RectI

			// TODO use rect_inf
			for child in task_visible_children_iter(p.indentation, &index) {
				rect := child.bounds

				if bound_rect == {} {
					bound_rect = rect
				} else {
					bound_rect = rect_bounding(bound_rect, rect)
				}
			}

			bound_rect.l -= tab
			bound_rect.r = bound_rect.l + int(max(2 * TASK_SCALE, 2))
			render_rect(target, bound_rect, color, 0)

			if color.a == 255 {
				color.a = 100
			}
		}

		p = p.visible_parent
	}
}

// set has children, index, and visible parent per each task
task_set_children_info :: proc() {
	// reset
	for child, i in mode_panel.children {
		task := cast(^Task) child
		task.index = i
		task.has_children = false
		task.visible_parent = nil
	}

	// simple check for indentation
	for i := 0; i < len(mode_panel.children) - 1; i += 1 {
		a := cast(^Task) mode_panel.children[i]
		b := cast(^Task) mode_panel.children[i + 1]

		if a.indentation < b.indentation {
			a.has_children = true
		}
	}

	// dumb set visible parent to everything coming after
	// each upcoming has_children will set correctly
	for i in 0..<len(mode_panel.children) {
		a := cast(^Task) mode_panel.children[i]

		if a.has_children {
			for j in i + 1..<len(mode_panel.children) {
				b := cast(^Task) mode_panel.children[j]

				if a.indentation < b.indentation {
					b.visible_parent = a
				} else {
					break
				}
			}
		}
	}
}

// set visible flags on task based on folding
task_set_visible_tasks :: proc() {
	clear(&tasks_visible)
	manager := mode_panel_manager_begin()

	// set visible lines based on fold of parents
	for child in mode_panel.children {
		task := cast(^Task) child
		p := task.visible_parent
		task.visible = true

		// unset folded 
		if !task.has_children && task.folded {
			item := Undo_Item_U8_Set {
				cast(^u8) (&task.folded),
				0,
			}

			// continue last undo because this happens manually
			undo_group_continue(manager)
			undo_u8_set(manager, &item)
			undo_group_end(manager)
		}

		// recurse up 
		for p != nil {
			if p.folded {
				task.visible = false
			}

			p = p.visible_parent
		}
		
		// just update icon & hide each
		if task.visible {
			task.visible_index = len(tasks_visible)
			append(&tasks_visible, task)
		}
	}
}

// automatically set task state of parents based on children counts
// manager = nil will not push changes to undo
task_check_parent_states :: proc(manager: ^Undo_Manager) {
	// reset all counts
	for i in 0..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]
		if task.has_children {
			task.state_count = {}
			task.children_count = 0
		}
	}

	changed_any: bool

	if manager != nil {
		undo_group_continue(manager)
	}

	// count up states
	task_count: int
	for i := len(mode_panel.children) - 1; i >= 0; i -= 1 {
		task := cast(^Task) mode_panel.children[i]

		// when has children - set state based on counted result
		if task.has_children {
			if task.state_count[.Normal] == 0 {
				goal: Task_State = task.state_count[.Done] >= task.state_count[.Canceled] ? .Done : .Canceled
				
				// set parent
				if task.state != goal {
					task_set_state_undoable(manager, task, goal, task_count)
					changed_any = true
					task_count += 1

					color: Color = pm_particle_colored() ? {} : theme_task_text(task.state)
					power_mode_spawn_rect(task.bounds, 50, color)
				}
			} else if task.state != .Normal {
				task_set_state_undoable(manager, task, .Normal, task_count)
				task_count += 1
				changed_any = true
			}
		}

		// count parent up based on this state		
		if task.visible_parent != nil {
			task.visible_parent.state_count[task.state] += 1
			task.visible_parent.children_count += 1
		}
	}	

	if manager != nil {
		undo_group_end(manager)
	}
}

// in real indicess
task_children_count :: proc(parent: ^Task) -> (count: int) {
	for i in parent.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation <= parent.indentation {
			break
		}

		count += 1
	}

	return
}

// in real indicess
task_children_range :: proc(parent: ^Task) -> (low, high: int) {
	low = min(parent.index + 1, len(mode_panel.children) - 1)
	high = -1

	for i in parent.index + 1..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]

		if task.indentation <= parent.indentation {
			break
		}

		high = i
	}

	return
}

//////////////////////////////////////////////
// messages
//////////////////////////////////////////////

tasks_eliminate_wanted_clear_tasks :: proc(panel: ^Mode_Panel) {
	// eliminate tasks set up for manual clearing
	for i in 0..<len(panel.children) {
		task := cast(^Task) panel.children[i]
		if task in task_clear_checking {
			delete_key(&task_clear_checking, task)
		}
	}
}

tasks_clear_left_over :: proc() {
	for key, value in task_clear_checking {
		element_destroy_and_deallocate(key)
	}
	clear(&task_clear_checking)
}
	
mode_panel_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	panel := cast(^Mode_Panel) element
	cam := &panel.cam[panel.mode]

	#partial switch msg {
		case .Destroy: {
			tasks_eliminate_wanted_clear_tasks(panel)
		}

		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp

			if image_display_has_content_now(custom_split.image_display) {
				child := custom_split.image_display

				if (.Hide not_in child.flags) && rect_contains(child.bounds, p.x, p.y) {
					p.res = child
					return 1
				}
			}

			for i := len(element.children) - 1; i >= 0; i -= 1 {
				task := cast(^Task) element.children[i]

				if !task.visible {
					continue
				}

				if element_message(task, .Find_By_Point_Recursive, 0, dp) == 1 {
					return 1
				}
			}

			return 1
		}

		// NOTE custom layout based on mode
		case .Layout: {
			bounds := element.bounds

			cam_update_screenshake(cam, power_mode_running())
			camx, camy := cam_offsets(cam)
			bounds.l += int(camx)
			bounds.r += int(camx)
			bounds.t += int(camy)
			bounds.b += int(camy)
			gap_vertical_scaled := int(visuals_gap_vertical() * TASK_SCALE)
			gap_horizontal_scaled := int(visuals_gap_horizontal() * TASK_SCALE)
			kanban_width_scaled := int(visuals_kanban_width() * TASK_SCALE)
			tab_scaled := int(visuals_tab() * TAB_WIDTH * TASK_SCALE)
			task_min_width := int(max(300, (rect_widthf(mode_panel.bounds) - 50) * TASK_SCALE))
			margin_scaled := int(visuals_task_margin() * TASK_SCALE)

			switch panel.mode {
				case .List: {
					cut := bounds

					for child in element.children {
						task := cast(^Task) child
						
						if !task.visible {
							continue
						}

						pseudo_rect := cut
						pseudo_rect.l += int(task.indentation) * tab_scaled
						pseudo_rect.r = pseudo_rect.l + task_min_width
						box_rect := task_layout(task, pseudo_rect, false, tab_scaled, margin_scaled)
						task_box_format_to_lines(task.box, rect_width(box_rect))

						h := element_message(task, .Get_Height)
						r := rect_cut_top(&cut, h)
						r.l = r.l + int(task.indentation_smooth * f32(tab_scaled))
						r.r = r.l + task_min_width
						element_move(task, r)

						cut.t += gap_vertical_scaled
					}
				}

				case .Kanban: {
					cut := bounds

					// cutoff a rect left
					kanban_current: RectI
					kanban_children_count: int
					kanban_children_start: int
					root: ^Task

					for child, i in element.children {
						task := cast(^Task) child
						
						if !task.visible {
							continue
						}

						if task.indentation == 0 {
							// get max indentations till same line is found
							max_indentations: int
							kanban_children_start = i
							kanban_children_count = 1

							for j in i + 1..<len(element.children) {
								other := cast(^Task) element.children[j]
								max_indentations = max(max_indentations, other.indentation)
								
								if other.indentation == 0 {
									break
								} else {
									kanban_children_count += 1
								}
							}

							kanban_width := kanban_width_scaled
							// TODO check this
							kanban_width += int(f32(max_indentations) * visuals_tab() * TAB_WIDTH * TASK_SCALE)
							kanban_current = rect_cut_left(&cut, kanban_width)
							task.kanban_rect = kanban_current
							cut.l += gap_horizontal_scaled
						}

						// pseudo layout for correct witdth
						pseudo_rect := kanban_current
						box_rect := task_layout(task, pseudo_rect, false, tab_scaled, margin_scaled)
						box_rect.l += int(f32(task.indentation) * visuals_tab() * TAB_WIDTH * TASK_SCALE)
						task_box_format_to_lines(task.box, rect_width(box_rect))

						h := element_message(task, .Get_Height)
						r := rect_cut_top(&kanban_current, h)
						r.l += int(task.indentation_smooth * f32(tab_scaled))
						element_move(task, r)

						if i - kanban_children_start < kanban_children_count - 1 {
							kanban_current.t += gap_vertical_scaled
						}
					}
				}
			}

			// update caret
			if task_head != -1 {
				task := tasks_visible[task_head]
				scaled_size := fcs_task(task)
				x := task.box.bounds.l
				y := task.box.bounds.t
				caret_rect = box_layout_caret(task.box, scaled_size, TASK_SCALE, x, y,)
				power_mode_check_spawn()
			}

			// check on change
			if task_head != -1 {
				mode_panel_cam_bounds_check_x(caret_rect.r, caret_rect.r, false, true)
				mode_panel_cam_bounds_check_y(caret_rect.t, caret_rect.b, true)
			}
		}

		case .Paint_Recursive: {
			target := element.window.target 

			bounds := element.bounds
			render_rect(target, bounds, theme.background[0], 0)

			if task_head == -1 {
				fcs_ahv()
				fcs_font(font_regular)
				fcs_color(theme.text_default)
				render_string_rect(target, mode_panel.bounds, "press \"return\" to insert a new task")
				// return 0
			}

			task_highlight_render(target, false)

			camx, camy := cam_offsets(cam)
			bounds.l -= int(camx)
			bounds.r -= int(camx)
			bounds.t -= int(camy)
			bounds.b -= int(camy)

			mode_panel_draw_verticals(target)

			// custom draw loop!
			for child in element.children {
				task := cast(^Task) child

				if !task.visible {
					continue
				}

				render_element_clipped(target, child)
			}

			search_draw_highlights(target, panel)

			// word error highlight
			when !PRESENTATION_MODE {
				if options_spell_checking() && task_head != -1 && task_head == task_tail {
					render_push_clip(target, panel.clip)
					task := tasks_visible[task_head] 
					spell_check_render_missing_words(target, task)
				}
			}

			// TODO looks shitty when swapping
			// shadow highlight for non selection
			if task_head != -1 && task_shadow_alpha != 0 {
				render_push_clip(target, panel.clip)
				low, high := task_low_and_high()
				color := color_alpha(theme.background[0], task_shadow_alpha)
				
				for t in tasks_visible {
					if !(low <= t.visible_index && t.visible_index <= high) {
						rect := t.bounds
						render_rect(target, rect, color)
					}
				}
			}

			// task outlines
			if task_head != -1 {
				low, high := task_low_and_high()
				render_push_clip(target, mode_panel.clip)
				for i in low..<high + 1 {
					task := tasks_visible[i]
					rect := task.bounds
					color := task_head == i ? theme.caret : theme.text_default
					render_rect_outline(target, rect, color)
				}
			}

			when !PRESENTATION_MODE {
				task_render_progressbars(target)
			}

			// drag visualizing circle
			if !drag_running && drag_circle {
				render_push_clip(target, panel.clip)
				circle_size := DRAG_CIRCLE * TASK_SCALE
				x := f32(drag_circle_pos.x)
				y := f32(drag_circle_pos.y)
				render_circle_outline(target, x, y, circle_size, 2, theme.text_default, true)
				diff_x := abs(drag_circle_pos.x - element.window.cursor_x)
				diff_y := abs(drag_circle_pos.y - element.window.cursor_y)
				diff := max(diff_x, diff_y)
				render_circle(target, x, y, f32(diff), theme.text_bad, true)
			}

			// drag visualizer line
			if task_head != -1 && drag_running && drag_index_at != -1 {
				render_push_clip(target, panel.clip)
				
				drag_task := tasks_visible[drag_index_at]
				bounds := drag_task.bounds
				margin := int(4 * TASK_SCALE)
				bounds.t = bounds.b - margin
				rect_lerp(&drag_rect_lerp, bounds, 0.5)
				bounds = rect_ftoi(drag_rect_lerp)

				// inner
				{
					b := bounds
					b.t += margin / 2
					b.b += margin / 2
					render_rect(target, b, theme.text_default, ROUNDNESS)
				}

				bounds.b += margin
				bounds.l -= margin / 2
				bounds.r += margin / 2
				render_rect(target, bounds, color_alpha(theme.text_default, .5), ROUNDNESS)
			}

			// render dragged tasks
			if drag_running {
				render_push_clip(target, panel.clip)

				// NOTE also have to change init positioning call :)
				width := int(TASK_DRAG_SIZE * TASK_SCALE)
				height := int(TASK_DRAG_SIZE * TASK_SCALE)
				x := element.window.cursor_x - int(f32(width) / 2)
				y := element.window.cursor_y - int(f32(height) / 2)

				for i := len(drag_goals) - 1; i >= 0; i -= 1 {
					pos := &drag_goals[i]
					state := true
					goal_x := x + int(f32(i) * 5 * TASK_SCALE)
					goal_y := y + int(f32(i) * 5 * TASK_SCALE)
					animate_to(&state, &pos.x, f32(goal_x), 1 - f32(i) * 0.1)
					animate_to(&state, &pos.y, f32(goal_y), 1 - f32(i) * 0.1)
					r := rect_wh(int(pos.x), int(pos.y), width, height)
					render_texture_from_kind(target, .Drag, r, theme_panel(.Front))
				}
			}

			if power_mode_running() {
				render_push_clip(target, panel.clip)
				power_mode_update()
				power_mode_render(target)
			}

			// bookmarks_render_connections(target, panel.clip)
			render_line_highlights(target, panel.clip)
			render_zoom_highlight(target, panel.clip)
			time_date_render_highlight_on_pressed(target, panel.clip)

			// draw the fullscreen image on top
			if image_display_has_content_now(custom_split.image_display) {
				render_push_clip(target, panel.clip)
				element_message(custom_split.image_display, .Paint_Recursive)
			}

			return 1
		}

		case .Middle_Down: {
			cam.start_x = int(cam.offset_x)
			cam.start_y = int(cam.offset_y)
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^

			if element.window.pressed_button == MOUSE_MIDDLE {
				diff_x := element.window.cursor_x - mouse.x
				diff_y := element.window.cursor_y - mouse.y

				cam_set_x(cam, cam.start_x + diff_x)
				cam_set_y(cam, cam.start_y + diff_y)
				cam.freehand = true

				window_set_cursor(element.window, .Crosshair)
				element_repaint(element)
				return 1
			}
		}

		case .Right_Up: {
			drag_circle = false
			
			if task_head == -1 {
				if task_dragging_end() {
					return 1
				}
			}

			if task_head != task_tail && task_head != -1 {
				task_context_menu_spawn(nil)
				return 1
			}

			mode_panel_context_menu_spawn()
		}

		case .Left_Up: {
			if element_hide(panel_search, true) {
				return 1
			}

			if task_head != task_tail {
				task_tail = task_head
				return 1
			}
		}

		case .Mouse_Scroll_Y: {
			if element.window.ctrl {
				res := TASK_SCALE + f32(di) * 0.05
				TASK_SCALE = clamp(res, 0.1, 10)
				fontstash.reset(&gs.fc)
				// fmt.eprintln("TASK SCALE", TASK_SCALE)

				mode_panel_zoom_animate()
			} else {
				cam_inc_y(cam, f32(di) * 20)
				cam.freehand = true
			}

			element_repaint(element)
			return 1
		}

		case .Mouse_Scroll_X: {
			if element.window.ctrl {
			} else {
				cam_inc_x(cam, f32(di) * 20)
				cam.freehand = true
			}

			element_repaint(element)
			return 1
		}

		case .Update: {
			for child in element.children {
				element_message(child, .Update, di, dp)
			}
		}

		case .Left_Down: {
			element_reset_focus(element.window)

			// add task on double click
			clicks := di % 2
			if clicks == 1 {
				if task_head != -1 {
					task := tasks_visible[task_head]
					diff_y := element.window.cursor_y - (task.bounds.t + rect_height_halfed(task.bounds))
					todool_insert_sibling(diff_y < 0 ? COMBO_SHIFT : COMBO_EMPTY)
				}
			}
		}

		case .Animate: {
			handled := false

			// drag animation and camera panning
			// NOTE clamps to the task bounds
			if drag_running {
				// just check for bounds
				x := element.window.cursor_x
				y := element.window.cursor_y
				ygoal, ydirection := cam_bounds_check_y(cam, mode_panel.bounds, y, y)
				xgoal, xdirection := cam_bounds_check_x(cam, mode_panel.bounds, x, x)
				task_bounds := task_total_bounds()

				top := task_bounds.t - mode_panel.bounds.t
				bottom := task_bounds.b - mode_panel.bounds.t

				if ydirection != 0 && 
					(ydirection == 1 && top < cam.margin_y * 2) ||
					(ydirection == -1 && bottom > mode_panel.bounds.b - cam.margin_y * 4) { 
					cam.freehand = true
					cam_inc_y(cam, f32(ygoal) * 0.1 * f32(ydirection))
				}

				// need to offset by mode panel
				left := task_bounds.l - mode_panel.bounds.l
				right := task_bounds.r - mode_panel.bounds.l

				if xdirection != 0 && 
					(xdirection == 1 && left < cam.margin_x * 2) ||
					(xdirection == -1 && right > mode_panel.bounds.r - cam.margin_x * 4) {
					cam.freehand = true
					cam_inc_x(cam, f32(xgoal) * 0.1 * f32(xdirection))
				}

				handled = true
			}

			y_handled := cam_animate(cam, false)
			handled |= y_handled

			// check y afterwards
			goal_y, direction_y := cam_bounds_check_y(cam, mode_panel.bounds, caret_rect.t, caret_rect.b)

			if cam.ay.direction != CAM_CENTER && direction_y == 0 {
				cam.ay.animating = false
			}

			x_handled := cam_animate(cam, true)
			handled |= x_handled

			// check x afterwards
			// NOTE just check this everytime due to inconsistency
			mode_panel_cam_bounds_check_x(caret_rect.l, caret_rect.r, true, true)

			// fmt.eprintln("animating!", handled, cam.offset_y, cam.offset_x)
			return int(handled)
		}
	}

	return 0
}

task_box_message_custom :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	box := cast(^Task_Box) element
	task := cast(^Task) element.parent

	#partial switch msg {
		case .Box_Text_Color: {
			color := cast(^Color) dp
			color^ = theme_task_text(task.state)

			if task.state_unit > 0 {
				a := theme_task_text(task.state_last)
				b := theme_task_text(task.state)
				color^ = color_blend_amount(a, b, task.state_unit)
			}

			return 1
		}

		case .Paint_Recursive: {
			target := element.window.target
			draw_search_results := (.Hide not_in panel_search.flags)

			x := box.bounds.l
			y := box.bounds.t

			// strike through line
			if task.state == .Canceled {
				fcs_task(task)
				state := fontstash.state_get(&gs.fc)
				font := fontstash.font_get(&gs.fc, state.font)
				isize := i16(state.size * 10)
				scaled_size := f32(isize / 10)
				offset := f32(font.ascender * 3 / 4) * scaled_size

				for line_text, line_y in box.wrapped_lines {
					text_width := string_width(line_text)
					real_y := f32(y) + f32(line_y) * scaled_size + offset

					rect := RectI {
						x,
						x + text_width,
						int(real_y),
						int(real_y) + LINE_WIDTH,
					}
					
					render_rect(target, rect, theme.text_bad, 0)
				}
			}

 			// paint selection before text
			scaled_size := fcs_task(task)
			if task_head == task_tail && task.visible_index == task_head {
				box_render_selection(target, box, x, y, theme.caret_selection)
				task_box_paint_default_selection(box, scaled_size)
				// task_box_paint_default(box)
			} else {
				task_box_paint_default(box, scaled_size)
			}

			// outline visible selected one
			if task_head == task_tail && task.visible_index == task_head {
				render_rect(target, caret_rect, theme.caret, 0)
			}

			return 1
		}

		case .Left_Down: {
			task_or_box_left_down(task, di, true)
		}

		case .Mouse_Drag: {
			mouse := (cast(^Mouse_Coordinates) dp)^

			if element.window.pressed_button == MOUSE_LEFT {
				// drag select tasks
				if element.window.shift {
					repaint: bool

					// find hovered task and set till
					for t in tasks_visible {
						if rect_contains(t.bounds, element.window.cursor_x, element.window.cursor_y) {
							if task_head != t.visible_index {
								repaint = true
							}

							task_head = t.visible_index
							break
						}
					}

					if repaint {
						element_repaint(task)
					}
				} else {
					if task_head == task_tail {
						scaled_size := fcs_task(task)
						fcs_ahv(.Left, .Top)
						element_box_mouse_selection(task.box, task.box, di, true, 0, scaled_size)
						element_repaint(task)
						return 1
					}
				}
			} else if element.window.pressed_button == MOUSE_RIGHT {
				element_repaint(element)
				drag_circle = true
				drag_circle_pos = mouse

				if task_dragging_check_start(task, mouse) {
					return 1
				}
			}

			return 0
		}

		case .Right_Up: {
			drag_circle = false

			if task_dragging_end() {
				return 1
			}

			task_context_menu_spawn(task)
		}

		case .Value_Changed: {
			dirty_push(&um_task)
		}
	}

	return 0
}

task_indentation_width :: proc(indentation: f32) -> f32 {
	return indentation * visuals_tab() * TAB_WIDTH * TASK_SCALE
}

fcs_task_tags :: proc() -> int {
	// text state
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_ahv()		
	return int(10 * TASK_SCALE)
}

// layout tags position
task_tags_layout :: proc(task: ^Task, rect: RectI) {
	field := task.tags
	rect := rect
	tag_mode := options_tag_mode()

	fcs_push()
	defer fcs_pop()

	text_margin := fcs_task_tags()
	gap := int(5 * TASK_SCALE)
	res: RectI
	cam := mode_panel_cam()
	halfed := int(DEFAULT_FONT_SIZE * TASK_SCALE * 0.5)
	// task.tags_rect = {}

	// layout tag structs and spawn particles when now ones exist
	for i in 0..<u8(8) {
		res = {}

		if field & 1 == 1 {
			text := ss_string(sb.tags.names[i])
			
			switch tag_mode {
				case TAG_SHOW_TEXT_AND_COLOR: {
					width := string_width(text)
					res = rect_cut_left(&rect, width + text_margin)
				}

				case TAG_SHOW_COLOR: {
					res = rect_cut_left(&rect, int(50 * TASK_SCALE))
				}
			}

			rect.l += gap
			
			// spawn partciles in power mode when changed
			if task.tags_rect[i] == {} {
				x := res.l
				y := res.t + halfed
				power_mode_spawn_along_text(text, f32(x + text_margin / 2), f32(y), theme.tags[i])
			}
		} 
		
		task.tags_rect[i] = res
		field >>= 1
	}
}

// manual layout call so we can predict the proper positioning
task_layout :: proc(
	task: ^Task, 
	bounds: RectI, 
	move: bool,
	tab_scaled: int,
	margin_scaled: int,
) -> RectI {
	offset_indentation := int(task.indentation_smooth * f32(tab_scaled))
	
	// manually offset the line rectangle in total while retaining parent clip
	bounds := bounds
	bounds.t += int(task.top_offset)
	bounds.b += int(task.top_offset)

	// seperator
	cut := bounds
	if task_seperator_is_valid(task) {
		rect := rect_cut_top(&cut, int(20 * TASK_SCALE))

		if move {
			element_move(task.seperator, rect)
		}
	}

	task.clip = rect_intersection(task.parent.clip, cut)
	task.bounds = cut

	// bookmark
	if task_bookmark_is_valid(task) {
		rect := rect_cut_left(&cut, int(15 * TASK_SCALE))

		if move {
			if task.button_bookmark.bounds == {} {
				x, y := rect_center(rect)
				cam := mode_panel_cam()
				cam_screenshake_reset(cam)
				power_mode_spawn_at(x, y, cam.offset_x, cam.offset_y, P_SPAWN_HIGH, theme.text_default)
			}

			element_move(task.button_bookmark, rect)
		}
	} else {
		if task.button_bookmark != nil {
			task.button_bookmark.bounds = {}
		}
	}

	// margin after bookmark
	cut = rect_margin(cut, margin_scaled)

	// image
	if image_display_has_content_soon(task.image_display) {
		top := rect_cut_top(&cut, int(IMAGE_DISPLAY_HEIGHT * TASK_SCALE))
		top.b -= int(5 * TASK_SCALE)

		if move {
			if task.image_display.bounds == {} {
				x, y := rect_center(top)
				power_mode_spawn_rect(top, 10, theme.text_default)
			}

			element_move(task.image_display, top)
		}
	} else {
		if task.image_display != nil {
			task.image_display.bounds = {}
		}
	}

	// link button
	if task_link_is_valid(task) {
		height := element_message(task.button_link, .Get_Height)
		width := element_message(task.button_link, .Get_Width)
		rect := rect_cut_bottom(&cut, height)
		rect.r = rect.l + width
		
		if move {
			element_move(task.button_link, rect)
		}
	} else {
		if task.button_link != nil {
			task.button_link.bounds = {}
		}
	}

	// tags place
	tag_mode := options_tag_mode()
	if tag_mode != TAG_SHOW_NONE && task.tags != 0x00 {
		rect := rect_cut_bottom(&cut, tag_mode_size(tag_mode))
		cut.b -= int(5 * TASK_SCALE)  // gap

		if move {
			task_tags_layout(task, rect)
		}
	}

	// fold button
	element_hide(task.button_fold, !task.has_children)
	if task.has_children {
		rect := rect_cut_left(&cut, int(DEFAULT_FONT_SIZE * TASK_SCALE))
		cut.l += int(5 * TASK_SCALE)

		if move {
			element_move(task.button_fold, rect)
		}
	}

	// time date
	if task_time_date_is_valid(task) {
		// width := element_message(task.time_date)
		rect := rect_cut_left(&cut, int(100 * TASK_SCALE))
		cut.l += int(5 * TASK_SCALE)

		if move {
			element_move(task.time_date, rect)
		}		
	} else {
		if task.time_date != nil {
			task.time_date.bounds = {}
		}
	}
	
	task.box.font_options = task.font_options
	if move {
		task.box.rendered_glyphs = nil
		element_move(task.box, cut)
	}

	return cut
}

tag_mode_size :: proc(tag_mode: int) -> (res: int) {
	if tag_mode == TAG_SHOW_TEXT_AND_COLOR {
		res = int(DEFAULT_FONT_SIZE * TASK_SCALE)
	} else if tag_mode == TAG_SHOW_COLOR {
		res = int(10 * TASK_SCALE)
	} 

	return
}

task_or_box_left_down :: proc(task: ^Task, clicks: int, only_box: bool) {
	// set line to the head
	shift := window_main.shift
	task_head_tail_check_begin(shift)
	task_head = task.visible_index
	task_head_tail_check_end(shift)

	if only_box {
		if task_head != task_tail {
			box_set_caret(task.box, BOX_END, nil)
		} else {
			old_tail := task.box.tail
			scaled_size := fcs_task(task)
			fcs_ahv(.Left, .Top)
			element_box_mouse_selection(task.box, task.box, clicks, false, 0, scaled_size)

			if task.window.shift && clicks == 0 {
				task.box.tail = old_tail
			}
		}
	}
}

task_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	task := cast(^Task) element
	tag_mode := options_tag_mode()
	draw_tags := tag_mode != TAG_SHOW_NONE && task.tags != 0x0

	#partial switch msg {
		case .Get_Width: {
			return int(TASK_SCALE * 200)
		}

		case .Get_Height: {
			line_size := task_font_size(element) * len(task.box.wrapped_lines)
			// line_size += int(f32(task.has_children ? DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL : 0) * TASK_SCALE)

			line_size += draw_tags ? tag_mode_size(tag_mode) + int(5 * TASK_SCALE) : 0
			line_size += image_display_has_content_soon(task.image_display) ? int(IMAGE_DISPLAY_HEIGHT * TASK_SCALE) : 0
			line_size += task_link_is_valid(task) ? element_message(task.button_link, .Get_Height) : 0
			line_size += task_seperator_is_valid(task) ? int(20 * TASK_SCALE) : 0
			margin_scaled := int(visuals_task_margin() * TASK_SCALE * 2)
			line_size += margin_scaled

			return int(line_size)
		}

		case .Layout: {
			if task.top_animation_start {
				task.top_offset = f32(task.top_old - task.bounds.t)
				task.top_animation_start = false
			}

			tab_scaled := int(visuals_tab() * TAB_WIDTH * TASK_SCALE)
			margin_scaled := int(visuals_task_margin() * TASK_SCALE)
			task_layout(task, element.bounds, true, tab_scaled, margin_scaled)
		}

		case .Paint_Recursive: {
			target := element.window.target
			rect := task.bounds

			// render panel front color
			task_color := theme_panel(task.has_children ? .Parent : .Front)
			render_rect(target, rect, task_color, ROUNDNESS)

			// draw tags at an offset
			if draw_tags {
				fcs_task_tags()
				field := task.tags

				// go through each existing tag, draw each one
				for i in 0..<u8(8) {
					if field & 1 == 1 {
						tag := sb.tags.names[i]
						tag_color := theme.tags[i]
						r := task.tags_rect[i]

						switch tag_mode {
							case TAG_SHOW_TEXT_AND_COLOR: {
								render_rect(target, r, tag_color, ROUNDNESS)
								fcs_color(color_to_bw(tag_color))
								render_string_rect(target, r, ss_string(tag))
							}

							case TAG_SHOW_COLOR: {
								render_rect(target, r, tag_color, ROUNDNESS)
							}

							case: {
								unimplemented("shouldnt get here")
							}
						}
					}

					field >>= 1
				}
			}
		}

		case .Middle_Down: {
			window_set_pressed(element.window, mode_panel, MOUSE_MIDDLE)
		}

		case .Find_By_Point_Recursive: {
			p := cast(^Find_By_Point) dp
			task.tag_hovered = -1

			// find tags first
			field := task.tags
			for i in 0..<8 {
				if field & 1 == 1 {
					r := task.tags_rect[i]
					
					if rect_contains(r, p.x, p.y) {
						p.res = task
						task.tag_hovered = i
						return 1
					}
				}

				field >>= 1
			}

			handled := element_find_by_point_custom(element, p)

			if handled == 0 {
				if rect_contains(task.bounds, p.x, p.y) {
					p.res = task
					handled = 1
				}
			}

			return handled
		}

		case .Get_Cursor: {
			return int(task.tag_hovered != -1 ? Cursor.Hand : Cursor.Arrow)
		}

		case .Left_Down: {
			if task.tag_hovered != -1 {
				bit := u8(1 << u8(task.tag_hovered))
				manager := mode_panel_manager_scoped()
				task_head_tail_push(manager)
				u8_xor_push(manager, &task.tags, bit)
			} else {
				task_or_box_left_down(task, di, false)
			}
		}

		case .Animate: {
			handled := false

			handled |= animate_to(
				&task.indentation_animating,
				&task.indentation_smooth, 
				f32(task.indentation),
				2, 
				0.01,
			)
			
			handled |= animate_to(
				&task.top_animating,
				&task.top_offset, 
				0, 
				1, 
				1,
			)

			// progress animation on parent
			if task.has_children && progressbar_show() {
				for count, i in task.state_count {
					always := true
					state := Task_State(i)
					// in case this gets run too early to avoid divide by 0
					value := f32(count) / max(f32(task.children_count), 1)

					handled |= animate_to(
						&always,
						&task.progress_animation[state],
						value,
						1,
						0.01,
					)
				}
			}

			return int(handled)
		}

		case .Update: {
			for child in element.children {
				element_message(child, msg, di, dp)
			}
		}
	}

	return 0
}

task_progress_state_set :: proc(task: ^Task) {
	for count, i in task.state_count {
		state := Task_State(i)
		value := f32(count) / f32(task.children_count)
		task.progress_animation[state] = value
	}
}

//////////////////////////////////////////////
// init calls
//////////////////////////////////////////////

goto_init :: proc(window: ^Window) {
	p := panel_floaty_init(&window.element, {})
	panel_goto = p
	p.panel.background_index = 2
	p.width = 200
	// p.height = DEFAULT_FONT_SIZE * 2 * SCALE + p.panel.margin * 2
	p.panel.flags |= {}
	p.panel.margin = 5
	p.panel.shadow = true

	p.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		floaty := cast(^Panel_Floaty) element

		#partial switch msg {
			case .Animate: {
				handled := animate_to(
					&goto_transition_animating,
					&goto_transition_unit,
					goto_transition_hide ? 1 : 0,
					4,
					0.01,
				)

				if !handled && goto_transition_hide {
					element_hide(floaty, true)
				}

				return int(handled)
			}

			case .Layout: {
				floaty.height = 0
				for c in element.children {
					floaty.height += element_message(c, .Get_Height)
				}

				w := int(f32(floaty.width) * SCALE)

				floaty.x = 
					mode_panel.bounds.l + rect_width_halfed(mode_panel.bounds) - w / 2
				
				off := int(10 * SCALE)
				floaty.y = 
					(mode_panel.bounds.t + off) + int(goto_transition_unit * -f32(floaty.height + off))

				// NOTE already taking scale into account from children
				h := floaty.height
				rect := rect_wh(floaty.x, floaty.y, w, h)
				element_move(floaty.panel, rect)
				return 1
			}

			case .Key_Combination: {
				combo := (cast(^string) dp)^
				handled := true

				switch combo {
					case "escape": {
						goto_transition_unit = 0
						goto_transition_hide = true
						goto_transition_animating = true
						element_animation_start(floaty)

						// reset to origin 
						task_head = goto_saved_task_head
						task_tail = goto_saved_task_tail
					}

					case "return": {
						goto_transition_unit = 0
						goto_transition_hide = true
						goto_transition_animating = true
						element_animation_start(floaty)
					}

					case: {
						handled = false
					}
				}

				return int(handled)
			}
		}

		return 0
	}

	label_init(p.panel, { .Label_Center, .HF }, "Goto Line")
	spacer_init(p.panel, { .HF }, 0, 10)
	box := text_box_init(p.panel, { .HF })
	box.codepoint_numbers_only = true
	box.um = &um_goto
	box.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		box := cast(^Text_Box) element

		#partial switch msg {
			case .Value_Changed: {
				value := strconv.atoi(ss_string(&box.ss))
				old_head := task_head
				old_tail := task_tail

				// NOTE kinda bad because it changes on reparse
				// if options_vim_use() {
				// 	temp := task_head
				// 	task_head = temp + value
				// 	task_tail = temp + value
				// 	fmt.eprintln(task_head, task_tail)
				// } else {
					value -= 1
					task_head = value
					task_tail = value
				// }

				if old_head != task_head && old_tail != task_tail {
					element_repaint(box)
				}
			}

			case .Update: {
				if di == UPDATE_FOCUS_LOST {
					element_hide(panel_goto, true)
					element_focus(element.window, nil)
				}
			}
		}

		return 0
	}

	element_hide(p, true)
}

custom_split_set_scrollbars :: proc(split: ^Custom_Split) {
	cam := mode_panel_cam()
	if split.vscrollbar != nil {
		split.vscrollbar.position = f32(-cam.offset_y)
	}
	if split.hscrollbar != nil {
		split.hscrollbar.position = f32(-cam.offset_x)
	}
}

custom_split_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	split := cast(^Custom_Split) element

	#partial switch msg {
		case .Layout: {
			bounds := element.bounds
			// log.info("BOUNDS", element.bounds, window_rect(window_main))

			// if .Hide not_in split.statusbar.stat.flags {
			// 	bot := rect_cut_bottom(&bounds, int(DEFAULT_FONT_SIZE * SCALE + TEXT_MARGIN_VERTICAL * SCALE * 2))
			// 	element_move(split.statusbar.stat, bot)
			// }

			if .Hide not_in panel_search.flags {
				bot := rect_cut_bottom(&bounds, int(50 * SCALE))
				element_move(panel_search, bot)
			}

			if image_display_has_content_now(split.image_display) {
				element_move(split.image_display, rect_margin(bounds, int(20 * SCALE)))
			} else {
				split.image_display.bounds = {}
				split.image_display.clip = {}
			}

			// avoid layouting twice
			bottom, right := scrollbars_layout_prior(&bounds, split.hscrollbar, split.vscrollbar)
			element_move(mode_panel, bounds)

			// scrollbar depends on result after mode panel layouting
			task_bounds := task_total_bounds()
			scrollbar_layout_post(
				split.hscrollbar, bottom, rect_width(task_bounds),
				split.vscrollbar, right, rect_height(task_bounds),
			)
		}

		case .Scrolled_X: {
			cam := &mode_panel.cam[mode_panel.mode]
			if split.hscrollbar != nil {
				cam.offset_x = math.round(-split.hscrollbar.position)
			}
			cam.freehand = true
		}

		case .Scrolled_Y: {
			cam := &mode_panel.cam[mode_panel.mode]
			if split.vscrollbar != nil {
				cam.offset_y = math.round(-split.vscrollbar.position)
			}	
			cam.freehand = true
		}
	}

	return 0  	
}

task_panel_init :: proc(split: ^Split_Pane) -> (element: ^Element) {
	rect := split.window.rect

	custom_split = element_init(Custom_Split, split, {}, custom_split_message, context.allocator)

	when !PRESENTATION_MODE {
		custom_split.vscrollbar = scrollbar_init(custom_split, {}, false, context.allocator)
		custom_split.vscrollbar.force_visible = true	
		custom_split.hscrollbar = scrollbar_init(custom_split, {}, true, context.allocator)
		custom_split.hscrollbar.force_visible = true	
	}

	custom_split.image_display = image_display_init(custom_split, {}, nil)
	custom_split.image_display.aspect = .Mix
	custom_split.image_display.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
		display := cast(^Image_Display) element

		#partial switch msg {
			case .Clicked: {
				display.img = nil
				element_repaint(display)
			}

			case .Get_Cursor: {
				return int(Cursor.Hand)
			}
		}

		return 0
	}

	mode_panel = mode_panel_init(custom_split, {})
	search_init(custom_split)
	
	return mode_panel
}

tasks_load_file :: proc() {
	spall.scoped("load tasks")
	err: io.Error = .Empty
	
	if last_save_location != "" {
		err = editor_load(last_save_location)
	} 
	
	// on error reset and load default
	if err != nil {
		log.info("TODOOL: Loading failed -> Loading default")
		last_save_set()
		tasks_load_reset()
		tasks_load_tutorial()
	} else {
		log.info("TODOOL: Loading success")
	}
}

tasks_load_reset :: proc() {
	mode_panel.mode = .List

	// NOTE TEMP
	// TODO need to cleanup node data
	tasks_eliminate_wanted_clear_tasks(mode_panel)
	element_destroy_descendents(mode_panel, false)
	element_deallocate(&window_main.element) // clear mem
	tasks_clear_left_over()
	clear(&mode_panel.children)
	
	// mode_panel.flags += { .Destroy_Descendent }
	undo_manager_reset(&um_task)
	dirty = 0
	dirty_saved = 0
}

tasks_load_tutorial :: proc() {
	@static load_indent := 0

	@(deferred_none=pop)
	push_scoped_task :: #force_inline proc(text: string) {
		task_push(max(load_indent, 0), text)
		load_indent	+= 1
	}

	push_scoped :: #force_inline proc(text: string) {
		load_indent	+= 1
	}

	pop :: #force_inline proc() {
	  load_indent -= 1
	}

	t :: #force_inline proc(text: string) {
		task_push(max(load_indent, 0), text)
	}

	{
		push_scoped_task("Thank You For Trying Todool!")
		t("if you have any issues, please post them on the discord or the itch comments")
		t("tutorial shortcut explanations are based on default key bindings")
	}

	{
		push_scoped_task("Task Keyboard Movement")

		t("up / down -> move to upper / lower task")
		t("shift + movement -> shift select till the new destination")
		t("ctrl+up / ctrl+down -> move to same upper/ lower task with the same indentation")
		t("ctrl+m -> moves to the last task in scope, then shuffles between the start of the scope")
		t("ctrl+, / ctrl+. -> moves to the previous / next task at indentation 0")
		t("alt+up / alt+down -> shift the selected tasks up / down")
		t("ctrl+home / ctrl+end -> move up/down a stack")
	}

	{
		push_scoped_task("Text Box Keyboard Movement")
		t("same as normal text editors")
		t("up / down are used for task based movement")
		t("copying text switches to text paste mode")
	}

	{
		push_scoped_task("Task Addition / Deletion")
		t("return -> insert a new task at the same indentation as the current task")
		t("ctrl+return -> insert a a task as a child with indentation + 1")
		t("backspace -> removes the task when it has no text")
		t("ctrl+d -> removes the selected tasks")
	}

	{
		push_scoped_task("Bookmarks")
		t("ctrl+b -> toggle the current selected tasks bookmark flag")
		t("ctrl+shift+tab -> cycle jump through the previous bookmark")
		t("ctrl+tab -> cycle jump through the next bookmark")
	}

	{
		push_scoped_task("Task Properties")
		t("tab -> increase the selected tasks indentation")
		t("shift+tab -> decrease the selected tasks indentation")
		t("ctrl+q -> cycle through the selected tasks state")
		t("ctrl+j -> toggle the current task folding level")
	}

	{
		push_scoped_task("Tags")
		t("ctrl+(1-8) -> toggle the selected tasks tag (1-8)")
	}

	{
		push_scoped_task("Text Manipulation")
		t("ctrl+shift+j -> uppercase the starting words of the selected tasks")
		t("ctrl+shift+l -> lowercase all letters of the selected tasks")
	}

	{
		push_scoped_task("Task & Text | Copy & Paste")
		t("ctrl+c -> copy the selected tasks - when no text is selected")
		t("ctrl+x -> cut the selected tasks - when no text is selected")
		t("ctrl+shift+c -> copy the selected tasks to the clipboard with basic indentation")
		t("ctrl+v -> paste the previously copied tasks relative to the current position")
		t("ctrl+shift+v -> paste text from the clipboard based on newlines - text is left/right trimmed")
	}

	{
		push_scoped_task("Pomodoro")
		t("alt+1 -> toggle the pomodoro work time")
		t("alt+2 -> toggle the pomodoro short break time")
		t("alt+3 -> toggle the pomodoro long break time")
	}

	{
		push_scoped_task("Modes")
		t("alt+q -> enter the List mode")
		t("alt+w -> enter the Kanban mode")
		t("alt+e -> TEMP spawn the theme editor")
	}

	{
		push_scoped_task("Miscellaneous")
		t("ctrl+s -> save to a file or last saved location")
		t("ctrl+shift+s -> save to a file")
		t("ctrl+o -> load from a file")
		t("ctrl+n -> new file")
		t("ctrl+z -> undo")
		t("ctrl+y -> redo")
		t("ctrl+e -> center the view vertically")
	}

	{
		push_scoped_task("Context Menus")
		t("rightclick task -> Task Context Menu opens")
		t("rightclick multi-selection -> Multi-Selection Prompt opens")
		t("rightclick empty -> Default Context Menu Opens")
	}

	task_head = 0
	task_tail = 0

	// TODO add ctrl+shift+return to insert at prev
}

task_context_menu_spawn :: proc(task: ^Task) {
	menu := menu_init(mode_panel.window, { .Panel_Expand })

	task_multi_context := task_head != task_tail
	
	// select this task on single right click
	if task_head == task_tail {
		task_tail = task.visible_index
		task_head = task.visible_index
	}

	p := menu.panel
	p.gap = 5
	p.shadow = true
	p.background_index = 2
	header_name := task_multi_context ? "Multi Properties" : "Task Properties"
	header := label_init(p, { .Label_Center }, header_name)
	header.font_options = &font_options_bold

	if task_multi_context {
		button_panel := panel_init(p, { .Panel_Horizontal })
		button_panel.outline = true
		// button_panel.color = DARKEN
		b1 := button_init(button_panel, {}, "Normal")
		b1.invoke = proc(button: ^Button, data: rawptr) {
			todool_change_task_selection_state_to(.Normal)
		}
		b2 := button_init(button_panel, {}, "Done")
		b2.invoke = proc(button: ^Button, data: rawptr) {
			todool_change_task_selection_state_to(.Done)
		}
		b3 := button_init(button_panel, {}, "Canceled")
		b3.invoke = proc(button: ^Button, data: rawptr) {
			todool_change_task_selection_state_to(.Canceled)
		}
	} else {
		names := reflect.enum_field_names(Task_State)
		t := toggle_selector_init(p, {}, int(task.state), len(Task_State), names)
		t.data = task
		t.changed = proc(toggle: ^Toggle_Selector) {
			manager := mode_panel_manager_scoped()
			task_head_tail_push(manager)

			task := cast(^Task) toggle.data
			task_set_state_undoable(manager, task, Task_State(toggle.value), 0)
		}
	}

	// indentation
	{
		panel := panel_init(p, { .Panel_Horizontal })
		panel.outline = true

		b1 := button_init(panel, { .HF }, "<-")
		b1.invoke = proc(button: ^Button, data: rawptr) {
			todool_indentation_shift(COMBO_NEGATIVE)
		}
		label := label_init(panel, {  .HF, .Label_Center }, "indent")
		b2 := button_init(panel, { .HF }, "->")
		b2.invoke = proc(button: ^Button, data: rawptr) {
			todool_indentation_shift(COMBO_POSITIVE)
		}
	}

	// deletion
	{
		b2 := button_init(p, {}, "Cut")
		b2.invoke = proc(button: ^Button, data: rawptr) {
			todool_cut_tasks()
			menu_close(button.window)
		}

		b3 := button_init(p, {}, "Copy")
		b3.invoke = proc(button: ^Button, data: rawptr) {
			todool_copy_tasks()
			menu_close(button.window)
		}

		b4 := button_init(p, {}, "Paste")
		b4.invoke = proc(button: ^Button, data: rawptr) {
			todool_paste_tasks()
			menu_close(button.window)
		}

		b1 := button_init(p, {}, "Delete")
		b1.invoke = proc(button: ^Button, data: rawptr) {
			todool_delete_tasks()
			menu_close(button.window)
		}
	}

	// insert link from clipboard to task.button_link
	if clipboard_has_content() {
		link := clipboard_get_string(context.temp_allocator)

		Task_Set_Link :: struct {
			link: string,
			task: ^Task,
		}

		if strings.has_prefix(link, "https://") || strings.has_prefix(link, "http://") {
			b1 := button_init(p, {}, "Insert Link")

			// set saved data that will be destroyed by button
			tsl := new(Task_Set_Link)
			tsl.task = task
			tsl.link = strings.clone(link)

			b1.data = tsl
			b1.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
				button := cast(^Button) element

				#partial switch msg {
					case .Clicked: {
						tsl := cast(^Task_Set_Link) element.data
						task_set_link(tsl.task, tsl.link)
						menu_close(button.window)
					}

					case .Destroy: {
						tsl := cast(^Task_Set_Link) element.data
						delete(tsl.link)
						free(tsl)
					}
				}

				return 0
			}
		}
	}	

	{
		b1_text := task_seperator_is_valid(task) ? "Remove Seperator" : "Add Seperator"
		b1 := button_init(p, {}, b1_text)
		b1.invoke = proc(button: ^Button, data: rawptr) {
			task := tasks_visible[task_head]
			valid := task_seperator_is_valid(task)
			task_set_seperator(task, !valid)
			
			menu_close(button.window)
		}

		b2_text := task_highlight == task ? "Remove Highlight" : "Set Highlight"
		b2 := button_init(p, {}, b2_text)

		b2.invoke = proc(button: ^Button, data: rawptr) {
			task := tasks_visible[task_head]
			if task == task_highlight {
				task_highlight = nil
			} else {
				task_highlight = task
			}

			menu_close(button.window)
		}
	}

	menu_show(menu)
}

// Check if point is inside circle
check_collision_point_circle :: proc(point, center: [2]f32, radius: f32) -> bool {
	return check_collision_point_circles(point, 0, center, radius)
}

// Check collision between two circles
check_collision_point_circles :: proc(
	center1: [2]f32, 
	radius1: f32, 
	center2: [2]f32, 
	radius2: f32,
) -> (collision: bool) {
	dx := center2.x - center1.x	// X distance between centers
	dy := center2.y - center1.y	// Y distance between centers
	distance := math.sqrt(dx * dx + dy * dy) // Distance between centers

	if distance <= (radius1 + radius2) {
		collision = true
	}

	return
}

task_dragging_check_start :: proc(task: ^Task, mouse: Mouse_Coordinates) -> bool {
	if task_head == -1 || drag_running {
		return true
	}

	mouse: [2]f32 = { f32(mouse.x), f32(mouse.y) }
	pos := [2]f32 { f32(task.window.cursor_x), f32(task.window.cursor_y) }
	circle_size := DRAG_CIRCLE * TASK_SCALE
	if check_collision_point_circle(mouse, pos, circle_size) {
		return false
	}

	low, high := task_low_and_high()
	selected := low <= task.visible_index && task.visible_index <= high

	// on not task != selection just select this one
	if !selected {
		task_head = task.visible_index
		task_tail = task.visible_index
		low, high = task_low_and_high()
	}

	clear(&drag_list)
	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)

	// push removal tasks to array before
	iter := ti_init()
	for task in ti_step(&iter) {
		append(&drag_list, task)
	}

	task_head_tail_push(manager)
	task_remove_selection(manager, false)

	if low != high {
		task_head = low
		task_tail = low
	}

	drag_running = true
	drag_index_at = -1
	element_animation_start(mode_panel)

	// init animation positions
	{
		width := int(TASK_DRAG_SIZE * TASK_SCALE)
		height := int(TASK_DRAG_SIZE * TASK_SCALE)
		x := window_main.cursor_x - int(f32(width) / 2)
		y := window_main.cursor_y - int(f32(height) / 2)

		for i := len(drag_goals) - 1; i >= 0; i -= 1 {
			pos := &drag_goals[i]
			pos.x = f32(x) + f32(i) * 5 * TASK_SCALE
			pos.y = f32(y) + f32(i) * 5 * TASK_SCALE
		}
	}

	return true
}

task_dragging_end :: proc() -> bool {
	if !drag_running {
		return false
	}

	drag_circle = false
	drag_running = false
	element_animation_stop(mode_panel)
	force_push := task_head == -1

	// remove task on invalid
	if drag_index_at == -1 && !force_push {
		return true
	}

	// find lowest indentation 
	lowest_indentation := max(int)
	for i in 0..<len(drag_list) {
		task := drag_list[i]
		lowest_indentation = min(lowest_indentation, task.indentation)
	}

	drag_indentation: int
	drag_index := -1

	if drag_index_at != -1 {
		task_drag_at := tasks_visible[drag_index_at]
		drag_index = task_drag_at.index

		if task_head != -1 {
			drag_indentation = task_drag_at.indentation

			if task_drag_at.has_children {
				drag_indentation += 1
			}
		}
	}

	manager := mode_panel_manager_scoped()
	task_head_tail_push(manager)
	task_state_progression = .Update_Animated	
	
	// paste lines with indentation change saved
	visible_count: int
	for i in 0..<len(drag_list) {
		t := drag_list[i]
		visible_count += int(t.visible)
		relative_indentation := drag_indentation + int(t.indentation) - lowest_indentation
		
		item := Undo_Item_Task_Indentation_Set {
			task = t,
			set = t.indentation,
		}	
		undo_push(manager, undo_task_indentation_set, &item, size_of(Undo_Item_Task_Indentation_Set))

		t.indentation = relative_indentation
		t.indentation_smooth = f32(t.indentation)
		task_insert_at(manager, drag_index + i + 1, t)
	}

	task_tail = drag_index_at + 1
	task_head = drag_index_at + visible_count

	element_repaint(mode_panel)
	window_set_cursor(mode_panel.window, .Arrow)
	return true
}

mode_panel_context_menu_spawn :: proc() {
	menu := menu_init(mode_panel.window, { .Panel_Expand })

	p := menu.panel
	p.gap = 5
	p.shadow = true
	p.background_index = 2

	button_init(p, {}, "Theme Editor").invoke = proc(button: ^Button, data: rawptr) {
		theme_editor_spawn()
		menu_close(button.window)
	}

	button_init(p, {}, "Keymap Editor").invoke = proc(button: ^Button, data: rawptr) {
		keymap_editor_spawn()
		menu_close(button.window)
	}

	button_init(p, {}, "Changelog Generator").invoke = proc(button: ^Button, data: rawptr) {
		changelog_spawn()
		menu_close(button.window)
	}
	
	button_init(p, {}, "Load Tutorial").invoke = proc(button: ^Button, data: rawptr) {
	  if !todool_check_for_saving(window_main) {
		  tasks_load_reset()
		  last_save_set("")
		  tasks_load_tutorial()
	  }

		menu_close(button.window)
	}

	// button_init(p, {}, "Test").invoke = proc(button: ^Button, data: rawptr) {
	// 	if focusing {
	// 		focusing = false
	// 	} else {
	// 		focusing = true
	// 		focus_head = 6
	// 		focus_tail = 10
	// 	}

	// 	menu_close(button.window)
	// }

	menu_show(menu)
}

task_highlight_render :: proc(target: ^Render_Target, after: bool) {
	if task_highlight == nil {
		return
	}

	// if 
	// 	after && mode_panel.mode == .List ||
	// 	!after && mode_panel.mode == .Kanban {
	// 	return
	// }

	exists := false

	for task in tasks_visible {
		if task_highlight == task {
			exists = true
			continue
		}
	}

	if !exists {
		return
	}

	render_push_clip(target, mode_panel.clip)

	switch mode_panel.mode {
		case .List: {
			rect := mode_panel.bounds
			rect.t = task_highlight.bounds.t
			rect.b = task_highlight.bounds.b
			render_rect(target, rect, theme.text_bad)
		}

		case .Kanban: {
			rect := task_highlight.bounds
			rect = rect_margin(rect, int(-10 * TASK_SCALE))
			render_rect(target, rect, theme.text_bad, ROUNDNESS)
		}
	}
}

task_render_progressbars :: proc(target: ^Render_Target) {
	if progressbars_alpha == 0 {
		return
	}

	render_push_clip(target, mode_panel.clip)
	builder := strings.builder_make(16, context.temp_allocator)

	fcs_ahv()
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_color(theme_panel(.Parent))

	w := int(100 * TASK_SCALE)
	h := int((DEFAULT_FONT_SIZE + TEXT_MARGIN_VERTICAL) * TASK_SCALE)
	off := int(-10 * TASK_SCALE)
	// off := int(visuals_task_margin() / 2)
	default_rect := rect_wh(0, 0, w, h)
	low, high := task_low_and_high()
	hovered := mode_panel.window.hovered
	use_percentage := progressbar_percentage()
	hover_only := progressbar_hover_only()

	for task in tasks_visible {
		if hover_only && hovered != task && hovered.parent != task {
			continue
		}

		if task.has_children {
			rect := rect_translate(
				default_rect,
				rect_xxyy(task.bounds.r - w + off, task.bounds.t + off),
			)

			prect := rect
			progress_size := rect_widthf(rect)
			alpha: f32 = low <= task.visible_index && task.visible_index <= high ? 0.25 : 1
			alpha = min(progressbars_alpha, alpha)

			for state, i in Task_State {
				if task.progress_animation[state] != 0 {
					roundness := ROUNDNESS + (i == 0 ? 1 : 0)
					render_rect(target, prect, color_alpha(theme_task_text(state), alpha), roundness)
				}

				prect.l += int(task.progress_animation[state] * progress_size)
				// prect.r += i * 2
			}

			strings.builder_reset(&builder)
			non_normal := int(task.children_count) - task.state_count[.Normal]
			if use_percentage {
				fmt.sbprintf(&builder, "%.0f%%", f32(non_normal) / f32(task.children_count) * 100)
			} else {
				fmt.sbprintf(&builder, "%d / %d", non_normal, task.children_count)
			}
			render_string_rect(target, rect, strings.to_string(builder))
		}
	}
}

todool_menu_bar :: proc(parent: ^Element) -> (split: ^Menu_Split, menu: ^Menu_Bar) {
	split = menu_split_init(parent)
	menu = menu_bar_init(split)
	
	menu_bar_field_init(menu, "File", 1).invoke = proc(p: ^Panel) {
		mbl(p, "New File", "new_file")
		mbl(p, "Open File", "load")
		mbl(p, "Save", "save")
		mbl(p, "Save As...", "save", COMBO_TRUE)
		// mbs(p)
		// mbl(p, "Quit").command_custom
	}
	menu_bar_field_init(menu, "View", 2).invoke = proc(p: ^Panel) {
		mbl(p, "Mode List", "mode_list")
		mbl(p, "Mode Kanban", "mode_kanban")
		mbs(p)
		mbl(p, "Theme Editor", "theme_editor")
		mbl(p, "Changelog", "changelog")
		mbs(p)
		mbl(p, "Goto", "goto")
		mbl(p, "Search", "search")
		mbs(p)
		mbl(p, "Scale Tasks Up", "scale_tasks", COMBO_NEGATIVE)
		mbl(p, "Scale Tasks Down", "scale_tasks", COMBO_POSITIVE)
		mbl(p, "Center View", "center")
		mbl(p, "Toggle Progressbars", "toggle_progressbars")
	}
	menu_bar_field_init(menu, "Edit", 3).invoke = proc(p: ^Panel) {
		mbl(p, "Undo", "undo")
		mbl(p, "Redo", "redo")
		mbs(p)
		mbl(p, "Cut", "cut_tasks")
		mbl(p, "Copy", "copy_tasks")
		mbl(p, "Copy To Clipboard", "copy_tasks_to_clipboard")
		mbl(p, "Paste", "paste_tasks")
		mbl(p, "Paste From Clipboard", "paste_tasks_from_clipboard")
		mbs(p)
		mbl(p, "Shift Left", "indentation_shift", COMBO_NEGATIVE)
		mbl(p, "Shift Right", "indentation_shift", COMBO_POSITIVE)
		mbl(p, "Shift Up", "shift_up")
		mbl(p, "Shift Down", "shift_down")
		mbs(p)
		mbl(p, "Sort Locals", "sort_locals")
		mbl(p, "To Uppercase", "tasks_to_uppercase")
		mbl(p, "To Lowercase", "tasks_to_lowercase")
	}
	menu_bar_field_init(menu, "Task-State", 4).invoke = proc(p: ^Panel) {
		mbl(p, "Completion Forward", "change_task_state")
		mbl(p, "Completion Backward", "change_task_state", COMBO_SHIFT)
		mbs(p)
		mbl(p, "Folding", "toggle_folding")
		mbl(p, "Bookmark", "toggle_bookmark")
		mbl(p, "Timestamp", "toggle_timestamp")
		mbs(p)
		mbl(p, "Tag 1", "toggle_tag", COMBO_VALUE + 0x01)
		mbl(p, "Tag 2", "toggle_tag", COMBO_VALUE + 0x02)
		mbl(p, "Tag 3", "toggle_tag", COMBO_VALUE + 0x04)
		mbl(p, "Tag 4", "toggle_tag", COMBO_VALUE + 0x08)
		mbl(p, "Tag 5", "toggle_tag", COMBO_VALUE + 0x10)
		mbl(p, "Tag 6", "toggle_tag", COMBO_VALUE + 0x20)
		mbl(p, "Tag 7", "toggle_tag", COMBO_VALUE + 0x40)
		mbl(p, "Tag 8", "toggle_tag", COMBO_VALUE + 0x80)
	}
	menu_bar_field_init(menu, "Movement", 5).invoke = proc(p: ^Panel) {
		mbl(p, "Move Up", "move_up")
		mbl(p, "Move Down", "move_down")
		mbs(p)
		mbl(p, "Jump Low Indentation Up", "indent_jump_low_prev")
		mbl(p, "Jump Low Indentation Down", "indent_jump_low_next")
		mbl(p, "Jump Same Indentation Up", "indent_jump_same_prev")
		mbl(p, "Jump Same Indentation Down", "indent_jump_same_next")
		mbl(p, "Jump Scoped", "indent_jump_scope")
		mbs(p)
		mbl(p, "Jump Nearby Different State Forward", "jump_nearby")
		mbl(p, "Jump Nearby Different State Backward", "jump_nearby", COMBO_SHIFT)
		mbs(p)
		mbl(p, "Move Up Stack", "move_up_stack")
		mbl(p, "Move Down Stack", "move_down_stack")
		mbs(p)
		mbl(p, "Select All", "select_all")
		mbl(p, "Select Children", "select_children")
	}
	// p2 := panel_init(split, { .Panel_Default_Background })
	// p2.background_index = 1
	return
}

task_string :: #force_inline proc(task: ^Task) -> string {
	return ss_string(&task.box.ss)
}

// render number highlights
render_line_highlights :: proc(target: ^Render_Target, clip: RectI) {
	render := visuals_line_highlight_use()
	alpha := visuals_line_highlight_alpha()

	// force in goto
	if panel_goto != nil && (.Hide not_in panel_goto.flags) && !goto_transition_hide {
		render = true
	}
	
	// skip non rendering and forced on non alpha
	if !render || alpha == 0 {
		return
	}

	render_push_clip(target, clip)
	
	b := &builder_line_number
	fcs_ahv(.Right, .Middle)
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
	fcs_color(color_alpha(theme.text_default, alpha))
	gap := int(4 * TASK_SCALE)

	// line_offset := options_vim_use() ? -task_head : 1
	line_offset := 1

	for t, i in tasks_visible {
		// NOTE necessary as the modes could have the tasks at different positions
		if !rect_overlap(t.bounds, clip) {
			continue
		}

		r := RectI {
			t.bounds.l - 50 - gap,
			t.bounds.l - gap,
			t.bounds.t,
			t.bounds.b,
		}

		if !rect_overlap(r, clip) {
			continue
		}

		strings.builder_reset(b)
		strings.write_int(b, i + line_offset)
		text := strings.to_string(builder_line_number)
		width := string_width(text) + TEXT_MARGIN_HORIZONTAL
		render_string_rect(target, r, text)
	}
}

// render top right zoom highlight 
render_zoom_highlight :: proc(target: ^Render_Target, clip: RectI) {
	if mode_panel.zoom_highlight == 0 {
		return
	}

	render_push_clip(target, clip)
	alpha := min(mode_panel.zoom_highlight, 1)
	color := color_alpha(theme.text_default, alpha)
	rect := mode_panel.bounds
	rect.l = rect.r - 100
	rect.b = rect.t + 100
	zoom := fmt.tprintf("%.2f", TASK_SCALE)
	render_drop_shadow(
		target, 
		rect_margin(rect, 20), 
		color_alpha(theme_panel(.Front), alpha), 
		ROUNDNESS,
	)
	fcs_ahv()
	fcs_color(color)
	fcs_font(font_regular)
	fcs_size(DEFAULT_FONT_SIZE * SCALE)
	render_string_rect(target, rect, zoom)
}

// rendered glyphs system to store previously rendered glyphs 

rendered_glyphs_clear :: proc() {
	clear(&rendered_glyphs)	
}

rendered_glyph_start :: #force_inline proc() {
	rendered_glyphs_start = len(rendered_glyphs)
}

rendered_glyph_gather :: #force_inline proc(output: ^[]Rendered_Glyph) {
	output^ = rendered_glyphs[rendered_glyphs_start:len(rendered_glyphs)]
}

rendered_glyph_push :: proc(x, y: f32, codepoint: rune) -> ^Rendered_Glyph {
	append(&rendered_glyphs, Rendered_Glyph { 
		x = x, 
		y = y, 
		codepoint = codepoint,
	})
	return &rendered_glyphs[len(rendered_glyphs) - 1]
}

rendered_glyphs_slice :: proc(start, end: int) -> (res: []Rendered_Glyph, ok: bool) {
	if start == end || end == 0 {
		return 
	} else {
		res = rendered_glyphs[start:end]
		ok = true
	}

	return
}

// wrapped lines equivalent

wrapped_lines_clear :: proc() {
	clear(&wrapped_lines)	
}

wrapped_lines_push :: proc(
	text: string, 
	width: f32,
	output: ^[]string,
) {
	start := len(wrapped_lines)
	fontstash.wrap_format_to_lines(
		&gs.fc,
		text,
		width,
		&wrapped_lines,
	)
	output^ = wrapped_lines[start:len(wrapped_lines)]
}

wrapped_lines_push_forced :: proc(text: string, output: ^[]string) {
	start := len(wrapped_lines)
	append(&wrapped_lines, text)		
	output^ = wrapped_lines[start:len(wrapped_lines)]
}


bookmarks_render_connections :: proc(target: ^Render_Target, clip: RectI) {
	if task_head == -1 {
		return
	}

	render_push_clip(target, clip)
	// render_group_blend_test(target)
	p_last: [2]f32
	count := -1
	goal := bookmark_index

	if bookmark_index == -1 {
		goal = bookmark_nearest_index(true)
	}

	for task in tasks_visible {
		if task_bookmark_is_valid(task) {
			color := color_alpha(theme.text_default, count == goal ? 0.5 : 0.25)
			x, y := rect_center(task.button_bookmark.bounds)
			p := [2]f32 { x, y }

			if p_last != {} {
				render_line(target, p_last, p, color)
			}

			p_last = p
			count += 1
		}
	}
}