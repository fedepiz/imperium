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
ONSET_TIE :: 0.5
@(private = "file")
ONSET_ROUT_MARGIN :: 7
@(private = "file")
EDGE_PER_MARGIN :: 0.5
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
COHESION_READINESS_MIN :: 25
@(private = "file")
COHESION_MEN_PERCENT_MIN :: 30
@(private = "file")
COHESION_TARGET :: 10
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

@(private = "file", rodata)
TEMPERAMENT_FACTS := [Temperament]Fact {
	.Bold     = .Temperament_Bold,
	.Steady   = .Temperament_Steady,
	.Cautious = .Temperament_Cautious,
	.Cunning  = .Temperament_Cunning,
}

@(private = "file", rodata)
TEMPERAMENT_FOLLOW_OVERDRAW := [Temperament]f32 {
	.Bold     = 0,
	.Steady   = 0,
	.Cautious = 0,
	.Cunning  = 0,
}

@(private = "file")
Fact :: enum u8 {
	Temperament_Bold,
	Temperament_Steady,
	Temperament_Cautious,
	Temperament_Cunning,
	Spent,
	Garrisoning,
	Strength_Superior,
	Strength_Ahead,
	Strength_Even,
	Strength_Behind,
	Strength_Outmatched,
	Contact_Ordered,
	Contact_Intercepting,
	Role_Defending,
	Onset_Winning,
	Onset_Even,
	Onset_Losing,
	Onset_Losing_Badly,
	Victory_Slight,
	Victory_Clear,
	Victory_Heavy,
	Victory_Rout,
}

@(private = "file", rodata)
FACT_TITLES := [Fact]string {
	.Temperament_Bold     = "Bold",
	.Temperament_Steady   = "Steady",
	.Temperament_Cautious = "Cautious",
	.Temperament_Cunning  = "Cunning",
	.Spent                = "Spent",
	.Garrisoning          = "Garrisoning",
	.Strength_Superior    = "Superior",
	.Strength_Ahead       = "Ahead",
	.Strength_Even        = "Even",
	.Strength_Behind      = "Behind",
	.Strength_Outmatched  = "Outmatched",
	.Contact_Ordered      = "Ordered",
	.Contact_Intercepting = "Intercepting",
	.Role_Defending       = "Defending",
	.Onset_Winning        = "Winning",
	.Onset_Even           = "Even fight",
	.Onset_Losing         = "Losing",
	.Onset_Losing_Badly   = "Losing badly",
	.Victory_Slight       = "Slight victory",
	.Victory_Clear        = "Clear victory",
	.Victory_Heavy        = "Heavy victory",
	.Victory_Rout         = "Rout",
}

@(private = "file")
Rung :: struct {
	from: f32,
	fact: Fact,
}

@(private = "file", rodata)
STRENGTH_LADDER := [?]Rung {
	{2, .Strength_Superior},
	{0.5, .Strength_Ahead},
	{-0.5, .Strength_Even},
	{-2, .Strength_Behind},
	{math.NEG_INF_F32, .Strength_Outmatched},
}

@(private = "file", rodata)
ONSET_LADDER := [?]Rung {
	{ONSET_TIE, .Onset_Winning},
	{-ONSET_TIE, .Onset_Even},
	{-4, .Onset_Losing},
	{math.NEG_INF_F32, .Onset_Losing_Badly},
}

@(private = "file")
Choice :: enum u8 {
	None,
	Contact_Attack,
	Contact_Decline,
	Avoid_Try,
	Avoid_Stand,
	Posture_Press,
	Posture_Standard,
	Posture_Probe,
	Crisis_Commit,
	Crisis_Hold,
	Crisis_Break_Off,
	Follow_Stay,
	Follow_Advance,
	Follow_Pursue,
}

@(private = "file")
Decision :: enum u8 {
	Contact,
	Avoid,
	Posture,
	Crisis,
	Follow,
}

