package sim

import "core:math"

// Battle: one attacker against one defender, resolved from a copy of both sides. Pure: reads nothing but the Battle
// it is given, and its own dice from battle.seed.

// Constants -----------------------------------------------------------------------------------------------------------

// 2d6 is continuous: each die uniform on [0.5, 6.5)

// Numbers bonus = clamp(NUMBERS_SCALE × log2(own men / enemy men), 0, NUMBERS_MAX)
NUMBERS_SCALE :: 1.5
NUMBERS_MAX :: 2

// Avoiding battle and pursuing: 2d6 + MOBILITY_BONUS × (own mobility − other's) ≥ MOBILITY_TARGET
MOBILITY_BONUS :: 2
MOBILITY_TARGET :: 8

// Onset margin: below ONSET_TIE a tie, from ONSET_ROUT_MARGIN a rout, else the winner's edge is margin ×
// EDGE_PER_MARGIN
ONSET_TIE :: 0.5
ONSET_ROUT_MARGIN :: 7
EDGE_PER_MARGIN :: 0.5
// A probing side pulls out after the onset when its edge is this far behind or worse
PROBE_PULL_OUT :: -2
// Added to a crisis roll when committing
COMMIT_BONUS :: 1
// Crisis margins, at most: STALEMATE a stalemate, DEFEAT a defeat, HEAVY a heavy defeat; beyond, a rout
CRISIS_STALEMATE :: 2
CRISIS_DEFEAT :: 5
CRISIS_HEAVY :: 8

// Cohesion check: only when readiness < COHESION_READINESS or men < COHESION_MEN % of men_max. Passes when 2d6 +
// proficiency / 10 − (COHESION_READINESS − readiness) / 10 − (COHESION_MEN − men %) / 10 ≥ COHESION_TARGET, each
// subtracted part from 0. Before any pursuit.
COHESION_READINESS :: 25
COHESION_MEN :: 30
COHESION_TARGET :: 10

// Readiness lost by a defender that avoids battle
AVOID_READINESS :: 5

// Temperaments -------------------------------------------------------------------------------------------------------

Temperament :: enum u8 {
	Bold,
	Steady,
	Cautious,
	Cunning,
}

// Attacks when own strength − enemy strength + initiative ≥ 0
TEMPERAMENT_ATTACK_INITIATIVE := [Temperament]f32 {
	.Bold     = 1,
	.Steady   = 0,
	.Cautious = -2,
	.Cunning  = 0,
}
// As defender, tries to avoid battle when own strength − enemy strength < this (−inf: never)
TEMPERAMENT_AVOID_BELOW := [Temperament]f32 {
	.Bold     = math.NEG_INF_F32,
	.Steady   = 0,
	.Cautious = 1,
	.Cunning  = 1,
}
TEMPERAMENT_POSTURE := [Battle_Role][Temperament]Posture {
	.Attacker = {.Bold = .Press, .Steady = .Standard, .Cautious = .Probe, .Cunning = .Standard},
	.Defender = {.Bold = .Press, .Steady = .Standard, .Cautious = .Probe, .Cunning = .Press},
}
// Crisis: commits when edge > COMMIT_ABOVE, breaks off when edge ≤ BREAK_OFF_AT, holds otherwise
TEMPERAMENT_COMMIT_ABOVE := [Temperament]f32 {
	.Bold     = math.NEG_INF_F32,
	.Steady   = 0,
	.Cautious = math.INF_F32,
	.Cunning  = 0,
}
TEMPERAMENT_BREAK_OFF_AT := [Temperament]f32 {
	.Bold     = math.NEG_INF_F32,
	.Steady   = -2,
	.Cautious = -2,
	.Cunning  = -2,
}
// Least severity at which the winner advances, and pursues (4: never)
TEMPERAMENT_ADVANCE_FROM := [Temperament]int {
	.Bold     = 0,
	.Steady   = 1,
	.Cautious = 3,
	.Cunning  = 0,
}
TEMPERAMENT_PURSUE_FROM := [Temperament]int {
	.Bold     = 2,
	.Steady   = 3,
	.Cautious = 4,
	.Cunning  = 2,
}
// Movement points a winner marches beyond its budget to follow
TEMPERAMENT_FOLLOW_OVERDRAW := [Temperament]f32 {
	.Bold     = 0,
	.Steady   = 0,
	.Cautious = 0,
	.Cunning  = 0,
}

