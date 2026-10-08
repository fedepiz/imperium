package main

import "core:hash"
import "core:math"
import "core:math/linalg"
import "core:strings"
import "core:unicode/utf8"

import sdl "vendor:sdl3"

// Maximum number of ui boxes supported by the system
@(private = "file")
BOX_MAX :: 2048
@(private = "file")
DEPTH_MAX :: 32
// Maximum number of animated values alive at once
@(private = "file")
ANIM_MAX :: 1024
// Lines of wrapped text in a frame, all boxes together
@(private = "file")
LINES_MAX :: 4096
// Parts of one box's text
@(private = "file")
BOX_TEXT_PARTS_MAX :: 32

// What the ui reads each frame, in logical pixels
UI_Input :: struct {
	cursor:       [2]f32,
	// The cursor is in the window
	cursor_valid: bool,
	// Wheel movement this frame, in notches (fractional on touchpads); positive y is away from the user, positive x to
	// the right
	wheel:        [2]f32,
	// The button that presses is held, and went down this frame
	press_down:   bool,
	press:        bool,
	// Escape went down this frame
	escape:       bool,
	// Keys going down, repeats included, and typed characters, in the order they came this frame; the rest are dropped
	events:       [dynamic; UI_EVENTS_MAX]UI_Event,
}

UI_EVENTS_MAX :: 64

UI_Event_Kind :: enum {
	Key,
	Char,
}

// A key going down, or a character typed
UI_Event :: struct {
	kind: UI_Event_Kind,
	key:  sdl.Scancode,
	char: rune,
}

@(private = "file")
UI: struct {
	boxes:             [BOX_MAX]Box,
	// Free stack of boxes
	box_free:          [BOX_MAX]Id,
	box_free_count:    int,
	// Order of boxes, from bottom to top: the tree walked parents first, computed in end
	box_order:         [BOX_MAX]Id,
	box_order_count:   int,
	// The box everything else is built under, and its two children: what the app builds, then what floats over it
	root:              Id,
	// This box contains all "ground layer" ui elements
	content:           Id,
	// This box contains all the overlay stuff, such as the tooltip
	overlay:           Id,
	viewport:          [2]f32,
	// The base style's font, set by init
	font:              Text_Font_Id,
	// This frame's text-sized boxes' text, broken into lines in layout
	lines:             [dynamic; LINES_MAX]Text_Id,
	// Key -> Id hashmap
	key_hash_table:    Key_Hashtable,
	// Parent stack
	parent_stack:      [DEPTH_MAX]Id,
	parent_depth:      int,
	// UI_Style stack: the base style sits at the bottom, and each entry already includes the ones below it
	style_stack:       [DEPTH_MAX]UI_Style,
	style_depth:       int,
	// Overrides for the next box only
	style_next:        UI_Style,
	// Global interaction state, by key: a box, or a keyed run of text
	hot:               Key,
	// Owns the mouse from the press until the release, wherever the mouse goes
	active:            Key,
	// Only set for the frame the press happened or the release completed a click
	pressed:           Key,
	// Takes a press on a focusable box and keeps it until a press lands anywhere else, or Escape
	focus:             Key,
	// Given focus by focus, from the next end
	focus_next:        Key,
	// The focus as of the last end takes the keyboard, so the game gets no keys
	keyboard_captured: bool,
	// The keys and characters the last end gave to the box of events_key, the focused box then
	events:            [dynamic; UI_EVENTS_MAX]UI_Event,
	events_key:        Key,
	// Where the text cursor sits in the focused box's text, in bytes; a new focus puts it past the end
	cursor:            int,
	// The mouse as of the last end, and where the press that made the active box happened
	mouse:             [2]f32,
	drag_start:        [2]f32,
	// Wheel movement in the last end, in notches
	wheel:             [2]f32,
	// The last end saw a left press, wherever it landed
	pressed_any:       bool,
	// The mouse was over a box that takes it in the last end, disabled ones included
	hovered_any:       bool,
	// Saved by the widget being dragged, usually its value when the drag began
	drag_value:        [2]f32,
	// Animated values, kept alive by being asked for every frame
	anims:             [ANIM_MAX]Anim,
	// Free stack of anims
	anim_free:         [ANIM_MAX]Anim_Id,
	anim_free_count:   int,
	// Key -> Anim id hashmap
	anim_hash_table:   Anim_Hashtable,
	// Open tooltips, kept between frames
	tooltips:          [TOOLTIPS_MAX]Tooltip,
	// The tooltips being built, innermost last: the one a tooltip opened now is opened from
	tooltip_stack:     [TOOLTIPS_MAX]Key,
	tooltip_depth:     int,
	// The topmost tooltip under the mouse, as of the last end
	tooltip_under:     Key,
}

// The short live id for the ui boxes. Doubles up as the index in the table
@(private = "file")
Id :: distinct u16

@(private = "file")
Key :: distinct u64

// The 0 key is meant for default
@(private = "file")
KEY_NIL :: Key(0)

UI_Size_Kind :: enum {
	None,
	Pixels,
	Text,
	Fit,
	Grow,
}

UI_Size :: struct {
	kind:       UI_Size_Kind,
	value:      f32,
	// Fraction of the size kept when the parent overflows: 1 never shrinks, 0 can shrink to nothing.
	strictness: f32,
}

UI_Box_Flag :: enum {
	Background,
	Border,
	// Takes part in mouse hit testing; the box needs a key
	Clickable,
	// Fades the background toward hot_background and active_background while hovered and held, and the text toward hot_text_color
	Hot_Effects,
	// A press on the box gives it focus, drawn as a ring
	Focusable,
	// While focused, takes every key and typed character, and the game gets none
	Keyboard,
	// Gets no hover, press or focus, still blocks the mouse, and is drawn faded; inherited by children
	Disabled,
	// Children may overflow along the axis, and the wheel moves them through the box; the box needs a key
	Scroll_X,
	Scroll_Y,
	// Out of the flow: the parent neither sizes around the box nor places it; it sits at position from the parent's corner
	Floating,
	// Its text has keyed runs, which take the mouse like boxes; set by the box's text
	Hover_Text,
	// A tooltip: takes the mouse from what is under it without becoming hot, and is kept open while the
	// mouse is over it; set by ui_tooltip
	Tooltip,
}

// Distance moved per wheel notch, in multiples of the scrolled box's font size
@(private = "file")
SCROLL_STEP :: 3

// A partial set of box fields. Nil fields leave whatever was set before them alone.
UI_Style :: struct {
	width:             Maybe(UI_Size),
	height:            Maybe(UI_Size),
	padding:           Maybe([2]f32),
	gap:               Maybe(f32),
	background:        Maybe([4]f32),
	// Backgrounds faded toward while hovered and while held, on boxes with Hot_Effects
	hot_background:    Maybe([4]f32),
	active_background: Maybe([4]f32),
	border:            Maybe([4]f32),
	// Ring drawn over focused boxes, faded in by focus_t
	focus_border:      Maybe([4]f32),
	thickness:         Maybe(f32),
	radius:            Maybe(f32),
	font:              Maybe(Text_Font_Id),
	text_color:        Maybe([4]f32),
	// Text faded toward while hovered: a Hot_Effects box's own, and keyed runs of text
	hot_text_color:    Maybe([4]f32),
	// Sets or clears UI_Box_Flag.Disabled; a disabled parent still disables its children
	disabled:          Maybe(bool),
	// Where a floating box's top-left corner sits, from its parent's
	position:          Maybe([2]f32),
}

