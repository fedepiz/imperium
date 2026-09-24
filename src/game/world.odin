package game

WORLD: struct {
	atlas: Atlas,
}

WORLD_WIDTH :: 1024
WORLD_HEIGHT :: 1024
CELLS_MAX :: WORLD_WIDTH * WORLD_HEIGHT

TERRAINS_MAX :: 256

Atlas :: struct {
	terrains: [TERRAINS_MAX]Terrain,
	cells:    [CELLS_MAX]Map_Cell,
}

Terrain_Id :: distinct u8

Terrain :: struct {}

Map_Cell :: struct {
	terrain: Terrain_Id,
}
