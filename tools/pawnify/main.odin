// Turns the pawns' source drawings into the images the game draws, for every set in SETS: the detailed drawings pawns
// are seen as up close, and the medallions they are seen as from afar. Each source is a drawing in ink and wash on
// white paper; each becomes two images, cropped alike and scaled by its set's scale:
//   <name>.png       the drawing as ink and wash on glass: the white made clear, the ink a little heavier and in the
//                    map's ink colour
//   <name>_fill.png  its silhouette in white, a little wider than the drawing and soft at the edge, which the game
//                    draws in the paper's colour under the drawing so the map's marks do not show through
// Sources are named <culture>_<image>, as the game looks them up.
//
// Run from the repository root, after adding or changing a source: odin run tools/pawnify
// Every set is remade each run, and the outputs are committed alongside their sources.
package pawnify

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import stbi "vendor:stb/image"

Set :: struct {
	source, output: string,
	// How much the drawings are scaled down. Every source in a set is drawn at the same pen scale, so one factor for
	// all keeps the line the same weight across the set; how large each pawn is drawn is up to the game.
	scale:          f32,
}

SETS :: [?]Set {
	{source = "art/pawns", output = "assets/gfx/pawns", scale = 1.0 / 3.0},
	{source = "art/medallions", output = "assets/gfx/medallions", scale = 0.15},
}

// How far each ink stroke is thickened, and how far the silhouette reaches past the drawing, in source pixels
INK_GROW :: 2
FILL_MARGIN :: 8
// Passes of blur that soften the silhouette's edge
FILL_SOFTEN :: 3
// The terrain marks' ink, which every stroke is redrawn in
INK :: [3]f32{0.443, 0.373, 0.282}

// Colours are straight RGB from 0 to 1, in the images' own sRGB encoding.
Image :: struct {
	width, height: int,
	rgb:           [][3]f32,
}

main :: proc() {
	failed := false
	for set in SETS {
		entries, err := os.read_all_directory_by_path(set.source, context.allocator)
		if err != nil {
			fmt.eprintfln("Could not read %q: %v", set.source, err)
			failed = true
			continue
		}
		count := 0
		for entry in entries {
			if strings.to_lower(filepath.ext(entry.name)) != ".png" do continue
			name := strings.trim_suffix(entry.name, filepath.ext(entry.name))
			if pawnify(fmt.tprintf("%s/%s", set.source, entry.name), set.output, name, set.scale) do count += 1
			free_all(context.temp_allocator)
		}
		fmt.printfln("Made %d pawns from %q into %q", count, set.source, set.output)
	}
	if failed do os.exit(1)
}

// Makes one source into its two images; says whether it could.
pawnify :: proc(path, output, name: string, scale: f32) -> bool {
	image, ok := load(path)
	if !ok do return false
	n := image.width * image.height

	// Ink: dark strokes that are not wash, thickened and redrawn in the map's ink. Sepia is warm, red at least as strong
	// as green, and never very colourful; a wash is either colourful (vermilion) or cool (verdigris).
	ink := make([]f32, n, context.temp_allocator)
	for p, i in image.rgb {
		luma := 0.299 * p.r + 0.587 * p.g + 0.114 * p.b
		chroma := max(p.r, p.g, p.b) - min(p.r, p.g, p.b)
		warm := p.r >= p.g - 0.02
		ink[i] = chroma < 0.3 && warm ? clamp((0.75 - luma) / 0.35, 0, 1) : 0
	}
	ink = dilate(ink, image.width, image.height, INK_GROW)
	for &p, i in image.rgb do p = p * (1 - ink[i]) + INK * ink[i]

	// Glass: each pixel as the most transparent colour that, laid over white, gives what the drawing shows, so the
	// white goes clear and the wash tints whatever paper it is laid on
	glass := make([][4]f32, n, context.temp_allocator)
	for p, i in image.rgb {
		alpha := 1 - min(p.r, p.g, p.b)
		if alpha < 0.04 do continue
		glass[i] = {
			clamp((p.r - (1 - alpha)) / alpha, 0, 1),
			clamp((p.g - (1 - alpha)) / alpha, 0, 1),
			clamp((p.b - (1 - alpha)) / alpha, 0, 1),
			alpha,
		}
	}

	// Silhouette: the paper the border cannot reach through paper is inside the drawing
	inside := silhouette(glass, image.width, image.height)
	fill := dilate(inside, image.width, image.height, FILL_MARGIN)
	for _ in 0 ..< FILL_SOFTEN do fill = blur(fill, image.width, image.height)
	for &f, i in fill do f = max(f, inside[i])

	// Both cropped to the silhouette
	x0, y0, x1, y1 := image.width, image.height, 0, 0
	for f, i in fill {
		if f <= 0.02 do continue
		x, y := i % image.width, i / image.width
		x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x + 1), max(y1, y + 1)
	}
	if x1 <= x0 || y1 <= y0 {
		fmt.eprintfln("%q has no drawing in it", path)
		return false
	}
	rect := [4]int{x0, y0, x1, y1}
	ok = write(fmt.tprintf("%s/%s.png", output, name), glass, image.width, rect, scale, proc(g: [4]f32) -> [4]f32 {
		return g
	})
	ok &&= write(fmt.tprintf("%s/%s_fill.png", output, name), fill, image.width, rect, scale, proc(f: f32) -> [4]f32 {
		return {1, 1, 1, f}
	})
	if ok do fmt.printfln("%s: %dx%d, drawing %dx%d", name, image.width, image.height, x1 - x0, y1 - y0)
	return ok
}