// A ui box. Keyed boxes keep their slot, and so their persistent fields, for as long as they are built every frame.
@(private = "file")
Box :: struct {
	// Per-build: reset in begin when a box is kept, or overwritten by the style when it is built
	flags:             bit_set[UI_Box_Flag],
	key:               Key,
	size:              [2]UI_Size,
	child_axis:        Axis,
	// Space between the box edge and its children, applied on both sides of each axis
	padding:           [2]f32,
	// Space between consecutive children along the child axis
	gap:               f32,
	// Where a floating box's top-left corner sits, from its parent's
	position:          [2]f32,
	// Box tree hierarchy
	parent:            Id,
	child_first:       Id,
	child_last:        Id,
	sibling_next:      Id,
	// UI_Style
	background:        [4]f32,
	hot_background:    [4]f32,
	active_background: [4]f32,
	border:            [4]f32,
	focus_border:      [4]f32,
	thickness:         f32,
	radius:            f32,
	// Text
	text:              Text_Id,
	// The text broken into lines, a span of UI.lines, when the box is sized by it. Empty: one line,
	// cut with "..." when it does not fit
	lines:             Span,
	font:              Text_Font_Id,
	text_color:        [4]f32,
	hot_text_color:    [4]f32,
	// Layout results: until this frame's layout runs, they are last frame's
	pos_computed:      [2]f32,
	size_computed:     [2]f32,
	// Clipping bounds
	clip:              [4]f32,
	// Extent of the children, gaps and padding, as placed
	content_size:      [2]f32,
	// Persistent: eased a little every frame
	hot_t:             f32,
	active_t:          f32,
	focus_t:           f32,
	disabled_t:        f32,
	// How far the children are moved through the box, easing toward scroll_target
	scroll:            [2]f32,
	scroll_target:     [2]f32,
}

UI_Signal :: struct {
	hovered: bool,
	// The mouse went down on the box
	pressed: bool,
	// The box is active: pressed and not yet released
	held:    bool,
	focused: bool,
	// How far the mouse moved since the press, while held
	drag:    [2]f32,
	// Wheel movement in notches, while hovered
	wheel:   [2]f32,
}

// The mouse is over the ui, as of the last end: whatever is drawn under it should ignore the mouse.
ui_hovered_any :: proc() -> bool {
	return UI.hovered_any
}

// Something in the ui is focused, as of the last end.
ui_focused_any :: proc() -> bool {
	return UI.focus != KEY_NIL
}

// The focused box takes the keyboard, as of the last end: the game should ignore the keys.
ui_keyboard_captured :: proc() -> bool {
	return UI.keyboard_captured
}

// Gives focus to whatever carries the label's key in the current scope, from the next end.
ui_focus :: proc(label: string) {
	UI.focus_next = key_from_string(label)
}

// The key went down, or repeated, among the keys the last end gave to the focused box.
ui_key_pressed :: proc(key: sdl.Scancode) -> bool {
	for event in UI.events[:] {
		if event.kind == .Key && event.key == key {return true}
	}
	return false
}

// Saves a value for the box being dragged, usually its value when the press happened.
ui_drag_store :: proc(value: [2]f32) {
	UI.drag_value = value
}

// The value saved with drag_store.
ui_drag_stored :: proc() -> [2]f32 {
	return UI.drag_value
}

ui_px :: proc(value: f32, strictness: f32 = 1) -> UI_Size {
	return {.Pixels, value, strictness}
}

// Pixels in multiples of the current font's size, resolved when called.
ui_em :: proc(value: f32, strictness: f32 = 1) -> UI_Size {
	font := style_top().font.? or_else UI.font
	return ui_px(value * text_font_metrics(font).size, strictness)
}

// The size of the box's text, plus its padding.
ui_text_dim :: proc(strictness: f32 = 1) -> UI_Size {
	return {.Text, 0, strictness}
}

@(private = "file")
seed :: proc() -> u64 {
	for i := UI.parent_depth - 1; i >= 0; i = i - 1 {
		parent := UI.parent_stack[i]
		key := UI.boxes[parent].key
		if key != KEY_NIL {return u64(key)}
	}
	return 0
}

@(private = "file")
key_from_string :: proc(str: string) -> Key {
	return key_from_string_seeded(str, seed())
}

// A key scoped under seed rather than under the nearest keyed parent
@(private = "file")
key_from_string_seeded :: proc(str: string, seed: u64) -> Key {
	head, match, tail := strings.partition(str, "###")
	to_hash := tail
	if len(match) == 0 {
		to_hash = head
	}
	out: Key
	if len(to_hash) > 0 {
		h := hash.fnv64(transmute([]byte)to_hash, seed)
		if h == 0 {h = 1}
		out = Key(h)
	}
	return out
}

@(private = "file")
HASH_CAPACITY :: BOX_MAX

// Key -> Id map with linear probing, rebuilt from scratch each frame so it never needs deletion
@(private = "file")
Hashtable :: struct($Id: typeid, $N: int) {
	keys: [N]Key,
	ids:  [N]Id,
}

@(private = "file")
Key_Hashtable :: Hashtable(Id, HASH_CAPACITY)

@(private = "file")
hashtable_find :: proc(ht: ^Hashtable($Id, $N), needle: Key) -> Id {
	if needle == KEY_NIL {return 0}
	// Probe
	idx := u64(needle) % len(ht.keys)
	for _ in 0 ..< len(ht.keys) {
		key := ht.keys[idx]
		// Key not found...
		if key == needle {return ht.ids[idx]}
		if key == KEY_NIL {return 0}
		// Neither, keep going...
		idx = (idx + 1) % len(ht.keys)
	}
	return 0
}

@(private = "file")
hashtable_save :: proc(ht: ^Hashtable($Id, $N), key: Key, id: Id) {
	assert(key != 0 && id != 0)
	idx := u64(key) % len(ht.keys)
	for _ in 0 ..< len(ht.keys) {
		key_current := ht.keys[idx]
		// No double inserts
		assert(key_current != key)
		if key_current == KEY_NIL {
			ht.keys[idx] = key
			ht.ids[idx] = id
			return
		}
		idx = (idx + 1) % len(ht.keys)
	}
	assert(false)
}

// The short live id for animated values. Doubles up as the index in the table
@(private = "file")
Anim_Id :: distinct u16

// A value easing toward its target a little every frame
@(private = "file")
Anim :: struct {
	key:     Key,
	current: f32,
	target:  f32,
	// Asked for this frame; anims nobody asks for are freed in the next begin
	touched: bool,
}

@(private = "file")
ANIM_HASH_CAPACITY :: ANIM_MAX

@(private = "file")
Anim_Hashtable :: Hashtable(Anim_Id, ANIM_HASH_CAPACITY)

// A value stored under label (scoped like box keys) that eases toward target every frame.
// It starts at initial the first frame it is asked for, and is forgotten once a frame passes without asking.
ui_anim :: proc(label: string, target: f32, initial: f32 = 0) -> f32 {
	key := key_from_string(label)
	assert(key != KEY_NIL, "animated values need a non-empty label")
	return anim_from_key(key, target, initial)
}

@(private = "file")
anim_from_key :: proc(key: Key, target: f32, initial: f32 = 0) -> f32 {
	id := hashtable_find(&UI.anim_hash_table, key)
	if id == 0 {
		assert(UI.anim_free_count > 0)
		id = UI.anim_free[UI.anim_free_count - 1]
		UI.anim_free_count -= 1
		hashtable_save(&UI.anim_hash_table, key, id)
		UI.anims[id] = {
			key     = key,
			current = initial,
		}
	}
	anim := &UI.anims[id]
	anim.target = target
	anim.touched = true
	return anim.current
}

@(private = "file")
box_alloc :: proc(key: Key) -> Id {
	// A nil key gets a fresh value
	id := hashtable_find(&UI.key_hash_table, key)
	if id == 0 {
		assert(UI.box_free_count > 0)
		id = UI.box_free[UI.box_free_count - 1]
		UI.box_free_count -= 1

		// If we have a non-nil key, register
		if key != KEY_NIL {
			hashtable_save(&UI.key_hash_table, key, id)
		}
	}

	box := &UI.boxes[id]
	// No wrongful assingment of keys
	assert(box.key == KEY_NIL)
	box.key = key
	return id
}

// Gives the box a text in its font and color, showing the label up to any "##".
@(private = "file")
box_set_label :: proc(box: ^Box, label: string) {
	head, _, _ := strings.partition(label, "##")
	box_set_text(box, {UI_Text{text = head}})
}