// Postures -----------------------------------------------------------------------------------------------------------

Posture :: enum u8 {
	Press,
	Standard,
	Probe,
}

POSTURE_ONSET := [Posture]f32 {
	.Press    = 1,
	.Standard = 0,
	.Probe    = -1,
}
POSTURE_CRISIS := [Posture]f32 {
	.Press    = -1,
	.Standard = 0,
	.Probe    = 0,
}
// Can't be routed at the onset, and pulls out when behind after it
POSTURE_PROBES := bit_set[Posture]{.Probe}
// Losing the crisis is one step worse
POSTURE_WORSENS := bit_set[Posture]{.Press}

Crisis_Choice :: enum u8 {
	Hold,
	Commit,
	Break_Off,
}

// Outcomes -----------------------------------------------------------------------------------------------------------

Battle_Outcome :: enum u8 {
	// The defender got away; no battle
	Avoided,
	Stalemate,
	// The prober pulled out; the other holds the field
	Probed,
	// The defender broke off
	Withdrew,
	// The attacker broke off
	Repulsed,
	Defeat,
	Heavy_Defeat,
	Rout,
}

// How bad for the loser
OUTCOME_SEVERITY := [Battle_Outcome]int {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0,
	.Withdrew     = 0,
	.Repulsed     = 0,
	.Defeat       = 1,
	.Heavy_Defeat = 2,
	.Rout         = 3,
}
// One step worse, for a loser that committed or pressed
OUTCOME_WORSE := [Battle_Outcome]Battle_Outcome {
	.Avoided      = .Avoided,
	.Stalemate    = .Stalemate,
	.Probed       = .Probed,
	.Withdrew     = .Withdrew,
	.Repulsed     = .Repulsed,
	.Defeat       = .Heavy_Defeat,
	.Heavy_Defeat = .Rout,
	.Rout         = .Rout,
}
// There's a winner (Avoided and Stalemate have none)
OUTCOME_DECIDED := bit_set[Battle_Outcome] {
	.Probed,
	.Withdrew,
	.Repulsed,
	.Defeat,
	.Heavy_Defeat,
	.Rout,
}
// The loser falls back and the winner may advance (Avoided: the attacker is the winner)
OUTCOME_RETREATS := bit_set[Battle_Outcome] {
	.Avoided,
	.Probed,
	.Withdrew,
	.Repulsed,
	.Defeat,
	.Heavy_Defeat,
	.Rout,
}
// The winner may pursue
OUTCOME_PURSUABLE := bit_set[Battle_Outcome]{.Heavy_Defeat, .Rout}

// Losses by outcome. Men: share of the smaller side's men. Readiness: points. Stock: turns of supply. With no winner,
// the loser row is the defender (Avoided) or both sides (Stalemate).
OUTCOME_MEN_LOST := [Battle_Role_Result][Battle_Outcome]f32 {
	.Loser = {
		.Avoided = 0,
		.Stalemate = 0.05,
		.Probed = 0.04,
		.Withdrew = 0.06,
		.Repulsed = 0.08,
		.Defeat = 0.15,
		.Heavy_Defeat = 0.25,
		.Rout = 0.40,
	},
	.Winner = {
		.Avoided = 0,
		.Stalemate = 0.05,
		.Probed = 0.02,
		.Withdrew = 0.03,
		.Repulsed = 0.03,
		.Defeat = 0.05,
		.Heavy_Defeat = 0.05,
		.Rout = 0.03,
	},
}
OUTCOME_READINESS := [Battle_Role_Result][Battle_Outcome]f32 {
	.Loser = {
		.Avoided = -AVOID_READINESS,
		.Stalemate = -10,
		.Probed = -10,
		.Withdrew = -15,
		.Repulsed = -20,
		.Defeat = -25,
		.Heavy_Defeat = -35,
		.Rout = -50,
	},
	.Winner = {
		.Avoided = 0,
		.Stalemate = -10,
		.Probed = -5,
		.Withdrew = -5,
		.Repulsed = -5,
		.Defeat = -10,
		.Heavy_Defeat = -10,
		.Rout = -5,
	},
}
// Loser only: small for a controlled defeat, big for a rout
OUTCOME_STOCK_LOST := [Battle_Outcome]f32 {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0.1,
	.Withdrew     = 0.2,
	.Repulsed     = 0.2,
	.Defeat       = 0.5,
	.Heavy_Defeat = 1,
	.Rout         = 2,
}
// Share of the loser's lost supply the winner captures (its baggage train)
OUTCOME_STOCK_CAPTURED := [Battle_Outcome]f32 {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0,
	.Withdrew     = 0,
	.Repulsed     = 0,
	.Defeat       = 0.2,
	.Heavy_Defeat = 0.4,
	.Rout         = 0.6,
}
// Loser caught by pursuit: share of its men left
OUTCOME_PURSUIT_MEN := [Battle_Outcome]f32 {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0,
	.Withdrew     = 0,
	.Repulsed     = 0,
	.Defeat       = 0,
	.Heavy_Defeat = 0.10,
	.Rout         = 0.15,
}
PURSUIT_READINESS :: -10

