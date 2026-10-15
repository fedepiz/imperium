#+private
package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:slice"
import tbl "tabula"

AI_ARMIES_MAX :: FLOOD_QUESTIONS_MAX
AI_GOALS_MAX :: 256
AI_PLANS_MAX :: 1024

// From ai.txt
AI_Weights :: struct {
	coin:       f32,
	food:       f32,
	distance:   f32,
	continuity: f32,
	give_up:    f32,
	strike:     f32,
	runs:       int,
}

AI_Template :: enum u8 {
	Take,
}

// The pieces a template's goals are about
AI_Targets :: struct {
	flags: bit_set[Piece_Flag],
	enemy: bool,
}

@(rodata)
AI_TEMPLATES := [AI_Template]AI_Targets {
	.Take = {flags = {.Capturable}, enemy = true},
}

AI_Value_Term :: enum u8 {
	Coin,
	Food,
}

AI_Goal :: struct {
	template:    AI_Template,
	target:      Piece_Id,
	value_terms: [AI_Value_Term]f32,
	value:       f32,
}

// A field army of the side. Army a asks flood question floods_first + a
AI_Army :: struct {
	piece: Piece_Id,
	// Moved or fought this turn: no more orders
	acted: bool,
}

AI_Plan_Rule :: enum u8 {
	Give_Up,
	Strike,
	Approach,
}

AI_Score_Term :: enum u8 {
	Value,
	Odds,
	Distance,
	Continuity,
}

// Given_Up: not scored
AI_Selection :: enum u8 {
	Given_Up,
	Chosen,
	Not_Worth,
	Goal_Taken,
	Army_Taken,
}

// One army toward one goal. Plan p asks move question moves_first + p and battle question battles_first + p
AI_Plan :: struct {
	goal:        int,
	army:        int,
	kept:        bool,
	// In movement. INF: no way
	distance:    f32,
	// This turn, and the odds of winning as it would arrive; then the odds rested
	reached:     bool,
	strike_odds: f32,
	rested_odds: f32,
	rule:        AI_Plan_Rule,
	terms:       [AI_Score_Term]f32,
	score:       f32,
	selection:   AI_Selection,
}

AI_Plan_Key :: struct {
	template: AI_Template,
	target:   Piece_Id,
	army:     Piece_Id,
}

AI_Rule :: enum u8 {
	None,
	Read_Report,
	Appoint,
	// Asked its questions: decides at the next step
	Ask,
	Act,
	// Nothing more to order this turn
	Wait,
}

// What one think asked and decided
AI_Think :: struct {
	asked_for:     Faction_Id,
	armies:        [dynamic; AI_ARMIES_MAX]AI_Army,
	goals:         [dynamic; AI_GOALS_MAX]AI_Goal,
	plans:         [dynamic; AI_PLANS_MAX]AI_Plan,
	// Where its questions begin in the batch
	moves_first:   int,
	battles_first: int,
	floods_first:  int,
	// The plan ordered. -1: none
	acting:        int,
}

// Plays one side's turn, one order at a time. Ending it is the player's
Game_AI :: struct {
	weights: AI_Weights,
	// The side it plays until its turn ends. 0: none
	side:    Faction_Id,
	// The last decision
	rule:    AI_Rule,
	order:   Game_Order,
	// The decided one is shown while the other is asked
	thinks:  [2]AI_Think,
	decided: int,
	// Chosen at the last think
	kept:    [dynamic; AI_ARMIES_MAX]AI_Plan_Key,
	// Ordered since it started on the side
	ordered: [dynamic; AI_ARMIES_MAX]AI_Plan_Key,
}

ai_load :: proc(ai: ^Game_AI, scenario_name: string) {
	root, path := scenario_file(scenario_name, "ai.txt")
	fmt.assertf(len(root.children) == 1 && root.children[0].key == "ai", "%s: one ai record expected", path)
	row := root.children[0]
	row_check(row, AI_Weights, path, {}, {"coin", "food", "distance", "continuity", "give_up", "strike", "runs"})
	ai.weights = {
		coin       = tbl.get_num(row, "coin"),
		food       = tbl.get_num(row, "food"),
		distance   = tbl.get_num(row, "distance"),
		continuity = tbl.get_num(row, "continuity"),
		give_up    = tbl.get_num(row, "give_up"),
		strike     = tbl.get_num(row, "strike"),
		runs       = int(tbl.get_num(row, "runs")),
	}
}