// Gives the box a text made of parts, in the box's font and color where a part sets none.
@(private = "file")
box_set_text :: proc(box: ^Box, parts: []UI_Text) {
	assert(len(parts) <= BOX_TEXT_PARTS_MAX)
	// A Hot_Effects box's text fades with the box; a keyed run fades with its own hover, eased under its key.
	box_hot_t := box.hot_t if .Hot_Effects in box.flags else 0
	made: [BOX_TEXT_PARTS_MAX]Text_Part
	for part, i in parts {
		font := part.font.? or_else box.font
		color := part.color.? or_else box.text_color
		hot_color := part.hot_color.? or_else box.hot_text_color
		hot_t := box_hot_t
		// A keyed run's key is its tag; runs of disabled boxes take no mouse.
		tag: u64
		if len(part.key) > 0 && .Disabled not_in box.flags {
			key := key_from_string(part.key)
			box.flags += {.Hover_Text}
			tag = u64(key)
			hot_t = anim_from_key(key, 1 if UI.hot == key else 0)
		}
		color += (hot_color - color) * hot_t
		made[i] = {
			text  = part.text,
			font  = font,
			color = color,
			tag   = tag,
		}
	}
	box.text = text_make(made[:len(parts)])
}

// font is the base style's: what boxes use unless a font is pushed.
ui_init :: proc(font: Text_Font_Id) {
	UI = {}
	UI.font = font
}

ui_begin :: proc(viewport: [2]f32) {
	UI.key_hash_table = {}

	UI.box_free_count = 0

	UI.parent_stack = {}
	UI.parent_depth = 0

	UI.style_depth = 0
	UI.style_next = {}

	clear(&UI.lines)

	// Tooltips: what keeps them open is seen again while they are built
	UI.tooltip_depth = 0
	for &tooltip in UI.tooltips {
		tooltip.built = false
		tooltip.wanted = false
	}

	// Keyed boxes built last frame keep their slot and are ready to be built again; the rest are freed.
	UI.boxes[0] = {}
	for i in 1 ..< BOX_MAX {
		box := &UI.boxes[i]
		if box.key != KEY_NIL {
			hashtable_save(&UI.key_hash_table, box.key, Id(i))
			box.key = {}
			box.flags = {}
			box.parent, box.child_first, box.child_last, box.sibling_next = 0, 0, 0, 0
			box.child_axis = {}
			box.text = {}
			box.lines = {}
		} else {
			box^ = {}
			UI.box_free[UI.box_free_count] = Id(i)
			UI.box_free_count += 1
		}
	}

	// Anims asked for last frame survive; the rest go back on the free stack.
	UI.anim_hash_table = {}
	UI.anim_free_count = 0
	for i in 1 ..< ANIM_MAX {
		anim := &UI.anims[i]
		if anim.key != KEY_NIL && anim.touched {
			hashtable_save(&UI.anim_hash_table, anim.key, Anim_Id(i))
			anim.touched = false
		} else {
			anim^ = {}
			UI.anim_free[UI.anim_free_count] = Anim_Id(i)
			UI.anim_free_count += 1
		}
	}

	// Popped in end
	ui_style_push(style_base())

	// The content is attached before the overlay, so everything floating over it comes later in box_order.
	UI.viewport = viewport
	viewport_size := UI_Style {
		width  = ui_px(viewport.x),
		height = ui_px(viewport.y),
	}
	UI.root, _ = box_make({}, viewport_size)
	parent_push(UI.root)
	UI.content, _ = box_make({}, {width = ui_grow(), height = ui_grow()})
	UI.overlay, _ = box_make({}, viewport_size)
	UI.boxes[UI.overlay].flags += {.Floating}
	parent_push(UI.content)
}

// Out: quads, appended to.
// Lays out, interacts and eases what was built since ui_begin, and draws it as screen quads
ui_end :: proc(input: UI_Input, dt: f32, quads: ^[dynamic; $N]Render_Quad) {
	// Pop the content, the root and the base style
	parent_pop()
	parent_pop()
	ui_style_pop()

	assert(UI.parent_depth == 0)
	assert(UI.style_depth == 0)

	compute_box_order()

	layout()

	update_interaction(input)

	// Tooltips: kept open while wanted open, or while the mouse is over them or one opened from them, and for
	// TOOLTIP_GRACE after, to cross the gap. Closed when no longer built
	{
		// The hovered tooltip, and those it was opened from
		chain: [TOOLTIPS_MAX]Key
		chain_len := 0
		for key := UI.tooltip_under; key != KEY_NIL && chain_len < TOOLTIPS_MAX; {
			chain[chain_len] = key
			chain_len += 1
			parent := KEY_NIL
			for tooltip in UI.tooltips do if tooltip.key == key do parent = tooltip.parent
			key = parent
		}
		for &tooltip in UI.tooltips {
			if tooltip.key == KEY_NIL {continue}
			if !tooltip.built {
				tooltip = {}
				continue
			}
			hovered := false
			for key in chain[:chain_len] do if key == tooltip.key do hovered = true
			tooltip.idle = (tooltip.wanted || hovered) ? 0 : tooltip.idle + dt
			if tooltip.idle > TOOLTIP_GRACE {tooltip = {}}
		}
	}

	// Ease the persistent state of every keyed box built this frame, and every live anim
	rate := ease_step(16, dt)
	for i := 0; i < UI.box_order_count; i += 1 {
		box := &UI.boxes[UI.box_order[i]]
		key := box.key
		if key == KEY_NIL {continue}
		box.hot_t += ((key == UI.hot ? 1 : 0) - box.hot_t) * rate
		box.active_t += ((key == UI.active ? 1 : 0) - box.active_t) * rate
		box.focus_t += ((key == UI.focus ? 1 : 0) - box.focus_t) * rate
		disabled := .Disabled in box.flags
		box.disabled_t += ((disabled ? 1 : 0) - box.disabled_t) * rate

		// Scrolling stops at the ends of the content, and axes that do not scroll return to the start.
		for axis in Axis {
			limit: f32
			if scroll_flag(axis) in box.flags {
				limit = max(0, box.content_size[axis] - box.size_computed[axis])
			}
			box.scroll_target[axis] = clamp(box.scroll_target[axis], 0, limit)
		}
		box.scroll += (box.scroll_target - box.scroll) * rate
	}

	for &anim in UI.anims {
		if anim.key == KEY_NIL {continue}
		anim.current += (anim.target - anim.current) * rate
	}

	draw(quads)
}

@(private = "file")
update_interaction :: proc(input: UI_Input) {
	// A box that disappeared or became disabled can no longer be released or lose focus, so let go of it.
	if !key_is_enabled_box(UI.active) {
		UI.active = {}
	}
	if !key_is_enabled_box(UI.focus) {
		UI.focus = {}
	}
	focus_before := UI.focus

	// This frame's keys go to the box focused before them, if it takes the keyboard.
	clear(&UI.events)
	UI.events_key = {}
	if key_takes_keyboard(UI.focus) {
		UI.events = input.events
		UI.events_key = UI.focus
	}

	mouse_pos := input.cursor
	UI.mouse = mouse_pos
	UI.wheel = input.wheel
	UI.hot = {}
	UI.hovered_any = false

	// The topmost tooltip under the mouse
	UI.tooltip_under = {}
	for i := UI.box_order_count; i > 0 && input.cursor_valid; i -= 1 {
		box := &UI.boxes[UI.box_order[i - 1]]
		if .Tooltip in box.flags && rect_contains(box.clip, mouse_pos) {
			UI.tooltip_under = box.key
			break
		}
	}

	// Only boxes can be pressed or focused; keyed text is only hovered.
	hot_is_box, hot_focusable := false, false
	// From the top down, the first clickable box or keyed run of text under the mouse is hot, and the wheel
	// starts from the first box under it that is clickable or scrolls. Other boxes, like the overlay, let the mouse through.
	// With the mouse outside the window, nothing is under it.
	hot_found := false
	under: Id
	for i := UI.box_order_count; i > 0 && input.cursor_valid; i -= 1 {
		id := UI.box_order[i - 1]
		box := &UI.boxes[id]
		if !rect_contains(box.clip, mouse_pos) {continue}
		clickable := .Clickable in box.flags
		if under == 0 && (clickable || box.flags & {.Scroll_X, .Scroll_Y} != {}) {
			under = id
		}
		if !hot_found && .Hover_Text in box.flags {
			if tag := box_text_tag_at(box, mouse_pos - text_origin(box)); tag != 0 {
				UI.hot = Key(tag)
				UI.hovered_any = true
				hot_found = true
			}
		}
		if !hot_found && clickable {
			assert(box.key != KEY_NIL, "clickable boxes need a key to receive signals")
			UI.hovered_any = true
			// A disabled box stops the search without becoming hot, so the mouse reaches nothing.
			if .Disabled not_in box.flags {
				UI.hot = box.key
				hot_is_box = true
				hot_focusable = .Focusable in box.flags
			}
			hot_found = true
		}
		// A tooltip stops the search without becoming hot: the mouse is over it, not what is under it.
		// Nor does the wheel reach through it
		if !hot_found && .Tooltip in box.flags {
			UI.hovered_any = true
			hot_found = true
			if under == 0 {under = id}
		}
		if hot_found && under != 0 {break}
	}

	// The wheel moves the nearest box from there up that scrolls along each axis.
	if input.wheel != {} {
		for axis in Axis {
			if input.wheel[axis] == 0 {continue}
			for id := under; id != 0; id = UI.boxes[id].parent {
				box := &UI.boxes[id]
				if scroll_flag(axis) in box.flags {
					box.scroll_target[axis] += scroll_from_wheel(box, input.wheel)[axis]
					break
				}
			}
		}
	}

	left_pressed := input.press
	UI.pressed_any = left_pressed

	UI.pressed = {}
	if UI.active == KEY_NIL && left_pressed && hot_is_box {
		UI.active = UI.hot
		UI.pressed = UI.hot
		UI.drag_start = mouse_pos
	}
	// Nothing stays held once the button is up, even when the press and the release came in the same frame.
	if !input.press_down {
		UI.active = {}
	}
	// While something is held, nothing else reacts to the mouse.
	if UI.active != KEY_NIL && UI.hot != UI.active {
		UI.hot = {}
	}

	// Any press moves focus: to the pressed box if it takes focus, otherwise away.
	if left_pressed {
		UI.focus = UI.hot if hot_focusable else {}
	}
	if input.escape {
		UI.focus = {}
	}
	if UI.focus_next != KEY_NIL {
		UI.focus = UI.focus_next
		UI.focus_next = {}
	}
	if UI.focus != focus_before {
		UI.cursor = max(int)
	}
	UI.keyboard_captured = key_takes_keyboard(UI.focus)
}