// Types --------------------------------------------------------------------------------------------------------------

Battle_Role :: enum u8 {
	Attacker,
	Defender,
}

OTHER_ROLE := [Battle_Role]Battle_Role {
	.Attacker = .Defender,
	.Defender = .Attacker,
}

// A side's roll, in a margin
ROLE_FACTORS := [Battle_Role]Factor_Kind {
	.Attacker = .Attacker,
	.Defender = .Defender,
}

Battle_Role_Result :: enum u8 {
	Loser,
	Winner,
}

// The winner's move once the loser falls back
Follow :: enum u8 {
	Stay,
	// To where the loser stood
	Advance,
	// Advances, or on a catch follows the loser
	Pursue,
}

// One side, copied in from its army
Battle_Side :: struct {
	men:         f32,
	men_max:     f32,
	proficiency: f32,
	readiness:   f32,
	// Turns of supply carried, and the most it can carry
	stock:       f32,
	baggage:     f32,
	// 1..4
	mobility:    f32,
	temperament: Temperament,
}

Battle :: struct {
	sides:     [Battle_Role]Battle_Side,
	// Added to the defender's rolls: terrain, a prepared position
	ground:    f32,
	can_avoid: bool,
	// All dice come from this
	seed:      u64,
}

// What happened to one side. Changes are deltas, to apply to its army.
Battle_Side_Result :: struct {
	posture:           Posture,
	choice:            Crisis_Choice,
	// Won at the onset; empty for the other side
	edge:              Tally,
	// Changes to apply to its army
	men:               Tally,
	readiness:         f32,
	stock:             Tally,
	// Caught by pursuit: further losses
	pursuit_men:       Tally,
	pursuit_readiness: f32,
	// Failed the cohesion check: the army is gone
	dissolved:         bool,
	// Falls back or retreats after the battle
	falls_back:        bool,
	// Going in
	power:             Tally,
	// Rolls; cohesion is against COHESION_TARGET
	onset:             Tally,
	crisis:            Tally,
	cohesion:          Tally,
}

TALLY_FACTORS_MAX :: 20

// What a derived number is made of
Factor_Kind :: enum u8 {
	// The 2d6
	Dice,
	Proficiency,
	// What low readiness costs
	Readiness,
	Numbers,
	Posture,
	Ground,
	Edge,
	Commit,
	// MOBILITY_BONUS × (own mobility − the other's)
	Mobility,
	// Men below COHESION_MEN %
	Losses,
	// A side's roll, in a margin
	Attacker,
	Defender,
	Margin,
	// The smaller side's men
	Engaged,
	Share,
	// Supply lost by the outcome, and what wasn't carried of it
	Lost,
	Carried,
	// The loser's men over the winner's
	Men_Ratio,
	// Room left in the winner's baggage
	Baggage,
	// The loser's men after the battle
	Men_Left,
}

Factor_Op :: enum u8 {
	Add,
	// Multiplies the total so far
	Scale,
}

Factor :: struct {
	kind:  Factor_Kind,
	op:    Factor_Op,
	value: f32,
}

