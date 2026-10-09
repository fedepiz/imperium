package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

COMMANDS_BUFFER_BYTES :: 1 << 16

Command_Type :: enum {
	Step,
	Order_Target,
	Order_Move,
	Next,
	Conquer,
	Leave,
	End_Turn,
	Camera_Focus_On_Piece,
	Camera_Focus_On_Location,
}

Command :: struct {
	type:   Command_Type,
	count:  int,
	piece:  Piece_Id,
	target: Piece_Id,
	to:     [2]f32,
	zoom:   Maybe(f32),
}

@(private = "file", rodata)
TYPE_NAMES := [Command_Type]string {
	.Step         = "step",
	.Order_Target = "order_target",
	.Order_Move   = "order_move",
	.Next         = "next",
	.Conquer      = "conquer",
	.Leave                    = "leave",
	.End_Turn                 = "end_turn",
	.Camera_Focus_On_Piece    = "camera_focus_on_piece",
	.Camera_Focus_On_Location = "camera_focus_on_location",
}

@(private = "file")
Argument :: enum {
	Count,
	Piece,
	Target,
	X,
	Y,
	Zoom,
}

@(private = "file", rodata)
ARGUMENT_NAMES := [Argument]string {
	.Count  = "count",
	.Piece  = "piece",
	.Target = "target",
	.X      = "x",
	.Y      = "y",
	.Zoom   = "zoom",
}

@(private = "file", rodata)
REQUIRED := [Command_Type]bit_set[Argument] {
	.Step         = {.Count},
	.Order_Target = {.Piece, .Target},
	.Order_Move   = {.Piece, .X, .Y},
	.Next         = {},
	.Conquer      = {},
	.Leave                    = {},
	.End_Turn                 = {},
	.Camera_Focus_On_Piece    = {.Piece},
	.Camera_Focus_On_Location = {.X, .Y},
}

@(private = "file")
COMMANDS: struct {
	file:   ^os.File,
	buffer: [COMMANDS_BUFFER_BYTES]u8,
	start:  int,
	end:    int,
	line:   int,
	ended:  bool,
}

commands_open :: proc(path: string) -> bool {
	if path == "-" {
		COMMANDS.file = os.stdin
		return true
	}
	file, err := os.open(path)
	if err != nil {
		fmt.eprintln("Could not open", path, err)
		return false
	}
	COMMANDS.file = file
	return true
}

commands_close :: proc() {
	if COMMANDS.file != nil && COMMANDS.file != os.stdin do os.close(COMMANDS.file)
	COMMANDS.file = nil
}

commands_next :: proc(command: ^Command) -> bool {
	source := &COMMANDS
	for {
		newline := -1
		for i in source.start ..< source.end {
			if source.buffer[i] != '\n' do continue
			newline = i
			break
		}

		if newline < 0 && !source.ended {
			copy(source.buffer[:], source.buffer[source.start:source.end])
			source.end -= source.start
			source.start = 0
			if source.end == len(source.buffer) {
				fmt.eprintfln("Commands line %d is longer than %d bytes", source.line + 1, len(source.buffer))
				return false
			}
			read, err := os.read(source.file, source.buffer[source.end:])
			if read <= 0 || err != nil do source.ended = true
			source.end += max(read, 0)
			continue
		}

		line_end := newline >= 0 ? newline : source.end
		if line_end == source.start && newline < 0 do return false
		text := strings.trim_space(string(source.buffer[source.start:line_end]))
		source.start = newline >= 0 ? newline + 1 : source.end
		source.line += 1
		if text == "" do continue

		command^ = {}
		if error := command_parse(text, command); error != "" {
			fmt.eprintfln("Commands line %d: %s", source.line, error)
			continue
		}
		return true
	}
}