// A box was built this frame with key, is not disabled, and takes the keyboard while focused.
@(private = "file")
key_takes_keyboard :: proc(key: Key) -> bool {
	return(
		key_is_enabled_box(key) &&
		.Keyboard in UI.boxes[hashtable_find(&UI.key_hash_table, key)].flags \
	)
}

// Fills box_order by walking the tree from the root, parents before children.
@(private = "file")
compute_box_order :: proc() {
	UI.box_order_count = 0
	for id := UI.root; id != 0; {
		UI.box_order[UI.box_order_count] = id
		UI.box_order_count += 1

		// Down to the first child, else across to the next sibling of the nearest ancestor that has one.
		next := UI.boxes[id].child_first
		for p := id; next == 0 && p != UI.root; p = UI.boxes[p].parent {
			next = UI.boxes[p].sibling_next
		}
		id = next
	}
}

@(private = "file")
box_make :: proc(key: Key, forced: UI_Style) -> (Id, UI_Signal) {
	id := box_alloc(key)
	parent := parent_top()
	UI.boxes[id].parent = parent

	// Later layers win: the stack (base style and pushes), then the caller's next, then what the widget forces.
	style_apply(&UI.boxes[id], style_top())
	style_apply(&UI.boxes[id], UI.style_next)
	style_apply(&UI.boxes[id], forced)
	if parent != 0 && .Disabled in UI.boxes[parent].flags {
		UI.boxes[id].flags += {.Disabled}
	}
	UI.style_next = {}

	if parent != 0 {
		p_box := &UI.boxes[parent]
		if p_box.child_first == 0 {
			p_box.child_first = id
		} else {
			UI.boxes[p_box.child_last].sibling_next = id
		}
		p_box.child_last = id
	}

	return id, signal_from_key(key)
}

// A box was built this frame with key, and is not disabled.
@(private = "file")
key_is_enabled_box :: proc(key: Key) -> bool {
	box := &UI.boxes[hashtable_find(&UI.key_hash_table, key)]
	return key != KEY_NIL && box.key == key && .Disabled not_in box.flags
}

// The signal of whatever carries the label's key in the current scope: a box, or a keyed run of text.
ui_signal :: proc(label: string) -> UI_Signal {
	return signal_from_key(key_from_string(label))
}

// Unkeyed things cannot be told apart between frames, so they never get a signal.
@(private = "file")
signal_from_key :: proc(key: Key) -> UI_Signal {
	signal: UI_Signal
	if key != KEY_NIL {
		signal.hovered = UI.hot == key
		signal.pressed = UI.pressed == key
		signal.held = UI.active == key
		signal.focused = UI.focus == key
		if signal.held {
			signal.drag = UI.mouse - UI.drag_start
		}
		if signal.hovered {
			signal.wheel = UI.wheel
		}
	}
	return signal
}

@(private = "file")
parent_push :: proc(id: Id) {
	assert(UI.parent_depth < DEPTH_MAX)
	UI.parent_stack[UI.parent_depth] = id
	UI.parent_depth += 1
}

@(private = "file")
parent_pop :: proc() {
	assert(UI.parent_depth > 0)
	UI.parent_depth -= 1
	UI.parent_stack[UI.parent_depth] = {}
}

@(private = "file")
parent_top :: proc() -> Id {
	out: Id
	if UI.parent_depth > 0 {
		out = UI.parent_stack[UI.parent_depth - 1]
	}
	return out
}

// Overrides every box made until the matching pop.
ui_style_push :: proc(override: UI_Style) {
	assert(UI.style_depth < DEPTH_MAX)
	top := style_top()
	style_merge(&top, override)
	UI.style_stack[UI.style_depth] = top
	UI.style_depth += 1
}

ui_style_pop :: proc() {
	assert(UI.style_depth > 0)
	UI.style_depth -= 1
}

// Overrides only the next box made; repeated calls accumulate. Widgets route their style parameter through here.
ui_style_next :: proc(override: UI_Style) {
	style_merge(&UI.style_next, override)
}

@(private = "file")
style_top :: proc() -> UI_Style {
	out: UI_Style
	if UI.style_depth > 0 {
		out = UI.style_stack[UI.style_depth - 1]
	}
	return out
}

@(private = "file")
style_merge :: proc(dst: ^UI_Style, src: UI_Style) {
	if src.width != nil {dst.width = src.width}
	if src.height != nil {dst.height = src.height}
	if src.padding != nil {dst.padding = src.padding}
	if src.gap != nil {dst.gap = src.gap}
	if src.background != nil {dst.background = src.background}
	if src.hot_background != nil {dst.hot_background = src.hot_background}
	if src.active_background != nil {dst.active_background = src.active_background}
	if src.border != nil {dst.border = src.border}
	if src.focus_border != nil {dst.focus_border = src.focus_border}
	if src.thickness != nil {dst.thickness = src.thickness}
	if src.radius != nil {dst.radius = src.radius}
	if src.font != nil {dst.font = src.font}
	if src.text_color != nil {dst.text_color = src.text_color}
	if src.hot_text_color != nil {dst.hot_text_color = src.hot_text_color}
	if src.disabled != nil {dst.disabled = src.disabled}
	if src.position != nil {dst.position = src.position}
}

@(private = "file")
style_apply :: proc(dst: ^Box, src: UI_Style) {
	if v, ok := src.width.?; ok {dst.size.x = v}
	if v, ok := src.height.?; ok {dst.size.y = v}
	if v, ok := src.padding.?; ok {dst.padding = v}
	if v, ok := src.gap.?; ok {dst.gap = v}
	if v, ok := src.background.?; ok {dst.background = v}
	if v, ok := src.hot_background.?; ok {dst.hot_background = v}
	if v, ok := src.active_background.?; ok {dst.active_background = v}
	if v, ok := src.border.?; ok {dst.border = v}
	if v, ok := src.focus_border.?; ok {dst.focus_border = v}
	if v, ok := src.thickness.?; ok {dst.thickness = v}
	if v, ok := src.radius.?; ok {dst.radius = v}
	if v, ok := src.font.?; ok {dst.font = v}
	if v, ok := src.text_color.?; ok {dst.text_color = v}
	if v, ok := src.hot_text_color.?; ok {dst.hot_text_color = v}
	if v, ok := src.disabled.?; ok {
		if v {dst.flags += {.Disabled}} else {dst.flags -= {.Disabled}}
	}
	if v, ok := src.position.?; ok {dst.position = v}
}

