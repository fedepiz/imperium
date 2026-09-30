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

world_present :: proc(focus: Piece_Id, pointed: Region_Id, region_colouring: Region_Colouring_Mode, out: ^Scene) {
	mov := &WORLD.movement
	movement_flood(mov, focus)

	// The ground, taken up again only when it changed
	if out.ground_revision != WORLD.atlas.revision {
		out.ground_revision = WORLD.atlas.revision
		for cell, i in WORLD.atlas.terrain {
			ground := Ground {
				surface       = cell.surface,
				elevation     = cell.elevation,
				trees         = cell.trees,
				moisture      = cell.moisture,
				type          = cell.type,
				type_strength = cell.type_strength,
				region        = cell.region,
			}
			for id, kind in cell.way do if id != 0 do ground.ways += {kind}
			out.ground[i] = ground
		}
	}

	// Every piece, the focus focused, and the player's controlled
	clear(&out.pawns)
	for piece, index in WORLD.pieces {
		if !piece_alive(piece) do continue
		id := piece_id(index)
		pawn := Pawn {
			handle  = id,
			pos     = piece.pos,
			picture = {piece.icon, piece.culture},
			label   = string(WORLD.piece_names[index][:]),
		}
		if id == focus do pawn.flags += {.Focused}
		if piece_controlled(piece) do pawn.flags += {.Controlled}
		append(&out.pawns, pawn)
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

	// Every region, coloured as the mode has it, the pointed one highlighted unless the reach is shown or the mode is
	// muted
	clear(&out.regions)
	for &name, index in WORLD.region_names {
		id := Region_Id(index + 1)
		color: [4]f32
		switch region_colouring {
		case .Owner:
			color = REGION_UNHELD_COLOR
			if capital := piece_get(WORLD.region_capitals[index]); capital != nil {
				if faction := faction_get(capital.owner); faction != nil do color = faction.color
			}
		case .Identity:
			color = region_identity_color(id)
		case .Muted:
			color = REGION_UNHELD_COLOR
		}
		highlighted := !shown && id == pointed && region_colouring != .Muted
		append(&out.regions, Region{name = string(name[:]), color = color, highlighted = highlighted})
	}

	// The turn being played, and the faction playing it, with ending its part; and, when there is a focus, its picture
	// and name, or what it is when it has none, over what it is
	clear(&out.cards)
	status := Card {
		place = .Status,
		title = fmt.tprintf("Turn %d", WORLD.turn),
	}
	player := faction_get(WORLD.player)
	append(&status.fields, Field{"Playing", player != nil ? faction_name(WORLD.player) : "None"})
	append(
		&status.actions,
		Action{label = "End turn", command = End_Turn{}, enabled = turn_can_end()},
	)
	append(&out.cards, status)
	if piece := piece_get(focus); piece != nil {
		card := Card {
			place   = .Focus,
			title   = len(WORLD.piece_names[focus.index]) > 0 ? string(WORLD.piece_names[focus.index][:]) : ICON_TITLES[piece.icon],
			picture = Picture{piece.icon, piece.culture},
		}
		append(&card.fields, Field{"Type", ICON_TITLES[piece.icon]})
		faction := faction_get(piece.owner)
		append(&card.fields, Field{"Faction", faction != nil ? faction_name(piece.owner) : "None"})
		append(&card.fields, Field{"Culture", fmt.tprintf("%v", piece.culture)})
		if piece.movement_domain != nil {
			budget := fmt.tprintf("%.0f of %.0f", piece.movement_budget, piece.movement_per_turn)
			append(&card.fields, Field{"Movement", budget})
		}
		append(&out.cards, card)
	}

	// Take cached slices
	out.caches = {}
	pathfind_cache_get(&out.caches[.Pathfind_Land], .Land)
	pathfind_cache_get(&out.caches[.Pathfind_Sea], .Sea)
}

// The colour of a region with no capital, or whose capital belongs to no faction, and of every region when muted
@(private = "file")
REGION_UNHELD_COLOR :: [4]f32{0.6, 0.6, 0.6, 1}

// How much each region's identity hue turns from the one before: the golden ratio of a turn, so hues of nearby ids stay
// apart
@(private = "file")
REGION_HUE_STEP :: 0.618034
// How saturated and how light identity colours are: muted pigments, light enough to tint the map
@(private = "file")
REGION_SATURATION :: 0.55
@(private = "file")
REGION_VALUE :: 0.75

// A region's own colour, apart from its neighbours'
@(private = "file")
region_identity_color :: proc(id: Region_Id) -> [4]f32 {
	hue := math.mod(f32(id) * REGION_HUE_STEP, 1) * 6
	// Each channel's distance round the hue circle from where it is strongest, as HSV has it
	channel :: proc(hue, offset: f32) -> f32 {
		k := math.mod(offset + hue, 6)
		return REGION_VALUE - REGION_VALUE * REGION_SATURATION * max(0, min(k, 4 - k, 1))
	}
	return {channel(hue, 5), channel(hue, 3), channel(hue, 1), 1}
}

// The player controls the piece
@(private = "file")
piece_controlled :: proc(piece: Piece) -> bool {
	return faction_get(piece.owner) != nil && piece.owner == WORLD.player
}

// What each icon shows, as the cards call it. Words for the player, so they belong with the cards' other words; they
// leave with them once the game writes the cards.
@(private = "file", rodata)
ICON_TITLES := [Icon]string {
	.Village    = "Village",
	.Town       = "Town",
	.City       = "City",
	.Large_City = "Large City",
	.Army       = "Army",
	.Fleet      = "Fleet",
	.Priest     = "Priest",
	.Envoy      = "Envoy",
}

// The name of a living faction, as a view into the world
@(private = "file")
faction_name :: proc(id: Faction_Id) -> string {
	return string(WORLD.faction_names[id.index][:])
}
