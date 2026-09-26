package tabula

import "core:strconv"

// Text made of rows, key = value, one after another. A value is a number, a word, a "quoted string", an object of rows
// in { }, or a list of values in [ ] with commas between them. A key is a word, and can repeat. A document is an object
// with its braces left out. # starts a comment, to the end of the line.

Row_Flag :: enum {
	Has_Text,
	Has_Num,
}

// A key and its value. A word or a string is the text, without the quotes; a number is also the num. An object's rows
// and a list's values, which have no key, are the children.
Row :: struct {
	flags:    bit_set[Row_Flag],
	key:      string,
	text:     string,
	num:      f32,
	children: []Row,
}

// Where a document stops being readable, and why. The line and column count from 1, the column in bytes.
Error :: struct {
	line:    int,
	column:  int,
	message: string,
}

@(private = "file")
Parser :: struct {
	source:     string,
	pos:        int,
	line:       int,
	line_start: int,
	// The rows of every object and list still open, innermost last
	open:       [dynamic]Row,
	// The rows of those closed, each one's together
	closed:     []Row,
	closed_len: int,
	error:      Error,
}

// Reads a document into rows under the root. The keys and texts point into source, and the children are in alloc, so
// both must outlive the rows. On failure, returns where reading stopped.
parse :: proc(source: string, alloc := context.allocator) -> (root: Row, error: Error, ok: bool) {
	// Each row starts at a byte of the source no other row starts at
	p := Parser {
		source = source,
		line   = 1,
		open   = make([dynamic]Row, 0, len(source), context.temp_allocator),
		closed = make([]Row, len(source), alloc),
	}
	children, read := parse_rows(&p, 0)
	if !read do return {}, p.error, false
	return {children = children}, {}, true
}

// The first row under row with the key
find :: proc(row: Row, key: string) -> (found: Row, ok: bool) #optional_ok {
	for child in row.children do if child.key == key do return child, true
	return {}, false
}

// The text of the first row under row with the key and a text, or default
get_text :: proc(row: Row, key: string, default := "") -> (text: string, ok: bool) #optional_ok {
	for child in row.children do if child.key == key && .Has_Text in child.flags do return child.text, true
	return default, false
}

// The num of the first row under row with the key and a number, or default
get_num :: proc(row: Row, key: string, default: f32 = 0) -> (num: f32, ok: bool) #optional_ok {
	for child in row.children do if child.key == key && .Has_Num in child.flags do return child.num, true
	return default, false
}

// Reads rows up to close, or to the end of the source when close is 0: keyed ones for an object, values for a list.
@(private = "file")
parse_rows :: proc(p: ^Parser, close: u8) -> (children: []Row, ok: bool) {
	keyed := close != ']'
	begin := len(p.open)
	for {
		skip(p)
		if p.pos == len(p.source) {
			if close != 0 do return nil, fail(p, close == '}' ? "missing }" : "missing ]")
			break
		}
		if p.source[p.pos] == close {
			p.pos += 1
			break
		}
		key: string
		if keyed {
			key = word(p)
			if key == "" do return nil, fail(p, "expected a key")
			skip(p)
			if p.pos == len(p.source) || p.source[p.pos] != '=' do return nil, fail(p, "expected =")
			p.pos += 1
		}
		row := parse_value(p) or_return
		row.key = key
		append(&p.open, row)
		if !keyed {
			skip(p)
			if p.pos < len(p.source) && p.source[p.pos] == ',' do p.pos += 1
		}
	}
	children = p.closed[p.closed_len:][:len(p.open) - begin]
	copy(children, p.open[begin:])
	p.closed_len += len(children)
	resize(&p.open, begin)
	return children, true
}

@(private = "file")
parse_value :: proc(p: ^Parser) -> (row: Row, ok: bool) {
	skip(p)
	if p.pos == len(p.source) do return {}, fail(p, "missing value")
	switch p.source[p.pos] {
	case '{', '[':
		close: u8 = p.source[p.pos] == '{' ? '}' : ']'
		p.pos += 1
		row.children = parse_rows(p, close) or_return
	case '"':
		begin := p.pos + 1
		end := begin
		for end < len(p.source) && p.source[end] != '"' && p.source[end] != '\n' do end += 1
		if end == len(p.source) || p.source[end] != '"' do return {}, fail(p, "unclosed string")
		row.text = p.source[begin:end]
		row.flags += {.Has_Text}
		p.pos = end + 1
	case:
		row.text = word(p)
		if row.text == "" do return {}, fail(p, "expected a value")
		row.flags += {.Has_Text}
		switch row.text[0] {
		case '0' ..= '9', '-', '+', '.':
			if num, is_num := strconv.parse_f32(row.text); is_num {
				row.num = num
				row.flags += {.Has_Num}
			}
		}
	}
	return row, true
}

// Reads a word: bytes up to a space, a comment, or one of = { } [ ] , "
@(private = "file")
word :: proc(p: ^Parser) -> string {
	begin := p.pos
	scan: for p.pos < len(p.source) {
		switch p.source[p.pos] {
		case ' ', '\t', '\r', '\n', '#', '=', '{', '}', '[', ']', ',', '"':
			break scan
		}
		p.pos += 1
	}
	return p.source[begin:p.pos]
}

// Skips spaces and comments
@(private = "file")
skip :: proc(p: ^Parser) {
	for p.pos < len(p.source) {
		switch p.source[p.pos] {
		case '\n':
			p.line += 1
			p.line_start = p.pos + 1
		case ' ', '\t', '\r':
		case '#':
			for p.pos < len(p.source) && p.source[p.pos] != '\n' do p.pos += 1
			continue
		case:
			return
		}
		p.pos += 1
	}
}

@(private = "file")
fail :: proc(p: ^Parser, message: string) -> bool {
	p.error = {
		line    = p.line,
		column  = p.pos - p.line_start + 1,
		message = message,
	}
	return false
}