@(private = "file")
layout :: proc() {
	compute_independent_sizes()

	compute_dependent_sizes(.X)

	// Text breaks into lines at its box's final width, and boxes sized by their text take all of its height.
	for i := 0; i < UI.box_order_count; i += 1 {
		box := &UI.boxes[UI.box_order[i]]
		if box.text == 0 || box.size.y.kind != .Text {continue}
		box.lines.begin = len(UI.lines)
		text_wrap(box.text, text_room(box).x, &UI.lines)
		box.lines.len = len(UI.lines) - box.lines.begin
		box.size_computed.y = text_height(box) + 2 * box.padding.y
	}

	compute_dependent_sizes(.Y)

	// Placement. The root has no parent to clip it, so it sees all of itself.
	root := &UI.boxes[UI.box_order[0]]
	root.clip = rect_from_pos_size(root.pos_computed, root.size_computed)
	for i := 0; i < UI.box_order_count; i += 1 {
		parent := &UI.boxes[UI.box_order[i]]
		axis := parent.child_axis
		cross := axis_flip(axis)
		assert(
			parent.key != KEY_NIL || parent.flags & {.Scroll_X, .Scroll_Y} == {},
			"scrolling boxes need a key to keep their offset",
		)
		// Whole pixels, so scrolled text stays sharp
		scroll := parent.scroll
		scroll = {math.floor(scroll.x), math.floor(scroll.y)}
		offset, extent: f32
		placed := 0

		for id := parent.child_first; id != 0; id = UI.boxes[id].sibling_next {
			child := &UI.boxes[id]

			if .Floating in child.flags {
				child.pos_computed = parent.pos_computed + child.position - scroll
			} else {
				child.pos_computed = parent.pos_computed + parent.padding - scroll
				child.pos_computed[axis] += offset
				offset += child.size_computed[axis] + parent.gap
				extent = max(extent, child.size_computed[cross])
				placed += 1
			}

			child.clip = rect_intersect(
				parent.clip,
				rect_from_pos_size(child.pos_computed, child.size_computed),
			)
		}

		if placed > 0 {offset -= parent.gap}
		parent.content_size[axis] = offset + 2 * parent.padding[axis]
		parent.content_size[cross] = extent + 2 * parent.padding[cross]
	}
}

// The first child of parent in the flow, and the next one after id: floating boxes are skipped.
@(private = "file")
flow_first :: proc(parent: ^Box) -> Id {
	return flow_skip(parent.child_first)
}

@(private = "file")
flow_next :: proc(id: Id) -> Id {
	return flow_skip(UI.boxes[id].sibling_next)
}

@(private = "file")
flow_skip :: proc(id: Id) -> Id {
	id := id
	for id != 0 && (.Floating in UI.boxes[id].flags) {
		id = UI.boxes[id].sibling_next
	}
	return id
}

// How far the wheel moves a scrolling box's content, in pixels.
@(private = "file")
scroll_from_wheel :: proc(box: ^Box, wheel: [2]f32) -> [2]f32 {
	em := text_font_metrics(box.font).size
	// Turning the wheel away from the user reveals what is above.
	return [2]f32{wheel.x, -wheel.y} * SCROLL_STEP * em
}

// The flag that makes a box scroll along the axis
@(private = "file")
scroll_flag :: proc(axis: Axis) -> UI_Box_Flag {
	out: UI_Box_Flag
	switch axis {
	case .X:
		out = .Scroll_X
	case .Y:
		out = .Scroll_Y
	}
	return out
}

// Where a box's text starts: left-aligned after the padding, centered vertically, never above the box.
@(private = "file")
text_origin :: proc(box: ^Box) -> [2]f32 {
	pos := box.pos_computed
	pos.x += box.padding.x
	pos.y += max(0, box.size_computed.y - text_height(box)) / 2
	return pos
}

// Height of a box's text: its lines, or its one line
@(private = "file")
text_height :: proc(box: ^Box) -> f32 {
	line := text_size(box.text).y
	return box.lines.len > 0 ? f32(box.lines.len) * line : line
}

// Tag of the text under point, measured from the text's origin: on its line, or on its one line. 0: none
@(private = "file")
box_text_tag_at :: proc(box: ^Box, point: [2]f32) -> u64 {
	line_height := text_size(box.text).y
	if point.y < 0 || line_height <= 0 {return 0}
	line := int(point.y / line_height)
	if box.lines.len == 0 {
		return line == 0 ? text_tag_at(box.text, point.x) : 0
	}
	if line >= box.lines.len {return 0}
	return text_tag_at(span_slice(UI.lines[:], box.lines)[line], point.x)
}

// The room a box's text is laid out in: the box inside its padding. One-line text that does not fit ends in "...".
@(private = "file")
text_room :: proc(box: ^Box) -> [2]f32 {
	return {
		max(0, box.size_computed.x - 2 * box.padding.x),
		max(0, box.size_computed.y - 2 * box.padding.y),
	}
}

@(private = "file")
axis_flip :: proc(axis: Axis) -> Axis {
	out: Axis
	switch axis {
	case .X:
		out = .Y
	case .Y:
		out = .X
	}
	return out
}

@(private = "file")
compute_independent_sizes :: proc() {
	for i := 0; i < UI.box_order_count; i += 1 {
		box := &UI.boxes[UI.box_order[i]]
		size := box.size
		value: [2]f32

		for axis in Axis {
			#partial switch size[axis].kind {
			case .Pixels:
				value[axis] = size[axis].value
			case .Text:
				// On one line; a narrower final width wraps it and recomputes the height.
				value[axis] = text_size(box.text)[axis] + 2 * box.padding[axis]
			}
		}

		box.size_computed = value
	}
}

@(private = "file")
compute_dependent_sizes :: proc(axis: Axis) {
	// Backwards pass: fit
	for i := UI.box_order_count; i > 0; i = i - 1 {
		box := &UI.boxes[UI.box_order[i - 1]]
		size := box.size[axis]

		value := box.size_computed[axis]

		#partial switch size.kind {
		case .Fit, .Grow:
			value = 0
			count := 0
			for child := flow_first(box); child != 0; child = flow_next(child) {
				child_value := UI.boxes[child].size_computed[axis]
				if axis == box.child_axis {
					value += child_value
				} else {
					value = max(value, child_value)
				}
				count += 1
			}
			if axis == box.child_axis {
				value += f32(max(0, count - 1)) * box.gap
			}
			value += 2 * box.padding[axis]
		}
		box.size_computed[axis] = value
	}

	// Forward pass: grow or shrink (on children)
	for i := 0; i < UI.box_order_count; i += 1 {
		parent := &UI.boxes[UI.box_order[i]]
		available := max(0, parent.size_computed[axis] - 2 * parent.padding[axis])

		// Children of a box scrolling along this axis may overflow it.
		scrolls := scroll_flag(axis) in parent.flags

		if axis != parent.child_axis {
			// Cross-axis children each have the parent's full extent available, and no more.
			for kid := flow_first(parent); kid != 0; kid = flow_next(kid) {
				child := &UI.boxes[kid]
				if child.size[axis].kind == .Grow {
					child.size_computed[axis] = available
				}
				if !scrolls {
					child.size_computed[axis] = min(child.size_computed[axis], available)
				}
			}
			continue
		}

		total, total_weight: f32
		count := 0
		for kid := flow_first(parent); kid != 0; kid = flow_next(kid) {
			child := &UI.boxes[kid]
			total += child.size_computed[axis]
			if child.size[axis].kind == .Grow && child.size[axis].value > 0 {
				total_weight += child.size[axis].value
			}
			count += 1
		}
		gaps := f32(max(0, count - 1)) * parent.gap
		remaining := available - gaps - total

		if remaining > 0 && total_weight > 0 {
			// Leftover space goes to Grow children by weight.
			for kid := flow_first(parent); kid != 0; kid = flow_next(kid) {
				child := &UI.boxes[kid]
				size := child.size[axis]
				if size.kind == .Grow && size.value > 0 {
					child.size_computed[axis] += remaining * (size.value / total_weight)
				}
			}
		} else if remaining < 0 && !scrolls {
			// Overflow is taken from each child in proportion to the size it is willing to give up.
			budget: f32
			for kid := flow_first(parent); kid != 0; kid = flow_next(kid) {
				child := &UI.boxes[kid]
				budget += child.size_computed[axis] * (1 - child.size[axis].strictness)
			}
			if budget > 0 {
				fraction := min(1, -remaining / budget)
				for kid := flow_first(parent); kid != 0; kid = flow_next(kid) {
					child := &UI.boxes[kid]
					give := child.size_computed[axis] * (1 - child.size[axis].strictness)
					child.size_computed[axis] -= give * fraction
				}
			}
		}
	}
}

