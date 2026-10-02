#+private
package game

import "core:fmt"
import "core:os"

import "../gfx"
import "../sim"

// Picture: zoomed in. Medallion: zoomed out.
Icon_Set :: enum u8 {
	Picture,
	Medallion,
}

Font :: enum u8 {
	Text,
	Title,
}

// Images: assets/gfx/<set>/<culture>_<tag>, plus <culture>_<tag>_fill silhouettes. Made by tools/pawnify.
@(private = "file", rodata)
ICON_TAGS := [sim.Icon]string {
	.Village    = "town_0",
	.Town       = "town_1",
	.City       = "town_2",
	.Large_City = "town_3",
	.Army       = "army",
	.Fleet      = "fleet",
}

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
	// Missing drawings use blank
	image: [sim.Icon][Icon_Set][sim.Culture]gfx.Image_Id,
	fill:  [sim.Icon][Icon_Set][sim.Culture]gfx.Image_Id,
	// Fully transparent
	blank: gfx.Image_Id,
	fonts: [Font]gfx.Font_Id,
}

// Call before sprites_load
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

icon_image :: proc(icon: sim.Icon, set: Icon_Set, culture: sim.Culture) -> gfx.Image_Id {
	return ICONOGRAPHY.image[icon][set][culture]
}

icon_fill :: proc(icon: sim.Icon, set: Icon_Set, culture: sim.Culture) -> gfx.Image_Id {
	return ICONOGRAPHY.fill[icon][set][culture]
}

font_id :: proc(font: Font) -> gfx.Font_Id {
	return ICONOGRAPHY.fonts[font]
}