// Loads a PNG as colours on white: any transparency in it is laid over white paper first.
load :: proc(path: string) -> (image: Image, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	w, h, channels: c.int
	pixels := stbi.load(cpath, &w, &h, &channels, 4)
	if pixels == nil {
		fmt.eprintfln("Could not load %q: %s", path, stbi.failure_reason())
		return
	}
	defer stbi.image_free(pixels)
	image = {int(w), int(h), make([][3]f32, int(w) * int(h), context.temp_allocator)}
	for &p, i in image.rgb {
		px := pixels[i * 4:][:4]
		alpha := f32(px[3]) / 255
		p = [3]f32{f32(px[0]), f32(px[1]), f32(px[2])} / 255 * alpha + (1 - alpha)
	}
	return image, true
}

// Grows every value to the largest within radius pixels of it.
dilate :: proc(values: []f32, width, height, radius: int) -> []f32 {
	out := make([]f32, len(values), context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			most: f32
			for dy in -radius ..= radius {
				yy := y + dy
				if yy < 0 || yy >= height do continue
				for dx in -radius ..= radius {
					xx := x + dx
					if xx < 0 || xx >= width || dx * dx + dy * dy > radius * radius do continue
					most = max(most, values[yy * width + xx])
				}
			}
			out[y * width + x] = most
		}
	}
	return out
}

// Averages every value with its four neighbours.
blur :: proc(values: []f32, width, height: int) -> []f32 {
	out := make([]f32, len(values), context.temp_allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			i := y * width + x
			sum, count := values[i], f32(1)
			if x > 0 {sum += values[i - 1]; count += 1}
			if x < width - 1 {sum += values[i + 1]; count += 1}
			if y > 0 {sum += values[i - width]; count += 1}
			if y < height - 1 {sum += values[i + width]; count += 1}
			out[i] = sum / count
		}
	}
	return out
}

// 1 inside the drawing and 0 outside it: a fill from every clear pixel on the border, through clear pixels only,
// marks the outside, and the strokes and whatever they enclose are left inside.
silhouette :: proc(glass: [][4]f32, width, height: int) -> []f32 {
	CLEAR :: 0.06
	outside := make([]bool, len(glass), context.temp_allocator)
	queue := make([dynamic]int, 0, len(glass), context.temp_allocator)
	for x in 0 ..< width {
		for y in ([2]int{0, height - 1}) do seed(glass, outside, &queue, y * width + x, CLEAR)
	}
	for y in 0 ..< height {
		for x in ([2]int{0, width - 1}) do seed(glass, outside, &queue, y * width + x, CLEAR)
	}
	for head := 0; head < len(queue); head += 1 {
		i := queue[head]
		x, y := i % width, i / width
		if x > 0 do seed(glass, outside, &queue, i - 1, CLEAR)
		if x < width - 1 do seed(glass, outside, &queue, i + 1, CLEAR)
		if y > 0 do seed(glass, outside, &queue, i - width, CLEAR)
		if y < height - 1 do seed(glass, outside, &queue, i + width, CLEAR)
	}
	inside := make([]f32, len(glass), context.temp_allocator)
	for o, i in outside do inside[i] = o ? 0 : 1
	return inside

	seed :: proc(glass: [][4]f32, outside: []bool, queue: ^[dynamic]int, i: int, clear: f32) {
		if outside[i] || glass[i].a >= clear do return
		outside[i] = true
		append(queue, i)
	}
}

// Writes the part of an image inside rect ([x0, y0, x1, y1]) as a PNG scaled by scale, each value turned into a
// straight-alpha colour by pixel. The scaling weighs colours by their alpha, so clear pixels do not darken edges.
write :: proc(path: string, values: []$T, width: int, rect: [4]int, scale: f32, pixel: proc(v: T) -> [4]f32) -> bool {
	w, h := rect[2] - rect[0], rect[3] - rect[1]
	crop := make([]u8, w * h * 4, context.temp_allocator)
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := pixel(values[(rect[1] + y) * width + rect[0] + x])
			for ch in 0 ..< 4 do crop[(y * w + x) * 4 + ch] = u8(math.round(clamp(p[ch], 0, 1) * 255))
		}
	}
	out_w := max(int(math.round(f32(w) * scale)), 1)
	out_h := max(int(math.round(f32(h) * scale)), 1)
	scaled := make([]u8, out_w * out_h * 4, context.temp_allocator)
	stbi.resize_uint8_srgb(
		raw_data(crop),
		c.int(w),
		c.int(h),
		0,
		raw_data(scaled),
		c.int(out_w),
		c.int(out_h),
		0,
		4,
		3,
		0,
	)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if stbi.write_png(cpath, c.int(out_w), c.int(out_h), 4, raw_data(scaled), c.int(out_w * 4)) == 0 {
		fmt.eprintfln("Could not write %q", path)
		return false
	}
	return true
}
