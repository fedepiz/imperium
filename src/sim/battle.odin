package sim

import "core:math"

import "../span"
import "../util"

// Battle: two armies in contact, resolved from a copy of both: who attacks, then the fight. Pure: reads nothing but the
// Battle it is given, and its own dice from battle.seed.

// Constants -----------------------------------------------------------------------------------------------------------

// 2d6 is continuous: each die uniform on [0.5, 6.5)

// Numbers bonus = clamp(NUMBERS_SCALE × log2(own men / enemy men), 0, NUMBERS_MAX)
@(private = "file")
NUMBERS_SCALE :: 1.5
@(private = "file")
NUMBERS_MAX :: 2

// Avoiding battle and pursuing: 2d6 + MOBILITY_BONUS × (own mobility − other's) ≥ MOBILITY_TARGET
@(private = "file")
MOBILITY_BONUS :: 2
@(private = "file")
MOBILITY_TARGET :: 8

// Onset margin: below ONSET_TIE a tie, from ONSET_ROUT_MARGIN a rout, else the winner's edge is margin ×
// EDGE_PER_MARGIN
@(private = "file")
ONSET_TIE :: 0.5
@(private = "file")
ONSET_ROUT_MARGIN :: 7
@(private = "file")
EDGE_PER_MARGIN :: 0.5
// A probing side pulls out after the onset when its edge is this far behind or worse
@(private = "file")
PROBE_PULL_OUT :: -2
// Added to a crisis roll when committing
@(private = "file")
COMMIT_BONUS :: 1
// Crisis margins, at most: STALEMATE a stalemate, DEFEAT a defeat, HEAVY a heavy defeat; beyond, a rout
@(private = "file")
CRISIS_STALEMATE :: 2
@(private = "file")
CRISIS_DEFEAT :: 5
@(private = "file")
CRISIS_HEAVY :: 8

// Cohesion check: only when readiness < COHESION_READINESS or men < COHESION_MEN % of men_max. Passes when 2d6 +
// proficiency / 10 − (COHESION_READINESS − readiness) / 10 − (COHESION_MEN − men %) / 10 ≥ COHESION_TARGET, each
// subtracted part from 0. Before any pursuit.
@(private = "file")
COHESION_READINESS :: 25
@(private = "file")
COHESION_MEN :: 30
@(private = "file")
COHESION_TARGET :: 10

// Readiness lost by a defender that avoids battle
@(private = "file")
AVOID_READINESS :: 5

// Temperaments -------------------------------------------------------------------------------------------------------

@(private = "file")
TEMPERAMENT_FACTS := [Temperament]Fact {
	.Bold     = .Temperament_Bold,
	.Steady   = .Temperament_Steady,
	.Cautious = .Temperament_Cautious,
	.Cunning  = .Temperament_Cunning,
}
// Movement points a winner marches beyond its budget to follow
@(private = "file")
TEMPERAMENT_FOLLOW_OVERDRAW := [Temperament]f32 {
	.Bold     = 0,
	.Steady   = 0,
	.Cautious = 0,
	.Cunning  = 0,
}

// Decisions -----------------------------------------------------------------------------------------------------------

// Facts about a side
@(private = "file")
Fact :: enum u8 {
	// Temperament
	Temperament_Bold,
	Temperament_Steady,
	Temperament_Cautious,
	Temperament_Cunning,
	// Strength: own power − the enemy's
	Strength_Superior,
	Strength_Ahead,
	Strength_Even,
	Strength_Behind,
	Strength_Outmatched,
	// Contact
	Contact_Ordered,
	Contact_Intercepting,
	Role_Defending,
	// Onset: own roll − the enemy's
	Onset_Winning,
	Onset_Even,
	Onset_Losing,
	Onset_Losing_Badly,
	// Victory
	Victory_Slight,
	Victory_Clear,
	Victory_Heavy,
	Victory_Rout,
}

@(private = "file")
Rung :: struct {
	from: f32,
	fact: Fact,
}

