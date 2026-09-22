package main

// Box/layout/theme semantics adapted from RAD Debugger's UI by Ryan Fleury.
// Reference: https://github.com/EpicGames/raddebugger/tree/master/src/ui
// Copyright (c) Epic Games Tools. Original code licensed under the MIT license.
// This implementation owns its data in bounded, index-addressed tables.

import "core:fmt"
import "core:math"
import "core:strings"

UI_BOX_MAX :: 512
UI_HASH_MAX :: 1024
UI_STACK_MAX :: 64
UI_EVENT_MAX :: 128
UI_TEXT_MAX :: 65536
UI_RUN_MAX :: 1024
UI_TAG_MAX :: 128
UI_TAG_TEXT_MAX :: 8192
UI_THEME_MAX :: 4
UI_THEME_RULE_MAX :: 128
UI_TABLE_COLUMNS_MAX :: 16
UI_TABLE_DEPTH_MAX :: 8

UI_Key :: distinct u64
UI_Box_Id :: distinct u16
UI_Tag_Id :: distinct u8
UI_Theme_Id :: distinct u8
UI_Tags :: [2]u64

UI_Axis :: enum {
	X,
	Y,
}
UI_Size_Kind :: enum {
	Pixels,
	Text,
	Parent,
	Children,
	Fill,
}
UI_Size :: struct {
	kind:       UI_Size_Kind,
	value:      f32,
	strictness: f32,
}
ui_px :: proc(value: f32, strictness: f32 = 1) -> UI_Size {return {.Pixels, value, strictness}}
ui_text_size :: proc(padding: f32 = 0, strictness: f32 = 1) -> UI_Size {return{
		.Text,
		padding,
		strictness,
	}}
ui_pct :: proc(value: f32 = 1, strictness: f32 = 0) -> UI_Size {return{.Parent, value, strictness}}
ui_children_size :: proc(strictness: f32 = 1) -> UI_Size {return {.Children, 0, strictness}}
ui_fill :: proc(weight: f32 = 1) -> UI_Size {return {.Fill, weight, 0}}

UI_Color :: enum {
	None,
	Background,
	Text,
	Border,
	Hot,
	Active,
	Focus,
	Muted,
	Shadow,
}
UI_Palette :: [UI_Color][4]f32
UI_Align :: enum {
	Start,
	Center,
	End,
}
UI_Surface :: enum {
	Main,
	Popup,
	Tooltip,
}
UI_Box_Flag :: enum {
	Background,
	Border,
	Text,
	Image,
	Clickable,
	Focusable,
	Disabled,
	Clip,
	Scroll_X,
	Scroll_Y,
	Floating,
	Wrap,
	Ellipsis,
	Shadow,
	Adjustable,
	Movable,
	Selected,
}
UI_Box_Flags :: bit_set[UI_Box_Flag;u32]
UI_Draw_Kind :: enum {
	Normal,
	Checkbox,
	Expander,
	Slider,
	Scrollbar,
	Saturation_Value,
	Hue,
	Alpha,
	Swatch,
}

UI_Style :: struct {
	size:           [2]UI_Size,
	size_min:       [2]f32,
	position:       [2]f32,
	padding:        [2]f32,
	gap:            f32,
	axis:           UI_Axis,
	font:           Font_Id,
	radius:         f32,
	thickness:      f32,
	softness:       f32,
	opacity:        f32,
	text_align:     UI_Align,
	colors:         UI_Palette,
	color_override: bit_set[UI_Color;u16],
}
UI_Style_Field :: enum {
	All,
	Width,
	Height,
	Position,
	Font,
}

UI_Signal_Flag :: enum {
	Hovered,
	Pressed,
	Released,
	Clicked,
	Double_Clicked,
	Dragging,
	Changed,
	Right_Pressed,
	Keyboard,
}
UI_Signal :: struct {
	box:   UI_Box_Id,
	flags: bit_set[UI_Signal_Flag;u16],
	mouse: [2]f32,
	drag:  [2]f32,
	nav:   [2]i32,
}

UI_Event_Kind :: enum {
	None,
	Press,
	Release,
	Scroll,
	Key,
	Cancel,
}
UI_Action :: enum {
	None,
	Next,
	Previous,
	Accept,
	Cancel,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Page_Up,
	Page_Down,
}
UI_Event :: struct {
	kind:   UI_Event_Kind,
	action: UI_Action,
	pos:    [2]f32,
	delta:  [2]f32,
	button: u8,
	clicks: u8,
}

UI_Theme_Rule :: struct {
	role:        UI_Color, // None is the neutral rule.
	tags:        UI_Tags,
	specificity: int,
	color:       [4]f32,
}
UI_Theme :: struct {
	rules:     [UI_THEME_RULE_MAX]UI_Theme_Rule,
	rule_next: int,
}
UI_Tag :: struct {
	key:  UI_Key,
	text: Span,
}

// Only the procedure-input description borrows strings. Stored runs contain spans.
UI_Run_Desc :: struct {
	text:     string,
	font:     Font_Id,
	color:    [4]f32,
	image:    Image_Id,
	size:     [2]f32,
	is_image: bool,
}
UI_Run :: struct {
	text:     Span,
	font:     Font_Id,
	color:    [4]f32,
	image:    Image_Id,
	size:     [2]f32,
	is_image: bool,
}

UI_Box :: struct {
	key:           UI_Key,
	frame:         u64,
	parent:        UI_Box_Id,
	child_first:   UI_Box_Id,
	child_last:    UI_Box_Id,
	sibling_next:  UI_Box_Id,
	order:         int,
	flags:         UI_Box_Flags,
	style:         UI_Style,
	tags:          UI_Tags,
	surface:       UI_Surface,
	text:          Span,
	runs:          Span,
	image:         Image_Id,
	draw_kind:     UI_Draw_Kind,
	value:         [4]f32,
	rect:          [4]f32,
	clip:          [4]f32,
	content_size:  [2]f32,
	scroll:        [2]f32,
	scroll_target: [2]f32,
	drag_rect:     [4]f32,
	color_previous: [4]f32,
	hsv:           [3]f32,
	colors:        UI_Palette,
	hot_t:         f32,
	active_t:      f32,
	focus_t:       f32,
	disabled_t:    f32,
}

UI_Table_Build :: struct {
	weights:     [UI_TABLE_COLUMNS_MAX]f32,
	weight_sum:  f32,
	column_next: int,
	column_len:  int,
}

// Every field here is value data. No pointers, strings, slices, or built-in maps.
UI :: struct {
	boxes:           [UI_BOX_MAX]UI_Box,
	box_hash:        [UI_HASH_MAX]UI_Box_Id,
	box_free:        [UI_BOX_MAX]UI_Box_Id,
	box_free_span:   Span,
	order:           [UI_BOX_MAX]UI_Box_Id,
	order_next:      int,
	signals:         [UI_BOX_MAX]UI_Signal,
	text:            [UI_TEXT_MAX]u8,
	text_next:       int,
	runs:            [UI_RUN_MAX]UI_Run,
	run_next:        int,
	events:          [UI_EVENT_MAX]UI_Event,
	event_next:      int,
	tags:            [UI_TAG_MAX]UI_Tag,
	tag_hash:        [UI_TAG_MAX * 2]UI_Tag_Id,
	tag_text:        [UI_TAG_TEXT_MAX]u8,
	tag_text_next:   int,
	tag_next:        int,
	themes:          [UI_THEME_MAX]UI_Theme,
	theme_active:    UI_Theme_Id,
	parent_stack:    [UI_STACK_MAX]UI_Box_Id,
	parent_depth:    int,
	key_stack:       [UI_STACK_MAX]UI_Key,
	key_depth:       int,
	tag_stack:       [UI_STACK_MAX]UI_Tag_Id,
	tag_depth:       int,
	style_stack:     [UI_STACK_MAX]UI_Style,
	style_depth:     int,
	style_next:      UI_Style,
	style_next_mask: bit_set[UI_Style_Field;u8],
	table_stack:     [UI_TABLE_DEPTH_MAX]UI_Table_Build,
	table_depth:     int,
	frame:           u64,
	font_default:    Font_Id,
	font_heading:    Font_Id,
	root:            UI_Box_Id,
	hot:             UI_Key,
	active:          UI_Key,
	focus:           UI_Key,
	focus_reveal:    bool,
	drag_start:      [2]f32,
	hover_time:      f32,
	popup_key:       UI_Key,
	popup_anchor:    UI_Key,
	popup_focus_return: UI_Key,
	popup_position:  [2]f32,
	surface:         UI_Surface,
	scroll_drag:     int, // 0: none, 1: horizontal, 2: vertical.
}

// Only the transient context borrows table pointers.
UI_Ctx :: struct {
	ui:        ^UI,
	draw:      ^Draw_Ctx,
	input:     ^Input,
	view_size: [2]f32,
	dt:        f32,
}

@(private = "file")
ui_hash :: proc(seed: UI_Key, text: string) -> UI_Key {
	h := u64(seed) ~ 14695981039346656037
	for i in 0..<len(text) {
		h = (h ~ u64(text[i])) * 1099511628211
	}
	return UI_Key(h | 1)
}

ui_key_from_string :: proc(seed: UI_Key, text: string) -> UI_Key {
	if text == "" {return 0}
	part := text
	if at := strings.index(text, "###"); at >= 0 {part = text[at:]}
	return ui_hash(seed, part)
}

