#+private
package game

import "core:fmt"
import "core:os"
import "core:reflect"

import "../sim"
import "../tabula"

// Pieces --------------------------------------------------------------------------------------------------------------
// Pieces: the factions a scenario starts with, and the pieces each holds

// The file the pieces are read from, in a scenario's folder
PIECES_FILE :: "pieces.txt"

// Reads the factions and pieces from their file in a scenario's folder. They live in the temp allocator. The file is
// tabula: first kind rows, each a kind of piece to be named by pieces below it, then faction rows, each holding its
// pieces. A word for an enum value is written as it is declared, such as Large_City or Land. If the file cannot be
// read, where and why is shown, and false is returned.
//
// kind: name, icon, moves (a domain, left out for a piece that stays put), per_turn, contact, contact_on (a list of
// domains) and body.
// faction: name, culture, and a piece row for each piece: kind, name (may be left out), at ([x, y] in cells) and
// culture (the faction's when left out).
pieces_load :: proc(folder: string) -> (factions: []sim.Scenario_Faction, pieces: []sim.Scenario_Piece, ok: bool) {
	Kind :: struct {
		name:  string,
		piece: sim.Scenario_Piece,
	}
	fail :: proc(path, key: string, n: int, message: string) -> bool {
		fmt.eprintfln("%s, %s %d: %s", path, key, n + 1, message)
		return false
	}

	path := fmt.tprintf("%s/%s", folder, PIECES_FILE)
	source, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.eprintfln("Could not read %s: %v", path, err)
		return
	}
	root, error, parsed := tabula.parse(string(source), context.temp_allocator)
	if !parsed {
		fmt.eprintfln("%s:%d:%d: %s", path, error.line, error.column, error.message)
		return
	}

	kinds := make([dynamic]Kind, context.temp_allocator)
	faction_list := make([dynamic]sim.Scenario_Faction, context.temp_allocator)
	piece_list := make([dynamic]sim.Scenario_Piece, context.temp_allocator)
	for row, n in root.children {
		switch row.key {
		case "kind":
			kind: Kind
			kind.name = tabula.get_text(row, "name")
			if kind.name == "" do return nil, nil, fail(path, row.key, n, "it needs a name")
			icon, has_icon := enum_get(row, "icon", sim.Icon)
			if !has_icon do return nil, nil, fail(path, row.key, n, "it needs an icon")
			kind.piece.icon = icon
			if _, has_moves := tabula.get_text(row, "moves"); has_moves {
				domain, is_domain := enum_get(row, "moves", sim.Pathfind_Domain)
				if !is_domain do return nil, nil, fail(path, row.key, n, "moves must be a domain")
				kind.piece.movement_domain = domain
			}
			kind.piece.movement_per_turn = tabula.get_num(row, "per_turn")
			kind.piece.contact.radius = tabula.get_num(row, "contact")
			for value in tabula.find(row, "contact_on").children {
				domain, is_domain := reflect.enum_from_name(sim.Pathfind_Domain, value.text)
				if !is_domain do return nil, nil, fail(path, row.key, n, "contact_on must list domains")
				kind.piece.contact.domains += {domain}
			}
			kind.piece.body = tabula.get_num(row, "body")
			append(&kinds, kind)
		case "faction":
			faction := sim.Scenario_Faction {
				name = tabula.get_text(row, "name"),
			}
			if faction.name == "" do return nil, nil, fail(path, row.key, n, "it needs a name")
			culture, has_culture := enum_get(row, "culture", sim.Culture)
			if !has_culture do return nil, nil, fail(path, row.key, n, "it needs a culture")
			faction.culture = culture
			for piece_row in row.children {
				if piece_row.key != "piece" do continue
				kind_name := tabula.get_text(piece_row, "kind")
				piece: sim.Scenario_Piece
				found := false
				for kind in kinds {
					if kind.name != kind_name do continue
					piece = kind.piece
					found = true
					break
				}
				if !found {
					message := fmt.tprintf("its piece's kind %q is not a kind above it", kind_name)
					return nil, nil, fail(path, row.key, n, message)
				}
				piece.name = tabula.get_text(piece_row, "name")
				piece.owner = len(faction_list)
				piece.culture = culture
				if _, has_own := tabula.get_text(piece_row, "culture"); has_own {
					own, is_culture := enum_get(piece_row, "culture", sim.Culture)
					if !is_culture do return nil, nil, fail(path, row.key, n, "its piece's culture is not a culture")
					piece.culture = own
				}
				at := tabula.find(piece_row, "at")
				at_ok := len(at.children) == 2
				for coord in at.children do at_ok &&= .Has_Num in coord.flags
				if !at_ok {
					return nil, nil, fail(path, row.key, n, "each piece must stand at [x, y], in cells")
				}
				piece.pos = {at.children[0].num, at.children[1].num}
				append(&piece_list, piece)
			}
			append(&faction_list, faction)
		case:
			return nil, nil, fail(path, row.key, n, "expected a kind or a faction")
		}
	}
	return faction_list[:], piece_list[:], true
}

// The value of an enum written as a word under the key, if there is one and it names a value
@(private = "file")
enum_get :: proc(row: tabula.Row, key: string, $T: typeid) -> (value: T, ok: bool) {
	text := tabula.get_text(row, key) or_return
	return reflect.enum_from_name(T, text)
}