@(private = "file", rodata)
DECISION_CHOICES := [Decision]bit_set[Choice] {
	.Contact = {.Contact_Attack, .Contact_Decline},
	.Avoid   = {.Avoid_Try, .Avoid_Stand},
	.Posture = {.Posture_Press, .Posture_Standard, .Posture_Probe},
	.Crisis  = {.Crisis_Commit, .Crisis_Hold, .Crisis_Break_Off},
	.Follow  = {.Follow_Stay, .Follow_Advance, .Follow_Pursue},
}

@(private = "file")
Rule :: struct {
	all:    bit_set[Fact],
	any:    bit_set[Fact],
	none:   bit_set[Fact],
	choice: Choice,
}

@(private = "file")
RULES := [Decision][]Rule {
	.Contact = {
		{all = {.Spent}, choice = .Contact_Decline},
		{all = {.Temperament_Bold, .Contact_Ordered}, choice = .Contact_Attack},
		{
			all = {.Temperament_Bold, .Contact_Intercepting},
			any = {.Strength_Superior, .Strength_Ahead, .Strength_Even},
			choice = .Contact_Attack,
		},
		{
			all = {.Temperament_Bold},
			none = {.Contact_Intercepting, .Strength_Outmatched},
			choice = .Contact_Attack,
		},
		{
			all = {.Temperament_Cautious, .Contact_Ordered},
			any = {.Strength_Superior, .Strength_Ahead},
			choice = .Contact_Attack,
		},
		{all = {.Temperament_Cautious, .Strength_Superior}, choice = .Contact_Attack},
		{all = {.Temperament_Cautious}, choice = .Contact_Decline},
		{all = {.Contact_Ordered}, none = {.Strength_Outmatched}, choice = .Contact_Attack},
		{
			all = {.Contact_Intercepting},
			any = {.Strength_Superior, .Strength_Ahead},
			choice = .Contact_Attack,
		},
		{
			any = {.Strength_Superior, .Strength_Ahead, .Strength_Even},
			none = {.Contact_Intercepting},
			choice = .Contact_Attack,
		},
		{choice = .Contact_Decline},
	},
	.Avoid = {
		{all = {.Temperament_Bold}, choice = .Avoid_Stand},
		{
			all = {.Temperament_Cautious},
			any = {.Strength_Even, .Strength_Behind, .Strength_Outmatched},
			choice = .Avoid_Try,
		},
		{
			all = {.Temperament_Cunning},
			any = {.Strength_Even, .Strength_Behind, .Strength_Outmatched},
			choice = .Avoid_Try,
		},
		{any = {.Strength_Behind, .Strength_Outmatched}, choice = .Avoid_Try},
		{choice = .Avoid_Stand},
	},
	.Posture = {
		{all = {.Temperament_Bold}, choice = .Posture_Press},
		{all = {.Temperament_Cautious}, choice = .Posture_Probe},
		{all = {.Temperament_Cunning, .Role_Defending}, choice = .Posture_Press},
		{choice = .Posture_Standard},
	},
	.Crisis = {
		{all = {.Temperament_Bold}, choice = .Crisis_Commit},
		{all = {.Temperament_Cautious, .Onset_Losing_Badly}, choice = .Crisis_Break_Off},
		{all = {.Temperament_Cautious}, choice = .Crisis_Hold},
		{all = {.Onset_Winning}, choice = .Crisis_Commit},
		{all = {.Onset_Losing_Badly}, choice = .Crisis_Break_Off},
		{choice = .Crisis_Hold},
	},
	.Follow = {
		{
			all = {.Temperament_Bold},
			any = {.Victory_Heavy, .Victory_Rout},
			choice = .Follow_Pursue,
		},
		{all = {.Temperament_Bold}, choice = .Follow_Advance},
		{
			all = {.Temperament_Cunning},
			any = {.Victory_Heavy, .Victory_Rout},
			choice = .Follow_Pursue,
		},
		{all = {.Temperament_Cunning}, choice = .Follow_Advance},
		{all = {.Temperament_Cautious, .Victory_Rout}, choice = .Follow_Advance},
		{all = {.Temperament_Cautious}, choice = .Follow_Stay},
		{all = {.Victory_Rout}, choice = .Follow_Pursue},
		{any = {.Victory_Clear, .Victory_Heavy}, choice = .Follow_Advance},
		{choice = .Follow_Stay},
	},
}

