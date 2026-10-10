package main

import "core:mem"
import "core:reflect"

@(private = "file")
Rules_Tag :: enum u32 {
	Scenario,
	Faction,
	Region,
	Piece,
	Battle,
	End_Turn,
	Order_Refused,
	March,
	Moved,
	Arrived,
	Enter,
	Exit,
	Contact,
	Interaction,
	Conquered,
	Removed,
	Army,
	Spent,
	Spent_Roll,
	Unspent,
	Turn,
}

@(private = "file")
Scenario_Record :: struct {
	step:             int,
	map_size:         [2]int,
	steps_per_second: int,
}

@(private = "file")
Faction_Record :: struct {
	step:    int,
	id:      int,
	faction: Faction,
}

@(private = "file")
Region_Record :: struct {
	step:   int,
	index:  int,
	region: Region,
}

@(private = "file")
Piece_Record :: struct {
	step:    int,
	id:      Piece_Id,
	piece:   Piece_Data,
	general: Character,
}

@(private = "file")
Battle_Record :: struct {
	step:   int,
	sides:  [2]Piece_Id,
	result: Battle_Result,
}

@(private = "file")
Event_Record :: struct($T: typeid) {
	step:  int,
	event: T,
}

rules_log_open :: proc(path: string) -> bool {
	return stream_open(.Rules, path, rules_log_format)
}

rules_log_close :: proc() {
	stream_close(.Rules)
}

rules_log_begin :: proc(game: ^Game) {
	scenario := Scenario_Record {
		step             = game.step,
		map_size         = MAP_SIZE,
		steps_per_second = STEPS_PER_SECOND,
	}
	push(.Scenario, &scenario)

	for faction, id in game.factions {
		if id == 0 do continue
		record := Faction_Record{game.step, id, faction}
		push(.Faction, &record)
	}

	for &region, index in game.regions {
		if name_to_string(&region.id) == "" do continue
		record := Region_Record{game.step, index, region}
		push(.Region, &record)
	}

	pieces := slot_map_iterator(&game.pieces)
	for piece, id in slot_map_iterate(&pieces) {
		record := Piece_Record {
			step  = game.step,
			id    = id,
			piece = piece^,
		}
		if piece.general != 0 do record.general = game.characters[piece.general]
		push(.Piece, &record)
	}

	push_event(.Turn, game.step, Event_Turn{game.turn, game.player})
}

rules_log_events :: proc(game: ^Game, events: []Game_Event) {
	for event in events {
		switch e in event {
		case Event_End_Turn:
			push_event(.End_Turn, game.step, e)
		case Event_Order_Refused:
			push_event(.Order_Refused, game.step, e)
		case Event_March:
			push_event(.March, game.step, e)
		case Event_Moved:
			push_event(.Moved, game.step, e)
		case Event_Arrived:
			push_event(.Arrived, game.step, e)
		case Event_Enter:
			push_event(.Enter, game.step, e)
		case Event_Exit:
			push_event(.Exit, game.step, e)
		case Event_Contact:
			push_event(.Contact, game.step, e)
			if e.outcome == .Battle || e.outcome == .Refused {
				battle := Battle_Record {
					step   = game.step,
					sides  = {e.initiator, e.other},
					result = game.interaction.result,
				}
				push(.Battle, &battle)
			}
		case Event_Interaction:
			push_event(.Interaction, game.step, e)
		case Event_Conquered:
			push_event(.Conquered, game.step, e)
		case Event_Removed:
			push_event(.Removed, game.step, e)
		case Event_Army:
			push_event(.Army, game.step, e)
		case Event_Spent:
			push_event(.Spent, game.step, e)
		case Event_Spent_Roll:
			push_event(.Spent_Roll, game.step, e)
		case Event_Unspent:
			push_event(.Unspent, game.step, e)
		case Event_Turn:
			push_event(.Turn, game.step, e)
		}
	}
}

@(private = "file")
push :: proc(tag: Rules_Tag, record: ^$T) {
	stream_push(.Rules, u32(tag), mem.ptr_to_bytes(record))
}

