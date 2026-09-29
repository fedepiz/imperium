#+private
package sim

import "core:fmt"
import "core:math"

import "../span"

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

	// Every piece, the focus focused
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

	// Where the focus can walk, while it is not walking, taken up again only when it changed
	movement_flood(mov, focus != mov.subject ? focus : {})
	reach := &out.areas[.Reach]
	if reach.revision != mov.flood_revision {
		reach.revision = mov.flood_revision
		reach.cells = {}
		if mov.flood_subject != {} {
			flood := &mov.flood
			reach.on_water = flood.domain != .Land
			reach.corner = flood.corner
			for cost, i in flood.cost do reach.cells[i] = cost != math.INF_F32
		}
	}

	// The turn being played, with ending it; and, when there is a focus, its picture and name, or what it is when it
	// has none, over what it is
	clear(&out.cards)
	status := Card {
		place = .Status,
		title = fmt.tprintf("Turn %d", WORLD.turn),
	}
	append(&status.actions, Action{label = "End turn", command = End_Turn{}, enabled = turn_can_end()})
	append(&out.cards, status)
	if piece := piece_get(focus); piece != nil {
		card := Card {
			place   = .Focus,
			title   = piece.name != "" ? piece.name : piece.title,
			picture = Picture{piece.icon, piece.culture},
		}
		append(&card.fields, Field{"Type", piece.title})
		append(&card.fields, Field{"Culture", fmt.tprintf("%v", piece.culture)})
		if piece.movement_domain != nil {
			budget := fmt.tprintf("%.0f of %.0f", piece.movement_budget, piece.movement_per_turn)
			append(&card.fields, Field{"Movement", budget})
		}
		append(&out.cards, card)
	}
}
