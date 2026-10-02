#+private
package sim

import "core:fmt"
import "core:math"

import "../span"
import "../util"

// Area slots, in drawing order
REACH_AREA :: 0
FRIEND_AREA :: 1
ZONE_AREA :: 2
// Indices into the game's area palette
REACH_LOOK :: 1
ZONE_LOOK :: 2
OTHER_REACH_LOOK :: 3
FRIEND_LOOK :: 4

// Regions with no owner, and all regions when Muted
@(private = "file")
REGION_UNHELD_COLOR :: [4]f32{0.6, 0.6, 0.6, 1}

// Golden ratio, so hues of nearby ids stay apart
@(private = "file")
REGION_HUE_STEP :: 0.618034
@(private = "file")
REGION_SATURATION :: 0.55
@(private = "file")
REGION_VALUE :: 0.75

@(private = "file", rodata)
ICON_TITLES := [Icon]string {
	.Village    = "Village",
	.Town       = "Town",
	.City       = "City",
	.Large_City = "Large City",
	.Army       = "Army",
	.Fleet      = "Fleet",
}

world_present :: proc(
	focus: Piece_Id,
	pointed: Region_Id,
	region_colouring: Region_Colouring_Mode,
	out: ^Scene,
) {
	mov := &WORLD.movement
	ordering := ordering()

	// Supply map (only when rebuilt)
	if out.supply_map_revision != WORLD.supply_map_revision {
		out.supply_map_revision = WORLD.supply_map_revision
		out.supply_map = WORLD.supply_map
	}

	// Ground (only when the atlas changed)
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

	// Pawns
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
		if ordering != {} && piece.owner == ordering do pawn.flags += {.Controlled}
		append(&out.pawns, pawn)
	}

	// Walk arrow
	clear(&out.arrows)
	clear(&out.arrow_points)
	if walker := piece_get(mov.subject); walker != nil {
		begin := len(out.arrow_points)
		append(&out.arrow_points, walker.pos)
		append(&out.arrow_points, ..mov.path[mov.next:])
		append(&out.arrows, span.from_range(begin, len(out.arrow_points)))
	}

	// Reach and zones of the focus (hidden while it walks)
	flood := &mov.flood
	shown := mov.flood_subject != {} && mov.flood_subject != mov.subject
	// Flood key doubles as the areas' revision
	revision := shown ? mov.flood_key : 0
	reach := &out.areas[REACH_AREA]
	if reach.revision != revision {
		reach.revision, reach.cells = revision, {}
		reach.on_water, reach.corner = flood.domain != .Land, flood.corner
		if shown do for cost, i in flood.cost do reach.cells[i] = cost != math.INF_F32
	}
	reach.look = OTHER_REACH_LOOK
	if piece := piece_get(focus); piece != nil && ordering != {} && piece.owner == ordering {
		reach.look = REACH_LOOK
	}
	clear(&out.circles)
	for slot in 0 ..< 2 {
		area := &out.areas[FRIEND_AREA + slot]
		area.revision = revision
		area.look = slot == 0 ? FRIEND_LOOK : ZONE_LOOK
		area.on_water = flood.domain != .Land
		begin := len(out.circles)
		count := slot == 0 ? len(mov.friend_zones) : len(mov.enemy_zones)
		for i in 0 ..< count {
			disc := slot == 0 ? mov.friend_zones[i] : mov.enemy_zones[i].disc
			if shown && len(out.circles) < CIRCLES_MAX do append(&out.circles, Circle{disc.center, disc.radius})
		}
		area.circles = span.from_range(begin, len(out.circles))
	}

	// Regions
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
		append(
			&out.regions,
			Region{name = string(name[:]), color = color, highlighted = highlighted},
		)
	}

	// Cards
	clear(&out.cards)
	status := Card {
		place = .Status,
		title = fmt.tprintf("Turn %d", WORLD.turn),
	}
	player := faction_get(WORLD.player)
	append(&status.fields, Field{label = "Playing", value = player != nil ? faction_name(WORLD.player) : "None"})
	append(
		&status.actions,
		Action{label = "End turn", ask = .End_Turn, enabled = turn_endable()},
	)
	append(&out.cards, status)
	if piece := piece_get(focus); piece != nil {
		card := Card {
			place   = .Focus,
			title   = piece_title(focus),
			picture = Picture{piece.icon, piece.culture},
		}
		append(&card.fields, Field{label = "Type", value = ICON_TITLES[piece.icon]})
		faction := faction_get(piece.owner)
		append(&card.fields, Field{label = "Faction", value = faction != nil ? faction_name(piece.owner) : "None"})
		append(&card.fields, Field{label = "Culture", value = fmt.tprintf("%v", piece.culture)})
		if character_get(piece.general) != nil {
			append(&card.fields, Field{label = "General", value = string(WORLD.character_names[piece.general.index][:])})
		}
		army := WORLD.armies[focus.index]
		if army.active do append(&card.fields, Field{label = "Baggage", value = fmt.tprintf("%.0f turns", army.baggage)})
		if piece.movement_domain != nil {
			budget := fmt.tprintf(
				"%s of %s",
				util.format_compact(f64(movement_budget(piece^))),
				util.format_compact(f64(piece.movement_per_turn)),
			)
			append(&card.stats, Field{label = "Movement", value = budget})
		}
		if army.active {
			strength := fmt.tprintf(
				"%s of %s",
				util.format_compact(f64(army.strength_current)),
				util.format_compact(f64(army.strength_max)),
			)
			append(&card.stats, Field{label = "Strength", value = strength})
			append(&card.stats, Field{label = "Proficiency", value = fmt.tprintf("%.0f%%", army.proficiency)})
			append(&card.stats, Field{label = "Readiness", value = fmt.tprintf("%.0f%%", army.readiness)})
			supply: f32 = army.baggage > 0 ? 100 * army.stock / army.baggage : 0
			append(&card.stats, Field{label = "Supply", value = fmt.tprintf("%.0f%%", supply)})
			stock := fmt.tprintf("%.1f (%+.1f)", army.stock, army.resupply)
			append(&card.stats, Field{label = "Stock", value = stock})
			efficiency := fmt.tprintf("%.0f%%", 100 * army.resupply_efficiency)
			append(&card.stats, Field{label = "Efficiency", value = efficiency})
		}
		append(&out.cards, card)
	}
	open := WORLD.interaction
	if actor, met := piece_get(open.actor), piece_get(open.target); actor != nil && met != nil {
		card := Card {
			place   = .Interaction,
			title   = piece_title(open.target),
			picture = Picture{met.icon, met.culture},
		}
		append(&card.fields, Field{label = "Met by", value = piece_title(open.actor)})
		faction := faction_get(met.owner)
		append(&card.fields, Field{label = "Faction", value = faction != nil ? faction_name(met.owner) : "None"})
		append(
			&card.actions,
			Action{label = "Conquer", ask = .Conquer, enabled = open.conquerable},
		)
		append(
			&card.actions,
			Action{label = "Back", ask = .Leave_Interaction, enabled = true},
		)
		append(&out.cards, card)
	}

	// Caches
	out.caches = {}
	pathfind_cache_get(&out.caches[.Pathfind_Land], .Land)
	pathfind_cache_get(&out.caches[.Pathfind_Sea], .Sea)
}

@(private = "file")
region_identity_color :: proc(id: Region_Id) -> [4]f32 {
	hue := math.mod(f32(id) * REGION_HUE_STEP, 1) * 6
	// HSV to RGB
	channel :: proc(hue, offset: f32) -> f32 {
		k := math.mod(offset + hue, 6)
		return REGION_VALUE - REGION_VALUE * REGION_SATURATION * max(0, min(k, 4 - k, 1))
	}
	return {channel(hue, 5), channel(hue, 3), channel(hue, 1), 1}
}

// Name, or icon title if unnamed. Piece must be alive.
@(private = "file")
piece_title :: proc(id: Piece_Id) -> string {
	name := WORLD.piece_names[id.index][:]
	return len(name) > 0 ? string(name) : ICON_TITLES[WORLD.pieces[id.index].icon]
}

// Faction must be alive
@(private = "file")
faction_name :: proc(id: Faction_Id) -> string {
	return string(WORLD.faction_names[id.index][:])
}