@(private = "file")
ui_text_store :: proc(ui: ^UI, text: string) -> Span {
	n := min(len(text), UI_TEXT_MAX - ui.text_next)
	if n < len(text) {
		for n > 0 && (text[n] & 0xc0) == 0x80 {n -= 1}
	}
	span := Span{ui.text_next, n}
	copy(ui.text[span.begin:span.begin + n], transmute([]u8)text[:n])
	ui.text_next += n
	return span
}

@(private = "file")
ui_text_get :: proc(ui: ^UI, span: Span) -> string {
	return string(ui.text[span.begin:span.begin + span.len])
}

@(private = "file")
ui_box_find :: proc(ui: ^UI, key: UI_Key) -> UI_Box_Id {
	if key == 0 {return 0}
	for probe in 0 ..< UI_HASH_MAX {
		slot := (int(u64(key) % UI_HASH_MAX) + probe) % UI_HASH_MAX
		id := ui.box_hash[slot]
		if id == 0 || ui.boxes[id].key == key {return id}
	}
	return 0
}

@(private = "file")
ui_box_hash_insert :: proc(ui: ^UI, id: UI_Box_Id) {
	for probe in 0 ..< UI_HASH_MAX {
		slot := (int(u64(ui.boxes[id].key) % UI_HASH_MAX) + probe) % UI_HASH_MAX
		if ui.box_hash[slot] == 0 {ui.box_hash[slot] = id; break}
	}
}

ui_tag :: proc(ui: ^UI, name: string) -> UI_Tag_Id {
	if name == "" {return 0}
	key := ui_hash(0, name)
	for probe in 0 ..< len(ui.tag_hash) {
		slot := (int(u64(key) % u64(len(ui.tag_hash))) + probe) % len(ui.tag_hash)
		id := ui.tag_hash[slot]
		if id != 0 {
			entry := ui.tags[id]
			if entry.key == key &&
			   string(ui.tag_text[entry.text.begin:entry.text.begin + entry.text.len]) ==
				   name {return id}
		} else {
			if ui.tag_next >= UI_TAG_MAX ||
			   len(name) > UI_TAG_TEXT_MAX - ui.tag_text_next {return 0}
			id = UI_Tag_Id(ui.tag_next)
			span := Span{ui.tag_text_next, len(name)}
			copy(ui.tag_text[span.begin:span.begin + span.len], transmute([]u8)name)
			ui.tags[id] = {key, span}
			ui.tag_hash[slot] = id
			ui.tag_next += 1
			ui.tag_text_next += len(name)
			return id
		}
	}
	return 0
}

@(private = "file")
ui_tags_add :: proc(tags: ^UI_Tags, tag: UI_Tag_Id) {
	if tag != 0 {tags[int(tag) / 64] |= u64(1) << (uint(tag) % 64)}
}

// Rules match a color role plus a subset of scoped tags. More tags win; first wins ties.
ui_theme_rule :: proc(ui: ^UI, theme: UI_Theme_Id, role: UI_Color, tags: []string, color: [4]f32) {
	assert(int(theme) < UI_THEME_MAX)
	t := &ui.themes[theme]
	if t.rule_next < UI_THEME_RULE_MAX {
		rule := UI_Theme_Rule {
			role  = role,
			color = color,
		}
		for name in tags {
			before := rule.tags
			ui_tags_add(&rule.tags, ui_tag(ui, name))
			if before != rule.tags {rule.specificity += 1}
		}
		t.rules[t.rule_next] = rule
		t.rule_next += 1
	}
}

@(private = "file")
ui_theme_color :: proc(ui: ^UI, tags: UI_Tags, role: UI_Color) -> (color: [4]f32) {
	specificity := -1
	for rule in ui.themes[ui.theme_active].rules {
		if rule.role == role &&
		   rule.specificity > specificity &&
		   (rule.tags[0] & tags[0]) == rule.tags[0] &&
		   (rule.tags[1] & tags[1]) == rule.tags[1] {
			color, specificity = rule.color, rule.specificity
		}
	}
	return
}

ui_theme_select :: proc(ui: ^UI, theme: UI_Theme_Id) {
	if int(theme) < UI_THEME_MAX {ui.theme_active = theme}
}

ui_init :: proc(ui: ^UI, font: Font_Id, heading: Font_Id = 0) {
	ui^ = {}
	ui.font_default = font
	ui.font_heading = heading
	ui.tag_next = 1
	palettes := [3]UI_Palette {
		{
			.None = {}, .Background = {0.07, 0.09, 0.13, 1},
			.Text = {0.91, 0.92, 0.94, 1},
			.Border = {0.24, 0.29, 0.36, 1},
			.Hot = {0.24, 0.32, 0.43, 1},
			.Active = {0.29, 0.41, 0.56, 1},
			.Focus = {0.9, 0.71, 0.38, 1},
			.Muted = {0.55, 0.61, 0.7, 1},
			.Shadow = {0, 0, 0, 0.35},
		},
		{
			.None = {}, .Background = {0.91, 0.92, 0.94, 1},
			.Text = {0.13, 0.17, 0.23, 1},
			.Border = {0.65, 0.69, 0.75, 1},
			.Hot = {0.72, 0.81, 0.92, 1},
			.Active = {0.56, 0.7, 0.87, 1},
			.Focus = {0.15, 0.39, 0.72, 1},
			.Muted = {0.4, 0.45, 0.52, 1},
			.Shadow = {0, 0, 0, 0.16},
		},
		{
			.None = {}, .Background = {0.015, 0.015, 0.02, 1},
			.Text = {1, 1, 1, 1},
			.Border = {0.65, 0.68, 0.75, 1},
			.Hot = {0.22, 0.22, 0.29, 1},
			.Active = {0.36, 0.36, 0.46, 1},
			.Focus = {1, 0.85, 0.1, 1},
			.Muted = {0.75, 0.75, 0.8, 1},
			.Shadow = {0, 0, 0, 0.6},
		},
	}
	for palette, i in palettes {
		for role in UI_Color {
			if role != .None {ui_theme_rule(ui, UI_Theme_Id(i), role, nil, palette[role])}
		}
		panel := palette[.Background]
		button := palette[.Background]
		for c in 0 ..< 3 {
			panel[c] += -0.04 if i == 1 else 0.035
			button[c] += -0.08 if i == 1 else 0.08
		}
		ui_theme_rule(ui, UI_Theme_Id(i), .Background, []string{"button"}, button)
		ui_theme_rule(ui, UI_Theme_Id(i), .Background, []string{"panel"}, panel)
		ui_theme_rule(ui, UI_Theme_Id(i), .Background, []string{"popup"}, panel)
		ui_theme_rule(ui, UI_Theme_Id(i), .Background, []string{"tooltip"}, button)
		ui_theme_rule(ui, UI_Theme_Id(i), .Text, []string{"muted"}, palette[.Muted])
		ui_theme_rule(ui, UI_Theme_Id(i), .Text, []string{"heading"}, palette[.Focus])
		ui_theme_rule(
			ui,
			UI_Theme_Id(i),
			.Background,
			[]string{"button", "primary"},
			{0.23, 0.39, 0.61, 1},
		)
		ui_theme_rule(ui, UI_Theme_Id(i), .Text, []string{"button", "primary"}, {1, 1, 1, 1})
		ui_theme_rule(
			ui,
			UI_Theme_Id(i),
			.Background,
			[]string{"button", "danger"},
			{0.48, 0.15, 0.19, 1},
		)
		ui_theme_rule(ui, UI_Theme_Id(i), .Text, []string{"button", "danger"}, {1, 0.92, 0.9, 1})
	}
}

ui_style_top :: proc(ctx: ^UI_Ctx) -> UI_Style {
	return ctx.ui.style_stack[min(ctx.ui.style_depth, UI_STACK_MAX) - 1]
}
ui_style_push :: proc(ctx: ^UI_Ctx, style: UI_Style) {
	depth := ctx.ui.style_depth
	ctx.ui.style_depth += 1
	if depth < UI_STACK_MAX {ctx.ui.style_stack[depth] = style}
}
ui_style_pop :: proc(ctx: ^UI_Ctx) {ctx.ui.style_depth = max(1, ctx.ui.style_depth - 1)}
ui_style_next :: proc(ctx: ^UI_Ctx, style: UI_Style) {
	ctx.ui.style_next = style
	ctx.ui.style_next_mask = {.All}
}
ui_width_next :: proc(ctx: ^UI_Ctx, size: UI_Size) {
	ctx.ui.style_next.size[0] = size
	ctx.ui.style_next_mask += {.Width}
}
ui_height_next :: proc(ctx: ^UI_Ctx, size: UI_Size) {
	ctx.ui.style_next.size[1] = size
	ctx.ui.style_next_mask += {.Height}
}
ui_font_next :: proc(ctx: ^UI_Ctx, font: Font_Id) {
	ctx.ui.style_next.font = font
	ctx.ui.style_next_mask += {.Font}
}
ui_position_next :: proc(ctx: ^UI_Ctx, position: [2]f32) {
	ctx.ui.style_next.position = position
	ctx.ui.style_next_mask += {.Position}
}
ui_parent_push :: proc(ctx: ^UI_Ctx, box: UI_Box_Id) {
	depth := ctx.ui.parent_depth
	ctx.ui.parent_depth += 1
	if depth < UI_STACK_MAX {ctx.ui.parent_stack[depth] = box}
}
ui_parent_pop :: proc(ctx: ^UI_Ctx) {ctx.ui.parent_depth = max(1, ctx.ui.parent_depth - 1)}
ui_tag_push :: proc(ctx: ^UI_Ctx, name: string) {
	depth := ctx.ui.tag_depth
	ctx.ui.tag_depth += 1
	if depth < UI_STACK_MAX {ctx.ui.tag_stack[depth] = ui_tag(ctx.ui, name)}
}
ui_tag_pop :: proc(ctx: ^UI_Ctx) {ctx.ui.tag_depth = max(0, ctx.ui.tag_depth - 1)}

