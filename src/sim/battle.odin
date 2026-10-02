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
MOBILITY_TARGET :: 7.5

// Onset margin: below ONSET_TIE a tie, from ONSET_ROUT_MARGIN a rout, else the winner's edge is margin / 2
ONSET_TIE :: 0.5
ONSET_ROUT_MARGIN :: 7
// A probing side pulls out after the onset when its edge is this far behind or worse
PROBE_PULL_OUT :: -2
// Added to a crisis roll when committing
COMMIT_BONUS :: 1
// Crisis margins, at most: STALEMATE a stalemate, DEFEAT a defeat, HEAVY a heavy defeat; beyond, a rout
CRISIS_STALEMATE :: 2
CRISIS_DEFEAT :: 5
CRISIS_HEAVY :: 8

// Holding together: only when readiness < HOLD_READINESS or men < HOLD_MEN % of men_max.
// Holds when 2d6 + proficiency / 10 ≥ HOLD_TARGET + penalty, penalty = (HOLD_READINESS − readiness) / 10 +
// (HOLD_MEN − men %) / 10, each part from 0.
HOLD_READINESS :: 25
HOLD_MEN :: 30
HOLD_TARGET :: 9.5

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
	edge:              f32,
	men:               f32,
	readiness:         f32,
	stock:             f32,
	// Caught by pursuit: further losses
	pursuit_men:       f32,
	pursuit_readiness: f32,
	// Failed the holding-together roll: the army is gone
	dissolved:         bool,
	// Falls back or retreats after the battle
	falls_back:        bool,
	// Power going in
	power:             f32,
	onset:             Battle_Roll,
	crisis:            Battle_Roll,
	hold:              Battle_Roll,
}

// A roll as it happened: 2d6, the total with modifiers, and what it had to reach (threshold rolls only)
Battle_Roll :: struct {
	rolled: bool,
	dice:   f32,
	total:  f32,
	target: f32,
}

Battle_Result :: struct {
	outcome:       Battle_Outcome,
	// Valid when outcome in OUTCOME_RETREATS
	winner:        Battle_Role,
	sides:         [Battle_Role]Battle_Side_Result,
	onset_margin:  f32,
	crisis_margin: f32,
	follow:        Follow,
	// The pursuit caught the loser
	caught:        bool,
	// The defender's attempt to get away, and the winner's chase
	avoid:         Battle_Roll,
	pursuit:       Battle_Roll,
	// A prober pulled out after the onset
	pulled_out:    bool,
	// Both chose in the crisis (it wasn't decided before)
	crisis_chosen: bool,
	// The loser's commitment or pressing made the result one step worse
	worsened:      bool,
}

// Resolve ------------------------------------------------------------------------------------------------------------

