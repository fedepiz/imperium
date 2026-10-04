package sim

import "core:fmt"
import "core:strings"

import "../span"

TALLY_FACTORS_MAX :: 20
FACTOR_LABEL_MAX :: 16
REPORT_TEXT_MAX :: 4096
REPORT_PARTS_MAX :: 160
REPORT_LINES_MAX :: 24

// How a factor's value reads
Factor_Unit :: enum u8 {
	Points,
	Men,
	Percent,
	Ratio,
}

Factor_Op :: enum u8 {
	Add,
	// Multiplies the total so far
	Scale,
}

Factor :: struct {
	// Truncated to FACTOR_LABEL_MAX bytes
	label: [dynamic; FACTOR_LABEL_MAX]u8,
	op:    Factor_Op,
	unit:  Factor_Unit,
	value: f32,
}

// A derived number and what it is made of. A roll is a tally starting with the dice; empty = not rolled.
Tally :: struct {
	// Added zeros left out
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

// Text shown; on hover, its tally's factors and its note
Report_Part :: struct {
	text:  span.Span,
	tally: Tally,
	note:  span.Span,
}

// Text, with a span of the report's text shown on hover
Report_Note :: struct {
	text: string,
	note: span.Span,
}

// Fills a % slot
Report_Arg :: union {
	string,
	Tally,
	f32,
	Report_Note,
}

tally_add :: proc(tally: ^Tally, label: string, value: f32, unit := Factor_Unit.Points) {
	tally.total += value
	if value == 0 do return
	factor := Factor {
		op    = .Add,
		unit  = unit,
		value = value,
	}
	append(&factor.label, ..transmute([]u8)label)
	append(&tally.factors, factor)
}

tally_scale :: proc(tally: ^Tally, label: string, value: f32, unit := Factor_Unit.Points) {
	tally.total *= value
	factor := Factor {
		op    = .Scale,
		unit  = unit,
		value = value,
	}
	append(&factor.label, ..transmute([]u8)label)
	append(&tally.factors, factor)
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
		case Report_Note:
			put(report, value.text, {}, value.note)
		}
	}
	put(report, rest)
}

// Appends text as a part, the tally behind it
@(private = "file")
put :: proc(report: ^Report, text: string, tally: Tally = {}, note: span.Span = {}) {
	if text == "" do return
	begin := len(report.text)
	append(&report.text, ..transmute([]u8)text)
	part := Report_Part{span.from_range(begin, len(report.text)), tally, note}
	append(&report.parts, part)
}

// "Because X and Y, and not Z nor W"; empty when both sets are
report_because :: proc(
	report: ^Report,
	held, absent: bit_set[$E],
	titles: [E]string,
) -> span.Span {
	add :: proc(report: ^Report, text: string) {append(&report.text, ..transmute([]u8)text)}
	begin := len(report.text)
	if held != {} || absent != {} do add(report, "Because ")
	joint := ""
	for fact in held {
		add(report, joint)
		add(report, titles[fact])
		joint = " and "
	}
	joint = held != {} ? ", and not " : "not "
	for fact in absent {
		add(report, joint)
		add(report, titles[fact])
		joint = " nor "
	}
	return span.from_range(begin, len(report.text))
}