@(private = "file")
ui_seed :: proc(ctx: ^UI_Ctx) -> UI_Key {
	if ctx.ui.key_depth > 0 {return ctx.ui.key_stack[min(ctx.ui.key_depth, UI_STACK_MAX) - 1]}
	for i := min(ctx.ui.parent_depth, UI_STACK_MAX) - 1; i >= 0; i -= 1 {
		key := ctx.ui.boxes[ctx.ui.parent_stack[i]].key
		if key != 0 {return key}
	}
	return 0
}
ui_key_push :: proc(ctx: ^UI_Ctx, name: string) {
	key := ui_key_from_string(ui_seed(ctx), name)
	depth := ctx.ui.key_depth
	ctx.ui.key_depth += 1
	if depth < UI_STACK_MAX {ctx.ui.key_stack[depth] = key}
}
ui_key_push_u64 :: proc(ctx: ^UI_Ctx, value: u64) {
	value := value
	key := ui_hash(ui_seed(ctx), string((cast([^]u8)&value)[:size_of(value)]))
	depth := ctx.ui.key_depth
	ctx.ui.key_depth += 1
	if depth < UI_STACK_MAX {ctx.ui.key_stack[depth] = key}
}
ui_key_pop :: proc(ctx: ^UI_Ctx) {ctx.ui.key_depth = max(0, ctx.ui.key_depth - 1)}

@(private = "file")
ui_box_make :: proc(ctx: ^UI_Ctx, key: UI_Key, flags: UI_Box_Flags, style: UI_Style) -> UI_Box_Id {
	ui := ctx.ui
	s := style
	m := ui.style_next_mask
	if .All in m {s = ui.style_next}
	if .Width in m {s.size[0] = ui.style_next.size[0]}
	if .Height in m {s.size[1] = ui.style_next.size[1]}
	if .Position in m {s.position = ui.style_next.position}
	if .Font in m {s.font = ui.style_next.font}
	ui.style_next_mask = {}
	id := ui_box_find(ui, key)
	key := key
	if id != 0 && ui.boxes[id].frame == ui.frame {id, key = 0, 0}
	if id == 0 && ui.box_free_span.len > 0 {
		id = ui.box_free[ui.box_free_span.begin]
		span_advance(&ui.box_free_span)
		ui.boxes[id] = {
			key = key,
		}
		if key != 0 {ui_box_hash_insert(ui, id)}
	}
	if id != 0 {
		b := &ui.boxes[id]
		fresh := b.frame == 0
		b.frame = ui.frame
		b.parent =
			ui.parent_stack[min(ui.parent_depth, UI_STACK_MAX) - 1] if ui.parent_depth > 0 else 0
		b.child_first, b.child_last, b.sibling_next = 0, 0, 0
		b.flags, b.style, b.surface = flags, s, ui.surface
		b.text, b.runs, b.value, b.tags = {}, {}, {}, {}
		b.image, b.draw_kind = 0, .Normal
		for i in 0 ..< min(ui.tag_depth, UI_STACK_MAX) {ui_tags_add(&b.tags, ui.tag_stack[i])}
		b.order = ui.order_next
		ui.order[ui.order_next] = id
		ui.order_next += 1
		if b.parent != 0 {
			parent := &ui.boxes[b.parent]
			if .Disabled in parent.flags {b.flags += {.Disabled}}
			if parent.child_last ==
			   0 {parent.child_first = id} else {ui.boxes[parent.child_last].sibling_next = id}
			parent.child_last = id
		}
		if fresh {
			for role in UI_Color {
				b.colors[role] = s.colors[role] if role in s.color_override else ui_theme_color(ui, b.tags, role)
			}
		}
		ui.signals[id].box = id
	}
	return id
}

ui_box :: proc(ctx: ^UI_Ctx, label: string, flags: UI_Box_Flags) -> UI_Box_Id {
	id := ui_box_make(ctx, ui_key_from_string(ui_seed(ctx), label), flags, ui_style_top(ctx))
	if id != 0 && .Text in flags {
		end := strings.index(label, "##")
		if end < 0 {end = len(label)}
		ctx.ui.boxes[id].text = ui_text_store(ctx.ui, label[:end])
	}
	return id
}

ui_box_text :: proc(ctx: ^UI_Ctx, id: UI_Box_Id, text: string) {
	if id != 0 {
		ctx.ui.boxes[id].text = ui_text_store(ctx.ui, text)
		ctx.ui.boxes[id].flags += {.Text}
	}
}

ui_signal :: proc(ctx: ^UI_Ctx, id: UI_Box_Id) -> UI_Signal {return ctx.ui.signals[id]}

// Input records remain ordered. Empty records are neutral; cursor is only for insertion.
ui_input_begin :: proc(ui: ^UI) {ui.events = {}; ui.event_next = 0}
ui_input_push :: proc(ui: ^UI, event: UI_Event) {
	if ui.event_next < UI_EVENT_MAX {ui.events[ui.event_next] = event; ui.event_next += 1}
}

@(private = "file")
ui_rect_intersect :: proc(a, b: [4]f32) -> [4]f32 {
	x, y := max(a.x, b.x), max(a.y, b.y)
	return {x, y, max(0, min(a.x + a.z, b.x + b.z) - x), max(0, min(a.y + a.w, b.y + b.w) - y)}
}
@(private = "file")
ui_rect_contains :: proc(rect: [4]f32, pos: [2]f32) -> bool {
	return pos.x >= rect.x && pos.y >= rect.y && pos.x < rect.x + rect.z && pos.y < rect.y + rect.w
}
@(private = "file")
ui_surface_accepts_input :: proc(ui: ^UI, b: UI_Box) -> bool {
	return b.frame + 1 == ui.frame && .Disabled not_in b.flags && b.surface != .Tooltip &&
		((ui.popup_key != 0 && b.surface == .Popup) || (ui.popup_key == 0 && b.surface == .Main))
}
@(private = "file")
ui_hit :: proc(ctx: ^UI_Ctx, pos: [2]f32, scroll: bool = false) -> (id: UI_Box_Id) {
	order := -1
	for b, i in ctx.ui.boxes {
		interactive := (.Scroll_X in b.flags || .Scroll_Y in b.flags) if scroll else
			(.Clickable in b.flags || .Movable in b.flags || .Scroll_X in b.flags || .Scroll_Y in b.flags)
		if interactive && ui_surface_accepts_input(ctx.ui, b) && b.order > order &&
		   ui_rect_contains(ui_rect_intersect(b.rect, b.clip), pos) {
			id, order = UI_Box_Id(i), b.order
		}
	}
	return
}

@(private = "file")
ui_focus_move :: proc(ctx: ^UI_Ctx, action: UI_Action) {
	ui := ctx.ui
	current := ui_box_find(ui, ui.focus)
	order := ui.boxes[current].order if current != 0 else -1
	best, wrap: UI_Box_Id
	best_order := UI_BOX_MAX if action == .Next else -1
	wrap_order := UI_BOX_MAX if action == .Next else -1
	best_distance: f32 = 1e30
	for b, i in ui.boxes {
		if .Focusable in b.flags && ui_surface_accepts_input(ui, b) {
			id := UI_Box_Id(i)
			#partial switch action {
			case .Next:
				if b.order > order && b.order < best_order {best, best_order = id, b.order}
				if b.order < wrap_order {wrap, wrap_order = id, b.order}
			case .Previous:
				if b.order < order && b.order > best_order {best, best_order = id, b.order}
				if b.order > wrap_order {wrap, wrap_order = id, b.order}
			case .Home:
				if best == 0 || b.order < ui.boxes[best].order {best = id}
			case .End:
				if best == 0 || b.order > ui.boxes[best].order {best = id}
			case:
				origin := ui.boxes[current].rect
				delta := [2]f32{b.rect.x + b.rect.z/2 - origin.x - origin.z/2, b.rect.y + b.rect.w/2 - origin.y - origin.w/2}
				axis := 0 if action == .Left || action == .Right else 1
				direction: f32 = -1 if action == .Left || action == .Up || action == .Page_Up else 1
				distance := abs(delta[axis]) + 2 * abs(delta[1-axis])
				if id != current && delta[axis] * direction > 0 && distance < best_distance {best, best_distance = id, distance}
			}
		}
	}
	if best == 0 {best = wrap}
	if best != 0 {ui.focus = ui.boxes[best].key; ui.focus_reveal = true}
}

