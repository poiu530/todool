package src

import "core:time"
import "core:runtime"
import "core:math"
import "core:fmt"
import "core:mem"
import "core:log"
import "core:os"
import "core:strings"
import "core:encoding/json"

Sidebar_Mode :: enum {
	Options,
	Tags,
}

Sidebar :: struct {
	split: ^Split_Pane,
	enum_panel: ^Enum_Panel,
	
	mode: Sidebar_Mode,
	options: Sidebar_Options,
	tags: Sidebar_Tags,

	pomodoro_label: ^Label,
}
sb: Sidebar

Sidebar_Options :: struct {
	panel: ^Panel,
	slider_tab: ^Slider,
	checkbox_autosave: ^Checkbox,
	checkbox_invert_x: ^Checkbox,
	checkbox_invert_y: ^Checkbox,
	checkbox_uppercase_word: ^Checkbox,
	checkbox_use_animations: ^Checkbox,	
	checkbox_wrapping: ^Checkbox,

	slider_pomodoro_work: ^Slider,
	slider_pomodoro_short_break: ^Slider,
	slider_pomodoro_long_break: ^Slider,
	button_pomodoro_reset: ^Icon_Button,

	slider_work_today: ^Slider,
	gauge_work_today: ^Linear_Gauge,
	label_time_accumulated: ^Label,
}

TAG_SHOW_TEXT_AND_COLOR :: 0
TAG_SHOW_COLOR :: 1
TAG_SHOW_NONE :: 2
TAG_SHOW_COUNT :: 3

tag_show_text := [TAG_SHOW_COUNT]string {
	"Text & Color",
	"Color",
	"None",
}

Sidebar_Tags :: struct {
	panel: ^Panel,
	names: [8]^strings.Builder,
	temp_index: int,
	tag_show_mode: int,
	toggle_selector_tag: ^Toggle_Selector,
}

Sidebar_Activity :: struct {
	panel: ^Panel,
}

sidebar_mode_toggle :: proc(to: Sidebar_Mode) {
	if (.Hide in sb.enum_panel.flags) || to != sb.mode {
		sb.mode = to
		element_hide(sb.enum_panel, false)
	} else {
		element_hide(sb.enum_panel, true)
	}
}

// button with highlight based on selected
sidebar_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Icon_Button) element
	mode := cast(^Sidebar_Mode) element.data

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := (.Hide not_in sb.enum_panel.flags) && sb.mode == mode^
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			sidebar_mode_toggle(mode^)
			element_repaint(element)
		}

		case .Deallocate_Recursive: {
			free(element.data)
		}
	}

	return 0
}


