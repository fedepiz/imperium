package span

// A half-open index range [begin, begin + len).
Span :: struct {
	begin: int,
	len:   int,
}

from_range :: proc(begin, end: int) -> Span {
	return {begin, end - begin}
}

from_array :: proc(array: ^[$N]$T) -> Span {
	return {0, len(array^)}
}

advance :: proc(s: ^Span) {
	if s.len > 0 {
		s.begin += 1
		s.len -= 1
	}
}

// The part of source the span covers, as a string.
to_string :: proc(source: []byte, s: Span) -> string {
	return string(source[s.begin:][:s.len])
}