@(private = "file")
ui_interact :: proc(ctx: ^UI_Ctx) {
	ui := ctx.ui
	ui.signals = {}
	for event in ui.events {
		switch event.kind {
		case .None:
		case .Cancel:
			ui.active, ui.focus, ui.popup_key = 0, 0, 0
			ui.scroll_drag = 0
		case .Press:
			id := ui_hit(ctx, event.pos)
			if ui.popup_key != 0 && id == 0 {ui.popup_key = 0}
			if id != 0 {
				b := &ui.boxes[id]
				s := &ui.signals[id]
				s.mouse = event.pos
				if event.button == 3 {s.flags += {.Right_Pressed}}
				if event.button == 1 {
					ui.active = b.key
					ui.drag_start = event.pos
					b.drag_rect = b.rect
					s.flags += {.Pressed}
					if event.clicks >= 2 {s.flags += {.Double_Clicked}}
					if .Focusable in b.flags {ui.focus = b.key}
					ui.scroll_drag = 0
					if .Scroll_Y in b.flags && event.pos.x >= b.rect.x + b.rect.z - 14 {ui.scroll_drag = 2}
					if .Scroll_X in b.flags && event.pos.y >= b.rect.y + b.rect.w - 14 {ui.scroll_drag = 1}
				}
			} else if event.button == 1 {ui.focus = 0}
		case .Release:
			if event.button == 1 {
				id := ui_box_find(ui, ui.active)
				if id != 0 {
					s := &ui.signals[id]
					s.mouse = event.pos
					s.drag = event.pos - ui.drag_start
					s.flags += {.Released}
					if ui_hit(ctx, event.pos) == id {s.flags += {.Clicked}}
				}
				ui.active = 0
				ui.scroll_drag = 0
			}
		case .Scroll:
			id := ui_hit(ctx, event.pos, true)
			if id != 0 {
				b := &ui.boxes[id]
				if .Scroll_X in b.flags {b.scroll_target.x -= event.delta.x * 36}
				if .Scroll_Y in b.flags {b.scroll_target.y -= event.delta.y * 36}
			}
		case .Key:
			id := ui_box_find(ui, ui.focus)
			#partial switch event.action {
			case .Cancel:
				ui.active = 0
				if ui.popup_key != 0 {ui_popup_close(ctx)} else {ui.focus = 0}
			case .Next, .Previous:
				ui_focus_move(ctx, event.action)
			case .Accept:
				if id != 0 && ui_surface_accepts_input(ui, ui.boxes[id]) {ui.signals[id].flags += {.Pressed, .Released, .Clicked, .Keyboard}}
			case .Left, .Right, .Up, .Down, .Home, .End, .Page_Up, .Page_Down:
				if id != 0 && .Adjustable in ui.boxes[id].flags {
					#partial switch event.action {
					case .Left: ui.signals[id].nav.x -= 1
					case .Right: ui.signals[id].nav.x += 1
					case .Up: ui.signals[id].nav.y -= 1
					case .Down: ui.signals[id].nav.y += 1
					case .Home: ui.signals[id].nav = {-100000, -100000}
					case .End: ui.signals[id].nav = {100000, 100000}
					case .Page_Up: ui.signals[id].nav.y -= 10
					case .Page_Down: ui.signals[id].nav.y += 10
					case:
					}
				} else {ui_focus_move(ctx, event.action)}
			case:
			}
		}
	}
	hot: UI_Box_Id
	if ctx.input.pos_is_valid {hot = ui_hit(ctx, ctx.input.pos)}
	hot_key := ui.boxes[hot].key
	ui.hover_time = ui.hover_time + ctx.dt if hot_key == ui.hot else 0
	ui.hot = hot_key
	if hot != 0 {ui.signals[hot].flags += {.Hovered}}
	active := ui_box_find(ui, ui.active)
	if active != 0 {
		ui.signals[active].flags += {.Dragging}
		ui.signals[active].mouse = ctx.input.pos
		ui.signals[active].drag = ctx.input.pos - ui.drag_start
		if ui.scroll_drag > 0 {
			axis := ui.scroll_drag - 1
			b := &ui.boxes[active]
			view := max(1, b.rect[axis + 2] - 2*b.style.padding[axis])
			content := max(view, b.content_size[axis])
			fraction := clamp((ctx.input.pos[axis] - b.rect[axis] - b.style.padding[axis]) / view, 0, 1)
			b.scroll_target[axis] = max(0, fraction * content - view/2)
		}
	}
}

ui_begin :: proc(ctx: ^UI_Ctx, ui: ^UI, draw: ^Draw_Ctx, input: ^Input, view_size: [2]f32, dt: f32) {
	ctx^ = {ui, draw, input, view_size, clamp(dt, 0, 0.1)}
	ui.frame += 1
	ui_interact(ctx)
	// Rebuild the bounded lookup each frame: no tombstones or allocations.
	ui.box_hash = {}
	free_count := 0
	for &b, i in ui.boxes {
		if i != 0 {
			if b.frame + 1 == ui.frame && b.key != 0 {ui_box_hash_insert(ui, UI_Box_Id(i))} else {
				b = {}
				ui.box_free[free_count] = UI_Box_Id(i)
				free_count += 1
			}
		}
	}
	ui.box_free_span = {0, free_count}
	ui.order, ui.order_next = {}, 0
	ui.text_next, ui.run_next = 0, 0
	ui.parent_depth, ui.key_depth, ui.tag_depth, ui.table_depth = 0, 0, 0, 0
	ui.style_depth, ui.style_next_mask, ui.surface = 1, {}, .Main
	ui.style_stack[0] = {
		size = {ui_text_size(), ui_text_size()}, padding = {8, 5}, gap = 8,
		axis = .Y, font = ui.font_default, radius = 5, thickness = 1, softness = 0.8, opacity = 1,
	}
	root_style := ui_style_top(ctx)
	root_style.size = {ui_px(view_size.x), ui_px(view_size.y)}
	root_style.padding = {20, 20}
	root_style.gap = 12
	ui.root = ui_box_make(ctx, ui_key_from_string(0, "###root"), {.Background, .Clip}, root_style)
	ui_parent_push(ctx, ui.root)
}

@(private = "file")
ui_box_padding :: proc(b: UI_Box) -> [2]f32 {
	return b.style.padding * 2 + [2]f32{12 if .Scroll_Y in b.flags else 0, 12 if .Scroll_X in b.flags else 0}
}

// A zero-span writer reuses wrapped layout without writes, allocations, or a renderer.
@(private = "file")
ui_text_dimensions :: proc(ctx: ^UI_Ctx, b: UI_Box, width: f32 = 0) -> (size: [2]f32) {
	if b.runs.len > 0 {
		ascent, descent: f32
		for run in ctx.ui.runs[b.runs.begin:b.runs.begin + b.runs.len] {
			if run.is_image {size.x += run.size.x; ascent = max(ascent, run.size.y)} else {
				part := text_measure(ctx.draw.sprites, run.font, ui_text_get(ctx.ui, run.text))
				size.x += part.x
				info := ctx.draw.sprites.fonts[run.font].info
				ascent, descent = max(ascent, info.ascent), max(descent, -info.descent)
			}
		}
		size.y = ascent + descent
	} else if .Text in b.flags {
		text := ui_text_get(ctx.ui, b.text)
		if .Wrap in b.flags && width > 0 {
			sink := Draw_Ctx{sprites = ctx.draw.sprites}
			size = draw_text_wrapped(&sink, b.style.font, text, {}, width, {})
		} else {size = text_measure(ctx.draw.sprites, b.style.font, text)}
	} else if .Image in b.flags {
		region := ctx.draw.sprites.regions[sprite_of_image(b.image)]
		size = {region.source.z, region.source.w}
	}
	if b.draw_kind == .Checkbox || b.draw_kind == .Expander {size.x += 26}
	return
}

