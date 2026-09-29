#+private
package game

import "core:fmt"
import "core:os"

import "../gfx"
import "../sim"

// The two sets of drawings an icon comes in: its picture, seen up close, and its medallion, seen from afar
Icon_Set :: enum u8 {
	Picture,
	Medallion,
}

// The fonts the map and its cards are written in: names and text, and titles
Font :: enum u8 {
	Text,
	Title,
}

// Each icon's drawings are made from art/<set> by tools/pawnify, as <culture>_<tag> under assets/gfx/<set>. Each has
// a silhouette, <culture>_<tag>_fill, to draw in paper under it.
@(private = "file", rodata)
ICON_TAGS := [sim.Icon]string {
	.Village    = "town_0",
	.Town       = "town_1",
	.City       = "town_2",
	.Large_City = "town_3",
	.Army       = "army",
	.Fleet      = "fleet",
	.Priest     = "bishop",
	.Envoy      = "envoy",
}

// The folder under assets/gfx each set's drawings are in, and each culture's part of their names
@(private = "file", rodata)
ICON_SET_NAMES := [Icon_Set]string {
	.Picture   = "pawns",
	.Medallion = "medallions",
}

@(private = "file", rodata)
CULTURE_NAMES := [sim.Culture]string {
	.Roman    = "roman",
	.Germanic = "germanic",
}

@(private = "file")
ICONOGRAPHY: struct {
	// Each icon's drawing in each set and each culture's style, and its silhouette. A drawing not there yet is the
	// blank image.
	image: [sim.Icon][Icon_Set][sim.Culture]gfx.Image_Id,
	fill:  [sim.Icon][Icon_Set][sim.Culture]gfx.Image_Id,
	// Stands in for a drawing that is not there yet: fully clear
	blank: gfx.Image_Id,
	fonts: [Font]gfx.Font_Id,
}

// Defines the icons' images and the fonts, so call this before sprites_load.
iconography_init :: proc() {
	ICONOGRAPHY.blank = gfx.sprites_image_add("blank")
	ICONOGRAPHY.fonts = {
		.Text  = gfx.sprites_font_add("forgotten_uncial", 22),
		.Title = gfx.sprites_font_add("forgotten_uncial", 36),
	}
	for tag, icon in ICON_TAGS {
		for set_name, set in ICON_SET_NAMES {
			for culture_name, culture in CULTURE_NAMES {
				drawing := fmt.tprintf("%s/%s_%s", set_name, culture_name, tag)
				ICONOGRAPHY.image[icon][set][culture] = image_or_blank(drawing)
				ICONOGRAPHY.fill[icon][set][culture] = image_or_blank(fmt.tprintf("%s_fill", drawing))
			}
		}
	}

	image_or_blank :: proc(name: string) -> gfx.Image_Id {
		if !os.exists(fmt.tprintf("assets/gfx/%s.png", name)) do return ICONOGRAPHY.blank
		return gfx.sprites_image_add(name)
	}
}

// An icon's drawing in a set, in a culture's style
icon_image :: proc(icon: sim.Icon, set: Icon_Set, culture: sim.Culture) -> gfx.Image_Id {
	return ICONOGRAPHY.image[icon][set][culture]
}

// The silhouette of an icon's drawing in a set, in a culture's style
icon_fill :: proc(icon: sim.Icon, set: Icon_Set, culture: sim.Culture) -> gfx.Image_Id {
	return ICONOGRAPHY.fill[icon][set][culture]
}

font_id :: proc(font: Font) -> gfx.Font_Id {
	return ICONOGRAPHY.fonts[font]
}