// A derived number and what it is made of. A roll is a tally starting with the dice; empty = not rolled.
Tally :: struct {
	// Added zeros left out, other than the dice
	factors: [dynamic; TALLY_FACTORS_MAX]Factor,
	total:   f32,
}

Battle_Result :: struct {
	outcome:       Battle_Outcome,
	// Valid when outcome in OUTCOME_RETREATS
	winner:        Battle_Role,
	sides:         [Battle_Role]Battle_Side_Result,
	// The side ahead's total minus the other's
	onset_margin:  Tally,
	crisis_margin: Tally,
	follow:        Follow,
	// The pursuit caught the loser
	caught:        bool,
	// Rolls against MOBILITY_TARGET: the defender's attempt to get away, and the winner's chase
	avoid:         Tally,
	pursuit:       Tally,
	// A prober pulled out after the onset
	pulled_out:    bool,
	// Both chose in the crisis (it wasn't decided before)
	crisis_chosen: bool,
	// The loser's commitment or pressing made the result one step worse
	worsened:      bool,
}

// Resolve ------------------------------------------------------------------------------------------------------------

// Proficiency, minus what low readiness costs it, plus the bonus for outnumbering other. Commanders weigh battles by
// its total.
battle_power :: proc(side, other: Battle_Side) -> (power: Tally) {
	proficiency := side.proficiency / 10
	tally_add(&power, .Proficiency, proficiency)
	tally_add(&power, .Readiness, -proficiency * (0.5 - side.readiness / 200))
	ratio := other.men > 0 ? side.men / other.men : 1
	tally_add(&power, .Numbers, clamp(NUMBERS_SCALE * math.log2(max(ratio, 1e-6)), 0, NUMBERS_MAX))
	return
}

battle_strength :: proc(side, other: Battle_Side) -> f32 {
	power := battle_power(side, other)
	return power.total
}

tally_add :: proc(tally: ^Tally, kind: Factor_Kind, value: f32) {
	tally.total += value
	if value != 0 || kind == .Dice do append(&tally.factors, Factor{kind, .Add, value})
}

tally_scale :: proc(tally: ^Tally, kind: Factor_Kind, value: f32) {
	tally.total *= value
	append(&tally.factors, Factor{kind, .Scale, value})
}

// The ahead side's total minus the other's
@(private = "file")
margin_of :: proc(totals: [Battle_Role]f32, ahead: Battle_Role) -> (margin: Tally) {
	behind := OTHER_ROLE[ahead]
	tally_add(&margin, ROLE_FACTORS[ahead], totals[ahead])
	tally_add(&margin, ROLE_FACTORS[behind], -totals[behind])
	return
}