@(private = "file", rodata)
POSTURE_ONSET := #partial [Choice]f32 {
	.Posture_Press = 1,
	.Posture_Probe = -1,
}
@(private = "file", rodata)
POSTURE_CRISIS := #partial [Choice]f32 {
	.Posture_Press = -1,
}
@(private = "file")
PROBING :: bit_set[Choice]{.Posture_Probe}
@(private = "file")
WORSENING :: bit_set[Choice]{.Posture_Press, .Crisis_Commit}

@(private = "file", rodata)
POSTURE_TITLES := #partial [Choice]string {
	.Posture_Press    = "Press",
	.Posture_Standard = "Standard",
	.Posture_Probe    = "Probe",
}
@(private = "file", rodata)
CHOICE_VERBS := #partial [Choice]string {
	.Posture_Press    = "presses",
	.Posture_Standard = "stands",
	.Posture_Probe    = "probes",
	.Crisis_Commit    = "commits",
	.Crisis_Hold      = "holds",
	.Crisis_Break_Off = "breaks off",
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

@(private = "file", rodata)
OUTCOME_TITLES := [Battle_Outcome]string {
	.Avoided      = "Avoided",
	.Stalemate    = "Stalemate",
	.Probed       = "Probed",
	.Withdrew     = "Withdrew",
	.Repulsed     = "Repulsed",
	.Defeat       = "Defeat",
	.Heavy_Defeat = "Heavy defeat",
	.Rout         = "Rout",
}
@(private = "file", rodata)
LOSER_FATES := [Battle_Outcome]string {
	.Avoided      = "gets away",
	.Stalemate    = "",
	.Probed       = "pulls out",
	.Withdrew     = "withdraws",
	.Repulsed     = "is repulsed",
	.Defeat       = "is defeated",
	.Heavy_Defeat = "is heavily defeated",
	.Rout         = "is routed",
}
@(private = "file", rodata)
OUTCOME_VICTORY := [Battle_Outcome]Fact {
	.Avoided      = .Victory_Slight,
	.Stalemate    = .Victory_Slight,
	.Probed       = .Victory_Slight,
	.Withdrew     = .Victory_Slight,
	.Repulsed     = .Victory_Slight,
	.Defeat       = .Victory_Clear,
	.Heavy_Defeat = .Victory_Heavy,
	.Rout         = .Victory_Rout,
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
OUTCOMES_RETREATING :: bit_set[Battle_Outcome]{.Avoided, .Probed, .Withdrew, .Repulsed, .Defeat, .Heavy_Defeat, .Rout}
@(private = "file")
OUTCOMES_PURSUABLE :: bit_set[Battle_Outcome]{.Heavy_Defeat, .Rout}
@(private = "file")
OUTCOMES_DEFEATED :: bit_set[Battle_Outcome] {
	.Probed,
	.Withdrew,
	.Repulsed,
	.Defeat,
	.Heavy_Defeat,
	.Rout,
}

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
	.Defeat       = 0,
	.Heavy_Defeat = 0.10,
	.Rout         = 0.15,
}

@(private = "file")
Role :: enum u8 {
	Attacker,
	Defender,
}

@(private = "file", rodata)
OTHER_ROLE := [Role]Role {
	.Attacker = .Defender,
	.Defender = .Attacker,
}

@(private = "file", rodata)
ROLE_LABELS := [Role]string {
	.Attacker = "Attacker",
	.Defender = "Defender",
}

Battle_Side :: struct {
	men:           f32,
	men_max:       f32,
	// Share of men that can take part, 0..1
	engaged_share: f32,
	// Men that can take part at most
	engaged_max:   f32,
	proficiency:   f32,
	readiness:     f32,
	spent:         bool,
	garrisoning:   bool,
	stock:         f32,
	baggage:       f32,
	mobility:      f32,
	temperament:   Temperament,
	can_attack:    bool,
	can_avoid:     bool,
	can_fall_back: bool,
	can_pursue:    bool,
	name:          string,
}

Battle :: struct {
	sides:   [2]Battle_Side,
	ordered: bool,
	seed:    u64,
}