command_apply :: proc(
	game: ^Game,
	command: Command,
	input: ^Game_Input,
	camera: ^Camera,
) -> (
	steps: int,
) {
	if zoom, zoomed := command.zoom.?; zoomed {
		camera.target.zoom = clamp(zoom, CAMERA_ZOOM_MIN, CAMERA_ZOOM_MAX)
		camera.ease = camera.move_ease
	}
	switch command.type {
	case .Step:
		steps = command.count
	case .Order_Target:
		input.order = Game_Order {
			piece  = command.piece,
			target = command.target,
		}
	case .Order_Move:
		input.order = Game_Order {
			piece       = command.piece,
			destination = command.to,
			snap        = CLICK_MOVE_SNAP,
		}
	case .Next:
		input.answer = .Next
	case .Conquer:
		input.answer = .Conquer
	case .Leave:
		input.answer = .Leave
	case .End_Turn:
		input.end_turn = true
	case .Camera_Focus_On_Piece:
		if piece := slot_map_get(&game.pieces, command.piece); piece != nil {
			camera.target.center = piece.pos
			camera.ease = camera.move_ease
		}
	case .Camera_Focus_On_Location:
		camera.target.center = command.to
		camera.ease = camera.move_ease
	}
	return
}

@(private = "file")
command_parse :: proc(text: string, command: ^Command) -> (error: string) {
	at := 0
	skip_space :: proc(text: string, at: ^int) {
		for at^ < len(text) && (text[at^] == ' ' || text[at^] == '\t') do at^ += 1
	}
	quoted :: proc(text: string, at: ^int) -> (value: string, ok: bool) {
		if at^ >= len(text) || text[at^] != '"' do return
		start := at^ + 1
		end := strings.index_byte(text[start:], '"')
		if end < 0 do return
		value = text[start:][:end]
		if strings.index_byte(value, '\\') >= 0 do return
		at^ = start + end + 1
		return value, true
	}

	skip_space(text, &at)
	if at >= len(text) || text[at] != '{' do return "expected {"
	at += 1

	has_type := false
	given: bit_set[Argument]
	for {
		skip_space(text, &at)
		if at < len(text) && text[at] == '}' do break

		key, key_ok := quoted(text, &at)
		if !key_ok do return "expected a quoted key"
		skip_space(text, &at)
		if at >= len(text) || text[at] != ':' do return "expected :"
		at += 1
		skip_space(text, &at)

		if key == "type" {
			name, name_ok := quoted(text, &at)
			if !name_ok do return "type must be a quoted name"
			found := false
			for type_name, type in TYPE_NAMES {
				if type_name != name do continue
				command.type = type
				found = true
			}
			if !found do return fmt.tprintf("unknown type %q", name)
			has_type = true
		} else {
			argument: Argument
			found := false
			for argument_name, candidate in ARGUMENT_NAMES {
				if argument_name != key do continue
				argument = candidate
				found = true
			}
			if !found do return fmt.tprintf("unknown key %q", key)

			start := at
			for at < len(text) && text[at] != ',' && text[at] != '}' && text[at] != ' ' do at += 1
			number, number_ok := strconv.parse_f64(text[start:at])
			if !number_ok do return fmt.tprintf("%s must be a number", key)
			given += {argument}

			switch argument {
			case .Count:
				command.count = int(number)
			case .Piece:
				command.piece = piece_id_from_value(u64(number))
			case .Target:
				command.target = piece_id_from_value(u64(number))
			case .X:
				command.to.x = f32(number)
			case .Y:
				command.to.y = f32(number)
			case .Zoom:
				command.zoom = f32(number)
			}
		}

		skip_space(text, &at)
		if at < len(text) && text[at] == ',' {
			at += 1
			continue
		}
		if at < len(text) && text[at] == '}' do break
		return "expected , or }"
	}

	if !has_type do return "missing type"
	if missing := REQUIRED[command.type] - given; missing != {} {
		names: [dynamic; len(Argument)]string
		for argument in missing do append(&names, ARGUMENT_NAMES[argument])
		return fmt.tprintf("%s needs %s", TYPE_NAMES[command.type], strings.join(names[:], ", ", context.temp_allocator))
	}
	if command.type == .Step && command.count < 1 do return "count must be at least 1"
	return ""
}

@(private = "file")
piece_id_from_value :: proc(value: u64) -> Piece_Id {
	return {index = u32(value & 0xffff_ffff), generation = u32(value >> 32)}
}