combat_resolve :: proc(battle: Battle) -> (result: Battle_Result) {
	rng := battle.seed
	roll_2d6 :: proc(rng: ^u64) -> f32 {
		// splitmix64
		next :: proc(rng: ^u64) -> u64 {
			rng^ += 0x9e3779b97f4a7c15
			z := rng^
			z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
			z = (z ~ (z >> 27)) * 0x94d049bb133111eb
			return z ~ (z >> 31)
		}
		// Top 24 bits: uniform on [0, 1)
		die :: proc(rng: ^u64) -> f32 {return 0.5 + 6 * f32(next(rng) >> 40) / (1 << 24)}
		return die(rng) + die(rng)
	}

	// Step: Power
	for side, role in battle.sides do result.sides[role].power = battle_power(side, battle.sides[OTHER_ROLE[role]])
	ground := [Battle_Role]f32 {
		.Attacker = 0,
		.Defender = battle.ground,
	}

	decided: bool
	loser: Battle_Role
	{
		// Step: Avoid
		defender := battle.sides[.Defender]
		attacker := battle.sides[.Attacker]
		gap := result.sides[.Defender].power.total - result.sides[.Attacker].power.total
		if battle.can_avoid && gap < TEMPERAMENT_AVOID_BELOW[defender.temperament] {
			roll := &result.avoid
			tally_add(roll, .Dice, roll_2d6(&rng))
			tally_add(roll, .Mobility, MOBILITY_BONUS * (defender.mobility - attacker.mobility))
			if roll.total >= MOBILITY_TARGET {
				result.outcome = .Avoided
				loser = .Defender
				decided = true
			}
		}
	}

	// Step: Posture
	for side, role in battle.sides do result.sides[role].posture = TEMPERAMENT_POSTURE[role][side.temperament]

	// Step: Onset
	if !decided {
		totals: [Battle_Role]f32
		for role in Battle_Role {
			side := &result.sides[role]
			roll := &side.onset
			tally_add(roll, .Dice, roll_2d6(&rng))
			for factor in side.power.factors do tally_add(roll, factor.kind, factor.value)
			tally_add(roll, .Posture, POSTURE_ONSET[side.posture])
			tally_add(roll, .Ground, ground[role])
			totals[role] = roll.total
		}
		ahead: Battle_Role = totals[.Attacker] > totals[.Defender] ? .Attacker : .Defender
		result.onset_margin = margin_of(totals, ahead)
		margin := result.onset_margin.total
		if margin >= ONSET_TIE {
			beaten := OTHER_ROLE[ahead]
			if margin >= ONSET_ROUT_MARGIN {
				result.outcome = result.sides[beaten].posture in POSTURE_PROBES ? .Probed : .Rout
				loser = beaten
				decided = true
			} else {
				edge := &result.sides[ahead].edge
				tally_add(edge, .Margin, margin)
				tally_scale(edge, .Share, EDGE_PER_MARGIN)
			}
		}
	}

	// Step: Probe pull-out (the attacker first if both)
	if !decided {
		for role in Battle_Role {
			behind := result.sides[role].edge.total - result.sides[OTHER_ROLE[role]].edge.total
			if result.sides[role].posture in POSTURE_PROBES && behind <= PROBE_PULL_OUT {
				result.outcome = .Probed
				result.pulled_out = true
				loser = role
				decided = true
				break
			}
		}
	}

	// Step: Crisis
	if !decided {
		result.crisis_chosen = true
		for side, role in battle.sides {
			e := result.sides[role].edge.total - result.sides[OTHER_ROLE[role]].edge.total
			choice := Crisis_Choice.Hold
			if e > TEMPERAMENT_COMMIT_ABOVE[side.temperament] do choice = .Commit
			if e <= TEMPERAMENT_BREAK_OFF_AT[side.temperament] do choice = .Break_Off
			result.sides[role].choice = choice
		}
		breaking := [Battle_Role]bool {
			.Attacker = result.sides[.Attacker].choice == .Break_Off,
			.Defender = result.sides[.Defender].choice == .Break_Off,
		}
		switch {
		case breaking[.Attacker] && breaking[.Defender]:
			result.outcome = .Stalemate
		case breaking[.Attacker]:
			result.outcome = .Repulsed
			loser = .Attacker
		case breaking[.Defender]:
			result.outcome = .Withdrew
			loser = .Defender
		case:
			totals: [Battle_Role]f32
			for role in Battle_Role {
				side := &result.sides[role]
				roll := &side.crisis
				tally_add(roll, .Dice, roll_2d6(&rng))
				for factor in side.power.factors do tally_add(roll, factor.kind, factor.value)
				tally_add(roll, .Edge, side.edge.total)
				tally_add(roll, .Commit, side.choice == .Commit ? COMMIT_BONUS : 0)
				tally_add(roll, .Posture, POSTURE_CRISIS[side.posture])
				tally_add(roll, .Ground, ground[role])
				totals[role] = roll.total
			}
			ahead: Battle_Role = totals[.Attacker] < totals[.Defender] ? .Defender : .Attacker
			result.crisis_margin = margin_of(totals, ahead)
			margin := result.crisis_margin.total
			loser = OTHER_ROLE[ahead]
			switch {
			case margin <= CRISIS_STALEMATE:
				result.outcome = .Stalemate
			case margin <= CRISIS_DEFEAT:
				result.outcome = .Defeat
			case margin <= CRISIS_HEAVY:
				result.outcome = .Heavy_Defeat
			case:
				result.outcome = .Rout
			}
			beaten := &result.sides[loser]
			if beaten.choice == .Commit || beaten.posture in POSTURE_WORSENS {
				result.worsened = OUTCOME_WORSE[result.outcome] != result.outcome
				result.outcome = OUTCOME_WORSE[result.outcome]
			}
		}
	}
	result.winner = OTHER_ROLE[loser]

	// Step: Aftermath. Without a winner, both sides take the loser row (Stalemate) or only the defender does
	// (Avoided).
	{
		outcome := result.outcome
		as_loser: [Battle_Role]bool
		as_loser[loser] = true
		as_loser[OTHER_ROLE[loser]] = outcome == .Stalemate
		engaged := min(battle.sides[.Attacker].men, battle.sides[.Defender].men)
		for role in Battle_Role {
			row: Battle_Role_Result = as_loser[role] ? .Loser : .Winner
			out := &result.sides[role]
			if share := OUTCOME_MEN_LOST[row][outcome]; share > 0 {
				tally_add(&out.men, .Engaged, -engaged)
				tally_scale(&out.men, .Share, share)
			}
			out.readiness = OUTCOME_READINESS[row][outcome]
			out.falls_back = as_loser[role] && outcome in OUTCOME_RETREATS
		}
		// Supply: the loser loses some; the winner captures a share, converted to its own men's turns
		beaten := battle.sides[loser]
		victor := battle.sides[result.winner]
		lost := &result.sides[loser].stock
		if table := OUTCOME_STOCK_LOST[outcome]; table > 0 {
			tally_add(lost, .Lost, -table)
			if beaten.stock < table do tally_add(lost, .Carried, table - beaten.stock)
		}
		if share := OUTCOME_STOCK_CAPTURED[outcome]; share > 0 && lost.total < 0 && victor.men > 0 {
			captured := &result.sides[result.winner].stock
			tally_add(captured, .Lost, -lost.total)
			tally_scale(captured, .Men_Ratio, beaten.men / victor.men)
			tally_scale(captured, .Share, share)
			room := victor.baggage - victor.stock
			if captured.total > room do tally_add(captured, .Baggage, room - captured.total)
		}
	}

	// Step: Cohesion
	for side, role in battle.sides {
		out := &result.sides[role]
		men := side.men + out.men.total
		readiness := clamp(side.readiness + out.readiness, 0, 100)
		men_percent: f32 = side.men_max > 0 ? 100 * men / side.men_max : 100
		if readiness >= COHESION_READINESS && men_percent >= COHESION_MEN do continue
		roll := &out.cohesion
		tally_add(roll, .Dice, roll_2d6(&rng))
		tally_add(roll, .Proficiency, side.proficiency / 10)
		tally_add(roll, .Readiness, -max(0, (COHESION_READINESS - readiness) / 10))
		tally_add(roll, .Losses, -max(0, (COHESION_MEN - men_percent) / 10))
		out.dissolved = roll.total < COHESION_TARGET
	}

	// Step: Follow. Nothing to follow when either side dissolved.
	{
		outcome := result.outcome
		standing := !result.sides[loser].dissolved && !result.sides[result.winner].dissolved
		can_advance := standing && outcome in OUTCOME_RETREATS
		can_pursue := standing && outcome in OUTCOME_PURSUABLE
		victor := battle.sides[result.winner]
		beaten := battle.sides[loser]
		severity := OUTCOME_SEVERITY[outcome]
		if can_advance && severity >= TEMPERAMENT_ADVANCE_FROM[victor.temperament] do result.follow = .Advance
		if can_pursue && severity >= TEMPERAMENT_PURSUE_FROM[victor.temperament] do result.follow = .Pursue
		if result.follow == .Pursue {
			roll := &result.pursuit
			tally_add(roll, .Dice, roll_2d6(&rng))
			tally_add(roll, .Mobility, MOBILITY_BONUS * (victor.mobility - beaten.mobility))
			if roll.total >= MOBILITY_TARGET {
				result.caught = true
				out := &result.sides[loser]
				tally_add(&out.pursuit_men, .Men_Left, -(beaten.men + out.men.total))
				tally_scale(&out.pursuit_men, .Share, OUTCOME_PURSUIT_MEN[outcome])
				out.pursuit_readiness = PURSUIT_READINESS
			}
		}
	}
	return
}
