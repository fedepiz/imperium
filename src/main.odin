package main

import "core:fmt"
import "core:mem"
import gl "vendor:OpenGL"
import sdl "vendor:sdl3"

GLOBAL: struct {
	input:       Input,
	render_data: Render_Data,
	render_ctx:  Render_Ctx,
	sprites:     Sprites,
	ui:          UI,
	ui_demo:     UI_Demo,
}

Font_Name :: enum {
	Default,
	Heading,
}

Image_Name :: enum {
	Logo,
}

main :: proc() {
	context.allocator = mem.panic_allocator()

	if !sdl.Init({.VIDEO}) {
		fmt.eprintf("SDL initialization failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.Quit()

	if !sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3) ||
	   !sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3) ||
	   !sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE)) ||
	   !sdl.GL_SetAttribute(.CONTEXT_FLAGS, i32(sdl.GL_CONTEXT_FORWARD_COMPATIBLE_FLAG)) ||
	   !sdl.GL_SetAttribute(.DOUBLEBUFFER, 1) {
		fmt.eprintf("OpenGL attribute setup failed: %s\n", sdl.GetError())
		return
	}

	window := sdl.CreateWindow(
		"Imperium - UI",
		1600,
		900,
		{.OPENGL, .HIGH_PIXEL_DENSITY, .RESIZABLE},
	)
	if window == nil {
		fmt.eprintf("Window creation failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	gl_context := sdl.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintf("OpenGL context creation failed: %s\n", sdl.GetError())
		return
	}
	defer sdl.GL_DestroyContext(gl_context)

	if !sdl.GL_MakeCurrent(window, gl_context) {
		fmt.eprintf("Making the OpenGL context current failed: %s\n", sdl.GetError())
		return
	}
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)
	render_ctx := &GLOBAL.render_ctx
	if !render_init(render_ctx) {
		return
	}
	defer render_destroy(render_ctx)

	sprites_font_define(&GLOBAL.sprites, Font_Id(Font_Name.Default), "MeathFLF", 24)
	sprites_font_define(&GLOBAL.sprites, Font_Id(Font_Name.Heading), "MeathFLF", 32)
	sprites_image_define(&GLOBAL.sprites, Image_Id(Image_Name.Logo), "logo")
	sprites_load(&GLOBAL.sprites, render_ctx)
	ui_init(&GLOBAL.ui, Font_Id(Font_Name.Default), Font_Id(Font_Name.Heading))
	GLOBAL.ui_demo = {
		enabled   = true,
		details   = true,
		amount    = 0.4,
		selected  = -1,
		color     = {0.88, 0.66, 0.3, 1},
		pane_rect = {1130, 555, 360, 320},
	}

	if !sdl.GL_SetSwapInterval(1) {
		fmt.eprintf("Enabling VSync failed: %s\n", sdl.GetError())
	}


	frame_previous := sdl.GetTicksNS()
	keep_going := true
	for keep_going {
		free_all(context.temp_allocator)
		frame_now := sdl.GetTicksNS()
		dt := f32(f64(frame_now - frame_previous) / 1e9)
		frame_previous = frame_now
		ui_input_begin(&GLOBAL.ui)

		event: sdl.Event

		GLOBAL.input.keys[.Old] = GLOBAL.input.keys[.New]
		GLOBAL.input.btns[.Old] = GLOBAL.input.btns[.New]

		GLOBAL.input.keys[.New][.Pressed] = {}
		GLOBAL.input.btns[.New][.Pressed] = {}

		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				keep_going = false
			case .KEY_DOWN:
				id := event.key.scancode
				GLOBAL.input.keys[.New][.Down][id] = true
				GLOBAL.input.keys[.New][.Pressed][id] = !GLOBAL.input.keys[.Old][.Down][id]
				if action := ui_action_from_key(id, event.key.mod); action != .None {
					ui_input_push(&GLOBAL.ui, {kind = .Key, action = action})
				}
			case .KEY_UP:
				id := event.key.scancode
				GLOBAL.input.keys[.New][.Down][id] = false
			case .MOUSE_BUTTON_DOWN:
				id := event.button.button
				GLOBAL.input.btns[.New][.Down][id] = true
				GLOBAL.input.btns[.New][.Pressed][id] = !GLOBAL.input.btns[.Old][.Down][id]
				GLOBAL.input.pos = {event.button.x, event.button.y}
				GLOBAL.input.pos_is_valid = true
				ui_input_push(
					&GLOBAL.ui,
					{
						kind = .Press,
						pos = GLOBAL.input.pos,
						button = id,
						clicks = event.button.clicks,
					},
				)
			case .MOUSE_BUTTON_UP:
				id := event.button.button
				GLOBAL.input.btns[.New][.Down][id] = false
				GLOBAL.input.pos = {event.button.x, event.button.y}
				ui_input_push(&GLOBAL.ui, {kind = .Release, pos = GLOBAL.input.pos, button = id})
			case .MOUSE_MOTION:
				GLOBAL.input.pos = {event.motion.x, event.motion.y}
				GLOBAL.input.pos_is_valid = true
			case .WINDOW_MOUSE_LEAVE:
				GLOBAL.input.pos_is_valid = false
			case .MOUSE_WHEEL:
				direction: f32 = -1 if event.wheel.direction == .FLIPPED else 1
				ui_input_push(
					&GLOBAL.ui,
					{
						kind = .Scroll,
						pos = {event.wheel.mouse_x, event.wheel.mouse_y},
						delta = {event.wheel.x * direction, event.wheel.y * direction},
					},
				)
			case .WINDOW_FOCUS_LOST:
				GLOBAL.input.keys[.New][.Down] = {}
				GLOBAL.input.btns[.New][.Down] = {}
				ui_input_push(&GLOBAL.ui, {kind = .Cancel})
			}
		}

		keep_going &= !key_is_pressed(GLOBAL.input, .ESCAPE)

		if !keep_going {
			break
		}

		width, height: i32
		if !sdl.GetWindowSizeInPixels(window, &width, &height) {
			fmt.eprintf("Getting the window pixel size failed: %s\n", sdl.GetError())
			return
		}
		gl.Viewport(0, 0, width, height)
		gl.ClearColor(0.08, 0.10, 0.14, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		logical_width, logical_height: i32
		if !sdl.GetWindowSize(window, &logical_width, &logical_height) {
			fmt.eprintf("Getting the window size failed: %s\n", sdl.GetError())
			return
		}

		render_ctx.view_size = {f32(logical_width), f32(logical_height)}

		{
			draw: Draw_Ctx
			clip_span := span_from_array(&GLOBAL.render_data.clips)
			span_advance(&clip_span) // Clip zero means unclipped.
			draw_begin(
				&draw,
				&GLOBAL.render_data,
				&GLOBAL.sprites,
				span_from_array(&GLOBAL.render_data.instances),
				clip_span,
			)

			ui_ctx: UI_Ctx
			ui_begin(&ui_ctx, &GLOBAL.ui, &draw, &GLOBAL.input, render_ctx.view_size, dt)
			ui_demo_build(&ui_ctx, &GLOBAL.ui_demo)
			ui_end(&ui_ctx)
		}

		render(render_ctx, GLOBAL.render_data)

		sdl.GL_SwapWindow(window)
	}
}