@(private = "file")
push_event :: proc(tag: Rules_Tag, step: int, event: $T) {
	record := Event_Record(T){step, event}
	push(tag, &record)
}

@(private = "file")
piece_id_value :: proc(id: Piece_Id) -> i64 {
	return i64(id.generation) << 32 | i64(id.index)
}

@(private = "file")
field_piece :: proc(w: ^Json_Writer, key: string, id: Piece_Id) {
	json_key(w, key)
	if id == {} {
		json_null(w)
	} else {
		json_int(w, piece_id_value(id))
	}
}

@(private = "file")
field_enum :: proc(w: ^Json_Writer, key: string, value: $T) {
	json_field_string(w, key, reflect.enum_string(value))
}

@(private = "file")
field_set :: proc(w: ^Json_Writer, key: string, set: bit_set[$T]) {
	json_key(w, key)
	json_array_begin(w)
	for member in set do json_string(w, reflect.enum_string(member))
	json_array_end(w)
}

@(private = "file")
field_tally :: proc(w: ^Json_Writer, key: string, tally: ^Report_Tally) {
	json_key(w, key)
	json_object_begin(w)
	json_field_float(w, "total", tally.total)
	json_key(w, "factors")
	json_array_begin(w)
	for &factor in tally.factors {
		json_object_begin(w)
		json_field_string(w, "label", string(factor.label[:]))
		field_enum(w, "op", factor.op)
		field_enum(w, "unit", factor.unit)
		json_field_float(w, "value", factor.value)
		json_object_end(w)
	}
	json_array_end(w)
	json_object_end(w)
}

@(private = "file")
write_header :: proc(w: ^Json_Writer, step: int, type: string) {
	json_field_int(w, "step", i64(step))
	json_field_string(w, "type", type)
}

@(private = "file")
write_army :: proc(w: ^Json_Writer, army: ^Army) {
	json_object_begin(w)
	json_field_int(w, "men", i64(army.men))
	json_field_int(w, "men_max", i64(army.men_max))
	json_field_float(w, "proficiency", army.proficiency)
	json_field_float(w, "readiness", army.readiness)
	json_field_bool(w, "spent", army.spent)
	json_field_float(w, "foraging", army.foraging)
	json_field_float(w, "mobility", army.mobility)
	json_field_float(w, "stock", army.stock)
	json_field_float(w, "baggage", army.baggage)
	json_field_float(w, "resupply", army.resupply)
	field_enum(w, "resupply_source", army.resupply_source)
	json_field_float(w, "resupply_efficiency", army.resupply_efficiency)
	json_object_end(w)
}