@(private = "file")
ui_layout :: proc(ctx: ^UI_Ctx) {
	ui := ctx.ui
	for axis in 0..<2 {
		// Standalone and ancestor-relative sizes, in parent-before-child order.
		for id in ui.order {
			if id != 0 {
				b := &ui.boxes[id]
				pref := b.style.size[axis]
				pad := ui_box_padding(b^)
				size: f32
				switch pref.kind {
				case .Pixels: size = pref.value
				case .Text:
					dim := ui_text_dimensions(ctx, b^, max(0, b.rect.z - pad.x))
					size = dim[axis] + pad[axis] + pref.value
				case .Parent:
					parent := b.parent
					for parent != 0 && ui.boxes[parent].style.size[axis].kind == .Children {parent = ui.boxes[parent].parent}
					if parent != 0 {size = max(0, ui.boxes[parent].rect[axis+2] - ui_box_padding(ui.boxes[parent])[axis]) * pref.value}
				case .Children, .Fill:
				}
				b.rect[axis+2] = max(size, b.style.size_min[axis])
			}
		}
		// Children-derived sizes, in reverse construction order.
		for i := UI_BOX_MAX - 1; i >= 0; i -= 1 {
			id := ui.order[i]
			if id != 0 {
				b := &ui.boxes[id]
				if b.style.size[axis].kind == .Children {
					size: f32
					count := 0
					for child := b.child_first; child != 0; child = ui.boxes[child].sibling_next {
						c := ui.boxes[child]
						if .Floating not_in c.flags {
							if int(b.style.axis) == axis {size += c.rect[axis+2]} else {size = max(size, c.rect[axis+2])}
							count += 1
						}
					}
					if int(b.style.axis) == axis {size += f32(max(0, count-1)) * b.style.gap}
					b.rect[axis+2] = max(b.style.size_min[axis], size + ui_box_padding(b^)[axis])
				}
			}
		}
		// Distribute fill space, then shrink non-strict children where necessary.
		for id in ui.order {
			if id != 0 {
				b := &ui.boxes[id]
				available := max(0, b.rect[axis+2] - ui_box_padding(b^)[axis])
				along := axis == int(b.style.axis)
				overflow := (.Scroll_X in b.flags) if axis == 0 else (.Scroll_Y in b.flags)
				total, flexible, weights: f32
				count := 0
				for child := b.child_first; child != 0; child = ui.boxes[child].sibling_next {
					c := &ui.boxes[child]
					if .Floating not_in c.flags {
						count += 1
						if c.style.size[axis].kind == .Parent && b.style.size[axis].kind != .Children {
							c.rect[axis+2] = max(c.style.size_min[axis], available * c.style.size[axis].value)
						}
						if c.style.size[axis].kind == .Fill {weights += max(0, c.style.size[axis].value)} else {total += c.rect[axis+2]}
						flexible += max(0, c.rect[axis+2] - c.style.size_min[axis]) * (1 - clamp(c.style.size[axis].strictness, 0, 1))
					}
				}
				if along {total += f32(max(0, count-1)) * b.style.gap}
				shrink := clamp((total - available) / flexible, 0, 1) if flexible > 0 && !overflow else 0
				for child := b.child_first; child != 0; child = ui.boxes[child].sibling_next {
					c := &ui.boxes[child]
					if .Floating not_in c.flags {
						size := c.rect[axis+2]
						if c.style.size[axis].kind == .Fill {
							size = max(0, available - total) * c.style.size[axis].value / weights if along && weights > 0 else available
						} else if along {
							size -= max(0, size - c.style.size_min[axis]) * (1 - clamp(c.style.size[axis].strictness, 0, 1)) * shrink
						} else if !overflow {size = min(size, available)}
						c.rect[axis+2] = max(c.style.size_min[axis], size)
					}
				}
			}
		}
	}
	// Final positions, clipping, and scrolling. Every edge is visited once.
	ui.boxes[ui.root].rect.x, ui.boxes[ui.root].rect.y = 0, 0
	ui.boxes[ui.root].clip = {0, 0, ctx.view_size.x, ctx.view_size.y}
	for id in ui.order {
		if id != 0 {
			b := &ui.boxes[id]
			if b.surface != .Main && .Floating in b.flags {
				pos := b.style.position
				if b.key == ui.popup_key {
					anchor := ui_box_find(ui, ui.popup_anchor)
					pos = ui.popup_position
					if anchor != 0 {a := ui.boxes[anchor].rect; pos = {a.x, a.y+a.w+4}}
				}
				b.rect.x = clamp(pos.x, 0, max(0, ctx.view_size.x-b.rect.z))
				b.rect.y = clamp(pos.y, 0, max(0, ctx.view_size.y-b.rect.w))
			}
			cursor: f32
			bounds: [2]f32
			axis := int(b.style.axis)
			for child := b.child_first; child != 0; child = ui.boxes[child].sibling_next {
				c := &ui.boxes[child]
				if .Floating not_in c.flags {
					bounds[axis] = cursor + c.rect[axis+2]
					bounds[1-axis] = max(bounds[1-axis], c.rect[3-axis])
					cursor += c.rect[axis+2] + b.style.gap
				}
			}
			b.content_size = bounds
			view := [2]f32{b.rect.z, b.rect.w} - ui_box_padding(b^)
			for a in 0..<2 {b.scroll_target[a] = clamp(b.scroll_target[a], 0, max(0, bounds[a] - view[a]))}
			b.scroll += (b.scroll_target - b.scroll) * f32(1 - math.exp(-20 * f64(ctx.dt)))
			cursor = 0
			for child := b.child_first; child != 0; child = ui.boxes[child].sibling_next {
				c := &ui.boxes[child]
				pos := [2]f32{b.rect.x, b.rect.y} + b.style.padding - b.scroll
				if .Floating in c.flags {pos = c.style.position} else {pos[axis] += cursor; cursor += c.rect[axis+2] + b.style.gap}
				if ui.popup_key != 0 && c.key == ui.popup_key {
					anchor := ui_box_find(ui, ui.popup_anchor)
					pos = ui.popup_position
					if anchor != 0 {a := ui.boxes[anchor].rect; pos = {a.x, a.y + a.w + 4}}
				}
				if c.surface != .Main && .Floating in c.flags {
					pos = {clamp(pos.x, 0, max(0, ctx.view_size.x - c.rect.z)), clamp(pos.y, 0, max(0, ctx.view_size.y - c.rect.w))}
				}
				c.rect.x, c.rect.y = pos.x, pos.y
				c.clip = ui_rect_intersect(b.clip, b.rect) if .Clip in b.flags else b.clip
			}
		}
	}
}

// Widgets are box constructors. Application-owned values are borrowed only during calls.
ui_label :: proc(ctx: ^UI_Ctx, text: string) -> UI_Signal {
	id := ui_box(ctx, text, {.Text, .Ellipsis})
	return ui_signal(ctx, id)
}
ui_label_wrapped :: proc(ctx: ^UI_Ctx, text: string) -> UI_Signal {
	ui_width_next(ctx, ui_pct())
	id := ui_box(ctx, text, {.Text, .Wrap})
	return ui_signal(ctx, id)
}
ui_heading :: proc(ctx: ^UI_Ctx, text: string) -> UI_Signal {
	ui_tag_push(ctx, "heading")
	ui_font_next(ctx, ctx.ui.font_heading)
	id := ui_box(ctx, text, {.Text, .Ellipsis})
	ui_tag_pop(ctx)
	return ui_signal(ctx, id)
}
ui_button :: proc(ctx: ^UI_Ctx, label: string) -> UI_Signal {
	ui_tag_push(ctx, "button")
	id := ui_box(ctx, label, {.Text, .Background, .Border, .Clickable, .Focusable, .Ellipsis})
	ui_tag_pop(ctx)
	return ui_signal(ctx, id)
}
ui_checkbox :: proc(ctx: ^UI_Ctx, label: string, value: ^bool) -> UI_Signal {
	s := ui_button(ctx, label)
	if .Clicked in s.flags {value^ = !value^; s.flags += {.Changed}}
	if s.box != 0 {ctx.ui.boxes[s.box].draw_kind = .Checkbox; ctx.ui.boxes[s.box].value.x = 1 if value^ else 0}
	return s
}
ui_expander :: proc(ctx: ^UI_Ctx, label: string, expanded: ^bool) -> UI_Signal {
	s := ui_checkbox(ctx, label, expanded)
	if s.box != 0 {ctx.ui.boxes[s.box].draw_kind = .Expander}
	return s
}
ui_image :: proc(ctx: ^UI_Ctx, key: string, image: Image_Id) -> UI_Signal {
	id := ui_box(ctx, key, {.Image})
	if id != 0 {ctx.ui.boxes[id].image = image}
	return ui_signal(ctx, id)
}
ui_label_rich :: proc(ctx: ^UI_Ctx, key: string, parts: []UI_Run_Desc) -> UI_Signal {
	id := ui_box(ctx, key, {.Text})
	if id != 0 {
		b := &ctx.ui.boxes[id]
		b.text = {}
		b.runs.begin = ctx.ui.run_next
		for part in parts {
			if ctx.ui.run_next < UI_RUN_MAX {
				size := part.size
				if part.is_image && size.y == 0 {size.y = f32(ctx.draw.sprites.fonts[b.style.font].size)}
				if part.is_image && size.x == 0 {
					region := ctx.draw.sprites.regions[sprite_of_image(part.image)]
					size.x = size.y * region.source.z / region.source.w if region.source.w > 0 else 0
				}
				ctx.ui.runs[ctx.ui.run_next] = {ui_text_store(ctx.ui, part.text), part.font, part.color, part.image, size, part.is_image}
				ctx.ui.run_next += 1
				b.runs.len += 1
			}
		}
	}
	return ui_signal(ctx, id)
}

@(private = "file")
ui_group_begin :: proc(ctx: ^UI_Ctx, key: string, axis: UI_Axis, flags: UI_Box_Flags, padding: [2]f32) -> UI_Box_Id {
	style := ui_style_top(ctx)
	style.axis, style.padding = axis, padding
	style.size = {ui_pct(), ui_children_size()}
	id := ui_box_make(ctx, ui_key_from_string(ui_seed(ctx), key), flags, style)
	ui_parent_push(ctx, id)
	return id
}
ui_row_begin :: proc(ctx: ^UI_Ctx, key: string = "") -> UI_Box_Id {return ui_group_begin(ctx, key, .X, {}, {})}
ui_row_end :: proc(ctx: ^UI_Ctx) {ui_parent_pop(ctx)}
ui_col_begin :: proc(ctx: ^UI_Ctx, key: string = "") -> UI_Box_Id {return ui_group_begin(ctx, key, .Y, {}, {})}
ui_col_end :: proc(ctx: ^UI_Ctx) {ui_parent_pop(ctx)}
ui_panel_begin :: proc(ctx: ^UI_Ctx, key: string) -> UI_Box_Id {
	ui_tag_push(ctx, "panel")
	return ui_group_begin(ctx, key, .Y, {.Background, .Border, .Clip}, {12, 12})
}
ui_panel_end :: proc(ctx: ^UI_Ctx) {ui_parent_pop(ctx); ui_tag_pop(ctx)}
ui_scrollpane_begin :: proc(ctx: ^UI_Ctx, key: string, height: f32, horizontal: bool = false) -> UI_Box_Id {
	ui_height_next(ctx, ui_px(height))
	id := ui_panel_begin(ctx, key)
	if id != 0 {
		ctx.ui.boxes[id].flags += {.Scroll_Y}
		if horizontal {ctx.ui.boxes[id].flags += {.Scroll_X}}
	}
	return id
}
ui_scrollpane_end :: proc(ctx: ^UI_Ctx) {ui_panel_end(ctx)}