// Demo values are application-owned; UI tables retain no pointers to them.
UI_Demo :: struct {
	clicks:    int,
	enabled:   bool,
	details:   bool,
	amount:    f32,
	selected:  int,
	radio:     int,
	theme:     int,
	color:     [4]f32,
	pane_rect: [4]f32,
}

@(private = "file")
ui_demo_build :: proc(ctx: ^UI_Ctx, demo: ^UI_Demo) {
	ui_row_begin(ctx, "header")
	ui_width_next(ctx, ui_px(72))
	ui_height_next(ctx, ui_px(72))
	ui_padding_next(ctx, {})
	ui_image(ctx, "logo", Image_Id(Image_Name.Logo))
	ui_width_next(ctx, ui_fill())
	ui_col_begin(ctx, "title")
	ui_heading(ctx, "Imperium")
	ui_tag_push(ctx, "muted")
	ui_label(ctx, "Immediate boxes. Fixed tables. No heap.")
	ui_tag_pop(ctx)
	ui_col_end(ctx)
	ui_width_next(ctx, ui_px(220))
	if theme := ui_combo(
		ctx,
		"theme",
		&demo.theme,
		[]string{"Midnight", "Daylight", "High contrast"},
	); .Changed in theme.flags {
		ui_theme_select(ctx.ui, UI_Theme_Id(demo.theme))
	}
	ui_row_end(ctx)
	ui_divider(ctx)

	ui_height_next(ctx, ui_fill())
	ui_row_begin(ctx, "body")
	ui_width_next(ctx, ui_fill())
	ui_height_next(ctx, ui_pct())
	controls := ui_col_begin(ctx, "controls")
	if controls != 0 {ctx.ui.boxes[controls].flags += {.Clip, .Scroll_Y}}
	ui_panel_begin(ctx, "basics")
	ui_heading(ctx, "Controls")
	ui_label(ctx, fmt.tprintf("Button presses: %d###press_count", demo.clicks))
	ui_row_begin(ctx)
	ui_tag_push(ctx, "primary")
	button := ui_button(ctx, "Press me")
	if .Clicked in button.flags {demo.clicks += 1}
	ui_tag_pop(ctx)
	ui_tooltip(
		ctx,
		button.box,
		"This button keeps its identity across frames. Try Tab and Enter, too.",
	)
	ui_tag_push(ctx, "danger")
	if reset := ui_button(ctx, "Reset"); .Clicked in reset.flags {demo.clicks = 0}
	ui_tag_pop(ctx)
	ui_row_end(ctx)
	ui_checkbox(ctx, "Enable option", &demo.enabled)
	ui_row_begin(ctx)
	ui_radio(ctx, "Choice A", &demo.radio, 0)
	ui_radio(ctx, "Choice B", &demo.radio, 1)
	ui_row_end(ctx)
	ui_box(ctx, "Unavailable", {.Text, .Background, .Border, .Disabled, .Clickable, .Focusable})
	ui_slider(ctx, "Amount", &demo.amount, 0, 1)
	ui_label(ctx, fmt.tprintf("Value: %.2f###amount_value", demo.amount))
	ui_expander(ctx, "Details", &demo.details)
	if demo.details {
		ui_label_wrapped(
			ctx,
			"Boxes combine layout, appearance and interaction. Children inherit clipping and disabled state.",
		)
	}
	ui_panel_end(ctx)
	ui_panel_begin(ctx, "table_panel")
	ui_heading(ctx, "Table")
	ui_table_begin(ctx, "resources", []f32{2, 1, 1})
	resource_names := [4]string{"Resource", "Boxes", "Events", "Text bytes"}
	resource_sizes := [4]string{"Storage", "512", "128", "65536"}
	resource_lifetimes := [4]string{"Lifetime", "Retained", "Frame", "Frame"}
	for row in 0 ..< 4 {
		ui_key_push_u64(ctx, u64(row))
		ui_table_row_begin(ctx)
		ui_table_cell_begin(ctx)
		ui_label(ctx, resource_names[row])
		ui_table_cell_end(ctx)
		ui_table_cell_begin(ctx)
		ui_label(ctx, resource_sizes[row])
		ui_table_cell_end(ctx)
		ui_table_cell_begin(ctx)
		ui_label(ctx, resource_lifetimes[row])
		ui_table_cell_end(ctx)
		ui_table_row_end(ctx)
		ui_key_pop(ctx)
	}
	ui_table_end(ctx)
	ui_panel_end(ctx)
	ui_col_end(ctx)

	ui_width_next(ctx, ui_fill())
	ui_height_next(ctx, ui_pct())
	content := ui_col_begin(ctx, "content")
	if content != 0 {ctx.ui.boxes[content].flags += {.Clip, .Scroll_Y}}
	ui_panel_begin(ctx, "scroll_panel")
	ui_heading(ctx, "Scrolling and selection")
	ui_label(ctx, "Wheel to scroll; click a row.")
	ui_scrollpane_begin(ctx, "list", 290)
	for row in 0 ..< 40 {
		ui_key_push_u64(ctx, u64(row))
		item := ui_list_item(ctx, fmt.tprintf("Item %02d###item", row + 1), demo.selected == row)
		if .Clicked in item.flags {demo.selected = row}
		if .Right_Pressed in item.flags {ui_popup_open(ctx, "row_menu", item.box)}
		if ui_popup_begin(ctx, "row_menu") {
			ui_label(ctx, fmt.tprintf("Item %d", row + 1))
			if choice := ui_menu_item(ctx, "Select");
			   .Clicked in choice.flags {demo.selected = row}
			if choice := ui_menu_item(ctx, "Clear selection");
			   .Clicked in choice.flags {demo.selected = -1}
			ui_popup_end(ctx)
		}
		ui_key_pop(ctx)
	}
	ui_scrollpane_end(ctx)
	ui_panel_end(ctx)
	ui_panel_begin(ctx, "text_panel")
	ui_heading(ctx, "Text and images")
	ui_label_rich(
		ctx,
		"rich",
		[]UI_Run_Desc {
			{
				is_image = true,
				image = Image_Id(Image_Name.Logo),
				size = {28, 28},
				color = {1, 1, 1, 1},
			},
			{text = "  One ", font = Font_Id(Font_Name.Default), color = {0.65, 0.8, 1, 1}},
			{
				text = "shared baseline",
				font = Font_Id(Font_Name.Default),
				color = {0.95, 0.73, 0.35, 1},
			},
		},
	)
	ui_label_wrapped(
		ctx,
		"This paragraph is measured at its available width before the children-sized panel is resolved. Resize the window to see the layout respond.",
	)
	ui_width_next(ctx, ui_px(220))
	ui_label(ctx, "A deliberately long label that is truncated with an ellipsis.")
	ui_panel_end(ctx)
	ui_col_end(ctx)

	ui_width_next(ctx, ui_fill())
	ui_height_next(ctx, ui_pct())
	appearance := ui_col_begin(ctx, "appearance")
	if appearance != 0 {ctx.ui.boxes[appearance].flags += {.Clip, .Scroll_Y}}
	ui_panel_begin(ctx, "theme_panel")
	ui_heading(ctx, "Theme tags")
	ui_label_wrapped(
		ctx,
		"Scoped tags choose the most specific matching rule. Changing themes animates colors without changing the boxes.",
	)
	ui_row_begin(ctx)
	ui_button(ctx, "Ordinary")
	ui_tag_push(ctx, "primary")
	ui_button(ctx, "Primary")
	ui_tag_pop(ctx)
	ui_row_end(ctx)
	ui_tag_push(ctx, "danger")
	ui_button(ctx, "Danger")
	ui_tag_pop(ctx)
	ui_spacer(ctx, ui_px(8))
	ui_tag_push(ctx, "muted")
	ui_label_wrapped(
		ctx,
		"Tab / Shift-Tab: focus. Arrows: navigate or adjust. Enter / Space: activate. Escape: dismiss menus.",
	)
	ui_tag_pop(ctx)
	ui_panel_end(ctx)
	ui_panel_begin(ctx, "popup_panel")
	ui_heading(ctx, "Menus and tooltips")
	menu := ui_button(ctx, "Open menu")
	if .Clicked in menu.flags {ui_popup_open(ctx, "actions", menu.box)}
	ui_tooltip(ctx, menu.box, "Menus float above the main UI and capture input until dismissed.")
	if ui_popup_begin(ctx, "actions") {
		if action := ui_menu_item(ctx, "Add ten"); .Clicked in action.flags {demo.clicks += 10}
		if action := ui_menu_item(ctx, "Toggle details");
		   .Clicked in action.flags {demo.details = !demo.details}
		ui_popup_end(ctx)
	}
	ui_panel_end(ctx)
	ui_col_end(ctx)
	ui_row_end(ctx)

	ui_tag_push(ctx, "muted")
	ui_label(
		ctx,
		fmt.tprintf(
			"%d boxes | %d text bytes | fixed storage###stats",
			ctx.ui.order_next,
			ctx.ui.text_next,
		),
	)
	ui_tag_pop(ctx)
	ui_pane_begin(ctx, "palette", &demo.pane_rect)
	ui_heading(ctx, "Color laboratory")
	ui_color_picker(ctx, "picker", &demo.color)
	ui_label(ctx, "Drag the panel; resize its bottom-right corner.")
	ui_pane_end(ctx)
}

