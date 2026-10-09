package main

import "core:fmt"
import "core:math"

JSON_BUFFER_MAX :: 1 << 20
JSON_DEPTH_MAX :: 16

Json_Writer :: struct {
	buffer:    [dynamic; JSON_BUFFER_MAX]u8,
	has_items: [JSON_DEPTH_MAX]bool,
	depth:     int,
	after_key: bool,
}

json_object_begin :: proc(w: ^Json_Writer) {
	json_separate(w)
	append(&w.buffer, '{')
	json_push(w)
}

json_object_end :: proc(w: ^Json_Writer) {
	w.depth -= 1
	append(&w.buffer, '}')
}

json_array_begin :: proc(w: ^Json_Writer) {
	json_separate(w)
	append(&w.buffer, '[')
	json_push(w)
}

json_array_end :: proc(w: ^Json_Writer) {
	w.depth -= 1
	append(&w.buffer, ']')
}

json_key :: proc(w: ^Json_Writer, key: string) {
	json_separate(w)
	json_quoted(w, key)
	append(&w.buffer, ':')
	w.after_key = true
}

json_string :: proc(w: ^Json_Writer, value: string) {
	json_separate(w)
	json_quoted(w, value)
}

json_float :: proc(w: ^Json_Writer, value: f32) {
	json_separate(w)
	if math.is_nan(value) || math.is_inf(value) {
		append(&w.buffer, "null")
		return
	}
	digits: [32]u8
	append(&w.buffer, fmt.bprintf(digits[:], "%v", value))
}

json_int :: proc(w: ^Json_Writer, value: i64) {
	json_separate(w)
	digits: [32]u8
	append(&w.buffer, fmt.bprintf(digits[:], "%d", value))
}

json_bool :: proc(w: ^Json_Writer, value: bool) {
	json_separate(w)
	append(&w.buffer, value ? "true" : "false")
}

json_null :: proc(w: ^Json_Writer) {
	json_separate(w)
	append(&w.buffer, "null")
}

json_field_string :: proc(w: ^Json_Writer, key: string, value: string) {
	json_key(w, key)
	json_string(w, value)
}

json_field_float :: proc(w: ^Json_Writer, key: string, value: f32) {
	json_key(w, key)
	json_float(w, value)
}

json_field_int :: proc(w: ^Json_Writer, key: string, value: i64) {
	json_key(w, key)
	json_int(w, value)
}

json_field_bool :: proc(w: ^Json_Writer, key: string, value: bool) {
	json_key(w, key)
	json_bool(w, value)
}

json_field_vec2 :: proc(w: ^Json_Writer, key: string, value: [2]f32) {
	json_key(w, key)
	json_array_begin(w)
	json_float(w, value.x)
	json_float(w, value.y)
	json_array_end(w)
}

json_field_rgb :: proc(w: ^Json_Writer, key: string, value: [3]f32) {
	json_key(w, key)
	json_array_begin(w)
	for channel in value do json_float(w, channel)
	json_array_end(w)
}

json_line_end :: proc(w: ^Json_Writer) {
	assert(w.depth == 0)
	append(&w.buffer, '\n')
	w.has_items = {}
}

@(private = "file")
json_push :: proc(w: ^Json_Writer) {
	assert(w.depth < JSON_DEPTH_MAX)
	w.has_items[w.depth] = false
	w.depth += 1
}

@(private = "file")
json_separate :: proc(w: ^Json_Writer) {
	if w.after_key {
		w.after_key = false
		return
	}
	if w.depth == 0 do return
	if w.has_items[w.depth - 1] do append(&w.buffer, ',')
	w.has_items[w.depth - 1] = true
}

@(private = "file")
json_quoted :: proc(w: ^Json_Writer, text: string) {
	hex := "0123456789abcdef"
	append(&w.buffer, '"')
	for i in 0 ..< len(text) {
		c := text[i]
		switch c {
		case '"':
			append(&w.buffer, `\"`)
		case '\\':
			append(&w.buffer, `\\`)
		case '\n':
			append(&w.buffer, `\n`)
		case '\t':
			append(&w.buffer, `\t`)
		case 0 ..< 0x20:
			append(&w.buffer, `\u00`)
			append(&w.buffer, hex[c >> 4])
			append(&w.buffer, hex[c & 0xf])
		case:
			append(&w.buffer, c)
		}
	}
	append(&w.buffer, '"')
}