ui_spacer :: proc(ctx: ^UI_Ctx, size: UI_Size) {
	style := ui_style_top(ctx)
	parent := ctx.ui.parent_stack[min(ctx.ui.parent_depth, UI_STACK_MAX) - 1]
	style.size = {ui_px(0), ui_px(0)}
	style.size[int(ctx.ui.boxes[parent].style.axis)] = size
	style.padding = {}
	ui_box_make(ctx, 0, {}, style)
}
ui_divider :: proc(ctx: ^UI_Ctx, thickness: f32 = 1) {
	style := ui_style_top(ctx)
	parent := ctx.ui.parent_stack[min(ctx.ui.parent_depth, UI_STACK_MAX) - 1]
	axis := int(ctx.ui.boxes[parent].style.axis)
	style.size = {ui_pct(), ui_pct()}
	style.size[axis] = ui_px(thickness)
	style.colors[.Background] = ui_theme_color(ctx.ui, {}, .Border)
	style.color_override += {.Background}
	style.radius, style.softness, style.padding = 0, 0, {}
	ui_box_make(ctx, 0, {.Background}, style)
}

ui_slider :: proc(ctx: ^UI_Ctx, label: string, value: ^f32, low, high: f32, step: f32 = 0) -> UI_Signal {
	ui_tag_push(ctx, "button")
	style := ui_style_top(ctx)
	style.size = {ui_pct(), ui_px(56)}
	id := ui_box_make(ctx, ui_key_from_string(ui_seed(ctx), label), {.Background, .Border, .Text, .Clickable, .Focusable, .Adjustable}, style)
	ui_box_text(ctx, id, label[:strings.index(label, "##")] if strings.index(label, "##") >= 0 else label)
	ui_tag_pop(ctx)
	s := ui_signal(ctx, id)
	if id != 0 {
		b := &ctx.ui.boxes[id]
		previous := value^
		if (.Pressed in s.flags || .Dragging in s.flags) && .Keyboard not_in s.flags && b.rect.z > 0 {
			value^ = low + clamp((s.mouse.x - b.rect.x - 10) / max(1, b.rect.z - 20), 0, 1) * (high-low)
		}
		increment := step if step > 0 else (high-low)/100
		value^ += f32(s.nav.x - s.nav.y) * increment
		if step > 0 {value^ = low + f32(math.round(f64((value^ - low)/step))) * step}
		value^ = clamp(value^, low, high)
		if value^ != previous {s.flags += {.Changed}}
		b.draw_kind, b.value.x = .Slider, (value^ - low)/(high-low) if high > low else 0
	}
	return s
}

ui_scrollbar :: proc(ctx: ^UI_Ctx, key: string, axis: UI_Axis, offset: ^f32, content, view: f32) -> UI_Signal {
	style := ui_style_top(ctx)
	style.padding = {}
	style.size = {ui_pct(), ui_px(12)} if axis == .X else [2]UI_Size{ui_px(12), ui_pct()}
	id := ui_box_make(ctx, ui_key_from_string(ui_seed(ctx), key), {.Clickable, .Focusable, .Adjustable}, style)
	s := ui_signal(ctx, id)
	if id != 0 {
		b := &ctx.ui.boxes[id]
		a := int(axis)
		old := offset^
		if (.Pressed in s.flags || .Dragging in s.flags) && .Keyboard not_in s.flags && b.rect[a+2] > 0 {
			offset^ = (s.mouse[a] - b.rect[a]) / b.rect[a+2] * content - view/2
		}
		offset^ = clamp(offset^ + f32(s.nav[a])*24, 0, max(0, content-view))
		if old != offset^ {s.flags += {.Changed}}
		b.draw_kind = .Scrollbar
		b.value = {offset^ / max(1, content), min(1, view/max(1, content)), f32(a), 0}
	}
	return s
}

// A floating panel can be moved from its unused background and resized at its bottom-right corner.
ui_pane_begin :: proc(ctx: ^UI_Ctx, key: string, rect: ^[4]f32) -> UI_Box_Id {
	ui_tag_push(ctx, "panel")
	style := ui_style_top(ctx)
	style.position, style.size = {rect.x, rect.y}, {ui_px(rect.z), ui_px(rect.w)}
	style.padding = {12, 12}
	id := ui_box_make(ctx, ui_key_from_string(ui_seed(ctx), key), {.Background, .Border, .Clip, .Floating, .Movable, .Shadow}, style)
	if id != 0 {
		s := ui_signal(ctx, id)
		b := &ctx.ui.boxes[id]
		if .Dragging in s.flags || .Released in s.flags {
			start := b.drag_rect
			if ctx.ui.drag_start.x > start.x + start.z - 18 && ctx.ui.drag_start.y > start.y + start.w - 18 {
				rect.z, rect.w = max(100, start.z + s.drag.x), max(60, start.w + s.drag.y)
			} else {rect.x, rect.y = start.x + s.drag.x, start.y + s.drag.y}
			b.style.position, b.style.size = {rect.x, rect.y}, {ui_px(rect.z), ui_px(rect.w)}
		}
	}
	ui_parent_push(ctx, id)
	return id
}
ui_pane_end :: proc(ctx: ^UI_Ctx) {ui_parent_pop(ctx); ui_tag_pop(ctx)}

ui_popup_open :: proc(ctx: ^UI_Ctx, key: string, anchor: UI_Box_Id = 0) {
	ctx.ui.popup_focus_return = ctx.ui.focus
	ctx.ui.popup_key = ui_key_from_string(ui_seed(ctx), key)
	ctx.ui.popup_anchor = ctx.ui.boxes[anchor].key
	ctx.ui.popup_position = ctx.input.pos
}
ui_popup_close :: proc(ctx: ^UI_Ctx) {
	ctx.ui.popup_key = 0
	ctx.ui.focus = ctx.ui.popup_focus_return
}
ui_popup_begin :: proc(ctx: ^UI_Ctx, key: string, width: f32 = 240) -> bool {
	popup_key := ui_key_from_string(ui_seed(ctx), key)
	if ctx.ui.popup_key != popup_key {return false}
	ui_tag_push(ctx, "popup")
	ui_parent_push(ctx, ctx.ui.root)
	ctx.ui.surface = .Popup
	style := ui_style_top(ctx)
	style.position = ctx.ui.popup_position
	style.size, style.padding = {ui_px(width), ui_children_size()}, {6, 6}
	style.axis = .Y
	id := ui_box_make(ctx, popup_key, {.Background, .Border, .Floating, .Clip, .Shadow, .Clickable}, style)
	ui_parent_push(ctx, id)
	return true
}
ui_popup_end :: proc(ctx: ^UI_Ctx) {
	ui_parent_pop(ctx)
	ui_parent_pop(ctx)
	ui_tag_pop(ctx)
	ctx.ui.surface = .Main
}
ui_menu_item :: proc(ctx: ^UI_Ctx, label: string) -> UI_Signal {
	ui_width_next(ctx, ui_pct())
	s := ui_button(ctx, label)
	if .Clicked in s.flags {ui_popup_close(ctx)}
	return s
}
ui_tooltip :: proc(ctx: ^UI_Ctx, anchor: UI_Box_Id, text: string, width: f32 = 260) {
	if anchor != 0 && ctx.ui.boxes[anchor].key == ctx.ui.hot && ctx.ui.hover_time >= 0.5 && ctx.ui.active == 0 {
		surface := ctx.ui.surface
		ctx.ui.surface = .Tooltip
		ui_tag_push(ctx, "tooltip")
		ui_parent_push(ctx, ctx.ui.root)
		style := ui_style_top(ctx)
		style.position = ctx.input.pos + [2]f32{16, 20}
		style.size = {ui_px(width), ui_children_size()}
		style.padding = {8, 8}
		id := ui_box_make(ctx, ui_key_from_string(ctx.ui.boxes[anchor].key, "###tooltip"), {.Background, .Border, .Floating, .Shadow}, style)
		ui_parent_push(ctx, id)
		ui_label_wrapped(ctx, text)
		ui_parent_pop(ctx)
		ui_parent_pop(ctx)
		ui_tag_pop(ctx)
		ctx.ui.surface = surface
	}
}

ui_table_begin :: proc(ctx: ^UI_Ctx, key: string, weights: []f32) -> UI_Box_Id {
	depth := ctx.ui.table_depth
	ctx.ui.table_depth += 1
	if depth < UI_TABLE_DEPTH_MAX {
		t := &ctx.ui.table_stack[depth]
		t^ = {column_len = min(len(weights), UI_TABLE_COLUMNS_MAX)}
		for weight, i in weights[:t.column_len] {t.weights[i] = max(weight, 0); t.weight_sum += t.weights[i]}
	}
	return ui_col_begin(ctx, key)
}
ui_table_end :: proc(ctx: ^UI_Ctx) {ui_col_end(ctx); ctx.ui.table_depth = max(0, ctx.ui.table_depth - 1)}
ui_table_row_begin :: proc(ctx: ^UI_Ctx, key: string = "") -> UI_Box_Id {
	if ctx.ui.table_depth > 0 && ctx.ui.table_depth <= UI_TABLE_DEPTH_MAX {ctx.ui.table_stack[ctx.ui.table_depth-1].column_next = 0}
	style := ui_style_top(ctx)
	style.gap = 0
	ui_style_push(ctx, style)
	return ui_row_begin(ctx, key)
}
ui_table_row_end :: proc(ctx: ^UI_Ctx) {ui_row_end(ctx); ui_style_pop(ctx)}
ui_table_cell_begin :: proc(ctx: ^UI_Ctx) -> UI_Box_Id {
	weight: f32
	if ctx.ui.table_depth > 0 && ctx.ui.table_depth <= UI_TABLE_DEPTH_MAX {
		t := &ctx.ui.table_stack[ctx.ui.table_depth-1]
		if t.column_next < t.column_len && t.weight_sum > 0 {weight = t.weights[t.column_next] / t.weight_sum}
		t.column_next += 1
	}
	ui_width_next(ctx, ui_pct(weight))
	return ui_col_begin(ctx)
}
ui_table_cell_end :: proc(ctx: ^UI_Ctx) {ui_col_end(ctx)}

