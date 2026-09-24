package gfx

// Rects are [x, y, width, height], with a top-left origin.

// The part of both rects; empty rects keep their corner and have no size.
rect_intersect :: proc(r1: [4]f32, r2: [4]f32) -> [4]f32 {
	lo := [2]f32{max(r1.x, r2.x), max(r1.y, r2.y)}
	hi := [2]f32{min(r1.x + r1.z, r2.x + r2.z), min(r1.y + r1.w, r2.y + r2.w)}
	return {lo.x, lo.y, max(hi.x - lo.x, 0), max(hi.y - lo.y, 0)}
}

// The point is inside, counting the top and left edges but not the bottom and right.
rect_contains :: proc(rect: [4]f32, pt: [2]f32) -> bool {
	return pt.x >= rect.x && pt.y >= rect.y && pt.x < rect.x + rect.z && pt.y < rect.y + rect.w
}

rect_from_pos_size :: proc(pos: [2]f32, size: [2]f32) -> [4]f32 {
	return {pos.x, pos.y, size.x, size.y}
}
