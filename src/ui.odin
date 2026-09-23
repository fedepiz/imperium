package main

import "core:hash"
import "core:math"
import "core:strings"
import "vendor:sdl3"

// Maximum number of ui boxes supported by the system
UI_BOX_MAX :: 2048
UI_DEPTH_MAX :: 32
// Maximum number of animated values alive at once
UI_ANIM_MAX :: 1024

@(private = "file")
UI: struct {
	boxes:           [UI_BOX_MAX]Ui_Box,
	// Free stack of boxes
	box_free:        [UI_BOX_MAX]Ui_Id,
	box_free_count:  int,
	// Order of boxes, from bottom to top: the tree walked parents first, computed in ui_end
	box_order:       [UI_BOX_MAX]Ui_Id,
	box_order_count: int,
	// The box everything else is built under, and its two children: what the app builds, then what floats over it
	root:            Ui_Id,
	// This box contains all "ground layer" ui elements
	content:         Ui_Id,
	// This box contains all the overlay stuff, such as the tooltip
	overlay:         Ui_Id,
	viewport:        [2]f32,
	// Key -> Id hashmap
	key_hash_table:  Ui_Key_Hashtable,
	// Parent stack
	parent_stack:    [UI_DEPTH_MAX]Ui_Id,
	parent_depth:    int,
	// Style stack: the base style sits at the bottom, and each entry already includes the ones below it
	style_stack:     [UI_DEPTH_MAX]Ui_Style,
	style_depth:     int,
	// Overrides for the next box only
	style_next:      Ui_Style,
	// Font metrics, for em sizes
	sprites:         ^Sprites,
	// Where box texts are built, measured and drawn
	text:            ^Text_Ctx,
	// Global interaction state
	hot_box:         Ui_Key,
	// Owns the mouse from the press until the release, wherever the mouse goes
	active_box:      Ui_Key,
	// Only set for the frame the press happened or the release completed a click
	pressed:         Ui_Key,
	// Takes a press on a focusable box and keeps it until a press lands anywhere else
	focus_box:       Ui_Key,
	// The mouse as of the last ui_end, and where the press that made the active box happened
	mouse:           [2]f32,
	drag_start:      [2]f32,
	// Wheel movement in the last ui_end, in notches
	wheel:           [2]f32,
	// The last ui_end saw a left press, wherever it landed
	pressed_any:     bool,
	// The mouse was over a box that takes it in the last ui_end, disabled ones included
	hovered_any:     bool,
	// Saved by the widget being dragged, usually its value when the drag began
	drag_value:      [2]f32,
	// Animated values, kept alive by being asked for every frame
	anims:           [UI_ANIM_MAX]Ui_Anim,
	// Free stack of anims
	anim_free:       [UI_ANIM_MAX]Ui_Anim_Id,
	anim_free_count: int,
	// Key -> Anim id hashmap
	anim_hash_table: Ui_Anim_Hashtable,
}

// The short live id for the ui boxes. Dobules up as the index in the table
Ui_Id :: distinct u16

@(private = "file")
Ui_Key :: distinct u64

// The 0 key is meant for default
@(private = "file")
UI_KEY_NIL :: Ui_Key(0)

Ui_Size_Kind :: enum {
	None,
	Pixels,
	Text,
	Fit,
	Grow,
}

Ui_Size :: struct {
	kind:       Ui_Size_Kind,
	value:      f32,
	// Fraction of the size kept when the parent overflows: 1 never shrinks, 0 can shrink to nothing.
	strictness: f32,
}

Ui_Box_Flag :: enum {
	Background,
	Border,
	// Takes part in mouse hit testing; the box needs a key
	Clickable,
	// Fades the background toward hot_background and active_background while hovered and held
	Hot_Effects,
	// A press on the box gives it focus, drawn as a ring
	Focusable,
	// Gets no hover, press or focus, still blocks the mouse, and is drawn faded; inherited by children
	Disabled,
	// Children may overflow along the axis, and the wheel moves them through the box; the box needs a key
	Scroll_X,
	Scroll_Y,
	// Out of the flow: the parent neither sizes around the box nor places it; it sits at position from the parent's corner
	Floating,
}

// Distance moved per wheel notch, in multiples of the scrolled box's font size
UI_SCROLL_STEP :: 3

// A partial set of box fields. Nil fields leave whatever was set before them alone.
Ui_Style :: struct {
	width:             Maybe(Ui_Size),
	height:            Maybe(Ui_Size),
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
	font:              Maybe(Font_Id),
	text_color:        Maybe([4]f32),
	// Sets or clears Ui_Box_Flag.Disabled; a disabled parent still disables its children
	disabled:          Maybe(bool),
	// Where a floating box's top-left corner sits, from its parent's
	position:          Maybe([2]f32),
}