ui_list_item :: proc(ctx: ^UI_Ctx, label: string, selected: bool) -> UI_Signal {
	ui_width_next(ctx, ui_pct())
	s := ui_button(ctx, label)
	if s.box != 0 && selected {ctx.ui.boxes[s.box].flags += {.Selected}}
	return s
}

@(private = "file")
ui_hsv_rgb :: proc(hsv: [3]f32) -> [3]f32 {
	h := hsv.x - f32(math.floor(f64(hsv.x)))
	p := hsv.z * (1-hsv.y)
	f := h*6 - f32(math.floor(f64(h*6)))
	q, t := hsv.z*(1-hsv.y*f), hsv.z*(1-hsv.y*(1-f))
	switch int(h*6) {
	case 0: return {hsv.z,t,p}
	case 1: return {q,hsv.z,p}
	case 2: return {p,hsv.z,t}
	case 3: return {p,q,hsv.z}
	case 4: return {t,p,hsv.z}
	case: return {hsv.z,p,q}
	}
}
@(private = "file")
ui_rgb_hsv :: proc(rgb: [3]f32) -> [3]f32 {
	hi, lo := max(rgb.x, rgb.y, rgb.z), min(rgb.x, rgb.y, rgb.z)
	d := hi-lo
	h: f32
	if d > 0 {
		if hi == rgb.x {h = (rgb.y-rgb.z)/d} else if hi == rgb.y {h = 2+(rgb.z-rgb.x)/d} else {h = 4+(rgb.x-rgb.y)/d}
		h /= 6
		if h < 0 {h += 1}
	}
	return {h, d/hi if hi > 0 else 0, hi}
}

ui_color_picker :: proc(ctx: ^UI_Ctx, key: string, color: ^[4]f32) -> (signal: UI_Signal) {
	root := ui_col_begin(ctx, key)
	signal.box = root
	hsv := ui_rgb_hsv({color.x, color.y, color.z})
	if root != 0 && ctx.ui.boxes[root].color_previous == color^ {hsv = ctx.ui.boxes[root].hsv}
	hsv_initial := hsv
	controls: [3]UI_Box_Id
	old := color^
	for kind in 0..<3 {
		style := ui_style_top(ctx)
		style.size = {ui_pct(), ui_px(140 if kind == 0 else 20)}
		style.padding, style.radius = {}, 0
		name := "sv" if kind == 0 else ("hue" if kind == 1 else "alpha")
		id := ui_box_make(ctx, ui_key_from_string(ui_seed(ctx), name), {.Border, .Clickable, .Focusable, .Adjustable}, style)
		controls[kind] = id
		if id != 0 {
			b := &ctx.ui.boxes[id]
			s := ui_signal(ctx, id)
			signal.flags += s.flags
			if (.Pressed in s.flags || .Dragging in s.flags) && .Keyboard not_in s.flags {
				p := [2]f32{clamp((s.mouse.x-b.rect.x)/max(1,b.rect.z),0,1), clamp((s.mouse.y-b.rect.y)/max(1,b.rect.w),0,1)}
				if kind == 0 {hsv.y, hsv.z = p.x, 1-p.y}
				if kind == 1 {hsv.x = p.x}
				if kind == 2 {color.w = p.x}
			}
			if kind == 0 {hsv.y = clamp(hsv.y+f32(s.nav.x)*0.01,0,1); hsv.z = clamp(hsv.z-f32(s.nav.y)*0.01,0,1)}
			if kind == 1 {hsv.x = clamp(hsv.x+f32(s.nav.x)*0.01,0,1)}
			if kind == 2 {color.w = clamp(color.w+f32(s.nav.x)*0.01,0,1)}
			b.draw_kind = .Saturation_Value if kind == 0 else (.Hue if kind == 1 else .Alpha)
		}
	}
	rgb := ui_hsv_rgb(hsv)
	if hsv != hsv_initial {color.x, color.y, color.z = rgb.x, rgb.y, rgb.z}
	for id in controls {
		if id != 0 {ctx.ui.boxes[id].value = {hsv.x,hsv.y,hsv.z,color.w}}
	}
	if root != 0 {ctx.ui.boxes[root].hsv = hsv; ctx.ui.boxes[root].color_previous = color^}
	if old != color^ {signal.flags += {.Changed}}
	ui_col_end(ctx)
	return
}

ui_combo :: proc(ctx: ^UI_Ctx, key: string, selection: ^int, choices: []string) -> (signal: UI_Signal) {
	ui_key_push(ctx, key)
	label := choices[selection^] if selection^ >= 0 && selection^ < len(choices) else "Select"
	signal = ui_button(ctx, fmt.tprintf("%s###value", label))
	if .Clicked in signal.flags {ui_popup_open(ctx, "choices", signal.box)}
	if ui_popup_begin(ctx, "choices") {
		for choice, i in choices {
			ui_key_push_u64(ctx, u64(i))
			if item := ui_menu_item(ctx, choice); .Clicked in item.flags {
				selection^ = i
				signal.flags += {.Changed}
			}
			ui_key_pop(ctx)
		}
		ui_popup_end(ctx)
	}
	ui_key_pop(ctx)
	return
}

ui_radio :: proc(ctx: ^UI_Ctx, label: string, selection: ^int, value: int) -> UI_Signal {
	checked := selection^ == value
	s := ui_checkbox(ctx, label, &checked)
	if .Clicked in s.flags {selection^ = value; s.flags += {.Changed}}
	if s.box != 0 {ctx.ui.boxes[s.box].value.x = 1 if selection^ == value else 0}
	return s
}

// The simple Draw API emits the instance; this adapter supplies its supported
// per-corner colors. No renderer commands or OpenGL calls are introduced here.
@(private = "file")
ui_draw_gradient :: proc(draw: ^Draw_Ctx, rect: [4]f32, colors: [Corner][4]f32) {
	index := draw.instance_span.begin
	draw_rectangle(draw, rect, colors[.Top_Left])
	if draw.instance_span.begin != index {draw.render.instances[index].color = colors}
}

@(private = "file")
ui_draw_text :: proc(ctx: ^UI_Ctx, b: UI_Box, position: [2]f32, width: f32, color: [4]f32) {
	text := ui_text_get(ctx.ui, b.text)
	if b.runs.len > 0 {
		ascent: f32
		for run in ctx.ui.runs[b.runs.begin:b.runs.begin + b.runs.len] {
			ascent = max(ascent, run.size.y if run.is_image else ctx.draw.sprites.fonts[run.font].info.ascent)
		}
		x := position.x
		for run in ctx.ui.runs[b.runs.begin:b.runs.begin + b.runs.len] {
			tint := run.color
			tint.w *= b.style.opacity * (1 - b.disabled_t*0.5)
			if run.is_image {
				draw_image(ctx.draw, run.image, {x, position.y + ascent - run.size.y, run.size.x, run.size.y}, tint)
				x += run.size.x
			} else {
				size := draw_text(ctx.draw, run.font, ui_text_get(ctx.ui, run.text),
					{x, position.y + ascent - ctx.draw.sprites.fonts[run.font].info.ascent}, tint)
				x += size.x
			}
		}
	} else if .Wrap in b.flags {
		if width > 0 {draw_text_wrapped(ctx.draw, b.style.font, text, position, width, color)}
	} else if .Ellipsis in b.flags && text_measure(ctx.draw.sprites, b.style.font, text).x > width {
		trailer := text_measure(ctx.draw.sprites, b.style.font, "...").x
		advance: f32
		end := len(text)
		for ch, offset in text {
			amount: f32
			if sprite, ok := sprite_of_glyph(ctx.draw.sprites, b.style.font, ch); ok {amount = ctx.draw.sprites.glyphs[sprite].advance}
			if ch == '\n' || advance + amount + trailer > width {end = offset; break}
			advance += amount
		}
		draw_text(ctx.draw, b.style.font, text[:end], position, color)
		if trailer <= width {draw_text(ctx.draw, b.style.font, "...", position + [2]f32{advance, 0}, color)}
	} else {draw_text(ctx.draw, b.style.font, text, position, color)}
}

@(private = "file")
ui_draw_scrollbar :: proc(draw: ^Draw_Ctx, rect: [4]f32, axis: int, offset, fraction: f32, track, thumb: [4]f32) {
	draw_rectangle(draw, rect, track, radius = 4)
	r := rect
	r[axis] += rect[axis+2] * offset
	r[axis+2] = min(rect[axis+2], max(8, rect[axis+2] * fraction))
	r[axis] = min(r[axis], rect[axis] + rect[axis+2] - r[axis+2])
	draw_rectangle(draw, r, thumb, radius = 4)
}

