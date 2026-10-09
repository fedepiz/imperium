#+private
package main

import "core:math"

@(private = "file")
NUMBERS_SCALE :: 1.5
@(private = "file")
NUMBERS_MAX :: 2
@(private = "file")
MOBILITY_BONUS :: 2
@(private = "file")
MOBILITY_TARGET :: 8
@(private = "file")
ONSET_ROUT_MARGIN :: 7
@(private = "file")
PROBE_PULL_OUT :: -2
@(private = "file")
COMMIT_BONUS :: 1
@(private = "file")
CRISIS_STALEMATE_MAX :: 2
@(private = "file")
CRISIS_DEFEAT_MAX :: 5
@(private = "file")
CRISIS_HEAVY_DEFEAT_MAX :: 8
@(private = "file")
HOLD_READINESS_MIN :: 25
@(private = "file")
HOLD_MEN_PERCENT_MIN :: 30
@(private = "file")
HOLD_TARGET :: 10
@(private = "file")
AVOID_READINESS :: 5
@(private = "file")
PURSUIT_READINESS :: -10

Temperament :: enum u8 {
	Bold,
	Steady,
	Cautious,
	Cunning,
}

Posture :: enum u8 {
	Press,
	Standard,
	Probe,
}

Crisis_Choice :: enum u8 {
	Hold,
	Commit,
	Break_Off,
}

Battle_Outcome :: enum u8 {
	Avoided,
	Stalemate,
	Probed,
	Withdrew,
	Repulsed,
	Defeat,
	Heavy_Defeat,
	Rout,
}

Battle_Role :: enum u8 {
	Attacker,
	Defender,
}

@(rodata)
BATTLE_OTHER_ROLE := [Battle_Role]Battle_Role {
	.Attacker = .Defender,
	.Defender = .Attacker,
}

@(rodata)
BATTLE_ATTACK_THRESHOLD := [Temperament]f32 {
	.Bold     = -1,
	.Steady   = 0,
	.Cautious = 1,
	.Cunning  = 0,
}

@(private = "file", rodata)
AVOID_BELOW := [Temperament]f32 {
	.Bold     = math.NEG_INF_F32,
	.Steady   = 0,
	.Cautious = 1,
	.Cunning  = 1,
}
@(private = "file", rodata)
POSTURES := [Battle_Role][Temperament]Posture {
	.Attacker = {.Bold = .Press, .Steady = .Standard, .Cautious = .Probe, .Cunning = .Standard},
	.Defender = {.Bold = .Press, .Steady = .Standard, .Cautious = .Probe, .Cunning = .Press},
}
@(private = "file", rodata)
COMMIT_ABOVE := [Temperament]f32 {
	.Bold     = math.NEG_INF_F32,
	.Steady   = 0,
	.Cautious = math.INF_F32,
	.Cunning  = 0,
}
@(private = "file", rodata)
BREAK_OFF_AT := [Temperament]f32 {
	.Bold     = math.NEG_INF_F32,
	.Steady   = -2,
	.Cautious = -2,
	.Cunning  = -2,
}
@(private = "file", rodata)
PURSUE_FROM_SEVERITY := [Temperament]int {
	.Bold     = 1,
	.Steady   = 3,
	.Cautious = 4,
	.Cunning  = 2,
}

@(private = "file", rodata)
POSTURE_ONSET := [Posture]f32 {
	.Press    = 1,
	.Standard = 0,
	.Probe    = -1,
}
@(private = "file", rodata)
POSTURE_CRISIS := [Posture]f32 {
	.Press    = -1,
	.Standard = 0,
	.Probe    = 0,
}
@(private = "file")
PROBING_POSTURES :: bit_set[Posture]{.Probe}
@(private = "file")
WORSENING_POSTURES :: bit_set[Posture]{.Press}

@(private = "file", rodata)
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
@(private = "file", rodata)
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
@(private = "file")
OUTCOMES_WITH_WINNER :: bit_set[Battle_Outcome]{.Probed, .Withdrew, .Repulsed, .Defeat, .Heavy_Defeat, .Rout}

@(private = "file")
Fate :: enum u8 {
	Loser,
	Winner,
}