sidebar_init :: proc(parent: ^Element) -> (split: ^Split_Pane) {
	// left panel
	{
		panel_info = panel_init(parent, { .Panel_Default_Background, .VF, .Tab_Movement_Allowed }, 0, 5)
		panel_info.background_index = 2
		panel_info.z_index = 3

		// side options
		{
			i1 := icon_button_init(panel_info, { .HF }, .Cog, sidebar_button_message)
			i1.data = new_clone(Sidebar_Mode.Options)
			i1.hover_info = "Options"
			
			i2 := icon_button_init(panel_info, { .HF }, .Tag, sidebar_button_message)
			i2.data = new_clone(Sidebar_Mode.Tags)
			i2.hover_info = "Tags"
		}

		// pomodoro
		{
			spacer_init(panel_info, { .VF, }, 0, 20, .Thin)
			i1 := icon_button_init(panel_info, { .HF }, .Tomato)
			i1.hover_info = "Start / Stop Pomodoro Time"
			i1.invoke = proc(data: rawptr) {
				element_hide(sb.options.button_pomodoro_reset, pomodoro.stopwatch.running)
				pomodoro_stopwatch_toggle()
			}
			i2 := icon_button_init(panel_info, { .HF }, .Reply)
			i2.invoke = proc(data: rawptr) {
				element_hide(sb.options.button_pomodoro_reset, pomodoro.stopwatch.running)
				pomodoro_stopwatch_reset()
				pomodoro_label_format()
				sound_play(.Timer_Stop)
			}
			i2.hover_info = "Reset Pomodoro Time"
			sb.options.button_pomodoro_reset = i2
			element_hide(i2, true)

			sb.pomodoro_label = label_init(panel_info, { .HF, .Label_Center }, "00:00")

			b1 := button_init(panel_info, { .HF }, "1", pomodoro_button_message)
			b1.hover_info = "Select Work Time"
			b2 := button_init(panel_info, { .HF }, "2", pomodoro_button_message)
			b2.hover_info = "Select Short Break Time"
			b3 := button_init(panel_info, { .HF }, "3", pomodoro_button_message)
			b3.hover_info = "Select Long Break Time"
		}
	
		// mode		
		{
			spacer_init(panel_info, { }, 0, 20, .Thin)
			b1 := button_init(panel_info, { .HF }, "L", mode_based_button_message)
			b1.data = new_clone(Mode_Based_Button { 0 })
			b1.hover_info = "List Mode"
			b2 := button_init(panel_info, { .HF }, "K", mode_based_button_message)
			b2.data = new_clone(Mode_Based_Button { 1 })
			b2.hover_info = "Kanban Mode"
		}

		// TODO add border
		// b := button_init(panel_info, { .CT, .Hover_Has_Info }, "b")
		// b.invoke = proc(data: rawptr) {
		// 	element := cast(^Element) data
		// 	window_border_toggle(element.window)
		// 	element_repaint(element)
		// }
		// b.hover_info = "border"

	}

	split = split_pane_init(parent, { .Split_Pane_Hidable, .VF, .HF, .Tab_Movement_Allowed }, 300, 300)
	sb.split = split
	sb.split.pixel_based = true

	shared_panel :: proc(element: ^Element, title: string) -> ^Panel {
		panel := panel_init(element, { .Panel_Default_Background, .Tab_Movement_Allowed }, 5, 5)
		panel.background_index = 1
		panel.z_index = 2

		header := label_init(panel, { .Label_Center }, title)
		header.font_options = &font_options_header
		spacer_init(panel, {}, 0, 5, .Thin)

		return panel
	}

	// init all sidebar panels

	enum_panel := enum_panel_init(split, { .Tab_Movement_Allowed }, cast(^int) &sb.mode, len(Sidebar_Mode))
	sb.enum_panel = enum_panel
	element_hide(sb.enum_panel, true)

	SPACER_HEIGHT :: 10
	spacer_scaled := SPACER_HEIGHT * SCALE

	// options
	{
		temp := &sb.options
		using temp
		flags := Element_Flags { .HF }

		panel = shared_panel(enum_panel, "Options")

		slider_tab = slider_init(panel, flags, 0.5)
		slider_tab.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Tab: %.3f%%", position)
		}

		checkbox_autosave = checkbox_init(panel, flags, "Autosave", true)
		checkbox_uppercase_word = checkbox_init(panel, flags, "Uppercase Parent Word", true)
		checkbox_invert_x = checkbox_init(panel, flags, "Invert Scroll X", false)
		checkbox_invert_y = checkbox_init(panel, flags, "Invert Scroll Y", false)
		checkbox_use_animations = checkbox_init(panel, flags, "Use Animations", true)
		checkbox_wrapping = checkbox_init(panel, flags, "Wrap in List Mode", true)

		slider_volume := slider_init(panel, flags, 1)
		slider_volume.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			slider := cast(^Slider) element

			if msg == .Value_Changed {
				value := i32(slider.position * 128)
				mix_volume_set(value)
			}

			return 0
		}
		slider_volume.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Volume: %d%%", int(position * 100))
		}

		// pomodoro
		spacer_init(panel, flags, 0, spacer_scaled, .Empty)
		l1 := label_init(panel, { .HF, .Label_Center }, "Pomodoro")
		l1.font_options = &font_options_header
		
		slider_pomodoro_work = slider_init(panel, flags, 50.0 / 60.0)
		slider_pomodoro_work.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Work: %dmin", int(position * 60))
		}
		slider_pomodoro_short_break = slider_init(panel, flags, 10.0 / 60)
		slider_pomodoro_short_break.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Short Break: %dmin", int(position * 60))
		}
		slider_pomodoro_long_break = slider_init(panel, flags, 30.0 / 60)
		slider_pomodoro_long_break.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Long Break: %dmin", int(position * 60))
		}

		// statistics
		spacer_init(panel, flags, 0, spacer_scaled, .Empty)
		l2 := label_init(panel, { .HF, .Label_Center }, "Statistics")
		l2.font_options = &font_options_header

		label_time_accumulated = label_init(panel, { .HF, .Label_Center })
		b := button_init(panel, flags, "Reset acummulated")
		b.invoke = proc(data: rawptr) {
			pomodoro.accumulated = {}
		}

		slider_work_today = slider_init(panel, flags, 8.0 / 24)
		slider_work_today.formatting = proc(builder: ^strings.Builder, position: f32) {
			fmt.sbprintf(builder, "Goal Today: %dh", int(position * 24))
		}

		gauge_work_today = linear_gauge_init(panel, flags, 0.5, "Done Today", "Working Overtime")
		gauge_work_today.message_user = proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
			if msg == .Paint_Recursive {
				if pomodoro.celebrating {
					target := element.window.target
					render_push_clip(target, element.parent.bounds)
					pomodoro_celebration_render(target)
				}
			}

			return 0
		}
	}

	// tags
	{
		temp := &sb.tags
		using temp
		panel = shared_panel(enum_panel, "Tags")

		shared_box :: proc(
			panel: ^Panel, 
			text: string,
		) {
			b := text_box_init(panel, { .HF }, text)
			sb.tags.names[sb.tags.temp_index]	= &b.builder
			sb.tags.temp_index += 1
		}

		label_init(panel, { .Label_Center }, "Tags 1-8")
		shared_box(panel, "one")
		shared_box(panel, "two")
		shared_box(panel, "three")
		shared_box(panel, "four")
		shared_box(panel, "five")
		shared_box(panel, "six")
		shared_box(panel, "seven")
		shared_box(panel, "eight")

		spacer_init(panel, { .HF }, 0, spacer_scaled, .Empty)
		label_init(panel, { .HF, .Label_Center }, "Tag Showcase")
		toggle_selector_tag = toggle_selector_init(
			panel,
			{ .HF },
			&sb.tags.tag_show_mode,
			TAG_SHOW_COUNT,
			tag_show_text[:],
		)

		// duration: time.Duration
		// {
		// 	time.SCOPED_TICK_DURATION(&duration)

		// 	handle0 := image_load_push("july_next.png")
		// 	image_display_init(panel, { .HF }, handle0)
		// 	handle1 := image_load_push("august_one.png")
		// 	image_display_init(panel, { .HF }, handle1)
		// }
		// log.info("IMG LOADING TOOK", duration)
	}

	return
}

