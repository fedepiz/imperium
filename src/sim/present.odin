#+private
package sim

import "core:fmt"
import "core:math"

import "../span"

// Area slots, in drawing order, and looks for game's area palette
REACH_AREA :: 0
BODY_AREA :: 1
ZONE_AREA :: 2
REACH_LOOK :: 1
ZONE_LOOK :: 2
// Reach of a piece the player does not control
OTHER_REACH_LOOK :: 3
BODY_LOOK :: 4

world_present :: proc(focus: Piece_Id, out: ^Scene) {
	mov := &WORLD.movement
	movement_flood(mov, focus)

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
	if walker := piece_get(mov.subject); walker != nil {
		begin := len(out.arrow_points)
		append(&out.arrow_points, walker.pos)
		append(&out.arrow_points, ..mov.path[mov.next:])
		append(&out.arrows, span.from_range(begin, len(out.arrow_points)))
	}

	// Where the focus can walk, unless it is walking: the reach as cells, rebuilt when the flood changes, and the
	// bodies and zones as circles over it
	flood := &mov.flood
	shown := mov.flood_subject != {} && mov.flood_subject != mov.subject
	reach := &out.areas[REACH_AREA]
	if key := shown ? mov.flood_key : 0; reach.revision != key {
		reach.revision, reach.cells = key, {}
		reach.on_water, reach.corner = flood.domain != .Land, flood.corner
		if shown do for cost, i in flood.cost do reach.cells[i] = cost != math.INF_F32
	}
	reach.look = OTHER_REACH_LOOK
	if piece := piece_get(focus); piece != nil && piece_controlled(piece^) do reach.look = REACH_LOOK
	clear(&out.circles)
	for discs, slot in ([2][]Disc{mov.bodies[:], mov.zones[:]}) {
		area := &out.areas[BODY_AREA + slot]
		area.look = slot == 0 ? BODY_LOOK : ZONE_LOOK
		area.on_water = flood.domain != .Land
		begin := len(out.circles)
		for disc in discs {
			if shown && len(out.circles) < CIRCLES_MAX do append(&out.circles, Circle{disc.center, disc.radius})
		}
		area.circles = span.from_range(begin, len(out.circles))
	}

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

// The player controls the piece
@(private = "file")
piece_controlled :: proc(piece: Piece) -> bool {
	return faction_get(piece.owner) != nil && piece.owner == WORLD.player
}