// Out: quads, appended to.
// Every box, parents first: background, border, text and focus ring, each clipped to the box's clip
@(private = "file")
draw :: proc(quads: ^[dynamic; $N]Render_Quad) {
	for i := 0; i < UI.box_order_count; i += 1 {
		id := UI.box_order[i]
		box := &UI.boxes[id]
		// Clipped away. An empty quad clip would mean no clip at all
		if box.clip.z <= 0 || box.clip.w <= 0 {continue}
		bounds: [4]f32 = {
			box.pos_computed.x,
			box.pos_computed.y,
			box.size_computed.x,
			box.size_computed.y,
		}
		clip := Extents{box.clip.x, box.clip.y, box.clip.x + box.clip.z, box.clip.y + box.clip.w}

		SOFTNESS :: 0.8

		// Unkeyed boxes are new every frame and cannot animate, so they fade fully at once.
		disabled_t := box.disabled_t
		if box.key == KEY_NIL {
			disabled_t = 1 if .Disabled in box.flags else 0
		}
		alpha := 1 - 0.5 * disabled_t

		if UI_Box_Flag.Background in box.flags {
			background := box.background
			if .Hot_Effects in box.flags {
				background += (box.hot_background - background) * box.hot_t
				background += (box.active_background - background) * box.active_t
			}
			background.a *= alpha
			append(quads, rect_quad(bounds, background, box.radius, 0, SOFTNESS, clip))
		}
		if UI_Box_Flag.Border in box.flags && box.thickness > 0 {
			border := box.border
			border.a *= alpha
			append(quads, rect_quad(bounds, border, box.radius, box.thickness, SOFTNESS, clip))
		}
		if box.text != 0 {
			// Its lines one under the other, or its one line. Faded with the box
			first := len(quads)
			origin := text_origin(box)
			width := text_room(box).x
			if box.lines.len > 0 {
				line_height := text_size(box.text).y
				for line, n in span_slice(UI.lines[:], box.lines) {
					text_quads(line, origin + {0, f32(n) * line_height}, width, true, clip, quads)
				}
			} else {
				text_quads(box.text, origin, width, true, clip, quads)
			}
			for &quad in quads[first:] {
				for &color in quad.colors do color.a = u8(f32(color.a) * alpha + 0.5)
			}
		}
		if .Focusable in box.flags {
			focus_t := box.focus_t
			if focus_t > 0.001 {
				color := box.focus_border
				color.a *= focus_t * alpha
				append(quads, rect_quad(bounds, color, box.radius, 2, SOFTNESS, clip))
			}
		}
	}
}

// A rectangle's quad. bounds: x, y, width, height. color: straight RGBA, 0..1
@(private = "file")
rect_quad :: proc(
	bounds: [4]f32,
	color: [4]f32,
	radius, thickness, softness: f32,
	clip: Extents,
) -> Render_Quad {
	c := linalg.clamp(color, 0, 1) * 255 + 0.5
	bytes := [4]u8{u8(c.r), u8(c.g), u8(c.b), u8(c.a)}
	return {
		rect = {bounds.x, bounds.y, bounds.x + bounds.z, bounds.y + bounds.w},
		clip = clip,
		colors = {bytes, bytes, bytes, bytes},
		radii = radius,
		thickness = thickness,
		softness = softness,
	}
}

// Rects as x, y, width, height
@(private = "file")
rect_intersect :: proc(r1: [4]f32, r2: [4]f32) -> [4]f32 {
	lo := [2]f32{max(r1.x, r2.x), max(r1.y, r2.y)}
	hi := [2]f32{min(r1.x + r1.z, r2.x + r2.z), min(r1.y + r1.w, r2.y + r2.w)}
	return {lo.x, lo.y, max(hi.x - lo.x, 0), max(hi.y - lo.y, 0)}
}

// The point is inside, counting the top and left edges but not the bottom and right.
@(private = "file")
rect_contains :: proc(rect: [4]f32, pt: [2]f32) -> bool {
	return pt.x >= rect.x && pt.y >= rect.y && pt.x < rect.x + rect.z && pt.y < rect.y + rect.w
}

@(private = "file")
rect_from_pos_size :: proc(pos: [2]f32, size: [2]f32) -> [4]f32 {
	return {pos.x, pos.y, size.x, size.y}
}

/// Widgets ///

ui_fit :: proc(strictness: f32 = 1) -> UI_Size {
	return {.Fit, 0, strictness}
}

ui_grow :: proc(weight: f32 = 1, strictness: f32 = 0) -> UI_Size {
	return {.Grow, weight, strictness}
}

// The Midnight palette
@(private = "file")
BACKGROUND :: [4]f32{0.15, 0.17, 0.21, 1}
@(private = "file")
HOT_BACKGROUND :: [4]f32{0.24, 0.32, 0.43, 1}
@(private = "file")
ACTIVE_BACKGROUND :: [4]f32{0.29, 0.41, 0.56, 1}
@(private = "file")
BORDER :: [4]f32{0.24, 0.29, 0.36, 1}
@(private = "file")
FOCUS_BORDER :: [4]f32{0.9, 0.71, 0.38, 1}
@(private = "file")
TEXT_COLOR :: [4]f32{0.91, 0.92, 0.94, 1}
@(private = "file")
HOT_TEXT_COLOR :: [4]f32{1, 1, 1, 1}
// The checkbox square and the space between it and its label
@(private = "file")
CHECK_SIZE :: 18
@(private = "file")
CHECK_GAP :: 8
// Where a tooltip sits from the mouse
@(private = "file")
TOOLTIP_OFFSET :: [2]f32{16, 16}
// The thickness of a scrollbar
@(private = "file")
SCROLLBAR_SIZE :: 8
// The width of the text cursor
@(private = "file")
CARET_WIDTH :: 2
// The label of the box a scroll panel's children scroll in
@(private = "file")
SCROLL_PANE :: "scroll pane"

// The look of every box unless pushed or overridden: pushed at the bottom of the stack in begin.
@(private = "file")
style_base :: proc() -> UI_Style {
	font := UI.font
	em := text_font_metrics(font).size
	return {
		width = ui_px(10 * em),
		height = ui_px(1.5 * em),
		padding = [2]f32{0, 0},
		gap = 0,
		background = BACKGROUND,
		hot_background = HOT_BACKGROUND,
		active_background = ACTIVE_BACKGROUND,
		border = BORDER,
		focus_border = FOCUS_BORDER,
		thickness = 1,
		radius = 5,
		font = font,
		text_color = TEXT_COLOR,
		hot_text_color = HOT_TEXT_COLOR,
		position = [2]f32{0, 0},
	}
}

// Closes a container opened by a widget, at the end of the caller's scope.
@(private = "file")
container_end :: proc(open: bool) {
	if open {
		parent_pop()
	}
}

@(private = "file")
container_begin :: proc(label: string, child_axis: Axis, style: UI_Style) -> (^Box, UI_Signal) {
	ui_style_next(style)
	id, signal := box_make(key_from_string(label), {})
	box := &UI.boxes[id]
	box.child_axis = child_axis
	parent_push(id)
	return box, signal
}

// Children left to right.
@(deferred_out = container_end)
ui_row :: proc(style := UI_Style{}) -> bool {
	container_begin("", .X, style)
	return true
}

// Children top to bottom.
@(deferred_out = container_end)
ui_column :: proc(style := UI_Style{}) -> bool {
	container_begin("", .Y, style)
	return true
}

