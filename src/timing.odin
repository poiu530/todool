package src

import "core:strconv"
import "core:unicode"
import "core:fmt"
import "core:strings"
import "core:time"

duration_clock :: proc(duration: time.Duration) -> (hours, minutes, seconds: int) {
	hours = int(time.duration_hours(duration)) % 24
	minutes = int(time.duration_minutes(duration)) % 60
	seconds = int(time.duration_seconds(duration)) % 60
	return
}

DAY :: time.Hour * 24
MONTH :: DAY * 30
YEAR :: MONTH * 12
TIMESTAMP_LENGTH :: 10

// build today timestamp
timing_sbprint_timestamp :: proc(b: ^strings.Builder) {
	year, month, day := time.date(time.now())
	strings.builder_reset(b)
	fmt.sbprintf(b, "%4d-%2d-%2d", year, month, day)
}

// build today timestamp
timing_bprint_timestamp :: proc(b: []byte) {
	year, month, day := time.date(time.now())
	fmt.bprintf(b, "%4d-%2d-%2d ", year, month, day)
}

// check if the text contains a timestamp at the starting runes
timing_timestamp_check :: proc(text: string) -> (index: int) {
	index = -1
	
	if len(text) >= 8 && unicode.is_digit(rune(text[0])) {
		// find 2 minus signs without break
		// 2022-01-28 
		minus_count := 0
		index = 0

		for index < 10 {
			b := rune(text[index])
		
			if b == '-' {
				minus_count += 1
			}

			if !(b == '-' || unicode.is_digit(b)) {
				break
			}

			index += 1
		}

		if minus_count != 2 {
			index = -1
		}
		} 

	return
}

Timestamp :: struct {
	year, month, day: int,
}

timing_timestamp_extract :: proc(text: []byte) -> (
	stamp: Timestamp,
	ok: bool,
) {
	assert(len(text) >= TIMESTAMP_LENGTH)

	stamp.year = strconv.parse_int(string(text[0:4])) or_return
	stamp.month = strconv.parse_int(string(text[5:7])) or_return
	stamp.day = strconv.parse_int(string(text[8:10])) or_return
	stamp.month = clamp(stamp.month, 0, 12)
	stamp.day = clamp(stamp.day, 0, 31)
	ok = true

	return
}

// true if the timestamp isnt today
timing_timestamp_is_today :: proc(stamp: Timestamp) -> bool {
	year, month, day := time.date(time.now())
	return year == stamp.year &&
		int(month) == stamp.month &&
		day == stamp.day
}

month_day_count :: proc(month: time.Month) -> i32 {
	month := int(month)
	assert(month >= 0 && month <= 12)
	return time.days_before[month] - time.days_before[month - 1]
}

wrap_int :: proc(x, low, high: int) -> int {
	temp := x % high
	return temp < low ? high + (temp - low) : temp
}

month_wrap :: proc(month: time.Month, offset: int) -> time.Month {
	return time.Month(wrap_int(int(month) + offset, 1, 13))
}

Time_Date_Format :: enum {
	US,
	EUROPE,
}

Time_Date_Drag :: enum {
	None,
	Day,
	Month,
	Year,
}

// positions
TIME_DATE_FORMAT_TABLE :: [Time_Date_Drag][Time_Date_Format][2]int {
	.None = {}, // empty
	.Day = { // day
		.US = { 8, 10 },
		.EUROPE = { 0, 2 },
	},
	.Month = { // month
		.US = { 5, 7 },
		.EUROPE = { 3, 5 },
	},
	.Year = { // year
		.US = { 0, 4 },
		.EUROPE = { 6, 10 },
	},
}

// TODO put this into options
time_date_format: Time_Date_Format = .US

Time_Date :: struct {
	using element: Element,

	stamp: time.Time,
	saved: time.Time,
	drag: Time_Date_Drag,

	builder: strings.Builder,
	rstart, rend: int,
	spawn_particles: bool,
}

time_date_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
	particles: bool,
) -> (res: ^Time_Date) {
	res = element_init(Time_Date, parent, flags, time_date_message, context.allocator)
	res.stamp = time.now()
	strings.builder_init(&res.builder, 0, 16)
	res.spawn_particles = particles
	return
}

time_date_drag_find :: proc(td: ^Time_Date) -> Time_Date_Drag {
	// find dragged property
	if glyphs, ok := rendered_glyphs_slice(td.rstart, td.rend); ok {
		count: int
		
		for g in glyphs {
			if td.window.cursor_x < int(g.x) {
				break
			}

			if g.codepoint == '-' || g.codepoint == '.' {
				count += 1
			}
		}

		// set drag property
		switch time_date_format {
			case .US: {
				return Time_Date_Drag(2 - count + 1)
			}

			case .EUROPE: {
				return Time_Date_Drag(count + 1)
			}
		}
	}

	return .None
}