@(private = "file")
rules_log_format :: proc(w: ^Json_Writer, tag: u32, payload: []u8) {
	json_object_begin(w)
	switch Rules_Tag(tag) {
	case .Scenario:
		record := (^Scenario_Record)(raw_data(payload))
		write_header(w, record.step, "scenario")
		json_field_vec2(w, "map_size", {f32(record.map_size.x), f32(record.map_size.y)})
		json_field_int(w, "steps_per_second", i64(record.steps_per_second))

	case .Faction:
		record := (^Faction_Record)(raw_data(payload))
		write_header(w, record.step, "faction")
		json_field_int(w, "id", i64(record.id))
		json_field_string(w, "name", name_to_string(&record.faction.name))
		field_enum(w, "culture", record.faction.culture)
		json_field_rgb(w, "color", record.faction.color)

	case .Region:
		record := (^Region_Record)(raw_data(payload))
		region := &record.region
		write_header(w, record.step, "region")
		json_field_int(w, "index", i64(record.index))
		json_field_string(w, "id", name_to_string(&region.id))
		json_field_string(w, "name", name_to_string(&region.name))
		field_piece(w, "capital", region.capital)

	case .Piece:
		record := (^Piece_Record)(raw_data(payload))
		piece := &record.piece
		write_header(w, record.step, "piece")
		field_piece(w, "id", record.id)
		json_field_string(w, "name", name_to_string(&piece.name))
		field_enum(w, "icon", piece.icon)
		field_enum(w, "culture", piece.culture)
		json_field_int(w, "owner", i64(piece.owner))
		json_field_vec2(w, "pos", piece.pos)
		json_key(w, "domain")
		if domain, moves := piece.domain.?; moves {
			json_string(w, reflect.enum_string(domain))
		} else {
			json_null(w)
		}
		json_field_float(w, "movement_per_turn", piece.movement_per_turn)
		json_field_float(w, "movement_left", game_movement_left(piece^))
		json_field_bool(w, "attacked", piece.this_turn.attacked)
		json_field_float(w, "contact_radius", piece.contact_radius)
		field_set(w, "contact_domains", piece.contact_domains)
		json_field_float(w, "body_radius", piece.body_radius)
		json_field_float(w, "hindrance", piece.hindrance)
		json_field_float(w, "supply", piece.supply)
		field_set(w, "traits", piece.flags)
		field_piece(w, "inside", piece.inside)
		field_piece(w, "contains", piece.contains)
		json_key(w, "general")
		if piece.general != 0 {
			json_object_begin(w)
			json_field_string(w, "name", name_to_string(&record.general.name))
			field_enum(w, "temperament", record.general.temperament)
			json_object_end(w)
		} else {
			json_null(w)
		}
		json_key(w, "army")
		if army, is_army := &piece.army.?; is_army {
			write_army(w, army)
		} else {
			json_null(w)
		}

	case .Battle:
		record := (^Battle_Record)(raw_data(payload))
		result := &record.result
		report := &result.report
		write_header(w, record.step, "battle")
		json_field_bool(w, "fought", result.fought)
		json_field_bool(w, "refused", result.refused)
		field_piece(w, "attacker", record.sides[result.attacker])
		field_enum(w, "outcome", result.outcome)
		field_piece(w, "winner", record.sides[result.winner])
		json_field_bool(w, "follows", result.follows)
		json_field_float(w, "follow_overdraw", result.follow_overdraw)
		json_field_bool(w, "caught", result.caught)

		json_key(w, "sides")
		json_array_begin(w)
		for &side, i in result.sides {
			json_object_begin(w)
			field_piece(w, "piece", record.sides[i])
			json_field_string(w, "name", report_string(report, result.names[i]))
			field_tally(w, "power", &side.power)
			json_field_string(w, "posture", report_string(report, side.posture))
			field_tally(w, "men", &side.men)
			json_field_float(w, "readiness", side.readiness)
			field_tally(w, "stock", &side.stock)
			field_tally(w, "pursuit_men", &side.pursuit_men)
			json_field_float(w, "pursuit_readiness", side.pursuit_readiness)
			json_field_bool(w, "dissolved", side.dissolved)
			json_field_bool(w, "falls_back", side.falls_back)
			json_object_end(w)
		}
		json_array_end(w)

		json_key(w, "report")
		json_array_begin(w)
		for line in report.lines {
			json_array_begin(w)
			for part in span_slice(report.parts[:], line) {
				json_object_begin(w)
				json_field_string(w, "text", report_string(report, part.text))
				if tally, has_tally := part.tally.?; has_tally {
					field_tally(w, "tally", &report.tallies[tally])
				}
				if part.note.len > 0 do json_field_string(w, "note", report_string(report, part.note))
				json_object_end(w)
			}
			json_array_end(w)
		}
		json_array_end(w)

	case .End_Turn:
		record := (^Event_Record(Event_End_Turn))(raw_data(payload))
		write_header(w, record.step, "end_turn")
		json_field_bool(w, "accepted", record.event.accepted)

	case .Order_Refused:
		record := (^Event_Record(Event_Order_Refused))(raw_data(payload))
		write_header(w, record.step, "order_refused")
		field_piece(w, "piece", record.event.piece)
		field_enum(w, "reason", record.event.reason)

	case .March:
		record := (^Event_Record(Event_March))(raw_data(payload))
		write_header(w, record.step, "march")
		field_piece(w, "piece", record.event.piece)
		field_enum(w, "mover", record.event.mover)
		field_piece(w, "target", record.event.target)
		json_field_vec2(w, "to", record.event.to)

	case .Moved:
		record := (^Event_Record(Event_Moved))(raw_data(payload))
		write_header(w, record.step, "moved")
		field_piece(w, "piece", record.event.piece)
		json_field_vec2(w, "pos", record.event.pos)
		json_field_float(w, "movement_left", record.event.movement_left)
		json_field_float(w, "overdrawn", record.event.overdrawn)

	case .Arrived:
		record := (^Event_Record(Event_Arrived))(raw_data(payload))
		write_header(w, record.step, "arrived")
		field_piece(w, "piece", record.event.piece)
		json_field_vec2(w, "pos", record.event.pos)

	case .Enter:
		record := (^Event_Record(Event_Enter))(raw_data(payload))
		write_header(w, record.step, "enter")
		field_piece(w, "piece", record.event.piece)
		field_piece(w, "settlement", record.event.settlement)

	case .Exit:
		record := (^Event_Record(Event_Exit))(raw_data(payload))
		write_header(w, record.step, "exit")
		field_piece(w, "piece", record.event.piece)
		field_piece(w, "settlement", record.event.settlement)

	case .Contact:
		record := (^Event_Record(Event_Contact))(raw_data(payload))
		write_header(w, record.step, "contact")
		field_piece(w, "initiator", record.event.initiator)
		field_piece(w, "other", record.event.other)
		json_field_bool(w, "targeted", record.event.targeted)
		field_enum(w, "outcome", record.event.outcome)

	case .Interaction:
		record := (^Event_Record(Event_Interaction))(raw_data(payload))
		write_header(w, record.step, "interaction")
		field_piece(w, "actor", record.event.actor)
		field_piece(w, "target", record.event.target)
		field_enum(w, "stage", record.event.stage)
		json_field_bool(w, "closed", record.event.closed)

	case .Conquered:
		record := (^Event_Record(Event_Conquered))(raw_data(payload))
		write_header(w, record.step, "conquered")
		field_piece(w, "piece", record.event.piece)
		field_piece(w, "by", record.event.by)
		json_field_int(w, "from", i64(record.event.from))
		json_field_int(w, "to", i64(record.event.to))

	case .Removed:
		record := (^Event_Record(Event_Removed))(raw_data(payload))
		write_header(w, record.step, "removed")
		field_piece(w, "piece", record.event.piece)

	case .Army:
		record := (^Event_Record(Event_Army))(raw_data(payload))
		write_header(w, record.step, "army")
		field_piece(w, "piece", record.event.piece)
		field_set(w, "changes", record.event.changes)
		json_key(w, "army")
		write_army(w, &record.event.army)

	case .Spent:
		record := (^Event_Record(Event_Spent))(raw_data(payload))
		write_header(w, record.step, "spent")
		field_piece(w, "piece", record.event.piece)
		json_field_float(w, "readiness", record.event.readiness)

	case .Spent_Roll:
		record := (^Event_Record(Event_Spent_Roll))(raw_data(payload))
		write_header(w, record.step, "spent_roll")
		field_piece(w, "piece", record.event.piece)
		json_field_float(w, "readiness", record.event.readiness)
		json_field_float(w, "roll", record.event.roll)
		json_field_float(w, "total", record.event.total)
		json_field_float(w, "target", record.event.target)

	case .Unspent:
		record := (^Event_Record(Event_Unspent))(raw_data(payload))
		write_header(w, record.step, "unspent")
		field_piece(w, "piece", record.event.piece)

	case .Turn:
		record := (^Event_Record(Event_Turn))(raw_data(payload))
		write_header(w, record.step, "turn")
		json_field_int(w, "turn", i64(record.event.turn))
		json_field_int(w, "player", i64(record.event.player))
	}
	json_object_end(w)
	json_line_end(w)
}