options_autosave :: #force_inline proc() -> bool {
	return sb.options.checkbox_autosave.state
}

options_wrapping :: #force_inline proc() -> bool {
	return sb.options.checkbox_wrapping.state
}

options_tab :: #force_inline proc() -> f32 {
	return sb.options.slider_tab.position
}

options_scroll_x :: #force_inline proc() -> int {
	return sb.options.checkbox_invert_x.state ? -1 : 1
}

options_scroll_y :: #force_inline proc() -> int {
	return sb.options.checkbox_invert_y.state ? -1 : 1
}

options_tag_mode :: #force_inline proc() -> int {
	return sb.tags.tag_show_mode
}

options_uppercase_word :: #force_inline proc() -> bool {
	return sb.options.checkbox_uppercase_word.state
}

options_use_animations :: #force_inline proc() -> bool {
	return sb.options.checkbox_use_animations.state
}

Mode_Based_Button :: struct {
	index: int,
}

mode_based_button_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	button := cast(^Button) element
	info := cast(^Mode_Based_Button) element.data

	#partial switch msg {
		case .Button_Highlight: {
			color := cast(^Color) dp
			selected := info.index == int(mode_panel.mode)
			color^ = selected ? theme.text_default : theme.text_blank
			return selected ? 1 : 2
		}

		case .Clicked: {
			set := cast(^int) &mode_panel.mode
			if set^ != info.index {
				set^ = info.index
				element_repaint(element)
			}
		}

		case .Deallocate_Recursive: {
			free(element.data)
		}
	}

	return 0
}
