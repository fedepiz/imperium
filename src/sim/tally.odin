package sim

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

tally_add :: proc(tally: ^Tally, kind: Factor_Kind, value: f32) {
	tally.total += value
	if value != 0 || kind == .Dice do append(&tally.factors, Factor{kind, .Add, value})
}

tally_scale :: proc(tally: ^Tally, kind: Factor_Kind, value: f32) {
	tally.total *= value
	append(&tally.factors, Factor{kind, .Scale, value})
}

