package main

import "core:hash"
import "core:strings"

TWEAKS_MAX :: 1024
TWEAK_CHOICE_NAMES_MAX :: 4096

Tweak_Kind :: enum {
	Label,
	Button,
	Toggle,
	Slider,
	Choice,
}

Tweak_Id :: distinct u16

Tweak :: struct {
	key:       u64,
	kind:      Tweak_Kind,
	edited:    bool,
	flag:      bool,
	value:     f32,
	selection: int,
}

Tweak_Shown :: struct {
	id:      Tweak_Id,
	kind:    Tweak_Kind,
	label:   string,
	name:    string,
	text:    string,
	lo:      f32,
	hi:      f32,
	choices: []string,
}

@(private = "file")
TWEAK: struct {
	tweaks:    [dynamic; TWEAKS_MAX]Tweak,
	shown:     [dynamic; TWEAKS_MAX]Tweak_Shown,
	names:     [dynamic; TWEAK_CHOICE_NAMES_MAX]string,
	fired:     Tweak_Id,
	fire_next: Tweak_Id,
}

tweak_begin :: proc() {
	if len(TWEAK.tweaks) == 0 do append(&TWEAK.tweaks, Tweak{})
	clear(&TWEAK.shown)
	clear(&TWEAK.names)
	TWEAK.fired = TWEAK.fire_next
	TWEAK.fire_next = 0
}

tweak_label :: proc(label, text: string) {
	tweak_declare({kind = .Label, label = label, text = text})
}

tweak_button :: proc(label, text: string) -> bool {
	_, id := tweak_declare({kind = .Button, label = label, text = text})
	return id == TWEAK.fired
}

tweak_toggle :: proc(label, text: string, flag: bool) -> bool {
	tweak, _ := tweak_declare({kind = .Toggle, label = label, text = text})
	if !tweak.edited do tweak.flag = flag
	tweak.edited = false
	return tweak.flag
}

tweak_slider :: proc(label: string, value, lo, hi: f32) -> f32 {
	tweak, _ := tweak_declare({kind = .Slider, label = label, lo = lo, hi = hi})
	if !tweak.edited do tweak.value = value
	tweak.edited = false
	tweak.value = clamp(tweak.value, lo, hi)
	return tweak.value
}

tweak_choice :: proc(label: string, selection: int, choices: []string) -> int {
	assert(len(choices) > 0)
	names_begin := len(TWEAK.names)
	append(&TWEAK.names, ..choices)
	tweak, _ := tweak_declare({kind = .Choice, label = label, choices = TWEAK.names[names_begin:]})
	if !tweak.edited do tweak.selection = selection
	tweak.edited = false
	tweak.selection = clamp(tweak.selection, 0, len(choices) - 1)
	return tweak.selection
}

tweak_shown :: proc() -> []Tweak_Shown {
	return TWEAK.shown[:]
}

tweak_get :: proc(id: Tweak_Id) -> Tweak {
	return TWEAK.tweaks[id]
}

tweak_set_flag :: proc(id: Tweak_Id, flag: bool) {
	TWEAK.tweaks[id].flag = flag
	TWEAK.tweaks[id].edited = true
}

tweak_set_value :: proc(id: Tweak_Id, value: f32) {
	TWEAK.tweaks[id].value = value
	TWEAK.tweaks[id].edited = true
}

tweak_set_selection :: proc(id: Tweak_Id, selection: int) {
	TWEAK.tweaks[id].selection = selection
	TWEAK.tweaks[id].edited = true
}

tweak_fire :: proc(id: Tweak_Id) {
	TWEAK.fire_next = id
}

@(private = "file")
tweak_declare :: proc(shown: Tweak_Shown) -> (tweak: ^Tweak, id: Tweak_Id) {
	head, separator, tail := strings.partition(shown.label, "###")
	keyed := len(separator) > 0 ? tail : head
	assert(len(keyed) > 0)
	key := hash.fnv64a(transmute([]u8)keyed)

	for existing, index in TWEAK.tweaks {
		if index == 0 || existing.key != key do continue
		id = Tweak_Id(index)
		break
	}
	if id == 0 {
		assert(len(TWEAK.tweaks) < TWEAKS_MAX)
		id = Tweak_Id(len(TWEAK.tweaks))
		append(&TWEAK.tweaks, Tweak{key = key, kind = shown.kind})
	}
	tweak = &TWEAK.tweaks[id]
	assert(tweak.kind == shown.kind)

	name, _, _ := strings.partition(shown.label, "##")
	shown := shown
	shown.id = id
	shown.name = name
	append(&TWEAK.shown, shown)
	return
}
