#+private
package main
import "core:slice"

// All sorts of mixed math helper types
Range_F32 :: struct {
	min: f32,
	max: f32,
}

Extents :: struct {
	x_min: f32,
	y_min: f32,
	x_max: f32,
	y_max: f32,
}

Rect :: struct {
	x: f32,
	y: f32,
	w: f32,
	h: f32,
}

Axis :: enum {
	X,
	Y,
}

//  Shelf packing algorithm
shelf_pack :: proc(region: [2]int, sizes: [][2]int, padding: int, pos: [][2]int) -> bool {
	assert(len(sizes) == len(pos))

	Pack_Entry :: struct {
		height: int,
		index:  int,
	}

	// Sort the inputs by height to simplify shelf-packing
	entries := make([]Pack_Entry, len(sizes), context.temp_allocator)
	for size, i in sizes do entries[i] = {size.y, i}
	slice.sort_by(entries, proc(a, b: Pack_Entry) -> bool {return a.height > b.height})

	// Perform shelf packing
	cursor: [2]int
	shelf_height := 0
	for entry in entries {
		size := sizes[entry.index]
		if size.x == 0 || size.y == 0 {
			pos[entry.index] = {}
		} else {
			if cursor.x + size.x > region.x {
				cursor.x = 0
				cursor.y += shelf_height + padding
				shelf_height = 0
			}

			if cursor.x + size.x > region.x || cursor.y + size.y > region.y {
				return false
			}

			pos[entry.index] = cursor
			cursor.x += size.x + padding
			shelf_height = max(shelf_height, size.y)
		}
	}
	return true
}
