#+private
package sim

import "core:fmt"
import "core:hash"
import "core:math"

import "../span"

// Area slots, and looks for game's area palette
REACH_AREA :: 0
ZONE_AREA :: 1
REACH_LOOK :: 1
ZONE_LOOK :: 2
// Reach of a piece the player does not control
OTHER_REACH_LOOK :: 3

world_present :: proc(focus: Piece_Id, out: ^Scene) {
	// The ground, taken up again only when it changed
	if out.ground_revision != WORLD.atlas.revision {
		out.ground_revision = WORLD.atlas.revision
		for cell, i in WORLD.atlas.terrain {
			ground := Ground {
				surface   = cell.surface,
				elevation = cell.elevation,
				trees     = cell.trees,
				moisture  = cell.moisture,
			}
			for id, kind in cell.way do if id != 0 do ground.ways += {kind}
			out.ground[i] = ground
		}
	}

	// Every piece, the focus focused, and the player's controlled
	clear(&out.tokens)
	for piece, index in WORLD.pieces {
		if !piece_alive(piece) do continue
		id := piece_id(index)
		token := Token {
			handle  = id,
			pos     = piece.pos,
			picture = {piece.icon, piece.culture},
			label   = piece.name,
		}
		if id == focus do token.flags += {.Focused}
		if piece_controlled(piece) do token.flags += {.Controlled}
		append(&out.tokens, token)
	}

	// The way the walking piece has still to go, from where it stands
	clear(&out.arrows)
	clear(&out.arrow_points)
	mov := &WORLD.movement
	if walker := piece_get(mov.subject); walker != nil {
		begin := len(out.arrow_points)
		append(&out.arrow_points, walker.pos)
		append(&out.arrow_points, ..mov.path[mov.next:])
		append(&out.arrows, span.from_range(begin, len(out.arrow_points)))
	}

	// Reach and zones of the focus, unless it is walking
	movement_flood(mov, focus != mov.subject ? focus : {})
	reach_look: u8 = OTHER_REACH_LOOK
	if piece := piece_get(focus); piece != nil && piece_controlled(piece^) do reach_look = REACH_LOOK
	area_from_flood(&out.areas[REACH_AREA], mov, reach_look, false)
	area_from_flood(&out.areas[ZONE_AREA], mov, ZONE_LOOK, true)

	// The turn being played, and the faction playing it, with ending its part; and, when there is a focus, its picture
	// and name, or what it is when it has none, over what it is
	clear(&out.cards)
	status := Card {
		place = .Status,
		title = fmt.tprintf("Turn %d", WORLD.turn),
	}
	player := faction_get(WORLD.player)
	append(&status.fields, Field{"Playing", player != nil ? player.name : "None"})
	append(&status.actions, Action{label = "End turn", command = End_Turn{}, enabled = turn_can_end()})
	append(&out.cards, status)
	if piece := piece_get(focus); piece != nil {
		card := Card {
			place   = .Focus,
			title   = piece.name != "" ? piece.name : piece.title,
			picture = Picture{piece.icon, piece.culture},
		}
		append(&card.fields, Field{"Type", piece.title})
		faction := faction_get(piece.owner)
		append(&card.fields, Field{"Faction", faction != nil ? faction.name : "None"})
		append(&card.fields, Field{"Culture", fmt.tprintf("%v", piece.culture)})
		if piece.movement_domain != nil {
			budget := fmt.tprintf("%.0f of %.0f", piece.movement_budget, piece.movement_per_turn)
			append(&card.fields, Field{"Movement", budget})
		}
		append(&out.cards, card)
	}
}

// Fills the area from the flood, in the look: its zone cells, or else its reached cells outside zones. Rebuilt only when
// its key changes.
@(private = "file")
area_from_flood :: proc(area: ^Area, mov: ^Movement, look: u8, zone: bool) {
	key: u64
	if mov.flood_subject != {} do key = hash.fnv64a({look}, mov.flood_key)
	if area.revision == key do return
	area^ = {revision = key, look = look}
	if key == 0 do return
	flood := &mov.flood
	area.on_water = flood.domain != .Land
	area.corner = flood.corner
	for cost, i in flood.cost {
		area.cells[i] = zone ? flood.zone[i] : cost != math.INF_F32 && !flood.zone[i]
	}
}

// The player controls the piece
@(private = "file")
piece_controlled :: proc(piece: Piece) -> bool {
	return faction_get(piece.owner) != nil && piece.owner == WORLD.player
}
