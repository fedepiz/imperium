package tweak

import "core:hash"
import "core:strings"

import "../span"

// Immediate-mode tweakables: declare every frame, passing the value in and getting it (possibly edited) back.
// Label: shown up to "##". Key: the whole label, or the part after "###" if present.

TWEAK_MAX :: 1024
SHOWN_MAX :: 1024
// Per-frame storage for labels and choice names
BLOB_SIZE :: 1 << 16
NAMES_MAX :: 4096

@(private = "file")
HASH_CAPACITY :: 2 * TWEAK_MAX

Kind :: enum {
	Label,
	Button,
	Toggle,
	Slider,
	Choice,
}

// 0 = none
Id :: distinct u16

// Persists for the whole run once declared
Tweak :: struct {
	key:       u64,
	kind:      Kind,
	// Changed since last declaration
	edited:    bool,
	// Toggle
	flag:      bool,
	// Slider
	value:     f32,
	// Choice
	selection: int,
}

Shown :: struct {
	kind:    Kind,
	id:      Id,
	// In the blob
	label:   span.Span,
	// Label: shown text. Button/Toggle: widget text. In the blob.
	text:    span.Span,
	// Slider
	lo:      f32,
	hi:      f32,
	// Choice: in the names
	choices: span.Span,
}

@(private = "file")
TWEAKS: struct {
	// Id 0 is kept empty
	tweaks:    [dynamic; TWEAK_MAX]Tweak,
	// Key -> Id, linear probing
	keys:      [HASH_CAPACITY]u64,
	ids:       [HASH_CAPACITY]Id,
	// This frame's declarations, in order
	shown:     [dynamic; SHOWN_MAX]Shown,
	blob:      [dynamic; BLOB_SIZE]u8,
	names:     [dynamic; NAMES_MAX]span.Span,
	// Fired last frame; button() returns true for it this frame
	fired:     Id,
	fire_next: Id,
	open:      bool,
}

begin :: proc() {
	if len(TWEAKS.tweaks) == 0 {
		append(&TWEAKS.tweaks, Tweak{})
	}
	clear(&TWEAKS.shown)
	clear(&TWEAKS.blob)
	clear(&TWEAKS.names)
	TWEAKS.fired = TWEAKS.fire_next
	TWEAKS.fire_next = 0
}

is_open :: proc() -> bool {
	return TWEAKS.open
}

set_open :: proc(open: bool) {
	TWEAKS.open = open
}

// Read-only text
label :: proc(label, text: string) {
	id, _ := declare(label, .Label)
	show({kind = .Label, id = id, label = store(label), text = store(text)})
}

// True the frame after fire()
button :: proc(label, text: string) -> bool {
	id, _ := declare(label, .Button)
	show({kind = .Button, id = id, label = store(label), text = store(text)})
	return id == TWEAKS.fired
}

// By value, or by pointer (written back immediately)
toggle :: proc {
	toggle_value,
	toggle_in_place,
}
slider :: proc {
	slider_value,
	slider_in_place,
}
choice :: proc {
	choice_value,
	choice_in_place,
}

toggle_value :: proc(label, text: string, flag: bool) -> bool {
	id, t := declare(label, .Toggle)
	if !t.edited {
		t.flag = flag
	}
	t.edited = false
	show({kind = .Toggle, id = id, label = store(label), text = store(text)})
	return t.flag
}

toggle_in_place :: proc(label, text: string, flag: ^bool) {
	flag^ = toggle_value(label, text, flag^)
}

slider_value :: proc(label: string, value, lo, hi: f32) -> f32 {
	id, t := declare(label, .Slider)
	if !t.edited {
		t.value = value
	}
	t.edited = false
	t.value = clamp(t.value, lo, hi)
	show({kind = .Slider, id = id, label = store(label), lo = lo, hi = hi})
	return t.value
}

slider_in_place :: proc(label: string, value: ^f32, lo, hi: f32) {
	value^ = slider_value(label, value^, lo, hi)
}

choice_value :: proc(label: string, selection: int, choices: []string) -> int {
	assert(len(choices) > 0, "a choice needs something to choose")
	id, t := declare(label, .Choice)
	if !t.edited {
		t.selection = selection
	}
	t.edited = false
	t.selection = clamp(t.selection, 0, len(choices) - 1)
	names_begin := len(TWEAKS.names)
	for name in choices {
		if len(TWEAKS.names) == NAMES_MAX {break}
		append(&TWEAKS.names, store(name))
	}
	names := span.from_range(names_begin, len(TWEAKS.names))
	show({kind = .Choice, id = id, label = store(label), choices = names})
	return t.selection
}

choice_in_place :: proc(label: string, selection: ^int, choices: []string) {
	selection^ = choice_value(label, selection^, choices)
}

shown :: proc() -> []Shown {
	return TWEAKS.shown[:]
}

shown_label :: proc(s: Shown) -> string {
	return span.to_string(TWEAKS.blob[:], s.label)
}

shown_text :: proc(s: Shown) -> string {
	return span.to_string(TWEAKS.blob[:], s.text)
}

shown_choice :: proc(s: Shown, i: int) -> string {
	return span.to_string(TWEAKS.blob[:], TWEAKS.names[s.choices.begin + i])
}

get :: proc(id: Id) -> Tweak {
	return TWEAKS.tweaks[id]
}

// Returned by the next declaration
set_flag :: proc(id: Id, flag: bool) {
	TWEAKS.tweaks[id].flag = flag
	TWEAKS.tweaks[id].edited = true
}

set_value :: proc(id: Id, value: f32) {
	TWEAKS.tweaks[id].value = value
	TWEAKS.tweaks[id].edited = true
}

set_selection :: proc(id: Id, selection: int) {
	TWEAKS.tweaks[id].selection = selection
	TWEAKS.tweaks[id].edited = true
}

fire :: proc(id: Id) {
	TWEAKS.fire_next = id
}

display :: proc(label: string) -> string {
	head, _, _ := strings.partition(label, "##")
	return head
}

// Truncates when full
@(private = "file")
store :: proc(text: string) -> span.Span {
	begin := len(TWEAKS.blob)
	n := min(len(text), BLOB_SIZE - begin)
	append(&TWEAKS.blob, ..transmute([]u8)text[:n])
	return span.from_range(begin, len(TWEAKS.blob))
}

// When full, further tweaks aren't shown but still work
@(private = "file")
show :: proc(s: Shown) {
	if len(TWEAKS.shown) < SHOWN_MAX {
		append(&TWEAKS.shown, s)
	}
}

// Created on first declaration
@(private = "file")
declare :: proc(label: string, kind: Kind) -> (id: Id, t: ^Tweak) {
	head, match, tail := strings.partition(label, "###")
	to_hash := tail if len(match) > 0 else head
	assert(len(to_hash) > 0, "tweaks need a non-empty label")
	key := hash.fnv64(transmute([]byte)to_hash)
	if key == 0 {key = 1}

	idx := key % HASH_CAPACITY
	for TWEAKS.keys[idx] != 0 && TWEAKS.keys[idx] != key {
		idx = (idx + 1) % HASH_CAPACITY
	}
	if TWEAKS.keys[idx] == 0 {
		assert(len(TWEAKS.tweaks) < TWEAK_MAX, "too many tweaks")
		TWEAKS.keys[idx] = key
		TWEAKS.ids[idx] = Id(len(TWEAKS.tweaks))
		append(&TWEAKS.tweaks, Tweak{key = key, kind = kind})
	}
	id = TWEAKS.ids[idx]
	t = &TWEAKS.tweaks[id]
	assert(t.kind == kind, "a label names one kind of tweak")
	return
}