// Quality (proficiency, worn by low readiness) plus the numbers bonus against other. Commanders weigh battles by it.
battle_strength :: proc(side, other: Battle_Side) -> f32 {
	quality := side.proficiency / 10 * (0.5 + side.readiness / 200)
	ratio := other.men > 0 ? side.men / other.men : 1
	numbers := clamp(NUMBERS_SCALE * math.log2(max(ratio, 1e-6)), 0, NUMBERS_MAX)
	return quality + numbers
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

	// Step: Strength
	strength: [Battle_Role]f32
	for side, role in battle.sides do strength[role] = battle_strength(side, battle.sides[OTHER_ROLE[role]])
	for role in Battle_Role do result.sides[role].power = strength[role]
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
		gap := strength[.Defender] - strength[.Attacker]
		if battle.can_avoid && gap < TEMPERAMENT_AVOID_BELOW[defender.temperament] {
			dice := roll_2d6(&rng)
			escape := dice + MOBILITY_BONUS * (defender.mobility - attacker.mobility)
			result.avoid = {true, dice, escape, MOBILITY_TARGET}
			if escape >= MOBILITY_TARGET {
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
			dice := roll_2d6(&rng)
			totals[role] =
				dice + strength[role] + POSTURE_ONSET[result.sides[role].posture] + ground[role]
			result.sides[role].onset = {
				rolled = true,
				dice   = dice,
				total  = totals[role],
			}
		}
		margin := abs(totals[.Attacker] - totals[.Defender])
		result.onset_margin = margin
		if margin >= ONSET_TIE {
			winner: Battle_Role = totals[.Attacker] > totals[.Defender] ? .Attacker : .Defender
			beaten := OTHER_ROLE[winner]
			if margin >= ONSET_ROUT_MARGIN {
				result.outcome = result.sides[beaten].posture in POSTURE_PROBES ? .Probed : .Rout
				loser = beaten
				decided = true
			} else {
				result.sides[winner].edge = margin / 2
			}
		}
	}

	// Step: Probe pull-out (the attacker first if both)
	if !decided {
		for role in Battle_Role {
			behind := result.sides[role].edge - result.sides[OTHER_ROLE[role]].edge
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
			e := result.sides[role].edge - result.sides[OTHER_ROLE[role]].edge
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
				side := result.sides[role]
				commit: f32 = side.choice == .Commit ? COMMIT_BONUS : 0
				dice := roll_2d6(&rng)
				totals[role] =
					dice +
					strength[role] +
					side.edge +
					commit +
					POSTURE_CRISIS[side.posture] +
					ground[role]
				result.sides[role].crisis = {
					rolled = true,
					dice   = dice,
					total  = totals[role],
				}
			}
			margin := abs(totals[.Attacker] - totals[.Defender])
			result.crisis_margin = margin
			loser = totals[.Attacker] < totals[.Defender] ? .Attacker : .Defender
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
			beaten := result.sides[loser]
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
			out.men = -engaged * OUTCOME_MEN_LOST[row][outcome]
			out.readiness = OUTCOME_READINESS[row][outcome]
			out.falls_back = as_loser[role] && outcome in OUTCOME_RETREATS
		}
		// Supply: the loser loses some; the winner captures a share, converted to its own men's turns
		beaten := battle.sides[loser]
		victor := battle.sides[result.winner]
		lost := min(beaten.stock, OUTCOME_STOCK_LOST[outcome])
		result.sides[loser].stock = -lost
		if outcome in OUTCOME_DECIDED && victor.men > 0 {
			captured := lost * beaten.men / victor.men * OUTCOME_STOCK_CAPTURED[outcome]
			result.sides[result.winner].stock = min(captured, victor.baggage - victor.stock)
		}
	}

	// Step: Follow
	{
		outcome := result.outcome
		can_advance := outcome in OUTCOME_RETREATS
		can_pursue := outcome in OUTCOME_PURSUABLE
		victor := battle.sides[result.winner]
		beaten := battle.sides[loser]
		severity := OUTCOME_SEVERITY[outcome]
		if can_advance && severity >= TEMPERAMENT_ADVANCE_FROM[victor.temperament] do result.follow = .Advance
		if can_pursue && severity >= TEMPERAMENT_PURSUE_FROM[victor.temperament] do result.follow = .Pursue
		if result.follow == .Pursue {
			dice := roll_2d6(&rng)
			catch := dice + MOBILITY_BONUS * (victor.mobility - beaten.mobility)
			result.pursuit = {true, dice, catch, MOBILITY_TARGET}
			if catch >= MOBILITY_TARGET {
				result.caught = true
				out := &result.sides[loser]
				out.pursuit_men = -(beaten.men + out.men) * OUTCOME_PURSUIT_MEN[outcome]
				out.pursuit_readiness = PURSUIT_READINESS
			}
		}
	}

	// Step: Holding together
	for side, role in battle.sides {
		out := &result.sides[role]
		men := side.men + out.men + out.pursuit_men
		readiness := clamp(side.readiness + out.readiness + out.pursuit_readiness, 0, 100)
		men_percent: f32 = side.men_max > 0 ? 100 * men / side.men_max : 100
		if readiness >= HOLD_READINESS && men_percent >= HOLD_MEN do continue
		penalty :=
			max(0, (HOLD_READINESS - readiness) / 10) + max(0, (HOLD_MEN - men_percent) / 10)
		dice := roll_2d6(&rng)
		out.hold = {true, dice, dice + side.proficiency / 10, HOLD_TARGET + penalty}
		out.dissolved = out.hold.total < out.hold.target
	}
	return
}