time_date_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	td := cast(^Time_Date) element

	#partial switch msg {
		case .Paint_Recursive: {
			target := element.window.target

			fcs_ahv()
			task := cast(^Task) element.parent
			task_color := theme_panel(task.has_children ? .Parent : .Front)
			fcs_color(task_color)
			fcs_font(font_regular)
			fcs_size(DEFAULT_FONT_SIZE * TASK_SCALE)
			
			render_rect(target, element.bounds, theme.text_date, ROUNDNESS)

			render_string_rect_store(target, element.bounds, strings.to_string(td.builder), &td.rstart, &td.rend)
		}

		case .Layout: {
			td.rend = 0

			b := &td.builder
			strings.builder_reset(b)
			year, month, day := time.date(td.stamp)
			switch time_date_format {
				case .US: fmt.sbprintf(b, "%4d-%2d-%2d", year, int(month), day)
				case .EUROPE: fmt.sbprintf(b, "%2d.%2d.%4d", day, int(month), year)
			}

			if td.spawn_particles {
				x := f32(element.bounds.l)
				y := f32(element.bounds.t)
				power_mode_spawn_along_text(strings.to_string(td.builder), x, y, theme.text_date)
				td.spawn_particles = false
			}
		}

		case .Destroy: {
			strings.builder_destroy(&td.builder)
		}

		case .Left_Down: {
			td.saved = td.stamp
			td.drag = time_date_drag_find(td)
		}

		case .Get_Cursor: {
			return int(Cursor.Resize_Horizontal)
		}

		case .Left_Up: {
			td.drag = .None
			element_repaint(element)
		}

		case .Mouse_Move: {
			element_repaint(element)
		}

		case .Mouse_Drag: {
			if element.window.pressed_button == MOUSE_LEFT {
				diff := window_mouse_position(element.window) - element.window.down_left
				old := td.stamp

				switch td.drag {
					case .None: {}

					case .Day: {
						step := time.Duration(diff.x / 20)
						td.stamp = time.time_add(td.saved, DAY * step)
					}

					case .Month: {
						year, month, day := time.date(td.saved)
						goal := clamp(int(month) + int(diff.x / 20), 1, 12)
						out, ok := time.datetime_to_time(year, goal, day, 0, 0, 0)

						if ok {
							td.stamp = out
						}
					}

					case .Year: {
						year, month, day := time.date(td.saved)
						goal := clamp(int(year) + int(diff.x / 20), 1970, 100_000)
						out, ok := time.datetime_to_time(goal, int(month), day, 10, 10, 10)

						if ok {
							td.stamp = out
						}
					}
				}

				if old != td.stamp {
					element_repaint(element)

					if pm_show() {
						table := TIME_DATE_FORMAT_TABLE
						pair := table[td.drag][time_date_format]
						
						if glyphs, ok := rendered_glyphs_slice(td.rstart, td.rend); ok {
							cam := mode_panel_cam()
							x1 := glyphs[pair.x].x
							x2 := glyphs[pair.y - 1].x
							x := f32(x1 + (x2 - x1))
							y := f32(glyphs[pair.x].y)
							power_mode_spawn_at(x, y, cam.offset_x, cam.offset_y, 4, theme.text_date)
						}
					}
				}
			} 
		}

		case .Right_Down: {
			// element_hide(td, true)
			time_date_format = Time_Date_Format((int(time_date_format) + 1) % len(Time_Date_Format))
			window_repaint(window_main)
		}
	}

	return 0
}

time_date_update :: proc(td: ^Time_Date) -> bool {
	y1, m1, d1 := time.date(td.stamp)
	next := time.now()
	y2, m2, d2 := time.date(next)
	td.stamp = next
	return y1 == y2 && m1 == m2 && d1 == d2
}

time_date_render_highlight_on_pressed :: proc(
	target: ^Render_Target, 
	clip: RectI,
) {
	element := window_main.pressed

	if element == nil {
		element = window_main.hovered

		if element == nil {
			return
		}
	}

	if element.message_class == time_date_message {
		td := cast(^Time_Date) element
		drag := td.drag

		if drag == .None {
			drag = time_date_drag_find(td)

			if drag == .None {
				return
			}
		}

		// render glyphs differently based on drag property
		if glyphs, ok := rendered_glyphs_slice(td.rstart, td.rend); ok {
			table := TIME_DATE_FORMAT_TABLE
			pair := table[drag][time_date_format]

			for i in pair.x..<pair.y {
				glyph := glyphs[i]

				for v in &glyph.vertices {
					v.color = theme.text_default
				}
			}
		}
	}
}