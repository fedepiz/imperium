package sim

import "core:fmt"
import "core:strings"

import "../span"

TALLY_FACTORS_MAX :: 20
REPORT_TEXT_MAX :: 4096
REPORT_PARTS_MAX :: 160
REPORT_LINES_MAX :: 24

// What a derived number is made of
Report_Term :: enum u8 {
	Dice,
	Proficiency,
	Readiness,
	Numbers,
	Posture,
	Ground,
	Edge,
	Commit,
	Mobility,
	Losses,
	Attacker,
	Defender,
	Margin,
	Engaged,
	Share,
	Lost,
	Carried,
	Men_Ratio,
	Baggage,
	Men_Left,
}

@(rodata)
TERM_TITLES := [Report_Term]string {
	.Dice        = "Roll",
	.Proficiency = "Proficiency",
	.Readiness   = "Readiness",
	.Numbers     = "Numbers",
	.Posture     = "Posture",
	.Ground      = "Ground",
	.Edge        = "Edge",
	.Commit      = "Committed",
	.Mobility    = "Mobility",
	.Losses      = "Losses",
	.Attacker    = "Attacker",
	.Defender    = "Defender",
	.Margin      = "Margin",
	.Engaged     = "Engaged",
	.Share       = "Share",
	.Lost        = "Lost",
	.Carried     = "Not carried",
	.Men_Ratio   = "Men ratio",
	.Baggage     = "Baggage full",
	.Men_Left    = "Men left",
}

Term_Unit :: enum u8 {
	Points,
	Men,
	Percent,
	Ratio,
}

// Points unless listed
@(rodata)
TERM_UNITS := #partial [Report_Term]Term_Unit {
	.Engaged   = .Men,
	.Men_Left  = .Men,
	.Share     = .Percent,
	.Men_Ratio = .Ratio,
}

Factor_Op :: enum u8 {
	Add,
	// Multiplies the total so far
	Scale,
}

Factor :: struct {
	term:  Report_Term,
	op:    Factor_Op,
	value: f32,
}

// A derived number and what it is made of. A roll is a tally starting with the dice; empty = not rolled.
Tally :: struct {
	// Added zeros left out, other than the dice
	factors: [dynamic; TALLY_FACTORS_MAX]Factor,
	total:   f32,
}

// Lines to read
Report :: struct {
	// Everything shown; parts are spans of it
	text:  [dynamic; REPORT_TEXT_MAX]u8,
	parts: [dynamic; REPORT_PARTS_MAX]Report_Part,
	// Ranges of parts
	lines: [dynamic; REPORT_LINES_MAX]span.Span,
}

// Text shown; on hover, the tally behind it when it has factors
Report_Part :: struct {
	text:  span.Span,
	tally: Tally,
}

// Fills a % slot
Report_Arg :: union {
	string,
	Tally,
	f32,
}

tally_add :: proc(tally: ^Tally, term: Report_Term, value: f32) {
	tally.total += value
	if value != 0 || term == .Dice do append(&tally.factors, Factor{term, .Add, value})
}

tally_scale :: proc(tally: ^Tally, term: Report_Term, value: f32) {
	tally.total *= value
	append(&tally.factors, Factor{term, .Scale, value})
}

// Adds a line; each % in text takes the next arg. A tally shows its total, and its factors on hover.
report_say :: proc(report: ^Report, text: string, args: ..Report_Arg) {
	first := len(report.parts)
	write(report, text, args)
	append(&report.lines, span.from_range(first, len(report.parts)))
}

// Adds text outside the lines; returns its span
report_text :: proc(report: ^Report, text: string, args: ..Report_Arg) -> span.Span {
	begin := len(report.text)
	write(report, text, args)
	return span.from_range(begin, len(report.text))
}

@(private = "file")
write :: proc(report: ^Report, text: string, args: []Report_Arg) {
	digits: [32]u8
	rest := text
	for arg in args {
		slot := strings.index_byte(rest, '%')
		put(report, rest[:slot])
		rest = rest[slot + 1:]
		switch value in arg {
		case string:
			put(report, value)
		case f32:
			put(report, fmt.bprintf(digits[:], "%v", value))
		case Tally:
			put(report, fmt.bprintf(digits[:], "%.1f", value.total), value)
		}
	}
	put(report, rest)
}

// Appends text as a part, the tally behind it
@(private = "file")
put :: proc(report: ^Report, text: string, tally: Tally = {}) {
	if text == "" do return
	begin := len(report.text)
	append(&report.text, ..transmute([]u8)text)
	end := len(report.text)
	append(&report.parts, Report_Part{text = span.from_range(begin, end), tally = tally})
}