Battle_Side_Result :: struct {
	power:             Report_Tally,
	posture:           Span,
	men:               Report_Tally,
	readiness:         f32,
	stock:             Report_Tally,
	pursuit_men:       Report_Tally,
	pursuit_readiness: f32,
	dissolved:         bool,
	falls_back:        bool,
}

Battle_Result :: struct {
	names:           [2]Span,
	fought:          bool,
	refused:         bool,
	attacker:        int,
	outcome:         Battle_Outcome,
	winner:          int,
	sides:           [2]Battle_Side_Result,
	follows:         bool,
	follow_overdraw: f32,
	caught:          bool,
	report:          Report,
	outcome_title:   Span,
	follow_title:    Span,
}

battle_resolve :: proc(battle: Battle) -> (result: Battle_Result) {
	rng := battle.seed
	report := &result.report
	for side, i in battle.sides do result.names[i] = report_text(report, side.name)

	// Men taking part
	men_engaged: [2]f32
	for side, i in battle.sides {
		assert(side.engaged_share > 0)
		men_engaged[i] = min(side.men * side.engaged_share, side.engaged_max)
	}

	for side, i in battle.sides {
		power := &result.sides[i].power
		proficiency := side.proficiency / 10
		report_tally_add(power, "Proficiency", proficiency)
		report_tally_add(power, "Readiness", -proficiency * (0.5 - side.readiness / 200))
		men_ratio := men_engaged[1 - i] > 0 ? men_engaged[i] / men_engaged[1 - i] : 1
		numbers := clamp(NUMBERS_SCALE * math.log2(max(men_ratio, 1e-6)), 0, NUMBERS_MAX)
		report_tally_add(power, "Numbers", numbers)
	}

	facts: [2]bit_set[Fact]
	for side, i in battle.sides {
		gap := result.sides[i].power.total - result.sides[1 - i].power.total
		facts[i] = {TEMPERAMENT_FACTS[side.temperament], ladder(gap, STRENGTH_LADDER[:])}
		if side.spent do facts[i] += {.Spent}
		if side.garrisoning do facts[i] += {.Garrisoning}
	}

	if battle.ordered do facts[0] += {.Contact_Ordered}
	facts[1] += {.Contact_Intercepting}
	attacking: [2]bool
	reasons: [2]Span
	for i in 0 ..< 2 {
		choice, held, absent := decide(.Contact, facts[i])
		attacking[i] = choice == .Contact_Attack
		reasons[i] = report_because(report, held, absent, FACT_TITLES)
	}
	switch {
	case battle.sides[0].can_attack && attacking[0]:
		result.fought = true
	case battle.sides[1].can_attack && attacking[1]:
		result.fought = true
		result.attacker = 1
	case:
		result.refused = battle.ordered
		refusal: Report_Arg = Report_Note{"Its commander declines.", reasons[0]}
		if !battle.sides[0].can_attack do refusal = "It has already attacked this turn."
		report_say(report, "%", refusal)
	}
	if !result.fought do return

	at := [Role]int {
		.Attacker = result.attacker,
		.Defender = 1 - result.attacker,
	}
	sides := [Role]Battle_Side {
		.Attacker = battle.sides[at[.Attacker]],
		.Defender = battle.sides[at[.Defender]],
	}
	names := [Role]string {
		.Attacker = sides[.Attacker].name,
		.Defender = sides[.Defender].name,
	}
	powers := [Role]Report_Tally {
		.Attacker = result.sides[at[.Attacker]].power,
		.Defender = result.sides[at[.Defender]].power,
	}
	situation := [Role]bit_set[Fact] {
		.Attacker = facts[at[.Attacker]],
		.Defender = facts[at[.Defender]] + {.Role_Defending},
	}
	report_say(
		report,
		"% % %.",
		names[.Attacker],
		Report_Note{"attacks", reasons[result.attacker]},
		names[.Defender],
	)

	// Engaged share of each side's men, scaling its readiness and stock effects
	scale: [Role]f32
	for side, role in sides {
		scale[role] = side.men > 0 ? men_engaged[at[role]] / side.men : 1
		if scale[role] >= 1 do continue
		report_say(report, "% engages % of % men.", names[role], men_engaged[at[role]], side.men)
	}
	report_say(report, "Power % against %.", powers[.Attacker], powers[.Defender])

	decided := false
	loser: Role

	{
		defender := sides[.Defender]
		attacker := sides[.Attacker]
		avoid, held, absent := decide(.Avoid, situation[.Defender])
		if defender.can_avoid && avoid == .Avoid_Try {
			roll: Report_Tally
			report_tally_add(&roll, "Roll", roll_2d6(&rng))
			report_tally_add(&roll, "Mobility", MOBILITY_BONUS * (defender.mobility - attacker.mobility))
			reason := report_because(report, held, absent, FACT_TITLES)
			tries := Report_Note{"tries to avoid battle", reason}
			if check(report, names[.Defender], roll, MOBILITY_TARGET, tries) {
				result.outcome = .Avoided
				loser = .Defender
				decided = true
			}
		}
	}

	postures: [Role]Choice
	{
		verbs: [Role]Report_Note
		for role in Role {
			held, absent: bit_set[Fact]
			postures[role], held, absent = decide(.Posture, situation[role])
			result.sides[at[role]].posture = report_text(report, POSTURE_TITLES[postures[role]])
			reason := report_because(report, held, absent, FACT_TITLES)
			verbs[role] = {CHOICE_VERBS[postures[role]], reason}
		}
		if !decided do choose(report, names, verbs)
	}

	edges: [Role]Report_Tally
	if !decided {
		rolls: [Role]Report_Tally
		for &roll, role in rolls {
			report_tally_add(&roll, "Roll", roll_2d6(&rng))
			append(&roll.factors, ..powers[role].factors[:])
			roll.total += powers[role].total
			report_tally_add(&roll, "Posture", POSTURE_ONSET[postures[role]])
		}
		ahead, margin := contest(report, "Onset", names, rolls)
		situation[ahead] += {ladder(margin, ONSET_LADDER[:])}
		situation[OTHER_ROLE[ahead]] += {ladder(-margin, ONSET_LADDER[:])}
		switch {
		case margin < ONSET_TIE:
			report_say(report, "Neither gains the upper hand.")
		case margin >= ONSET_ROUT_MARGIN:
			loser = OTHER_ROLE[ahead]
			result.outcome = postures[loser] in PROBING ? .Probed : .Rout
			decided = true
		case:
			report_tally_add(&edges[ahead], "Margin", margin)
			report_tally_scale(&edges[ahead], "Share", EDGE_PER_MARGIN, .Percent)
			report_say(report, "% gains an edge of %.", names[ahead], edges[ahead])
		}
	}

	if !decided {
		for role in Role {
			behind := edges[role].total - edges[OTHER_ROLE[role]].total
			if postures[role] in PROBING && behind <= PROBE_PULL_OUT {
				report_say(report, "% is probing and falls behind.", names[role])
				result.outcome = .Probed
				loser = role
				decided = true
				break
			}
		}
	}

	worsened := false
	if !decided {
		choices: [Role]Choice
		verbs: [Role]Report_Note
		for role in Role {
			held, absent: bit_set[Fact]
			choices[role], held, absent = decide(.Crisis, situation[role])
			reason := report_because(report, held, absent, FACT_TITLES)
			verbs[role] = {CHOICE_VERBS[choices[role]], reason}
		}
		choose(report, names, verbs)
		switch {
		case choices[.Attacker] == .Crisis_Break_Off && choices[.Defender] == .Crisis_Break_Off:
			result.outcome = .Stalemate
		case choices[.Attacker] == .Crisis_Break_Off:
			result.outcome = .Repulsed
			loser = .Attacker
		case choices[.Defender] == .Crisis_Break_Off:
			result.outcome = .Withdrew
			loser = .Defender
		case:
			rolls: [Role]Report_Tally
			for &roll, role in rolls {
				report_tally_add(&roll, "Roll", roll_2d6(&rng))
				append(&roll.factors, ..powers[role].factors[:])
				roll.total += powers[role].total
				report_tally_add(&roll, "Edge", edges[role].total)
				report_tally_add(&roll, "Committed", choices[role] == .Crisis_Commit ? COMMIT_BONUS : 0)
				report_tally_add(&roll, "Posture", POSTURE_CRISIS[postures[role]])
			}
			ahead, margin := contest(report, "Crisis", names, rolls)
			loser = OTHER_ROLE[ahead]
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
			if choices[loser] in WORSENING || postures[loser] in WORSENING {
				worsened = OUTCOME_WORSE[result.outcome] != result.outcome
				result.outcome = OUTCOME_WORSE[result.outcome]
			}
		}
	}

	winner := OTHER_ROLE[loser]
	result.winner = at[winner]
	result.outcome_title = report_text(report, OUTCOME_TITLES[result.outcome])
	if result.outcome == .Stalemate {
		report_say(report, "Stalemate.")
	} else {
		report_say(report, "% %.", names[loser], LOSER_FATES[result.outcome])
	}
	if worsened do report_say(report, "Having pressed or committed, % fares worse.", names[loser])

	{
		outcome := result.outcome
		takes_losers_losses: [Role]bool
		takes_losers_losses[loser] = true
		takes_losers_losses[winner] = outcome == .Stalemate
		for role in Role {
			fate: Fate = takes_losers_losses[role] ? .Loser : .Winner
			out := &result.sides[at[role]]
			if share := MEN_LOST_SHARE[fate][outcome]; share > 0 {
				report_tally_add(&out.men, "Engaged", -min(men_engaged[0], men_engaged[1]), .Men)
				report_tally_scale(&out.men, "Share", share, .Percent)
			}
			out.readiness = READINESS_CHANGE[fate][outcome] * scale[role]
			out.falls_back =
				takes_losers_losses[role] &&
				outcome in OUTCOMES_RETREATING &&
				sides[role].can_fall_back
		}

		beaten := sides[loser]
		victor := sides[winner]
		lost := &result.sides[at[loser]].stock
		if table := LOSER_STOCK_LOST[outcome]; table > 0 {
			report_tally_add(lost, "Lost", -table)
			if scale[loser] < 1 do report_tally_scale(lost, "Engaged", scale[loser], .Percent)
			short := -lost.total - beaten.stock
			if short > 0 do report_tally_add(lost, "Not carried", short)
		}
		if share := WINNER_STOCK_CAPTURED_SHARE[outcome];
		   share > 0 && lost.total < 0 && men_engaged[at[winner]] > 0 {
			captured := &result.sides[at[winner]].stock
			report_tally_add(captured, "Lost", -lost.total)
			report_tally_scale(
				captured,
				"Men ratio",
				men_engaged[at[loser]] / men_engaged[at[winner]],
				.Ratio,
			)
			report_tally_scale(captured, "Share", share, .Percent)
			room := victor.baggage - victor.stock
			if captured.total > room do report_tally_add(captured, "Baggage full", room - captured.total)
		}
	}

	if result.outcome in OUTCOMES_DEFEATED {
		side := sides[loser]
		out := &result.sides[at[loser]]
		men := side.men + out.men.total
		readiness := clamp(side.readiness + out.readiness, 0, 100)
		men_percent: f32 = side.men_max > 0 ? 100 * men / side.men_max : 100
		if readiness < COHESION_READINESS_MIN || men_percent < COHESION_MEN_PERCENT_MIN {
			roll: Report_Tally
			report_tally_add(&roll, "Roll", roll_2d6(&rng))
			report_tally_add(&roll, "Proficiency", side.proficiency / 10)
			report_tally_add(
				&roll,
				"Readiness",
				-max(0, (COHESION_READINESS_MIN - readiness) / 10),
			)
			report_tally_add(
				&roll,
				"Losses",
				-max(0, (COHESION_MEN_PERCENT_MIN - men_percent) / 10),
			)
			out.dissolved = !check(report, names[loser], roll, COHESION_TARGET, "checks cohesion")
		}
	}

	{
		outcome := result.outcome
		standing := !result.sides[at[loser]].dissolved && !result.sides[at[winner]].dissolved
		can_advance := standing && result.sides[at[loser]].falls_back
		can_pursue := standing && outcome in OUTCOMES_PURSUABLE && sides[winner].can_pursue
		victor := sides[winner]
		beaten := sides[loser]
		follow := Choice.Follow_Stay
		reason: Span
		if can_advance {
			held, absent: bit_set[Fact]
			follow, held, absent = decide(.Follow, situation[winner] + {OUTCOME_VICTORY[outcome]})
			reason = report_because(report, held, absent, FACT_TITLES)
		}
		if follow == .Follow_Pursue && !can_pursue do follow = .Follow_Advance
		pursued := follow == .Follow_Pursue
		result.follows = follow != .Follow_Stay
		result.follow_overdraw = TEMPERAMENT_FOLLOW_OVERDRAW[victor.temperament]
		if pursued {
			roll: Report_Tally
			report_tally_add(&roll, "Roll", roll_2d6(&rng))
			report_tally_add(&roll, "Mobility", MOBILITY_BONUS * (victor.mobility - beaten.mobility))
			pursues := Report_Note{"pursues", reason}
			result.caught = check(report, names[winner], roll, MOBILITY_TARGET, pursues)
			if result.caught {
				out := &result.sides[at[loser]]
				report_tally_add(&out.pursuit_men, "Men left", -(beaten.men + out.men.total), .Men)
				report_tally_scale(&out.pursuit_men, "Share", PURSUIT_MEN_LOST_SHARE[outcome], .Percent)
				out.pursuit_readiness = PURSUIT_READINESS
			}
		}
		switch {
		case !result.follows:
			result.follow_title = report_text(report, "% falls back", beaten.name)
		case !pursued:
			result.follow_title = report_text(report, "% falls back; % advances", beaten.name, victor.name)
		case result.caught:
			result.follow_title = report_text(report, "% pursues and catches %", victor.name, beaten.name)
		case:
			result.follow_title = report_text(report, "% pursues; % gets away", victor.name, beaten.name)
		}
	}
	return
}