// A container that draws its background and border, and catches the mouse over it.
@(deferred_out = container_end)
ui_panel :: proc(label: string, style := UI_Style{}, child_axis := Axis.Y) -> bool {
	box, _ := container_begin(label, child_axis, style)
	box.flags += {.Background, .Border, .Clickable}
	return true
}

// A panel whose children scroll along its child axis when they do not fit, with a scrollbar beside them.
// The style goes to the panel; its children sit in a pane that fills it, next to the bar.
@(deferred_out = scroll_panel_end)
ui_scroll_panel :: proc(label: string, style := UI_Style{}, child_axis := Axis.Y) -> bool {
	panel, _ := container_begin(label, axis_flip(child_axis), style)
	panel.flags += {.Background, .Border, .Clickable}
	pane, _ := box_make(
		key_from_string(SCROLL_PANE),
		{width = ui_grow(), height = ui_grow(), padding = [2]f32{0, 0}, gap = panel.gap},
	)
	UI.boxes[pane].flags += {scroll_flag(child_axis)}
	UI.boxes[pane].child_axis = child_axis
	parent_push(pane)
	return true
}

// Closes the pane, adds the bar after the caller's children, then closes the panel.
@(private = "file")
scroll_panel_end :: proc(open: bool) {
	if open {
		axis := UI.boxes[parent_top()].child_axis
		parent_pop()
		ui_scrollbar(SCROLL_PANE, axis)
		parent_pop()
	}
}

// Shows which part of a pane's content is in view along axis, from the pane's layout last frame; dragging the thumb scrolls it.
// The pane is found by its label, so it must have been made under the same parent.
ui_scrollbar :: proc(pane_label: string, axis: Axis, style := UI_Style{}) {
	pane_key := key_from_string(pane_label)
	pane_id := hashtable_find(&UI.key_hash_table, pane_key)
	pane := &UI.boxes[pane_id]
	view := pane.size_computed[axis]
	content := max(pane.content_size[axis], view)
	offset := pane.scroll[axis]

	// Grow weights split the track in proportion: the space before, the thumb, the space after.
	track_style, thumb_style: UI_Style
	switch axis {
	case .X:
		track_style = {
			width  = ui_grow(),
			height = ui_px(SCROLLBAR_SIZE),
		}
		thumb_style = {
			width  = ui_grow(view),
			height = ui_grow(),
		}
	case .Y:
		track_style = {
			width  = ui_px(SCROLLBAR_SIZE),
			height = ui_grow(),
		}
		thumb_style = {
			width  = ui_grow(),
			height = ui_grow(view),
		}
	}
	// Keyed under the pane, so every pane's bar has its own.
	ui_style_next(style)
	track, track_signal := box_make(
		key_from_string_seeded("scrollbar", u64(pane_key)),
		track_style,
	)
	UI.boxes[track].flags += {.Background, .Clickable}
	UI.boxes[track].child_axis = axis
	thumb_color := UI.boxes[track].border
	// Pixels of content per pixel of track, as laid out last frame
	ratio := content / max(1, UI.boxes[track].size_computed[axis])

	parent_push(track)
	defer parent_pop()
	ui_spacer(ui_grow(offset))
	thumb_style.background = thumb_color
	thumb, thumb_signal := box_make(key_from_string("thumb"), thumb_style)
	UI.boxes[thumb].flags += {.Background, .Clickable, .Hot_Effects}
	ui_spacer(ui_grow(max(0, content - view - offset)))

	// The thumb stays under the mouse: the offset it had at the press, plus the drag scaled to the content.
	if thumb_signal.pressed {
		ui_drag_store({offset, 0})
	}
	if thumb_signal.held && pane_id != 0 {
		target := clamp(ui_drag_stored().x + thumb_signal.drag[axis] * ratio, 0, content - view)
		pane.scroll_target[axis] = target
		pane.scroll[axis] = target
	}
	// The wheel over the bar scrolls its pane, as it would over the pane itself.
	wheel := track_signal.wheel + thumb_signal.wheel
	if pane_id != 0 {
		pane.scroll_target[axis] += scroll_from_wheel(pane, wheel)[axis]
	}
}

// Builds over everything else, filling the viewport; its children lay out left to right.
@(deferred_out = container_end)
ui_overlay :: proc() -> bool {
	parent_push(UI.overlay)
	return true
}

// Tooltips open at once, nested ones included
@(private = "file")
TOOLTIPS_MAX :: 8
// Seconds a tooltip stays open once nothing keeps it, to cross the gap from what opened it
@(private = "file")
TOOLTIP_GRACE :: 0.3

// A tooltip kept open between frames
@(private = "file")
Tooltip :: struct {
	key:       Key,
	// The tooltip it was opened from. KEY_NIL: none
	parent:    Key,
	// The mouse when it opened: it sits next to this
	opened_at: [2]f32,
	// This frame: built, and wanted open
	built:     bool,
	wanted:    bool,
	// Seconds since it was last wanted open, or the mouse was last over it or a tooltip opened from it
	idle:      f32,
}

// A column floating over everything next to where the mouse was when it opened, kept inside the window.
// Opens while want_open, and stays open while the mouse is over it, or over a tooltip opened from
// it, and for a moment after. Returns true while open: build its contents then. Built inside another
// tooltip, it is opened from that one. The label is only the key
@(deferred_out = tooltip_end)
ui_tooltip :: proc(label: string, want_open: bool, style := UI_Style{}) -> bool {
	key := key_from_string(label)
	assert(key != KEY_NIL, "tooltips need a non-empty label")

	// Open already, or opening now
	tooltip: ^Tooltip
	for &open in UI.tooltips do if open.key == key do tooltip = &open
	if tooltip == nil {
		if !want_open {return false}
		for &free in UI.tooltips do if free.key == KEY_NIL && tooltip == nil do tooltip = &free
		// Too many open
		if tooltip == nil {return false}
		tooltip^ = {
			key    = key,
			parent = UI.tooltip_depth > 0 ? UI.tooltip_stack[UI.tooltip_depth - 1] : KEY_NIL,
			opened_at = UI.mouse,
		}
	}
	tooltip.built = true
	if want_open {tooltip.wanted = true}

	parent_push(UI.overlay)
	// Last frame's size decides whether it fits to the right of and below where it opened.
	size := UI.boxes[hashtable_find(&UI.key_hash_table, key)].size_computed
	position := tooltip.opened_at + TOOLTIP_OFFSET
	flipped := tooltip.opened_at - TOOLTIP_OFFSET - size
	for axis in Axis {
		if position[axis] + size[axis] > UI.viewport[axis] {
			position[axis] = flipped[axis]
		}
		position[axis] = max(0, position[axis])
	}
	ui_style_next(style)
	id, _ := box_make(key, {position = position})
	box := &UI.boxes[id]
	box.flags += {.Floating, .Background, .Border, .Tooltip}
	box.child_axis = .Y
	parent_push(id)

	assert(UI.tooltip_depth < TOOLTIPS_MAX)
	UI.tooltip_stack[UI.tooltip_depth] = key
	UI.tooltip_depth += 1
	return true
}

@(private = "file")
tooltip_end :: proc(open: bool) {
	if open {
		UI.tooltip_depth -= 1
		// Ends the tooltip
		parent_pop()
		// And ends the UI.overlay scope
		parent_pop()
	}
}

// Empty space along the parent's child axis, and none across it.
ui_spacer :: proc(size: UI_Size) {
	forced: UI_Style
	switch UI.boxes[parent_top()].child_axis {
	case .X:
		forced.width = size
		forced.height = ui_px(0)
	case .Y:
		forced.width = ui_px(0)
		forced.height = size
	}
	box_make({}, forced)
}

// Part of a rich label. Font and color default to the label's.
UI_Text :: struct {
	text:      string,
	font:      Maybe(Text_Font_Id),
	color:     Maybe([4]f32),
	// Faded toward while the run, or a Hot_Effects box it is in, is hovered
	hot_color: Maybe([4]f32),
	// Makes the run take the mouse; ui_signal(key) in the same scope reads it
	key:       string,
}

// A label made of parts, which may mix fonts and colors.
ui_label_text :: proc(parts: []UI_Text, style := UI_Style{}) -> UI_Signal {
	ui_style_next(style)
	id, signal := box_make({}, {})
	box_set_text(&UI.boxes[id], parts)
	return signal
}