// Ask: wants its questions answered by the coming step, through ai_ask
ai_decide :: proc(ai: ^Game_AI, game: ^Game, questions: ^Game_Questions) {
	w := &ai.weights
	think := &ai.thinks[1 - ai.decided]
	vacancy := &game.appointment
	ai.order = nil
	switch {
	case game.interaction.actor != {}:
		ai.rule = .Read_Report
		ai.order = Next_Order{}
		return
	case vacancy.office != {} && vacancy.can_appoint && len(vacancy.candidates) > 0:
		ai.rule = .Appoint
		ai.order = Appoint_Order{vacancy.office, vacancy.candidates[0].character}
		return
	case ai.rule == .Wait:
		return
	case ai.rule != .Ask:
		ai.rule = .Ask
		return
	}

	// Phase: Distances. Each army's flood to the sites it reaches, then through the sites
	through := make([][SITES_MAX]f32, len(think.armies), context.temp_allocator)
	for _, a in think.armies do sites_distance(game, &questions.floods[think.floods_first + a].sites, &through[a])

	// Phase: Program. Each plan's, top down: the first rule that holds
	for &plan, p in think.plans {
		target := slot_map_get(&game.pieces, think.goals[plan.goal].target)
		move := &questions.moves[think.moves_first + p]
		rested := &questions.battles[think.battles_first + p].outcomes
		plan.distance = math.INF_F32
		if target == nil {
			plan.rule = .Give_Up
			continue
		}
		if site := field_sample_nearest(&game.site_graph.cell_site, target.pos); site != 0 {
			plan.distance = through[plan.army][site] + field_sample_nearest(&game.site_graph.cell_distance, target.pos)
		}
		plan.reached = move.refusal == nil
		plan.strike_odds = move.outcomes[.Clear_Win] + move.outcomes[.Close_Win]
		plan.rested_odds = rested[.Clear_Win] + rested[.Close_Win]
		switch {
		case plan.distance == math.INF_F32 || plan.rested_odds < w.give_up:
			plan.rule = .Give_Up
		case plan.reached && plan.strike_odds >= w.strike:
			plan.rule = .Strike
		case:
			plan.rule = .Approach
		}
	}

	// Phase: Score. The value at the rested odds, less the way there, plus keeping to a plan chosen before
	for &plan in think.plans {
		if plan.rule == .Give_Up do continue
		value := think.goals[plan.goal].value
		plan.terms = {
			.Value      = value,
			.Odds       = value * (plan.rested_odds - 1),
			.Distance   = -plan.distance * w.distance,
			.Continuity = plan.kept ? w.continuity : 0,
		}
		for term in plan.terms do plan.score += term
	}

	// Phase: Select. Best first: a goal takes one army, an army one goal
	Ranked :: struct {
		score: f32,
		plan:  int,
	}
	ranked := make([dynamic]Ranked, 0, len(think.plans), context.temp_allocator)
	for plan, p in think.plans do if plan.rule != .Give_Up do append(&ranked, Ranked{plan.score, p})
	slice.sort_by(ranked[:], proc(a, b: Ranked) -> bool {return a.score > b.score})
	goal_taken := make([]bool, len(think.goals), context.temp_allocator)
	army_taken := make([]bool, len(think.armies), context.temp_allocator)
	clear(&ai.kept)
	for entry in ranked {
		plan := &think.plans[entry.plan]
		switch {
		case plan.score <= 0:
			plan.selection = .Not_Worth
		case goal_taken[plan.goal]:
			plan.selection = .Goal_Taken
		case army_taken[plan.army]:
			plan.selection = .Army_Taken
		case:
			plan.selection = .Chosen
			goal_taken[plan.goal] = true
			army_taken[plan.army] = true
			goal := &think.goals[plan.goal]
			append(&ai.kept, AI_Plan_Key{goal.template, goal.target, think.armies[plan.army].piece})
		}
	}

	// Phase: Act. The best chosen plan with an order for an army that has not acted. Approach: toward the site its
	// flood reaches nearest the target through the sites, to the reachable spot outside enemy zones nearest that site
	ai.rule = .Wait
	think.acting = -1
	box := [2]int{PATHFIND_FLOOD_SIZE, PATHFIND_FLOOD_SIZE}
	for entry in ranked {
		plan := &think.plans[entry.plan]
		army := &think.armies[plan.army]
		if plan.selection != .Chosen || army.acted do continue
		goal := &think.goals[plan.goal]
		switch plan.rule {
		case .Give_Up:
		case .Strike:
			ai.order = Move_Order{piece = army.piece, target = goal.target}
		case .Approach:
			piece := slot_map_get(&game.pieces, army.piece)
			target := slot_map_get(&game.pieces, goal.target)
			flood := &questions.floods[think.floods_first + plan.army]
			from_target: [SITES_MAX]f32
			for &site in from_target do site = math.INF_F32
			from_target[field_sample_nearest(&game.site_graph.cell_site, target.pos)] = 0
			sites_distance(game, &from_target, &from_target)
			toward, nearest := target.pos, math.INF_F32
			for cost, s in flood.sites {
				if cost == math.INF_F32 || from_target[s] >= nearest do continue
				toward, nearest = game.sites[s], from_target[s]
			}
			spot, closest := -1, math.INF_F32
			for cost, i in flood.cost {
				if cost > piece.this_turn.movement_left do continue
				at := cell_center(flood.corner + grid_pos(i, box))
				if field_sample_nearest(&game.zones, at) != 0 || linalg.distance(at, toward) >= closest do continue
				spot, closest = i, linalg.distance(at, toward)
			}
			if spot >= 0 && flood.corner + grid_pos(spot, box) != cell_of(piece.pos) {
				ai.order = Move_Order{piece = army.piece, destination = cell_center(flood.corner + grid_pos(spot, box)), snap = 1}
			}
		}
		if ai.order != nil {
			ai.rule = .Act
			think.acting = entry.plan
			append(&ai.ordered, AI_Plan_Key{goal.template, goal.target, army.piece})
			break
		}
	}
	ai.decided = 1 - ai.decided
}