@(private = "file", rodata)
MEN_LOST_SHARE := [Fate][Battle_Outcome]f32 {
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
@(private = "file", rodata)
READINESS_CHANGE := [Fate][Battle_Outcome]f32 {
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
@(private = "file", rodata)
LOSER_STOCK_LOST := [Battle_Outcome]f32 {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0.1,
	.Withdrew     = 0.2,
	.Repulsed     = 0.2,
	.Defeat       = 0.5,
	.Heavy_Defeat = 1,
	.Rout         = 2,
}
@(private = "file", rodata)
WINNER_STOCK_CAPTURED_SHARE := [Battle_Outcome]f32 {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0,
	.Withdrew     = 0,
	.Repulsed     = 0,
	.Defeat       = 0.2,
	.Heavy_Defeat = 0.4,
	.Rout         = 0.6,
}
@(private = "file", rodata)
PURSUIT_MEN_LOST_SHARE := [Battle_Outcome]f32 {
	.Avoided      = 0,
	.Stalemate    = 0,
	.Probed       = 0,
	.Withdrew     = 0,
	.Repulsed     = 0,
	.Defeat       = 0.10,
	.Heavy_Defeat = 0.10,
	.Rout         = 0.15,
}

Battle_Side :: struct {
	men:         f32,
	men_max:     f32,
	proficiency: f32,
	readiness:   f32,
	stock:       f32,
	baggage:     f32,
	mobility:    f32,
	temperament: Temperament,
}

Battle :: struct {
	sides: [Battle_Role]Battle_Side,
	seed:  u64,
}

Battle_Roll :: struct {
	rolled: bool,
	dice:   f32,
	total:  f32,
	target: f32,
}

Battle_Side_Result :: struct {
	power:            f32,
	posture:          Posture,
	choice:           Crisis_Choice,
	edge:             f32,
	onset:            Battle_Roll,
	crisis:           Battle_Roll,
	hold:             Battle_Roll,
	men_change:       f32,
	readiness_change: f32,
	stock_change:     f32,
	dissolved:        bool,
	falls_back:       bool,
}

Battle_Result :: struct {
	outcome:       Battle_Outcome,
	winner:        Battle_Role,
	sides:         [Battle_Role]Battle_Side_Result,
	avoid:         Battle_Roll,
	onset_margin:  f32,
	pulled_out:    bool,
	crisis_chosen: bool,
	crisis_margin: f32,
	worsened:      bool,
	pursuit:       Battle_Roll,
	pursued:       bool,
}

battle_strength :: proc(side, other: Battle_Side) -> f32 {
	quality := side.proficiency / 10 * (0.5 + side.readiness / 200)
	men_ratio := other.men > 0 ? side.men / other.men : 1
	numbers := clamp(NUMBERS_SCALE * math.log2(max(men_ratio, 1e-6)), 0, NUMBERS_MAX)
	return quality + numbers
}

battle_resolve :: proc(battle: Battle) -> (result: Battle_Result) {
	rng := battle.seed
	roll_2d6 :: proc(rng: ^u64) -> f32 {
		splitmix64 :: proc(state: ^u64) -> u64 {
			state^ += 0x9e3779b97f4a7c15
			z := state^
			z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
			z = (z ~ (z >> 27)) * 0x94d049bb133111eb
			return z ~ (z >> 31)
		}
		return f32(splitmix64(rng) % 6 + 1 + splitmix64(rng) % 6 + 1)
	}

	strength: [Battle_Role]f32
	for side, role in battle.sides {
		strength[role] = battle_strength(side, battle.sides[BATTLE_OTHER_ROLE[role]])
		result.sides[role].power = strength[role]
		result.sides[role].posture = POSTURES[role][side.temperament]
	}

	decided := false
	loser: Battle_Role

	{
		defender := battle.sides[.Defender]
		attacker := battle.sides[.Attacker]
		if strength[.Defender] - strength[.Attacker] < AVOID_BELOW[defender.temperament] {
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

	if !decided {
		totals: [Battle_Role]f32
		for role in Battle_Role {
			dice := roll_2d6(&rng)
			totals[role] = dice + strength[role] + POSTURE_ONSET[result.sides[role].posture]
			result.sides[role].onset = {
				rolled = true,
				dice   = dice,
				total  = totals[role],
			}
		}
		margin := abs(totals[.Attacker] - totals[.Defender])
		result.onset_margin = margin
		if totals[.Attacker] != totals[.Defender] {
			ahead: Battle_Role = totals[.Attacker] > totals[.Defender] ? .Attacker : .Defender
			behind := BATTLE_OTHER_ROLE[ahead]
			if margin >= ONSET_ROUT_MARGIN {
				result.outcome = result.sides[behind].posture in PROBING_POSTURES ? .Probed : .Rout
				loser = behind
				decided = true
			} else {
				result.sides[ahead].edge = math.floor(margin / 2)
			}
		}
	}

	if !decided {
		for role in Battle_Role {
			edge_gap := result.sides[role].edge - result.sides[BATTLE_OTHER_ROLE[role]].edge
			if result.sides[role].posture in PROBING_POSTURES && edge_gap <= PROBE_PULL_OUT {
				result.outcome = .Probed
				result.pulled_out = true
				loser = role
				decided = true
				break
			}
		}
	}

	if !decided {
		result.crisis_chosen = true
		for side, role in battle.sides {
			edge_gap := result.sides[role].edge - result.sides[BATTLE_OTHER_ROLE[role]].edge
			choice := Crisis_Choice.Hold
			if edge_gap > COMMIT_ABOVE[side.temperament] do choice = .Commit
			if edge_gap <= BREAK_OFF_AT[side.temperament] do choice = .Break_Off
			result.sides[role].choice = choice
		}
		attacker_breaks := result.sides[.Attacker].choice == .Break_Off
		defender_breaks := result.sides[.Defender].choice == .Break_Off
		switch {
		case attacker_breaks && defender_breaks:
			result.outcome = .Stalemate
		case attacker_breaks:
			result.outcome = .Repulsed
			loser = .Attacker
		case defender_breaks:
			result.outcome = .Withdrew
			loser = .Defender
		case:
			totals: [Battle_Role]f32
			for role in Battle_Role {
				side := result.sides[role]
				commit: f32 = side.choice == .Commit ? COMMIT_BONUS : 0
				dice := roll_2d6(&rng)
				totals[role] = dice + strength[role] + side.edge + commit + POSTURE_CRISIS[side.posture]
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
			case margin <= CRISIS_STALEMATE_MAX:
				result.outcome = .Stalemate
			case margin <= CRISIS_DEFEAT_MAX:
				result.outcome = .Defeat
			case margin <= CRISIS_HEAVY_DEFEAT_MAX:
				result.outcome = .Heavy_Defeat
			case:
				result.outcome = .Rout
			}
			beaten := result.sides[loser]
			if beaten.choice == .Commit || beaten.posture in WORSENING_POSTURES {
				result.worsened = OUTCOME_WORSE[result.outcome] != result.outcome
				result.outcome = OUTCOME_WORSE[result.outcome]
			}
		}
	}
	result.winner = BATTLE_OTHER_ROLE[loser]

	{
		outcome := result.outcome
		takes_losses_as_loser: [Battle_Role]bool
		takes_losses_as_loser[loser] = true
		takes_losses_as_loser[result.winner] = outcome == .Stalemate
		for side, role in battle.sides {
			fate: Fate = takes_losses_as_loser[role] ? .Loser : .Winner
			out := &result.sides[role]
			out.men_change = -side.men * MEN_LOST_SHARE[fate][outcome]
			out.readiness_change = READINESS_CHANGE[fate][outcome]
			out.falls_back = takes_losses_as_loser[role] && outcome != .Stalemate
		}
		beaten := battle.sides[loser]
		victor := battle.sides[result.winner]
		lost := min(beaten.stock, LOSER_STOCK_LOST[outcome])
		result.sides[loser].stock_change = -lost
		if outcome in OUTCOMES_WITH_WINNER && victor.men > 0 {
			captured := lost * beaten.men / victor.men * WINNER_STOCK_CAPTURED_SHARE[outcome]
			result.sides[result.winner].stock_change = min(captured, victor.baggage - victor.stock)
		}
	}

	if result.outcome in OUTCOMES_WITH_WINNER {
		victor := battle.sides[result.winner]
		beaten := battle.sides[loser]
		if OUTCOME_SEVERITY[result.outcome] >= PURSUE_FROM_SEVERITY[victor.temperament] {
			dice := roll_2d6(&rng)
			catch := dice + MOBILITY_BONUS * (victor.mobility - beaten.mobility)
			result.pursuit = {true, dice, catch, MOBILITY_TARGET}
			if catch >= MOBILITY_TARGET {
				result.pursued = true
				out := &result.sides[loser]
				out.men_change -= (beaten.men + out.men_change) * PURSUIT_MEN_LOST_SHARE[result.outcome]
				out.readiness_change += PURSUIT_READINESS
			}
		}
	}

	for side, role in battle.sides {
		out := &result.sides[role]
		men := side.men + out.men_change
		readiness := clamp(side.readiness + out.readiness_change, 0, 100)
		men_percent: f32 = side.men_max > 0 ? 100 * men / side.men_max : 100
		if readiness >= HOLD_READINESS_MIN && men_percent >= HOLD_MEN_PERCENT_MIN do continue
		penalty :=
			max(0, (HOLD_READINESS_MIN - readiness) / 10) +
			max(0, (HOLD_MEN_PERCENT_MIN - men_percent) / 10)
		dice := roll_2d6(&rng)
		out.hold = {true, dice, dice + side.proficiency / 10, HOLD_TARGET + penalty}
		out.dissolved = out.hold.total < out.hold.target
	}
	return
}
