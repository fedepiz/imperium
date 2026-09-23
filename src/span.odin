package main

// A half-open index range [begin, begin + len).
Span :: struct {
	begin: int,
	len:   int,
}

span_from_range :: proc(begin, end: int) -> Span {
	return {begin, end - begin}
}

span_from_array :: proc(array: ^[$N]$T) -> Span {
	return {0, len(array^)}
}

span_advance :: proc(span: ^Span) {
	if span.len > 0 {
		span.begin += 1
		span.len -= 1
	}
}

span_string :: proc(source: []byte, span: Span) -> string {
	return string(source[span.begin:][:span.len])
}