@(private = "file")
check :: proc(report: ^Report, name: string, roll: Report_Tally, target: f32, action: Report_Arg) -> bool {
	passed := roll.total >= target
	verdict := passed ? "succeeds" : "fails"
	report_say(report, "% %: % against %, and %.", name, action, roll, target, verdict)
	return passed
}

@(private = "file")
contest :: proc(
	report: ^Report,
	label: string,
	names: [Role]string,
	rolls: [Role]Report_Tally,
) -> (
	ahead: Role,
	margin: f32,
) {
	ahead = rolls[.Attacker].total < rolls[.Defender].total ? .Defender : .Attacker
	behind := OTHER_ROLE[ahead]
	lead: Report_Tally
	report_tally_add(&lead, ROLE_LABELS[ahead], rolls[ahead].total)
	report_tally_add(&lead, ROLE_LABELS[behind], -rolls[behind].total)
	report_say(
		report,
		"%: % %, % %.",
		label,
		names[.Attacker],
		rolls[.Attacker],
		names[.Defender],
		rolls[.Defender],
	)
	report_say(report, "% is ahead by %.", names[ahead], lead)
	return ahead, lead.total
}

@(private = "file")
choose :: proc(report: ^Report, names: [Role]string, verbs: [Role]Report_Note) {
	report_say(report, "% %; % %.", names[.Attacker], verbs[.Attacker], names[.Defender], verbs[.Defender])
}

@(private = "file")
ladder :: proc(value: f32, rungs: []Rung) -> Fact {
	for rung in rungs do if value >= rung.from do return rung.fact
	return rungs[len(rungs) - 1].fact
}

@(private = "file")
decide :: proc(
	decision: Decision,
	situation: bit_set[Fact],
) -> (
	choice: Choice,
	held, absent: bit_set[Fact],
) {
	for rule in RULES[decision] {
		matches := rule.all <= situation && (rule.none & situation) == {}
		if matches && (rule.any == {} || (rule.any & situation) != {}) {
			choice = rule.choice
			held = (rule.all | rule.any) & situation
			absent = rule.none
			break
		}
	}
	assert(choice in DECISION_CHOICES[decision])
	return
}