// Highest rung first
@(private = "file")
STRENGTH_LADDER := [?]Rung {
	{2, .Strength_Superior},
	{0.5, .Strength_Ahead},
	{-0.5, .Strength_Even},
	{-2, .Strength_Behind},
	{math.NEG_INF_F32, .Strength_Outmatched},
}
@(private = "file")
ONSET_LADDER := [?]Rung {
	{ONSET_TIE, .Onset_Winning},
	{-ONSET_TIE, .Onset_Even},
	{-4, .Onset_Losing},
	{math.NEG_INF_F32, .Onset_Losing_Badly},
}

// None = undecided
@(private = "file")
Choice :: enum u8 {
	None,
	Contact_Attack,
	Contact_Decline,
	// As defender
	Avoid_Try,
	Avoid_Stand,
	Posture_Press,
	Posture_Standard,
	Posture_Probe,
	Crisis_Commit,
	Crisis_Hold,
	Crisis_Break_Off,
	// As winner
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

@(private = "file")
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
	// At least one, unless empty
	any:    bit_set[Fact],
	none:   bit_set[Fact],
	choice: Choice,
}

// First match wins
@(private = "file")
RULES := [Decision][]Rule {
	.Contact = {
		// Bold
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
		// Cautious
		{
			all = {.Temperament_Cautious, .Contact_Ordered},
			any = {.Strength_Superior, .Strength_Ahead},
			choice = .Contact_Attack,
		},
		{all = {.Temperament_Cautious, .Strength_Superior}, choice = .Contact_Attack},
		{all = {.Temperament_Cautious}, choice = .Contact_Decline},
		// Everyone
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
	.Avoid   = {
		// Bold
		{all = {.Temperament_Bold}, choice = .Avoid_Stand},
		// Cautious, Cunning
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
		// Everyone
		{any = {.Strength_Behind, .Strength_Outmatched}, choice = .Avoid_Try},
		{choice = .Avoid_Stand},
	},
	.Posture = {
		{all = {.Temperament_Bold}, choice = .Posture_Press},
		{all = {.Temperament_Cautious}, choice = .Posture_Probe},
		{all = {.Temperament_Cunning, .Role_Defending}, choice = .Posture_Press},
		{choice = .Posture_Standard},
	},
	.Crisis  = {
		// Bold
		{all = {.Temperament_Bold}, choice = .Crisis_Commit},
		// Cautious
		{all = {.Temperament_Cautious, .Onset_Losing_Badly}, choice = .Crisis_Break_Off},
		{all = {.Temperament_Cautious}, choice = .Crisis_Hold},
		// Everyone
		{all = {.Onset_Winning}, choice = .Crisis_Commit},
		{all = {.Onset_Losing_Badly}, choice = .Crisis_Break_Off},
		{choice = .Crisis_Hold},
	},
	.Follow  = {
		// Bold, Cunning
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
		// Cautious
		{all = {.Temperament_Cautious, .Victory_Rout}, choice = .Follow_Advance},
		{all = {.Temperament_Cautious}, choice = .Follow_Stay},
		// Everyone
		{all = {.Victory_Rout}, choice = .Follow_Pursue},
		{any = {.Victory_Clear, .Victory_Heavy}, choice = .Follow_Advance},
		{choice = .Follow_Stay},
	},
}

// Postures -----------------------------------------------------------------------------------------------------------

@(private = "file")
POSTURE_ONSET := #partial [Choice]f32 {
	.Posture_Press = 1,
	.Posture_Probe = -1,
}
@(private = "file")
POSTURE_CRISIS := #partial [Choice]f32 {
	.Posture_Press = -1,
}
// Can't be routed at the onset, and pulls out when behind after it
@(private = "file")
PROBING := bit_set[Choice]{.Posture_Probe}
// Losing the crisis is one step worse
@(private = "file")
WORSENING := bit_set[Choice]{.Posture_Press, .Crisis_Commit}