@(private = "file")
ui_action_from_key :: proc(key: sdl.Scancode, mods: sdl.Keymod) -> UI_Action {
	#partial switch key {
	case .TAB:
		return .Previous if .LSHIFT in mods || .RSHIFT in mods else .Next
	case .RETURN, .KP_ENTER, .SPACE:
		return .Accept
	case .BACKSPACE:
		return .Cancel
	case .LEFT:
		return .Left
	case .RIGHT:
		return .Right
	case .UP:
		return .Up
	case .DOWN:
		return .Down
	case .HOME:
		return .Home
	case .END:
		return .End
	case .PAGEUP:
		return .Page_Up
	case .PAGEDOWN:
		return .Page_Down
	}
	return .None
}

Old_New :: enum {
	Old,
	New,
}

Button_State :: enum {
	Down,
	Pressed,
}

Input :: struct {
	keys:         [Old_New][Button_State]#sparse[sdl.Scancode]b8,
	btns:         [Old_New][Button_State][max(u8)]b8,
	pos:          [2]f32,
	pos_is_valid: b32,
}

key_is_down :: proc(input: Input, key: sdl.Scancode) -> bool {
	return bool(input.keys[.New][.Down][key])
}

key_is_pressed :: proc(input: Input, key: sdl.Scancode) -> bool {
	return bool(input.keys[.New][.Pressed][key])
}

button_is_down :: proc(input: Input, button: u8) -> bool {
	return bool(input.btns[.New][.Down][button])
}

button_is_pressed :: proc(input: Input, button: u8) -> bool {
	return bool(input.btns[.New][.Pressed][button])
}

