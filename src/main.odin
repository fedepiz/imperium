package main

import "core:fmt"

import sdl "vendor:sdl3"

main :: proc() {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("Failed to initialised SDL", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow("Imperium", 1600, 900, {})
	if window == nil {
		fmt.eprintln("Failed to consturct window")
		return
	}
	defer sdl.DestroyWindow(window)


	// WGPU initialisation

	renderer := renderer_init(window)
	defer renderer_deinit(renderer)

	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					running = false
				}
			}
		}

		if !renderer_draw(&renderer) {
			sdl.Delay(16)
		}
	}
}