// Its armies, its goals and their plans, with the questions they ask, added to the batch
ai_ask :: proc(ai: ^Game_AI, game: ^Game, questions: ^Game_Questions) {
	w := &ai.weights
	think := &ai.thinks[1 - ai.decided]
	me := game.player
	clear(&think.armies)
	clear(&think.goals)
	clear(&think.plans)
	think.asked_for = me
	think.moves_first = len(questions.moves)
	think.battles_first = len(questions.battles)
	think.floods_first = len(questions.floods)

	// Phase: Armies. The side's field armies, each asking its flood
	{
		it := slot_map_iterator(&game.pieces)
		for piece, id in slot_map_iterate(&it) {
			if piece.owner != me || .Has_Army not_in piece.flags || piece.domain == nil do continue
			acted := piece.this_turn.moved_land || piece.this_turn.moved_sea || piece.this_turn.fought
			if append(&think.armies, AI_Army{piece = id, acted = acted}) == 0 do break
			append(&questions.floods, Flood_Question{army = id})
		}
	}

	// Phase: Goals. Each template's targets, with what they make a turn
	for targets, template in AI_TEMPLATES {
		it := slot_map_iterator(&game.pieces)
		for piece, id in slot_map_iterate(&it) {
			if targets.flags - piece.flags != {} || (piece.owner != me) != targets.enemy do continue
			goal := AI_Goal {
				template = template,
				target = id,
				value_terms = {.Coin = (piece.town.income + piece.town.wealth) * w.coin, .Food = piece.town.food * w.food},
			}
			for term in goal.value_terms do goal.value += term
			if append(&think.goals, goal) == 0 do break
		}
	}

	// Phase: Plans. Each army toward each goal, asking its move onto the target and its battle rested
	plans: for goal, g in think.goals {
		for army, a in think.armies {
			kept := slice.contains(ai.kept[:], AI_Plan_Key{goal.template, goal.target, army.piece})
			if append(&think.plans, AI_Plan{goal = g, army = a, kept = kept}) == 0 do break plans
			append(&questions.moves, Move_Question{order = {piece = army.piece, target = goal.target}, runs = w.runs})
			append(&questions.battles, Battle_Question{attacker = army.piece, defender = goal.target, runs = w.runs})
		}
	}
}