// Report wording
@(private = "file")
POSTURE_TITLES := #partial [Choice]string {
	.Posture_Press    = "Press",
	.Posture_Standard = "Standard",
	.Posture_Probe    = "Probe",
}
@(private = "file")
CHOICE_WORDS := #partial [Choice]string {
	.Posture_Press    = "presses",
	.Posture_Standard = "stands",
	.Posture_Probe    = "probes",
	.Crisis_Commit    = "commits",
	.Crisis_Hold      = "holds",
	.Crisis_Break_Off = "breaks off",
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

@(private = "file")
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
// What befalls the loser; Stalemate has none
@(private = "file")
OUTCOME_WORDS := [Battle_Outcome]string {
	.Avoided      = "gets away",
	.Stalemate    = "",
	.Probed       = "pulls out",
	.Withdrew     = "withdraws",
	.Repulsed     = "is repulsed",
	.Defeat       = "is defeated",
	.Heavy_Defeat = "is heavily defeated",
	.Rout         = "is routed",
}
@(private = "file")
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
// One step worse, for a loser that committed or pressed
@(private = "file")
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
@(private = "file")
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
@(private = "file")
OUTCOME_PURSUABLE := bit_set[Battle_Outcome]{.Heavy_Defeat, .Rout}

// Losses by outcome. Men: share of the smaller side's men. Readiness: points. Stock: turns of supply. With no winner,
// the loser row is the defender (Avoided) or both sides (Stalemate).
@(private = "file")
OUTCOME_MEN_LOST := [Role_Result][Battle_Outcome]f32 {
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
@(private = "file")
OUTCOME_READINESS := [Role_Result][Battle_Outcome]f32 {
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
@(private = "file")
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
@(private = "file")
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
@(private = "file")
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
@(private = "file")
PURSUIT_READINESS :: -10

// Types --------------------------------------------------------------------------------------------------------------

@(private = "file")
Role :: enum u8 {
	Attacker,
	Defender,
}

@(private = "file")
OTHER_ROLE := [Role]Role {
	.Attacker = .Defender,
	.Defender = .Attacker,
}

// A side's roll, in a margin
@(private = "file")
ROLE_TERMS := [Role]Report_Term {
	.Attacker = .Attacker,
	.Defender = .Defender,
}

@(private = "file")
Role_Result :: enum u8 {
	Loser,
	Winner,
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
	// Hasn't attacked this turn
	can_attack:  bool,
	// Shown in the report
	name:        string,
}

Battle :: struct {
	// In contact order: [0] made contact
	sides:     [2]Battle_Side,
	// [0] was sent at [1]; forced: it attacks without deciding
	ordered:   bool,
	forced:    bool,
	// Added to the defender's rolls: terrain, a prepared position
	ground:    f32,
	can_avoid: bool,
	// All dice come from this
	seed:      u64,
}

// What happened to one side
Battle_Side_Result :: struct {
	// Going in
	power:             Tally,
	// In the report's text
	posture:           span.Span,
	// Deltas to apply to its army
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
}

Battle_Result :: struct {
	// Sides are in the battle's contact order. Fought: [attacker] attacked. Refused: [0] was sent and won't attack.
	fought:          bool,
	refused:         bool,
	attacker:        int,
	outcome:         Battle_Outcome,
	// Valid when outcome in OUTCOME_RETREATS
	winner:          int,
	sides:           [2]Battle_Side_Result,
	// The winner trails the loser as it falls back: onto its ground, or all the way when caught
	follows:         bool,
	// Movement points the winner marches beyond its budget to follow
	follow_overdraw: f32,
	// The pursuit caught the loser
	caught:          bool,
	report:          Report,
	// In the report's text
	outcome_title:   span.Span,
	follow_title:    span.Span,
}

// Resolve ------------------------------------------------------------------------------------------------------------

// Proficiency, minus what low readiness costs it, plus the bonus for outnumbering other. Commanders weigh battles by
// its total.
@(private = "file")
power :: proc(side, other: Battle_Side) -> (power: Tally) {
	proficiency := side.proficiency / 10
	tally_add(&power, .Proficiency, proficiency)
	tally_add(&power, .Readiness, -proficiency * (0.5 - side.readiness / 200))
	ratio := other.men > 0 ? side.men / other.men : 1
	tally_add(&power, .Numbers, clamp(NUMBERS_SCALE * math.log2(max(ratio, 1e-6)), 0, NUMBERS_MAX))
	return
}

battle_resolve :: proc(battle: Battle) -> (result: Battle_Result) {
	rng := battle.seed
	report := &result.report
	roll_2d6 :: proc(rng: ^u64) -> f32 {
		die :: proc(rng: ^u64) -> f32 {return 0.5 + 6 * util.random_unit(rng)}
		return die(rng) + die(rng)
	}

	// Step: Contact. [0] attacks, else [1] may intercept; else nobody does.
	initiator := battle.sides[0]
	other := battle.sides[1]
	contact := [2]bit_set[Fact]{facts(initiator, other), facts(other, initiator)}
	if battle.ordered do contact[0] += {.Contact_Ordered}
	contact[1] += {.Contact_Intercepting}
	switch {
	case battle.forced ||
	     (initiator.can_attack && decide(.Contact, contact[0]) == .Contact_Attack):
		result.fought = true
	case other.can_attack && decide(.Contact, contact[1]) == .Contact_Attack:
		result.fought = true
		result.attacker = 1
	case:
		result.refused = battle.ordered
		reason := "Its commander judges the odds too poor."
		if !initiator.can_attack do reason = "It has already attacked this turn."
		report_say(report, reason)
	}

	// The fight, by role; at: each role's index in the contact order
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

	// Step: Power
	powers: [Role]Tally
	for side, role in sides {
		powers[role] = power(side, sides[OTHER_ROLE[role]])
		result.sides[at[role]].power = powers[role]
	}
	if !result.fought do return
	situation: [Role]bit_set[Fact]
	for side, role in sides do situation[role] = facts(side, sides[OTHER_ROLE[role]])
	situation[.Defender] += {.Role_Defending}
	report_say(report, "% attacks %.", names[.Attacker], names[.Defender])
	report_say(report, "Power % against %.", powers[.Attacker], powers[.Defender])
	ground := [Role]f32 {
		.Attacker = 0,
		.Defender = battle.ground,
	}

	decided: bool
	loser: Role
	{
		// Step: Avoid
		defender := sides[.Defender]
		attacker := sides[.Attacker]
		if battle.can_avoid && decide(.Avoid, situation[.Defender]) == .Avoid_Try {
			roll: Tally
			tally_add(&roll, .Dice, roll_2d6(&rng))
			tally_add(&roll, .Mobility, MOBILITY_BONUS * (defender.mobility - attacker.mobility))
			if check(report, names[.Defender], roll, MOBILITY_TARGET, "tries to avoid battle") {
				result.outcome = .Avoided
				loser = .Defender
				decided = true
			}
		}
	}

	// Step: Posture
	postures: [Role]Choice
	{
		words: [Role]string
		for role in Role {
			postures[role] = decide(.Posture, situation[role])
			result.sides[at[role]].posture = report_text(report, POSTURE_TITLES[postures[role]])
			words[role] = CHOICE_WORDS[postures[role]]
		}
		if !decided do choose(report, names, words)
	}

	// Step: Onset
	edges: [Role]Tally
	if !decided {
		rolls: [Role]Tally
		for &roll, role in rolls {
			tally_add(&roll, .Dice, roll_2d6(&rng))
			for factor in powers[role].factors do tally_add(&roll, factor.term, factor.value)
			tally_add(&roll, .Posture, POSTURE_ONSET[postures[role]])
			tally_add(&roll, .Ground, ground[role])
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
			tally_add(&edges[ahead], .Margin, margin)
			tally_scale(&edges[ahead], .Share, EDGE_PER_MARGIN)
			report_say(report, "% gains an edge of %.", names[ahead], edges[ahead])
		}
	}

	// Step: Probe pull-out (the attacker first if both)
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

	// Step: Crisis
	worsened: bool
	if !decided {
		choices: [Role]Choice
		words: [Role]string
		for role in Role {
			choices[role] = decide(.Crisis, situation[role])
			words[role] = CHOICE_WORDS[choices[role]]
		}
		choose(report, names, words)
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
			rolls: [Role]Tally
			for &roll, role in rolls {
				tally_add(&roll, .Dice, roll_2d6(&rng))
				for factor in powers[role].factors do tally_add(&roll, factor.term, factor.value)
				tally_add(&roll, .Edge, edges[role].total)
				tally_add(&roll, .Commit, choices[role] == .Crisis_Commit ? COMMIT_BONUS : 0)
				tally_add(&roll, .Posture, POSTURE_CRISIS[postures[role]])
				tally_add(&roll, .Ground, ground[role])
			}
			ahead, margin := contest(report, "Crisis", names, rolls)
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
		report_say(report, "% %.", names[loser], OUTCOME_WORDS[result.outcome])
	}
	if worsened do report_say(report, "Having pressed or committed, % fares worse.", names[loser])

	// Step: Aftermath. Without a winner, both sides take the loser row (Stalemate) or only the defender does
	// (Avoided).
	{
		outcome := result.outcome
		as_loser: [Role]bool
		as_loser[loser] = true
		as_loser[OTHER_ROLE[loser]] = outcome == .Stalemate
		engaged := min(sides[.Attacker].men, sides[.Defender].men)
		for role in Role {
			row: Role_Result = as_loser[role] ? .Loser : .Winner
			out := &result.sides[at[role]]
			if share := OUTCOME_MEN_LOST[row][outcome]; share > 0 {
				tally_add(&out.men, .Engaged, -engaged)
				tally_scale(&out.men, .Share, share)
			}
			out.readiness = OUTCOME_READINESS[row][outcome]
			out.falls_back = as_loser[role] && outcome in OUTCOME_RETREATS
		}
		// Supply: the loser loses some; the winner captures a share, converted to its own men's turns
		beaten := sides[loser]
		victor := sides[winner]
		lost := &result.sides[at[loser]].stock
		if table := OUTCOME_STOCK_LOST[outcome]; table > 0 {
			tally_add(lost, .Lost, -table)
			if beaten.stock < table do tally_add(lost, .Carried, table - beaten.stock)
		}
		if share := OUTCOME_STOCK_CAPTURED[outcome];
		   share > 0 && lost.total < 0 && victor.men > 0 {
			captured := &result.sides[at[winner]].stock
			tally_add(captured, .Lost, -lost.total)
			tally_scale(captured, .Men_Ratio, beaten.men / victor.men)
			tally_scale(captured, .Share, share)
			room := victor.baggage - victor.stock
			if captured.total > room do tally_add(captured, .Baggage, room - captured.total)
		}
	}

	// Step: Cohesion
	for side, role in sides {
		out := &result.sides[at[role]]
		men := side.men + out.men.total
		readiness := clamp(side.readiness + out.readiness, 0, 100)
		men_percent: f32 = side.men_max > 0 ? 100 * men / side.men_max : 100
		if readiness >= COHESION_READINESS && men_percent >= COHESION_MEN do continue
		roll: Tally
		tally_add(&roll, .Dice, roll_2d6(&rng))
		tally_add(&roll, .Proficiency, side.proficiency / 10)
		tally_add(&roll, .Readiness, -max(0, (COHESION_READINESS - readiness) / 10))
		tally_add(&roll, .Losses, -max(0, (COHESION_MEN - men_percent) / 10))
		out.dissolved = !check(report, names[role], roll, COHESION_TARGET, "checks cohesion")
	}

	// Step: Follow. Nothing to follow when either side dissolved.
	{
		outcome := result.outcome
		standing := !result.sides[at[loser]].dissolved && !result.sides[at[winner]].dissolved
		can_advance := standing && outcome in OUTCOME_RETREATS
		can_pursue := standing && outcome in OUTCOME_PURSUABLE
		victor := sides[winner]
		beaten := sides[loser]
		follow := Choice.Follow_Stay
		if can_advance do follow = decide(.Follow, situation[winner] + {OUTCOME_VICTORY[outcome]})
		if follow == .Follow_Pursue && !can_pursue do follow = .Follow_Advance
		pursued := follow == .Follow_Pursue
		result.follows = follow != .Follow_Stay
		result.follow_overdraw = TEMPERAMENT_FOLLOW_OVERDRAW[victor.temperament]
		if pursued {
			roll: Tally
			tally_add(&roll, .Dice, roll_2d6(&rng))
			tally_add(&roll, .Mobility, MOBILITY_BONUS * (victor.mobility - beaten.mobility))
			result.caught = check(report, names[winner], roll, MOBILITY_TARGET, "pursues")
			if result.caught {
				out := &result.sides[at[loser]]
				tally_add(&out.pursuit_men, .Men_Left, -(beaten.men + out.men.total))
				tally_scale(&out.pursuit_men, .Share, OUTCOME_PURSUIT_MEN[outcome])
				out.pursuit_readiness = PURSUIT_READINESS
			}
		}
		title: span.Span
		switch {
		case !result.follows:
			title = report_text(report, "% falls back", beaten.name)
		case !pursued:
			title = report_text(report, "% falls back; % advances", beaten.name, victor.name)
		case result.caught:
			title = report_text(report, "% pursues and catches %", victor.name, beaten.name)
		case:
			title = report_text(report, "% pursues; % gets away", victor.name, beaten.name)
		}
		result.follow_title = title
	}
	return
}

// The side's roll against target: whether it reached it
@(private = "file")
check :: proc(report: ^Report, name: string, roll: Tally, target: f32, action: string) -> bool {
	passed := roll.total >= target
	verdict := passed ? "succeeds" : "fails"
	report_say(report, "% %: % against %, and %.", name, action, roll, target, verdict)
	return passed
}

// Both sides' rolls: the side ahead (the attacker on a tie), and its margin
@(private = "file")
contest :: proc(
	report: ^Report,
	label: string,
	names: [Role]string,
	roll: [Role]Tally,
) -> (
	ahead: Role,
	margin: f32,
) {
	ahead = roll[.Attacker].total < roll[.Defender].total ? .Defender : .Attacker
	behind := OTHER_ROLE[ahead]
	by: Tally
	tally_add(&by, ROLE_TERMS[ahead], roll[ahead].total)
	tally_add(&by, ROLE_TERMS[behind], -roll[behind].total)
	attacker, defender := names[.Attacker], names[.Defender]
	report_say(report, "%: % %, % %.", label, attacker, roll[.Attacker], defender, roll[.Defender])
	report_say(report, "% is ahead by %.", names[ahead], by)
	return ahead, by.total
}

// Both sides' choices
@(private = "file")
choose :: proc(report: ^Report, names: [Role]string, words: [Role]string) {
	attacker, defender := names[.Attacker], names[.Defender]
	report_say(report, "% %; % %.", attacker, words[.Attacker], defender, words[.Defender])
}

// Temperament and strength
@(private = "file")
facts :: proc(side, other: Battle_Side) -> bit_set[Fact] {
	gap := power(side, other).total - power(other, side).total
	return {TEMPERAMENT_FACTS[side.temperament], ladder(gap, STRENGTH_LADDER[:])}
}

@(private = "file")
ladder :: proc(value: f32, rungs: []Rung) -> Fact {
	for rung in rungs do if value >= rung.from do return rung.fact
	return rungs[len(rungs) - 1].fact
}

@(private = "file")
decide :: proc(decision: Decision, situation: bit_set[Fact]) -> (choice: Choice) {
	for rule in RULES[decision] {
		matches := rule.all <= situation && (rule.none & situation) == {}
		if matches && (rule.any == {} || (rule.any & situation) != {}) {
			choice = rule.choice
			break
		}
	}
	assert(choice in DECISION_CHOICES[decision])
	return
}

