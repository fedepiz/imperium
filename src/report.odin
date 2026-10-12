package main

import "core:fmt"
import "core:math"
import "core:strings"

REPORT_TALLY_FACTORS_MAX :: 20
REPORT_FACTOR_LABEL_MAX :: 16
REPORT_TEXT_MAX :: 4096
REPORT_PARTS_MAX :: 160
REPORT_LINES_MAX :: 24
REPORT_TALLIES_MAX :: 32

Report_Unit :: enum u8 {
	Points,
	Men,
	Percent,
}

Report_Op :: enum u8 {
	Add,
	Scale,
}

Report_Factor :: struct {
	label: [dynamic; REPORT_FACTOR_LABEL_MAX]u8,
	op:    Report_Op,
	unit:  Report_Unit,
	value: f32,
}

Report_Tally :: struct {
	factors: [dynamic; REPORT_TALLY_FACTORS_MAX]Report_Factor,
	total:   f32,
	// Of the total
	unit:    Report_Unit,
}

Report_Part :: struct {
	text:  Span,
	tally: Maybe(int),
	note:  Span,
}

Report :: struct {
	text:    [dynamic; REPORT_TEXT_MAX]u8,
	parts:   [dynamic; REPORT_PARTS_MAX]Report_Part,
	lines:   [dynamic; REPORT_LINES_MAX]Span,
	tallies: [dynamic; REPORT_TALLIES_MAX]Report_Tally,
}

Report_Note :: struct {
	text: string,
	note: Span,
}

Report_Arg :: union {
	string,
	f32,
	Report_Tally,
	Report_Note,
}

report_tally_add :: proc(tally: ^Report_Tally, label: string, value: f32, unit := Report_Unit.Points) {
	tally.total += value
	if value == 0 do return
	factor := Report_Factor {
		op    = .Add,
		unit  = unit,
		value = value,
	}
	append(&factor.label, ..transmute([]u8)label)
	append(&tally.factors, factor)
}

report_tally_scale :: proc(tally: ^Report_Tally, label: string, value: f32, unit := Report_Unit.Points) {
	tally.total *= value
	factor := Report_Factor {
		op    = .Scale,
		unit  = unit,
		value = value,
	}
	append(&factor.label, ..transmute([]u8)label)
	append(&tally.factors, factor)
}

report_say :: proc(report: ^Report, text: string, args: ..Report_Arg) {
	first := len(report.parts)
	report_write(report, text, args, true)
	append(&report.lines, Span{first, len(report.parts) - first})
}

report_text :: proc(report: ^Report, text: string, args: ..Report_Arg) -> Span {
	begin := len(report.text)
	report_write(report, text, args, false)
	return {begin, len(report.text) - begin}
}

report_string :: proc(report: ^Report, span: Span) -> string {
	return string(span_slice(report.text[:], span))
}

report_because :: proc(
	report: ^Report,
	held, absent: bit_set[$E],
	titles: [E]string,
) -> Span {
	write :: proc(report: ^Report, text: string) {
		append(&report.text, ..transmute([]u8)text)
	}

	begin := len(report.text)
	if held != {} || absent != {} do write(report, "Because ")
	joint := ""
	for fact in held {
		write(report, joint)
		write(report, titles[fact])
		joint = " and "
	}
	joint = held != {} ? ", and not " : "not "
	for fact in absent {
		write(report, joint)
		write(report, titles[fact])
		joint = " nor "
	}
	return {begin, len(report.text) - begin}
}

@(private = "file")
report_write :: proc(report: ^Report, text: string, args: []Report_Arg, as_parts: bool) {
	digits: [32]u8
	rest := text
	for arg in args {
		slot := strings.index_byte(rest, '%')
		assert(slot >= 0)
		report_put(report, rest[:slot], nil, {}, as_parts)
		rest = rest[slot + 1:]
		switch value in arg {
		case string:
			report_put(report, value, nil, {}, as_parts)
		case f32:
			report_put(report, fmt.bprintf(digits[:], "%v", value), nil, {}, as_parts)
		case Report_Tally:
			tally: Maybe(int)
			if as_parts && len(value.factors) > 0 && append(&report.tallies, value) == 1 {
				tally = len(report.tallies) - 1
			}
			total: string
			switch value.unit {
			case .Points:
				total = fmt.bprintf(digits[:], "%.1f", value.total)
			case .Men:
				total = compact_number(f64(value.total))
			case .Percent:
				total = fmt.bprintf(digits[:], "%.0f%%", 100 * value.total)
			}
			report_put(report, total, tally, {}, as_parts)
		case Report_Note:
			report_put(report, value.text, nil, value.note, as_parts)
		}
	}
	report_put(report, rest, nil, {}, as_parts)
}

@(private = "file")
report_put :: proc(report: ^Report, text: string, tally: Maybe(int), note: Span, as_part: bool) {
	if text == "" do return
	begin := len(report.text)
	append(&report.text, ..transmute([]u8)text)
	if as_part {
		append(&report.parts, Report_Part{Span{begin, len(report.text) - begin}, tally, note})
	}
}

compact_number :: proc(value: f64) -> string {
	SUFFIXES :: [?]string{"", "K", "M", "B"}
	sign := value < 0 ? "-" : ""
	magnitude := abs(value)
	tier := 0
	for math.round(magnitude) >= 1000 && tier < len(SUFFIXES) - 1 {
		magnitude /= 1000
		tier += 1
	}
	suffixes := SUFFIXES
	switch {
	case tier == 0:
		return fmt.tprintf("%s%.0f", sign, magnitude)
	case math.round(magnitude * 100) < 1000:
		return fmt.tprintf("%s%.2f%s", sign, magnitude, suffixes[tier])
	case math.round(magnitude * 10) < 1000:
		return fmt.tprintf("%s%.1f%s", sign, magnitude, suffixes[tier])
	}
	return fmt.tprintf("%s%.0f%s", sign, magnitude, suffixes[tier])
}
