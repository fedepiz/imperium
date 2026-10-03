// Prints battle odds from sim's combat_resolve, for tuning. Run from the repo root:
//   odin run tools/combat_table
package combat_table

import "core:fmt"

import "../../src/sim"

BATTLES :: 20_000

Matchup :: struct {
	label:              string,
	attacker, defender: sim.Battle_Side,
	ground:             f32,
}

main :: proc() {
	// Reference conditions: 6,000 men, readiness 90, equal mobility, no avoiding, random temperaments per side
	base := sim.Battle_Side {
		men           = 6000,
		men_max       = 6000,
		proficiency   = 50,
		readiness     = 90,
		stock         = 4,
		baggage       = 4,
		mobility      = 2,
	}
	with :: proc(side: sim.Battle_Side, proficiency: f32 = -1, men: f32 = -1, readiness: f32 = -1) -> sim.Battle_Side {
		side := side
		if proficiency >= 0 do side.proficiency = proficiency
		if men >= 0 do side.men, side.men_max = men, men
		if readiness >= 0 do side.readiness = readiness
		return side
	}
	matchups := [?]Matchup {
		{"Equal armies, proficiency 50", base, base, 0},
		{"Proficiency 60 vs 50", with(base, proficiency = 60), base, 0},
		{"Proficiency 70 vs 50", with(base, proficiency = 70), base, 0},
		{"9,000 vs 6,000 men", with(base, men = 9000), base, 0},
		{"18,000 vs 6,000 men", with(base, men = 18000), base, 0},
		{"Readiness 90 vs 50", base, with(base, readiness = 50), 0},
		{"Readiness 90 vs 20", base, with(base, readiness = 20), 0},
		{"Defender on good ground (+1)", base, base, 1},
	}

	fmt.printfln("%-32s %9s %10s %9s", "Battle", "Attacker", "Stalemate", "Defender")
	seed: u64 = 1
	for matchup in matchups {
		wins: [3]int
		outcomes: [sim.Battle_Outcome]int
		for _ in 0 ..< BATTLES {
			battle := sim.Battle {
				sides  = {matchup.attacker, matchup.defender},
				forced = true,
				ground = matchup.ground,
				seed   = seed,
			}
			seed += 1
			// Random temperaments, from the seed so runs repeat
			battle.sides[0].temperament = sim.Temperament(((seed * 2654435761) >> 16) % 4)
			battle.sides[1].temperament = sim.Temperament(((seed * 0x9e3779b1) >> 20) % 4)
			result := sim.combat_resolve(battle)
			outcomes[result.outcome] += 1
			switch {
			case result.outcome not_in sim.OUTCOME_DECIDED:
				wins[1] += 1
			case result.winner == 0:
				wins[0] += 1
			case:
				wins[2] += 1
			}
		}
		percent :: proc(n: int) -> f32 {return 100 * f32(n) / BATTLES}
		cell :: proc(n: int) -> string {return fmt.tprintf("%.0f%%", 100 * f32(n) / BATTLES)}
		fmt.printfln("%-32s %9s %10s %9s", matchup.label, cell(wins[0]), cell(wins[1]), cell(wins[2]))
		if matchup.label == matchups[0].label {
			fmt.print("    outcomes:")
			for count, outcome in outcomes do if count > 0 do fmt.printf(" %v %.0f%%", outcome, percent(count))
			fmt.println()
		}
	}
}