@(private = "file")
ui_paint :: proc(ctx: ^UI_Ctx) {
	base_layer := ctx.draw.layer
	for id in ctx.ui.order {
		if id != 0 {
			b := ctx.ui.boxes[id]
			if b.surface == .Popup && ctx.ui.popup_key == 0 {continue}
			ctx.draw.layer = base_layer + u16(b.surface)
			draw_clip_push(ctx.draw, b.clip)
			palette := b.colors
			for role in UI_Color {palette[role].w *= b.style.opacity * (1 - b.disabled_t*0.5)}
			bg := palette[.Background]
			if .Clickable in b.flags {
				bg += (palette[.Hot] - bg)*b.hot_t
				bg += (palette[.Active] - bg)*b.active_t
			}
			if .Shadow in b.flags {
				r := b.rect
				draw_rectangle(ctx.draw, {r.x-8,r.y-4,r.z+16,r.w+16}, palette[.Shadow], radius=b.style.radius+8, softness=4)
			}
			if .Background in b.flags {draw_rectangle(ctx.draw, b.rect, bg, radius=b.style.radius, softness=b.style.softness)}
			if .Border in b.flags {draw_rectangle_lines(ctx.draw, b.rect, palette[.Border], b.style.thickness, radius=b.style.radius, softness=b.style.softness)}
			content := [4]f32{b.rect.x+b.style.padding.x,b.rect.y+b.style.padding.y,
				max(0,b.rect.z-ui_box_padding(b).x),max(0,b.rect.w-ui_box_padding(b).y)}
			if .Image in b.flags {draw_image(ctx.draw, b.image, content, {1,1,1,b.style.opacity*(1-b.disabled_t*0.5)})}
			#partial switch b.draw_kind {
			case .Checkbox, .Expander:
				d := min(18, content.w)
				r := [4]f32{content.x,content.y+(content.w-d)/2,d,d}
				draw_rectangle_lines(ctx.draw,r,palette[.Text],1,radius=3,softness=0.6)
				if b.draw_kind == .Checkbox {
					if b.value.x > 0 {draw_rectangle(ctx.draw,{r.x+4,r.y+4,d-8,d-8},palette[.Focus],radius=2)}
				} else {
					draw_rectangle(ctx.draw,{r.x+4,r.y+d/2-1,d-8,2},palette[.Text])
					if b.value.x == 0 {draw_rectangle(ctx.draw,{r.x+d/2-1,r.y+4,2,d-8},palette[.Text])}
				}
				content.x += d+8
				content.z = max(0,content.z-d-8)
			case .Slider:
				r := [4]f32{b.rect.x+10,b.rect.y+b.rect.w-12,max(0,b.rect.z-20),4}
				draw_rectangle(ctx.draw,r,palette[.Border],radius=2)
				draw_rectangle(ctx.draw,{r.x,r.y,r.z*b.value.x,r.w},palette[.Focus],radius=2)
				draw_rectangle(ctx.draw,{r.x+r.z*b.value.x-5,r.y-4,10,12},palette[.Text],radius=4,softness=0.5)
				content.w = max(0,content.w-14)
			case .Scrollbar:
				ui_draw_scrollbar(ctx.draw,b.rect,int(b.value.z),b.value.x,b.value.y,palette[.Background],palette[.Focus])
			case .Saturation_Value:
				hue := ui_hsv_rgb({b.value.x,1,1})
				ui_draw_gradient(ctx.draw,b.rect,{
					.Top_Left={1,1,1,b.style.opacity}, .Top_Right={hue.x,hue.y,hue.z,b.style.opacity},
					.Bot_Left={0,0,0,b.style.opacity}, .Bot_Right={0,0,0,b.style.opacity},
				})
				draw_rectangle_lines(ctx.draw,{b.rect.x+b.value.y*b.rect.z-4,b.rect.y+(1-b.value.z)*b.rect.w-4,8,8},{1,1,1,1},1,radius=4,softness=0.5)
			case .Hue:
				for segment in 0..<6 {
					a,b_color := ui_hsv_rgb({f32(segment)/6,1,1}),ui_hsv_rgb({f32(segment+1)/6,1,1})
					left,right := [4]f32{a.x,a.y,a.z,b.style.opacity},[4]f32{b_color.x,b_color.y,b_color.z,b.style.opacity}
					ui_draw_gradient(ctx.draw,{b.rect.x+f32(segment)*b.rect.z/6,b.rect.y,b.rect.z/6,b.rect.w},
						{.Top_Left=left,.Bot_Left=left,.Top_Right=right,.Bot_Right=right})
				}
				draw_rectangle_lines(ctx.draw,{b.rect.x+b.value.x*b.rect.z-3,b.rect.y,6,b.rect.w},{1,1,1,1},1)
			case .Alpha:
				for row in 0..<2 {
					for col in 0..<16 {
						v: f32 = 0.4 if (row+col)%2 == 0 else 0.7
						draw_rectangle(ctx.draw,{b.rect.x+f32(col)*b.rect.z/16,b.rect.y+f32(row)*b.rect.w/2,b.rect.z/16,b.rect.w/2},{v,v,v,b.style.opacity})
					}
				}
				rgb := ui_hsv_rgb({b.value.x,b.value.y,b.value.z})
				a,z := [4]f32{rgb.x,rgb.y,rgb.z,0},[4]f32{rgb.x,rgb.y,rgb.z,b.style.opacity}
				ui_draw_gradient(ctx.draw,b.rect,{.Top_Left=a,.Bot_Left=a,.Top_Right=z,.Bot_Right=z})
				draw_rectangle_lines(ctx.draw,{b.rect.x+b.value.w*b.rect.z-3,b.rect.y,6,b.rect.w},{1,1,1,1},1)
			case .Swatch:
				draw_rectangle(ctx.draw,content,b.value,radius=b.style.radius)
			}
			if .Text in b.flags {
				dim := ui_text_dimensions(ctx,b,content.z)
				if b.draw_kind == .Checkbox || b.draw_kind == .Expander {dim.x -= 26}
				align: f32 = 0 if b.style.text_align == .Start else (0.5 if b.style.text_align == .Center else 1)
				pos := [2]f32{content.x+max(0,content.z-dim.x)*align,content.y+max(0,content.w-dim.y)/2}
				draw_clip_push(ctx.draw, content)
				ui_draw_text(ctx,b,pos,content.z,palette[.Text])
				draw_clip_pop(ctx.draw)
			}
			for axis in 0..<2 {
				scroll := (.Scroll_X in b.flags) if axis == 0 else (.Scroll_Y in b.flags)
				if scroll {
					view := max(1,b.rect[axis+2]-ui_box_padding(b)[axis])
					total := max(view,b.content_size[axis])
					r := [4]f32{b.rect.x+b.style.padding.x,b.rect.y+b.rect.w-10,view,6} if axis == 0 else
						[4]f32{b.rect.x+b.rect.z-10,b.rect.y+b.style.padding.y,6,view}
					ui_draw_scrollbar(ctx.draw,r,axis,b.scroll[axis]/total,view/total,palette[.Border],palette[.Muted])
				}
			}
			if b.focus_t > 0.001 {
				color := palette[.Focus]
				color.w *= b.focus_t
				draw_rectangle_lines(ctx.draw,b.rect,color,2,radius=b.style.radius,softness=0.7)
			}
			draw_clip_pop(ctx.draw)
		}
	}
	ctx.draw.layer = base_layer
}

ui_end :: proc(ctx: ^UI_Ctx) {
	ui_layout(ctx)
	ui := ctx.ui
	rate := f32(1 - math.exp(-16*f64(ctx.dt)))
	for &b in ui.boxes {
		if b.frame == ui.frame {
			for role in UI_Color {
				target := b.style.colors[role] if role in b.style.color_override else ui_theme_color(ui,b.tags,role)
				b.colors[role] += (target-b.colors[role])*rate
			}
			b.hot_t += ((1 if b.key != 0 && b.key == ui.hot else 0)-b.hot_t)*rate
			b.active_t += ((1 if (b.key != 0 && b.key == ui.active) || .Selected in b.flags else 0)-b.active_t)*rate
			b.focus_t += ((1 if b.key != 0 && b.key == ui.focus else 0)-b.focus_t)*rate
			b.disabled_t += ((1 if .Disabled in b.flags else 0)-b.disabled_t)*rate
		}
	}
	active, focus := ui_box_find(ui,ui.active),ui_box_find(ui,ui.focus)
	if active == 0 || ui.boxes[active].frame != ui.frame {ui.active = 0}
	if focus == 0 || ui.boxes[focus].frame != ui.frame {ui.focus = 0}
	if ui.popup_key != 0 {
		popup := ui_box_find(ui,ui.popup_key)
		if popup == 0 || ui.boxes[popup].frame != ui.frame {ui.popup_key = 0}
		if ui.popup_key != 0 && (focus == 0 || ui.boxes[focus].surface != .Popup) {
			for id in ui.order {
				if id != 0 && ui.boxes[id].surface == .Popup && .Focusable in ui.boxes[id].flags && .Disabled not_in ui.boxes[id].flags {
					ui.focus = ui.boxes[id].key
					break
				}
			}
		}
	}
	if ui.focus_reveal {
		focused := ui_box_find(ui, ui.focus)
		if focused != 0 {
			r := ui.boxes[focused].rect
			for parent := ui.boxes[focused].parent; parent != 0; parent = ui.boxes[parent].parent {
				b := &ui.boxes[parent]
				for axis in 0..<2 {
					scroll := (.Scroll_X in b.flags) if axis == 0 else (.Scroll_Y in b.flags)
					if scroll {
						lo := b.rect[axis] + b.style.padding[axis]
						hi := lo + b.rect[axis+2] - ui_box_padding(b^)[axis]
						delta := min(0, r[axis]-lo) + max(0, r[axis]+r[axis+2]-hi)
						b.scroll_target[axis] = b.scroll[axis] + delta
					}
				}
			}
		}
		ui.focus_reveal = false
	}
	ui_paint(ctx)
}