// A ui box. Keyed boxes keep their slot, and so their persistent fields, for as long as they are built every frame.
Ui_Box :: struct {
	// Per-build: reset in ui_begin when a box is kept, or overwritten by the style when it is built
	flags:             bit_set[Ui_Box_Flag],
	key:               Ui_Key,
	size:              [2]Ui_Size,
	child_axis:        Axis,
	// Space between the box edge and its children, applied on both sides of each axis
	padding:           [2]f32,
	// Space between consecutive children along the child axis
	gap:               f32,
	// Where a floating box's top-left corner sits, from its parent's
	position:          [2]f32,
	// Box tree hierarchy
	parent:            Ui_Id,
	child_first:       Ui_Id,
	child_last:        Ui_Id,
	sibling_next:      Ui_Id,
	// Style
	background:        [4]f32,
	hot_background:    [4]f32,
	active_background: [4]f32,
	border:            [4]f32,
	focus_border:      [4]f32,
	thickness:         f32,
	radius:            f32,
	// Text
	text:              Text_Id,
	font:              Font_Id,
	text_color:        [4]f32,
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

Ui_Signal :: struct {
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

// The mouse is over the ui, as of the last ui_end: whatever is drawn under it should ignore the mouse.
ui_hovered_any :: proc() -> bool {
	return UI.hovered_any
}

// Saves a value for the box being dragged, usually its value when the press happened.
ui_drag_store :: proc(value: [2]f32) {
	UI.drag_value = value
}

// The value saved with ui_drag_store.
ui_drag_stored :: proc() -> [2]f32 {
	return UI.drag_value
}

Axis :: enum {
	X,
	Y,
}

ui_px :: proc(value: f32, strictness: f32 = 1) -> Ui_Size {
	return {.Pixels, value, strictness}
}

// Pixels in multiples of the current font's size, resolved when called.
ui_em :: proc(value: f32, strictness: f32 = 1) -> Ui_Size {
	font := ui_style_top().font.? or_else Font_Id(0)
	return ui_px(value * f32(UI.sprites.fonts[font].size), strictness)
}

// The size of the box's text, plus its padding.
ui_text_dim :: proc(strictness: f32 = 1) -> Ui_Size {
	return {.Text, 0, strictness}
}

@(private = "file")
ui_seed :: proc() -> u64 {
	for i := UI.parent_depth - 1; i >= 0; i = i - 1 {
		parent := UI.parent_stack[i]
		key := UI.boxes[parent].key
		if key != UI_KEY_NIL {return u64(key)}
	}
	return 0
}

@(private = "file")
ui_key_from_string :: proc(str: string) -> Ui_Key {
	return ui_key_from_string_seeded(str, ui_seed())
}

// A key scoped under seed rather than under the nearest keyed parent
@(private = "file")
ui_key_from_string_seeded :: proc(str: string, seed: u64) -> Ui_Key {
	head, match, tail := strings.partition(str, "###")
	to_hash := tail
	if len(match) == 0 {
		to_hash = head
	}
	out: Ui_Key
	if len(to_hash) > 0 {
		h := hash.fnv64(transmute([]byte)to_hash, seed)
		if h == 0 {h = 1}
		out = Ui_Key(h)
	}
	return out
}

@(private = "file")
HASH_CAPACITY :: UI_BOX_MAX

// Key -> Id map with linear probing, rebuilt from scratch each frame so it never needs deletion
@(private = "file")
Ui_Hashtable :: struct($Id: typeid, $N: int) {
	keys: [N]Ui_Key,
	ids:  [N]Id,
}

@(private = "file")
Ui_Key_Hashtable :: Ui_Hashtable(Ui_Id, HASH_CAPACITY)

@(private = "file")
ui_hashtable_find :: proc(ht: ^Ui_Hashtable($Id, $N), needle: Ui_Key) -> Id {
	if needle == UI_KEY_NIL {return 0}
	// Probe
	idx := u64(needle) % len(ht.keys)
	for _ in 0 ..< len(ht.keys) {
		key := ht.keys[idx]
		// Key not found...
		if key == needle {return ht.ids[idx]}
		if key == UI_KEY_NIL {return 0}
		// Neither, keep going...
		idx = (idx + 1) % len(ht.keys)
	}
	return 0
}

@(private = "file")
ui_hashtable_save :: proc(ht: ^Ui_Hashtable($Id, $N), key: Ui_Key, id: Id) {
	assert(key != 0 && id != 0)
	idx := u64(key) % len(ht.keys)
	for _ in 0 ..< len(ht.keys) {
		key_current := ht.keys[idx]
		// No double inserts
		assert(key_current != key)
		if key_current == UI_KEY_NIL {
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
Ui_Anim_Id :: distinct u16

// A value easing toward its target a little every frame
@(private = "file")
Ui_Anim :: struct {
	key:     Ui_Key,
	current: f32,
	target:  f32,
	// Asked for this frame; anims nobody asks for are freed in the next ui_begin
	touched: bool,
}

@(private = "file")
ANIM_HASH_CAPACITY :: UI_ANIM_MAX

@(private = "file")
Ui_Anim_Hashtable :: Ui_Hashtable(Ui_Anim_Id, ANIM_HASH_CAPACITY)

// A value stored under label (scoped like box keys) that eases toward target every frame.
// It starts at initial the first frame it is asked for, and is forgotten once a frame passes without asking.
ui_anim :: proc(label: string, target: f32, initial: f32 = 0) -> f32 {
	key := ui_key_from_string(label)
	assert(key != UI_KEY_NIL, "animated values need a non-empty label")
	id := ui_hashtable_find(&UI.anim_hash_table, key)
	if id == 0 {
		assert(UI.anim_free_count > 0)
		id = UI.anim_free[UI.anim_free_count - 1]
		UI.anim_free_count -= 1
		ui_hashtable_save(&UI.anim_hash_table, key, id)
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
ui_box_alloc :: proc(key: Ui_Key) -> Ui_Id {
	// A nil key gets a fresh value
	id := ui_hashtable_find(&UI.key_hash_table, key)
	if id == 0 {
		assert(UI.box_free_count > 0)
		id = UI.box_free[UI.box_free_count - 1]
		UI.box_free_count -= 1

		// If we have a non-nil key, register
		if key != UI_KEY_NIL {
			ui_hashtable_save(&UI.key_hash_table, key, id)
		}
	}

	box := &UI.boxes[id]
	// No wrongful assingment of keys
	assert(box.key == UI_KEY_NIL)
	box.key = key
	return id
}

// Gives the box a text in its font and color, showing the label up to any "##".
@(private = "file")
ui_box_text :: proc(box: ^Ui_Box, label: string) {
	head, _, _ := strings.partition(label, "##")
	box.text = text_from_string(UI.text, head, box.font, box.text_color)
}

ui_init :: proc(sprites: ^Sprites, text: ^Text_Ctx) {
	UI = {}
	UI.sprites = sprites
	UI.text = text
}

ui_begin :: proc(viewport: [2]f32) {
	UI.key_hash_table = {}

	UI.box_free_count = 0

	UI.parent_stack = {}
	UI.parent_depth = 0

	UI.style_depth = 0
	UI.style_next = {}

	// Keyed boxes built last frame keep their slot and are ready to be built again; the rest are freed.
	UI.boxes[0] = {}
	for i in 1 ..< UI_BOX_MAX {
		box := &UI.boxes[i]
		if box.key != UI_KEY_NIL {
			ui_hashtable_save(&UI.key_hash_table, box.key, Ui_Id(i))
			box.key = {}
			box.flags = {}
			box.parent, box.child_first, box.child_last, box.sibling_next = 0, 0, 0, 0
			box.child_axis = {}
			box.text = {}
		} else {
			box^ = {}
			UI.box_free[UI.box_free_count] = Ui_Id(i)
			UI.box_free_count += 1
		}
	}

	// Anims asked for last frame survive; the rest go back on the free stack.
	UI.anim_hash_table = {}
	UI.anim_free_count = 0
	for i in 1 ..< UI_ANIM_MAX {
		anim := &UI.anims[i]
		if anim.key != UI_KEY_NIL && anim.touched {
			ui_hashtable_save(&UI.anim_hash_table, anim.key, Ui_Anim_Id(i))
			anim.touched = false
		} else {
			anim^ = {}
			UI.anim_free[UI.anim_free_count] = Ui_Anim_Id(i)
			UI.anim_free_count += 1
		}
	}

	// Popped in ui_end
	ui_style_push(ui_style_base())

	// The content is attached before the overlay, so everything floating over it comes later in box_order.
	UI.viewport = viewport
	viewport_size := Ui_Style {
		width  = ui_px(viewport.x),
		height = ui_px(viewport.y),
	}
	UI.root, _ = ui_box_make({}, viewport_size)
	ui_parent_push(UI.root)
	UI.content, _ = ui_box_make({}, {width = ui_grow(), height = ui_grow()})
	UI.overlay, _ = ui_box_make({}, viewport_size)
	UI.boxes[UI.overlay].flags += {.Floating}
	ui_parent_push(UI.content)
}

ui_end :: proc(input: Input, draw_ctx: ^Draw_Ctx, dt: f32) {
	// Pop the content, the root and the base style
	ui_parent_pop()
	ui_parent_pop()
	ui_style_pop()

	assert(UI.parent_depth == 0)
	assert(UI.style_depth == 0)

	ui_compute_box_order()

	ui_layout()

	ui_update_interaction(input)

	// Ease the persistent state of every box built this frame
	for &box in UI.boxes {
		key := box.key
		if key == {} {continue}
		rate := 1 - math.exp(-16 * dt)
		box.hot_t += ((key == UI.hot_box ? 1 : 0) - box.hot_t) * rate
		box.active_t += ((key == UI.active_box ? 1 : 0) - box.active_t) * rate
		box.focus_t += ((key == UI.focus_box ? 1 : 0) - box.focus_t) * rate
		disabled := .Disabled in box.flags
		box.disabled_t += ((disabled ? 1 : 0) - box.disabled_t) * rate

		// Scrolling stops at the ends of the content, and axes that do not scroll return to the start.
		for axis in Axis {
			limit: f32
			if ui_scroll_flag(axis) in box.flags {
				limit = max(0, box.content_size[axis] - box.size_computed[axis])
			}
			box.scroll_target[axis] = clamp(box.scroll_target[axis], 0, limit)
		}
		box.scroll += (box.scroll_target - box.scroll) * rate
	}

	// Ease every live anim toward its target
	for &anim in UI.anims {
		if anim.key == UI_KEY_NIL {continue}
		rate := 1 - math.exp(-16 * dt)
		anim.current += (anim.target - anim.current) * rate
	}

	ui_draw(draw_ctx)
}

@(private = "file")
ui_update_interaction :: proc(input: Input) {
	// A box that disappeared or became disabled can no longer be released or lose focus, so let go of it.
	active_seen, focus_seen: bool
	for i := 0; i < UI.box_order_count; i += 1 {
		box := &UI.boxes[UI.box_order[i]]
		if box.key == UI_KEY_NIL || .Disabled in box.flags {continue}
		active_seen |= box.key == UI.active_box
		focus_seen |= box.key == UI.focus_box
	}
	if !active_seen {
		UI.active_box = {}
	}
	if !focus_seen {
		UI.focus_box = {}
	}

	mouse_pos := input.pos
	UI.mouse = mouse_pos
	UI.wheel = input.wheel
	UI.hot_box = {}
	UI.hovered_any = false
	hot_focusable := false
	// With the mouse outside the window, nothing is under it.
	for i := UI.box_order_count; i > 0 && input.pos_is_valid; i -= 1 {
		box := &UI.boxes[UI.box_order[i - 1]]
		if .Clickable not_in box.flags {continue}
		assert(box.key != UI_KEY_NIL, "clickable boxes need a key to receive signals")
		if rect_contains(box.clip, mouse_pos) {
			UI.hovered_any = true
			// A disabled box stops the search without becoming hot, so the mouse reaches nothing.
			if .Disabled not_in box.flags {
				UI.hot_box = box.key
				hot_focusable = .Focusable in box.flags
			}
			break
		}
	}

	// The wheel moves the nearest box under the mouse that scrolls along each axis.
	if input.wheel != {} {
		// Only boxes that take the mouse or scroll count; the rest, like the overlay, let it through.
		under: Ui_Id
		for i := UI.box_order_count; i > 0; i -= 1 {
			id := UI.box_order[i - 1]
			box := &UI.boxes[id]
			if .Clickable not_in box.flags && box.flags & {.Scroll_X, .Scroll_Y} == {} {continue}
			if rect_contains(box.clip, mouse_pos) {
				under = id
				break
			}
		}
		for axis in Axis {
			if input.wheel[axis] == 0 {continue}
			for id := under; id != 0; id = UI.boxes[id].parent {
				box := &UI.boxes[id]
				if ui_scroll_flag(axis) in box.flags {
					box.scroll_target[axis] += ui_scroll_from_wheel(box, input.wheel)[axis]
					break
				}
			}
		}
	}

	left_pressed := input.btns[.New][.Pressed][sdl3.BUTTON_LEFT]
	left_released :=
		input.btns[.Old][.Down][sdl3.BUTTON_LEFT] && !input.btns[.New][.Down][sdl3.BUTTON_LEFT]
	UI.pressed_any = bool(left_pressed)

	UI.pressed = {}
	if UI.active_box != UI_KEY_NIL {
		// While something is held, nothing else reacts to the mouse.
		if UI.hot_box != UI.active_box {
			UI.hot_box = {}
		}
		if left_released {
			UI.active_box = {}
		}
	} else if left_pressed && UI.hot_box != UI_KEY_NIL {
		UI.active_box = UI.hot_box
		UI.pressed = UI.hot_box
		UI.drag_start = mouse_pos
	}

	// Any press moves focus: to the pressed box if it takes focus, otherwise away.
	if left_pressed {
		UI.focus_box = UI.hot_box if hot_focusable else {}
	}

}

// Fills box_order by walking the tree from the root, parents before children.
@(private = "file")
ui_compute_box_order :: proc() {
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
ui_box_make :: proc(key: Ui_Key, forced: Ui_Style) -> (Ui_Id, Ui_Signal) {
	id := ui_box_alloc(key)
	parent := ui_parent_top()
	UI.boxes[id].parent = parent

	// Later layers win: the stack (base style and pushes), then the caller's next, then what the widget forces.
	ui_style_apply(&UI.boxes[id], ui_style_top())
	ui_style_apply(&UI.boxes[id], UI.style_next)
	ui_style_apply(&UI.boxes[id], forced)
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

	// Unkeyed boxes cannot be told apart between frames, so they never get a signal.
	signal: Ui_Signal
	if key != UI_KEY_NIL {
		signal.hovered = UI.hot_box == key
		signal.pressed = UI.pressed == key
		signal.held = UI.active_box == key
		signal.focused = UI.focus_box == key
		if signal.held {
			signal.drag = UI.mouse - UI.drag_start
		}
		if signal.hovered {
			signal.wheel = UI.wheel
		}
	}
	return id, signal
}

@(private = "file")
ui_parent_push :: proc(id: Ui_Id) {
	assert(UI.parent_depth < UI_DEPTH_MAX)
	UI.parent_stack[UI.parent_depth] = id
	UI.parent_depth += 1
}

@(private = "file")
ui_parent_pop :: proc() {
	assert(UI.parent_depth > 0)
	UI.parent_depth -= 1
	UI.parent_stack[UI.parent_depth] = {}
}

@(private = "file")
ui_parent_top :: proc() -> Ui_Id {
	out: Ui_Id
	if UI.parent_depth > 0 {
		out = UI.parent_stack[UI.parent_depth - 1]
	}
	return out
}

// Overrides every box made until the matching pop.
ui_style_push :: proc(override: Ui_Style) {
	assert(UI.style_depth < UI_DEPTH_MAX)
	top := ui_style_top()
	ui_style_merge(&top, override)
	UI.style_stack[UI.style_depth] = top
	UI.style_depth += 1
}

ui_style_pop :: proc() {
	assert(UI.style_depth > 0)
	UI.style_depth -= 1
}

// Overrides only the next box made; repeated calls accumulate. Widgets route their style parameter through here.
ui_style_next :: proc(override: Ui_Style) {
	ui_style_merge(&UI.style_next, override)
}

@(private = "file")
ui_style_top :: proc() -> Ui_Style {
	out: Ui_Style
	if UI.style_depth > 0 {
		out = UI.style_stack[UI.style_depth - 1]
	}
	return out
}

@(private = "file")
ui_style_merge :: proc(dst: ^Ui_Style, src: Ui_Style) {
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
	if src.disabled != nil {dst.disabled = src.disabled}
	if src.position != nil {dst.position = src.position}
}

@(private = "file")
ui_style_apply :: proc(dst: ^Ui_Box, src: Ui_Style) {
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
	if v, ok := src.disabled.?; ok {
		if v {dst.flags += {.Disabled}} else {dst.flags -= {.Disabled}}
	}
	if v, ok := src.position.?; ok {dst.position = v}
}

@(private = "file")
ui_layout :: proc() {
	ui_compute_independent_sizes()

	ui_compute_dependent_sizes(.X)

	// Text breaks into lines at its box's final width, and boxes sized by their text take its height.
	for i := 0; i < UI.box_order_count; i += 1 {
		box := &UI.boxes[UI.box_order[i]]
		if box.text == 0 || box.size.y.kind != .Text {continue}
		box.size_computed.y =
			text_measure(UI.text, box.text, ui_text_row_width(box)).y + 2 * box.padding.y
	}

	ui_compute_dependent_sizes(.Y)

	// Placement. The root has no parent to clip it, so it sees all of itself.
	root := &UI.boxes[UI.box_order[0]]
	root.clip = rect_from_pos_size(root.pos_computed, root.size_computed)
	for i := 0; i < UI.box_order_count; i += 1 {
		parent := &UI.boxes[UI.box_order[i]]
		axis := parent.child_axis
		cross := ui_axis_flip(axis)
		assert(
			parent.key != UI_KEY_NIL || parent.flags & {.Scroll_X, .Scroll_Y} == {},
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

@(private = "file")
rect_intersect :: proc(r1: [4]f32, r2: [4]f32) -> [4]f32 {
	lo := [2]f32{max(r1.x, r2.x), max(r1.y, r2.y)}
	hi := [2]f32{min(r1.x + r1.z, r2.x + r2.z), min(r1.y + r1.w, r2.y + r2.w)}
	return {lo.x, lo.y, max(hi.x - lo.x, 0), max(hi.y - lo.y, 0)}
}

@(private = "file")
rect_contains :: proc(rect: [4]f32, pt: [2]f32) -> bool {
	return pt.x >= rect.x && pt.y >= rect.y && pt.x < rect.x + rect.z && pt.y < rect.y + rect.w
}

rect_from_pos_size :: proc(pos: [2]f32, size: [2]f32) -> [4]f32 {
	return {pos.x, pos.y, size.x, size.y}
}

// How far the wheel moves a scrolling box's content, in pixels.
@(private = "file")
ui_scroll_from_wheel :: proc(box: ^Ui_Box, wheel: [2]f32) -> [2]f32 {
	em := f32(UI.sprites.fonts[box.font].size)
	// Turning the wheel away from the user reveals what is above.
	return [2]f32{wheel.x, -wheel.y} * UI_SCROLL_STEP * em
}

// The flag that makes a box scroll along the axis
@(private = "file")
ui_scroll_flag :: proc(axis: Axis) -> Ui_Box_Flag {
	out: Ui_Box_Flag
	switch axis {
	case .X:
		out = .Scroll_X
	case .Y:
		out = .Scroll_Y
	}
	return out
}

// The width a box's text breaks its lines at: the box's, inside the padding.
@(private = "file")
ui_text_row_width :: proc(box: ^Ui_Box) -> f32 {
	return max(0, box.size_computed.x - 2 * box.padding.x)
}

@(private = "file")
ui_axis_flip :: proc(axis: Axis) -> Axis {
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
ui_compute_independent_sizes :: proc() {
	for &box in UI.boxes {
		size := box.size
		value: [2]f32

		for axis in Axis {
			#partial switch size[axis].kind {
			case .Pixels:
				value[axis] = size[axis].value
			case .Text:
				// On one line; a narrower final width wraps it and recomputes the height.
				value[axis] = text_measure(UI.text, box.text, 0)[axis] + 2 * box.padding[axis]
			}
		}

		box.size_computed = value
	}
}

@(private = "file")
ui_compute_dependent_sizes :: proc(axis: Axis) {
	// Backwards pass: fit
	for i := UI.box_order_count; i > 0; i = i - 1 {
		box := &UI.boxes[UI.box_order[i - 1]]
		size := box.size[axis]

		value := box.size_computed[axis]

		#partial switch size.kind {
		case .Fit, .Grow:
			value = 0
			count := 0
			for child := box.child_first; child != 0; child = UI.boxes[child].sibling_next {
				if .Floating in UI.boxes[child].flags {continue}
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
		scrolls := ui_scroll_flag(axis) in parent.flags

		if axis != parent.child_axis {
			// Cross-axis children each have the parent's full extent available, and no more.
			for kid := parent.child_first; kid != 0; kid = UI.boxes[kid].sibling_next {
				child := &UI.boxes[kid]
				if .Floating in child.flags {continue}
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
		for kid := parent.child_first; kid != 0; kid = UI.boxes[kid].sibling_next {
			child := &UI.boxes[kid]
			if .Floating in child.flags {continue}
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
			for kid := parent.child_first; kid != 0; kid = UI.boxes[kid].sibling_next {
				child := &UI.boxes[kid]
				if .Floating in child.flags {continue}
				size := child.size[axis]
				if size.kind == .Grow && size.value > 0 {
					child.size_computed[axis] += remaining * (size.value / total_weight)
				}
			}
		} else if remaining < 0 && !scrolls {
			// Overflow is taken from each child in proportion to the size it is willing to give up.
			budget: f32
			for kid := parent.child_first; kid != 0; kid = UI.boxes[kid].sibling_next {
				child := &UI.boxes[kid]
				if .Floating in child.flags {continue}
				budget += child.size_computed[axis] * (1 - child.size[axis].strictness)
			}
			if budget > 0 {
				fraction := min(1, -remaining / budget)
				for kid := parent.child_first; kid != 0; kid = UI.boxes[kid].sibling_next {
					child := &UI.boxes[kid]
					if .Floating in child.flags {continue}
					give := child.size_computed[axis] * (1 - child.size[axis].strictness)
					child.size_computed[axis] -= give * fraction
				}
			}
		}
	}
}

@(private = "file")
ui_draw :: proc(ctx: ^Draw_Ctx) {
	for i := 0; i < UI.box_order_count; i += 1 {
		id := UI.box_order[i]
		box := &UI.boxes[id]
		bounds: [4]f32 = {
			box.pos_computed.x,
			box.pos_computed.y,
			box.size_computed.x,
			box.size_computed.y,
		}

		SOFTNESS :: 0.8

		// Unkeyed boxes are new every frame and cannot animate, so they fade fully at once.
		disabled_t := box.disabled_t
		if box.key == UI_KEY_NIL {
			disabled_t = 1 if .Disabled in box.flags else 0
		}
		alpha := 1 - 0.5 * disabled_t

		draw_clip_push(ctx, box.clip)
		defer draw_clip_pop(ctx)

		if Ui_Box_Flag.Background in box.flags {
			background := box.background
			if .Hot_Effects in box.flags {
				background += (box.hot_background - background) * box.hot_t
				background += (box.active_background - background) * box.active_t
			}
			background.a *= alpha
			draw_rectangle(ctx, bounds, background, box.radius, 0, SOFTNESS)
		}
		if Ui_Box_Flag.Border in box.flags && box.thickness > 0 {
			border := box.border
			border.a *= alpha
			draw_rectangle(ctx, bounds, border, box.radius, box.thickness, SOFTNESS)
		}
		if box.text != 0 {
			width := ui_text_row_width(box)
			size := text_measure(UI.text, box.text, width)
			// Left-aligned after the padding, centered vertically; never starts before the box.
			pos := box.pos_computed
			pos.x += box.padding.x
			pos.y += max(0, box.size_computed.y - size.y) / 2
			text_draw(UI.text, ctx, box.text, pos, width, {1, 1, 1, alpha})
		}
		if .Focusable in box.flags {
			focus_t := box.focus_t
			if focus_t > 0.001 {
				color := box.focus_border
				color.a *= focus_t * alpha
				draw_rectangle(ctx, bounds, color, box.radius, 2, SOFTNESS)
			}
		}
	}
}

/// Widgets ///

ui_fit :: proc(strictness: f32 = 1) -> Ui_Size {
	return {.Fit, 0, strictness}
}

ui_grow :: proc(weight: f32 = 1, strictness: f32 = 0) -> Ui_Size {
	return {.Grow, weight, strictness}
}

UI_PANEL_BACKGROUND :: [4]f32{0.93, 0.89, 0.80, 1}
UI_PANEL_BORDER :: [4]f32{0.36, 0.24, 0.16, 1}
UI_LABEL_COLOR :: [4]f32{0.20, 0.13, 0.09, 1}
UI_HOT_BACKGROUND :: [4]f32{0.87, 0.81, 0.69, 1}
UI_ACTIVE_BACKGROUND :: [4]f32{0.80, 0.72, 0.58, 1}
UI_FOCUS_BORDER :: [4]f32{0.72, 0.50, 0.20, 1}
// The checkbox square and the space between it and its label
UI_CHECK_SIZE :: 18
UI_CHECK_GAP :: 8
// Where a tooltip sits from the mouse
UI_TOOLTIP_OFFSET :: [2]f32{16, 16}
// The thickness of a scrollbar
UI_SCROLLBAR_SIZE :: 8
// The label of the box a scroll panel's children scroll in
@(private = "file")
UI_SCROLL_PANE :: "scroll pane"

// The look of every box unless pushed or overridden: pushed at the bottom of the stack in ui_begin.
@(private = "file")
ui_style_base :: proc() -> Ui_Style {
	font := Font_Id(0)
	em := f32(UI.sprites.fonts[font].size)
	return {
		width = ui_px(10 * em),
		height = ui_px(1.5 * em),
		padding = [2]f32{0, 0},
		gap = 0,
		background = UI_PANEL_BACKGROUND,
		hot_background = UI_HOT_BACKGROUND,
		active_background = UI_ACTIVE_BACKGROUND,
		border = UI_PANEL_BORDER,
		focus_border = UI_FOCUS_BORDER,
		thickness = 1,
		radius = 4,
		font = font,
		text_color = UI_LABEL_COLOR,
		position = [2]f32{0, 0},
	}
}

// Closes a container opened by a widget, at the end of the caller's scope.
@(private = "file")
ui_container_end :: proc(open: bool) {
	if open {
		ui_parent_pop()
	}
}

@(private = "file")
ui_container_begin :: proc(
	label: string,
	child_axis: Axis,
	style: Ui_Style,
) -> (
	^Ui_Box,
	Ui_Signal,
) {
	ui_style_next(style)
	id, signal := ui_box_make(ui_key_from_string(label), {})
	box := &UI.boxes[id]
	box.child_axis = child_axis
	ui_parent_push(id)
	return box, signal
}

// Children left to right.
@(deferred_out = ui_container_end)
ui_row :: proc(style := Ui_Style{}) -> bool {
	ui_container_begin("", .X, style)
	return true
}

// Children top to bottom.
@(deferred_out = ui_container_end)
ui_column :: proc(style := Ui_Style{}) -> bool {
	ui_container_begin("", .Y, style)
	return true
}

// A container that draws its background and border, and catches the mouse over it.
@(deferred_out = ui_container_end)
ui_panel :: proc(label: string, style := Ui_Style{}, child_axis := Axis.Y) -> bool {
	box, _ := ui_container_begin(label, child_axis, style)
	box.flags += {.Background, .Border, .Clickable}
	return true
}

// A panel whose children scroll along its child axis when they do not fit, with a scrollbar beside them.
// The style goes to the panel; its children sit in a pane that fills it, next to the bar.
@(deferred_out = ui_scroll_panel_end)
ui_scroll_panel :: proc(label: string, style := Ui_Style{}, child_axis := Axis.Y) -> bool {
	panel, _ := ui_container_begin(label, ui_axis_flip(child_axis), style)
	panel.flags += {.Background, .Border, .Clickable}
	pane, _ := ui_box_make(
		ui_key_from_string(UI_SCROLL_PANE),
		{width = ui_grow(), height = ui_grow(), padding = [2]f32{0, 0}, gap = panel.gap},
	)
	UI.boxes[pane].flags += {ui_scroll_flag(child_axis)}
	UI.boxes[pane].child_axis = child_axis
	ui_parent_push(pane)
	return true
}

// Closes the pane, adds the bar after the caller's children, then closes the panel.
@(private = "file")
ui_scroll_panel_end :: proc(open: bool) {
	if open {
		axis := UI.boxes[ui_parent_top()].child_axis
		ui_parent_pop()
		ui_scrollbar(UI_SCROLL_PANE, axis)
		ui_parent_pop()
	}
}

// Shows which part of a pane's content is in view along axis, from the pane's layout last frame; dragging the thumb scrolls it.
// The pane is found by its label, so it must have been made under the same parent.
ui_scrollbar :: proc(pane_label: string, axis: Axis, style := Ui_Style{}) {
	pane_key := ui_key_from_string(pane_label)
	pane_id := ui_hashtable_find(&UI.key_hash_table, pane_key)
	pane := &UI.boxes[pane_id]
	view := pane.size_computed[axis]
	content := max(pane.content_size[axis], view)
	offset := pane.scroll[axis]

	// Grow weights split the track in proportion: the space before, the thumb, the space after.
	track_style, thumb_style: Ui_Style
	switch axis {
	case .X:
		track_style = {
			width  = ui_grow(),
			height = ui_px(UI_SCROLLBAR_SIZE),
		}
		thumb_style = {
			width  = ui_grow(view),
			height = ui_grow(),
		}
	case .Y:
		track_style = {
			width  = ui_px(UI_SCROLLBAR_SIZE),
			height = ui_grow(),
		}
		thumb_style = {
			width  = ui_grow(),
			height = ui_grow(view),
		}
	}
	// Keyed under the pane, so every pane's bar has its own.
	ui_style_next(style)
	track, track_signal := ui_box_make(
		ui_key_from_string_seeded("scrollbar", u64(pane_key)),
		track_style,
	)
	UI.boxes[track].flags += {.Background, .Clickable}
	UI.boxes[track].child_axis = axis
	thumb_color := UI.boxes[track].border
	// Pixels of content per pixel of track, as laid out last frame
	ratio := content / max(1, UI.boxes[track].size_computed[axis])

	ui_parent_push(track)
	defer ui_parent_pop()
	ui_spacer(ui_grow(offset))
	thumb_style.background = thumb_color
	thumb, thumb_signal := ui_box_make(ui_key_from_string("thumb"), thumb_style)
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
		pane.scroll_target[axis] += ui_scroll_from_wheel(pane, wheel)[axis]
	}
}

// A column floating over everything near the mouse, kept inside the window. Build it while its anchor is hovered.
@(deferred_out = ui_tooltip_end)
ui_tooltip :: proc(style := Ui_Style{}) -> bool {
	ui_parent_push(UI.overlay)
	key := ui_key_from_string("tooltip")
	// Last frame's size decides whether it fits to the right of and below the mouse.
	size := UI.boxes[ui_hashtable_find(&UI.key_hash_table, key)].size_computed
	position := UI.mouse + UI_TOOLTIP_OFFSET
	flipped := UI.mouse - UI_TOOLTIP_OFFSET - size
	for axis in Axis {
		if position[axis] + size[axis] > UI.viewport[axis] {
			position[axis] = flipped[axis]
		}
		position[axis] = max(0, position[axis])
	}
	ui_style_next(style)
	id, _ := ui_box_make(key, {position = position})
	box := &UI.boxes[id]
	box.flags += {.Floating, .Background, .Border}
	box.child_axis = .Y
	ui_parent_push(id)
	return true
}

@(private = "file")
ui_tooltip_end :: proc(open: bool) {
	if open {
		// Ends the tooltip
		ui_parent_pop()
		// And ends the UI.overlay scope
		ui_parent_pop()
	}
}

// Empty space along the parent's child axis, and none across it.
ui_spacer :: proc(size: Ui_Size) {
	forced: Ui_Style
	switch UI.boxes[ui_parent_top()].child_axis {
	case .X:
		forced.width = size
		forced.height = ui_px(0)
	case .Y:
		forced.width = ui_px(0)
		forced.height = size
	}
	ui_box_make({}, forced)
}

// A line of text. Anything from "##" on is not shown.
ui_label :: proc(text: string, style := Ui_Style{}) -> Ui_Signal {
	ui_style_next(style)
	id, signal := ui_box_make({}, {})
	box := &UI.boxes[id]
	ui_box_text(box, text)
	return signal
}

// A clickable box with a label. The label is also the key: use "###" to keep the key stable when the text changes.
ui_button :: proc(label: string, style := Ui_Style{}) -> Ui_Signal {
	ui_style_next(style)
	id, signal := ui_box_make(ui_key_from_string(label), {})
	box := &UI.boxes[id]
	box.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	ui_box_text(box, label)
	return signal
}

// A button showing the selected choice; pressing it opens the choices under it, floating over everything.
// Picking one selects it, and any press closes the list. The label is only the key; choices must differ.
ui_combo :: proc(
	label: string,
	selection: ^int,
	open: ^bool,
	choices: []string,
	style := Ui_Style{},
) -> Ui_Signal {
	ui_style_next(style)
	key := ui_key_from_string(label)
	id, signal := ui_box_make(key, {})
	button := &UI.boxes[id]
	button.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	if selection^ >= 0 && selection^ < len(choices) {
		ui_box_text(button, choices[selection^])
	}
	if signal.pressed {
		open^ = !open^
	}

	if open^ {
		// Right under the button and as wide, from its layout last frame
		ui_parent_push(UI.overlay)
		list, _ := ui_box_make(
			ui_key_from_string_seeded("choices", u64(key)),
			{
				position = button.pos_computed + {0, button.size_computed.y},
				width = ui_px(button.size_computed.x),
				height = ui_fit(),
			},
		)
		UI.boxes[list].flags += {.Floating, .Background, .Border, .Clickable}
		UI.boxes[list].child_axis = .Y
		ui_parent_push(list)
		for choice, i in choices {
			// Laid out like the button, across the list
			if ui_button(choice, {width = ui_grow(), padding = button.padding}).pressed {
				selection^ = i
			}
		}
		ui_parent_pop()
		ui_parent_pop()

		// Built first, so a press on a choice was read before the list closes.
		if UI.pressed_any && !signal.pressed {
			open^ = false
		}
	}
	return signal
}

// A clickable row holding a check square and a label, all plain boxes. Flips value when pressed.
ui_checkbox :: proc(label: string, value: ^bool, style := Ui_Style{}) -> Ui_Signal {
	ui_style_next(style)
	id, signal := ui_box_make(ui_key_from_string(label), {})
	if signal.pressed {
		value^ = !value^
	}
	row := &UI.boxes[id]
	row.flags += {.Background, .Border, .Clickable, .Hot_Effects, .Focusable}
	row.child_axis = .X
	// The parts take their look from the row, so a style passed to the checkbox reaches them too.
	ink, mark_color, font := row.text_color, row.focus_border, row.font

	ui_parent_push(id)
	defer ui_parent_pop()

	// Keyed under the row, so every checkbox has its own.
	checked := f32(1) if value^ else 0
	checked_t := ui_anim("checked", checked, checked)

	// Spacers above and below center the square in the row's height.
	column, _ := ui_box_make(
		{},
		{width = ui_fit(), height = ui_grow(), padding = [2]f32{0, 0}, gap = 0},
	)
	UI.boxes[column].child_axis = .Y
	ui_parent_push(column)
	ui_spacer(ui_grow())
	square, _ := ui_box_make(
		{},
		{
			width = ui_px(UI_CHECK_SIZE),
			height = ui_px(UI_CHECK_SIZE),
			padding = [2]f32{4, 4},
			border = ink,
			thickness = 1,
			radius = 3,
		},
	)
	UI.boxes[square].flags += {.Border}
	if checked_t > 0.001 {
		mark_color.a *= checked_t
		ui_parent_push(square)
		mark, _ := ui_box_make(
			{},
			{width = ui_grow(), height = ui_grow(), background = mark_color, radius = 2},
		)
		UI.boxes[mark].flags += {.Background}
		ui_parent_pop()
	}
	ui_spacer(ui_grow())
	ui_parent_pop()

	ui_spacer(ui_px(UI_CHECK_GAP))

	text, _ := ui_box_make(
		{},
		{
			width = ui_text_dim(),
			height = ui_grow(),
			padding = [2]f32{0, 0},
			font = font,
			text_color = ink,
		},
	)
	ui_box_text(&UI.boxes[text], label)
	return signal
}