// A line of text. Anything from "##" on is not shown.
ui_label :: proc(text: string, style := UI_Style{}) -> UI_Signal {
	ui_style_next(style)
	id, signal := box_make({}, {})
	box := &UI.boxes[id]
	box_set_label(box, text)
	return signal
}

// A clickable box with a label. The label is also the key: use "###" to keep the key stable when the text changes.
ui_button :: proc(label: string, style := UI_Style{}) -> UI_Signal {
	ui_style_next(style)
	id, signal := box_make(key_from_string(label), {})
	box := &UI.boxes[id]
	box.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	box_set_label(box, label)
	return signal
}

// A button showing the selected choice; pressing it opens the choices under it, floating over everything.
// Picking one selects it, and any press closes the list. The label is only the key; choices must differ.
ui_combo :: proc(
	label: string,
	selection: ^int,
	open: ^bool,
	choices: []string,
	style := UI_Style{},
) -> UI_Signal {
	ui_style_next(style)
	key := key_from_string(label)
	id, signal := box_make(key, {})
	shown := &UI.boxes[id]
	shown.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	if selection^ >= 0 && selection^ < len(choices) {
		box_set_label(shown, choices[selection^])
	}
	if signal.pressed {
		open^ = !open^
	}

	if open^ {
		// Right under the button and as wide, from its layout last frame
		parent_push(UI.overlay)
		list, _ := box_make(
			key_from_string_seeded("choices", u64(key)),
			{
				position = shown.pos_computed + {0, shown.size_computed.y},
				width = ui_px(shown.size_computed.x),
				height = ui_fit(),
			},
		)
		UI.boxes[list].flags += {.Floating, .Background, .Border, .Clickable}
		UI.boxes[list].child_axis = .Y
		parent_push(list)
		for choice, i in choices {
			// Laid out like the button, across the list
			if ui_button(choice, {width = ui_grow(), padding = shown.padding}).pressed {
				selection^ = i
			}
		}
		parent_pop()
		parent_pop()

		// Built first, so a press on a choice was read before the list closes.
		if UI.pressed_any && !signal.pressed {
			open^ = false
		}
	}
	return signal
}

// A track that fills from the left up to value, between lo and hi. Pressing or dragging on it sets the value from where
// the mouse is along the track, as laid out last frame. The label is only the key.
ui_slider :: proc(label: string, value: ^f32, lo, hi: f32, style := UI_Style{}) -> UI_Signal {
	ui_style_next(style)
	id, signal := box_make(key_from_string(label), {})
	track := &UI.boxes[id]
	track.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	track.child_axis = .X
	if signal.held {
		inner := track.size_computed.x - 2 * track.padding.x
		if inner > 0 {
			t := clamp((UI.mouse.x - track.pos_computed.x - track.padding.x) / inner, 0, 1)
			value^ = lo + (hi - lo) * t
		}
	}
	// Grow weights split the track: the filled part, then the rest.
	t := clamp((value^ - lo) / (hi - lo), 0, 1)
	fill_color := track.focus_border
	parent_push(id)
	defer parent_pop()
	fill, _ := box_make(
		{},
		{width = ui_grow(t), height = ui_grow(), background = fill_color, radius = track.radius},
	)
	UI.boxes[fill].flags += {.Background}
	ui_spacer(ui_grow(1 - t))
	return signal
}

// A line of editable text held in buffer, length bytes of it in use. While focused it takes the keyboard: typing inserts
// at the cursor, and Backspace, Delete, Left, Right, Home and End edit and move it. The label is only the key.
ui_input :: proc(label: string, buffer: []u8, length: ^int, style := UI_Style{}) -> UI_Signal {
	ui_style_next(style)
	key := key_from_string(label)
	id, signal := box_make(key, {})
	box := &UI.boxes[id]
	box.flags += {.Background, .Border, .Clickable, .Focusable, .Keyboard}

	if signal.focused {
		// On a rune's first byte, within the text
		cursor := clamp(UI.cursor, 0, length^)
		for cursor > 0 && cursor < length^ && !utf8.rune_start(buffer[cursor]) {
			cursor -= 1
		}
		if UI.events_key == key {
			for event in UI.events[:] {
				switch event.kind {
				case .Char:
					if event.char < ' ' || event.char == 0x7f {continue}
					bytes, n := utf8.encode_rune(event.char)
					if length^ + n > len(buffer) {continue}
					copy(buffer[cursor + n:length^ + n], buffer[cursor:length^])
					copy(buffer[cursor:], bytes[:n])
					length^ += n
					cursor += n
				case .Key:
					#partial switch event.key {
					case .BACKSPACE:
						if cursor > 0 {
							_, n := utf8.decode_last_rune(buffer[:cursor])
							copy(buffer[cursor - n:], buffer[cursor:length^])
							length^ -= n
							cursor -= n
						}
					case .DELETE:
						if cursor < length^ {
							_, n := utf8.decode_rune(buffer[cursor:length^])
							copy(buffer[cursor:], buffer[cursor + n:length^])
							length^ -= n
						}
					case .LEFT:
						if cursor > 0 {
							_, n := utf8.decode_last_rune(buffer[:cursor])
							cursor -= n
						}
					case .RIGHT:
						if cursor < length^ {
							_, n := utf8.decode_rune(buffer[cursor:length^])
							cursor += n
						}
					case .HOME:
						cursor = 0
					case .END:
						cursor = length^
					}
				}
			}
		}
		UI.cursor = cursor
	}

	box_set_text(box, {UI_Text{text = string(buffer[:length^])}})

	// A bar one line tall before the byte at the cursor, from the box's layout last frame
	if signal.focused {
		metrics := text_font_metrics(box.font)
		line := metrics.ascent - metrics.descent
		before := text_make({{text = string(buffer[:UI.cursor]), font = box.font}})
		position := [2]f32 {
			math.round(box.padding.x + text_size(before).x),
			math.round(max(0, box.size_computed.y - line) / 2),
		}
		parent_push(id)
		caret, _ := box_make(
			{},
			{
				position = position,
				width = ui_px(CARET_WIDTH),
				height = ui_px(line),
				background = box.text_color,
				radius = 0,
			},
		)
		UI.boxes[caret].flags += {.Floating, .Background}
		parent_pop()
	}
	return signal
}

// A clickable row holding a check square and a label, all plain boxes. Flips value when pressed.
ui_checkbox :: proc(label: string, value: ^bool, style := UI_Style{}) -> UI_Signal {
	ui_style_next(style)
	id, signal := box_make(key_from_string(label), {})
	if signal.pressed {
		value^ = !value^
	}
	row := &UI.boxes[id]
	row.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	row.child_axis = .X
	// The parts take their look from the row, so a style passed to the checkbox reaches them too.
	ink, mark_color, font := row.text_color, row.focus_border, row.font

	parent_push(id)
	defer parent_pop()

	// Keyed under the row, so every checkbox has its own.
	checked := f32(1) if value^ else 0
	checked_t := ui_anim("checked", checked, checked)

	// Spacers above and below center the square in the row's height.
	column, _ := box_make(
		{},
		{width = ui_fit(), height = ui_grow(), padding = [2]f32{0, 0}, gap = 0},
	)
	UI.boxes[column].child_axis = .Y
	parent_push(column)
	ui_spacer(ui_grow())
	square, _ := box_make(
		{},
		{
			width = ui_px(CHECK_SIZE),
			height = ui_px(CHECK_SIZE),
			padding = [2]f32{4, 4},
			border = ink,
			thickness = 1,
			radius = 3,
		},
	)
	UI.boxes[square].flags += {.Border}
	if checked_t > 0.001 {
		mark_color.a *= checked_t
		parent_push(square)
		mark, _ := box_make(
			{},
			{width = ui_grow(), height = ui_grow(), background = mark_color, radius = 2},
		)
		UI.boxes[mark].flags += {.Background}
		parent_pop()
	}
	ui_spacer(ui_grow())
	parent_pop()

	ui_spacer(ui_px(CHECK_GAP))

	text, _ := box_make(
		{},
		{
			width = ui_text_dim(),
			height = ui_grow(),
			padding = [2]f32{0, 0},
			font = font,
			text_color = ink,
		},
	)
	box_set_label(&UI.boxes[text], label)
	return signal
}
