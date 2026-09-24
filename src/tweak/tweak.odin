package tweak

import "core:hash"
import "core:strings"

import "../span"

// Named values the game declares every frame, which a palette can show and change. Each declaration passes the
// value in and takes it back: the tweak keeps a copy, and a change made to the copy comes back from the next one.
// A label is shown up to any "##", and is also the key: from "###" on when there is one, so the shown text can change.

// Most tweaks ever declared, and declarations in one frame
TWEAK_MAX :: 1024
SHOWN_MAX :: 1024
// Room for one frame's labels and choice names, copied in as they are declared
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

// Where a tweak's value lives. Id 0 is none.
Id :: distinct u16

// A tweak's copy of its value, kept from the first frame it is declared on for as long as the game runs
Tweak :: struct {
	key:       u64,
	kind:      Kind,
	// The copy was changed since the last declaration, which returns it
	edited:    bool,
	// Toggle
	flag:      bool,
	// Slider
	value:     f32,
	// Choice
	selection: int,
}

// A declaration this frame: what to show, and the tweak it shows
Shown :: struct {
	kind:    Kind,
	id:      Id,
	// In the blob
	label:   span.Span,
	// Label: the text shown; Button and Toggle: the text on the widget. In the blob.
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
	// This frame's labels and choice names, and the spans of the names in the blob
	blob:      [dynamic; BLOB_SIZE]u8,
	names:     [dynamic; NAMES_MAX]span.Span,
	// The button fire named last frame, which button returns true for this frame
	fired:     Id,
	fire_next: Id,
	// The palette is showing
	open:      bool,
}

// Starts a frame: forgets the last frame's declarations, and makes the last fire this frame's.
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

// Text shown beside the label, which changes nothing.
label :: proc(label, text: string) {
	id, _ := declare(label, .Label)
	show({kind = .Label, id = id, label = store(label), text = store(text)})
}

// True the frame after fire named it.
button :: proc(label, text: string) -> bool {
	id, _ := declare(label, .Button)
	show({kind = .Button, id = id, label = store(label), text = store(text)})
	return id == TWEAKS.fired
}

// On or off.
toggle :: proc(label, text: string, flag: bool) -> bool {
	id, t := declare(label, .Toggle)
	if !t.edited {
		t.flag = flag
	}
	t.edited = false
	show({kind = .Toggle, id = id, label = store(label), text = store(text)})
	return t.flag
}

// A number between lo and hi.
slider :: proc(label: string, value, lo, hi: f32) -> f32 {
	id, t := declare(label, .Slider)
	if !t.edited {
		t.value = value
	}
	t.edited = false
	t.value = clamp(t.value, lo, hi)
	show({kind = .Slider, id = id, label = store(label), lo = lo, hi = hi})
	return t.value
}

// One of choices, by index.
choice :: proc(label: string, selection: int, choices: []string) -> int {
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

// This frame's declarations, in the order they came.
shown :: proc() -> []Shown {
	return TWEAKS.shown[:]
}

// A declaration's label, as declared.
shown_label :: proc(s: Shown) -> string {
	return span.to_string(TWEAKS.blob[:], s.label)
}

// A declaration's text.
shown_text :: proc(s: Shown) -> string {
	return span.to_string(TWEAKS.blob[:], s.text)
}

// The name of a choice declaration's choice i.
shown_choice :: proc(s: Shown, i: int) -> string {
	return span.to_string(TWEAKS.blob[:], TWEAKS.names[s.choices.begin + i])
}

// The tweak's copy of its value.
get :: proc(id: Id) -> Tweak {
	return TWEAKS.tweaks[id]
}

// Change the copy, which the next declaration returns.
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

// Makes the button return true next frame.
fire :: proc(id: Id) {
	TWEAKS.fire_next = id
}

// The part of a label that is shown.
display :: proc(label: string) -> string {
	head, _, _ := strings.partition(label, "##")
	return head
}

// Copies text into the blob. A full blob keeps what fits.
@(private = "file")
store :: proc(text: string) -> span.Span {
	begin := len(TWEAKS.blob)
	n := min(len(text), BLOB_SIZE - begin)
	append(&TWEAKS.blob, ..transmute([]u8)text[:n])
	return span.from_range(begin, len(TWEAKS.blob))
}

// Adds a declaration this frame. A full list shows no more; the tweaks still work.
@(private = "file")
show :: proc(s: Shown) {
	if len(TWEAKS.shown) < SHOWN_MAX {
		append(&TWEAKS.shown, s)
	}
}

// The tweak of the label, made the first time it is declared.
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

