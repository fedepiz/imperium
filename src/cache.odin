package main

import "core:fmt"
import "core:mem"
import "core:os"

// Cache files: data derived at load, kept on disk so later runs can skip deriving it.
// A file is a fingerprint, then the data. The fingerprint is a hash of whatever the data was derived
// from, so a file whose fingerprint differs from the current one is stale

CACHE_FOLDER :: "cache"

// The fingerprint and data of cache file name, in temporary memory. Missing or truncated: empty data
cache_read :: proc(name: string) -> (fingerprint: u64, data: []u8) {
	path := fmt.tprintf("%s/%s.cache", CACHE_FOLDER, name)
	file, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(file) < size_of(u64) do return
	copy(mem.ptr_to_bytes(&fingerprint), file[:size_of(u64)])
	return fingerprint, file[size_of(u64):]
}

// Writes fingerprint, then data, to cache file name. False, with a message, if it could not
cache_write :: proc(name: string, fingerprint: u64, data: []u8) -> bool {
	path := fmt.tprintf("%s/%s.cache", CACHE_FOLDER, name)
	// An error here shows up as the write failing
	_ = os.make_directory(CACHE_FOLDER)
	fingerprint := fingerprint
	file := make([]u8, size_of(u64) + len(data), context.temp_allocator)
	copy(file, mem.ptr_to_bytes(&fingerprint))
	copy(file[size_of(u64):], data)
	if err := os.write_entire_file(path, file); err != nil {
		fmt.eprintln("Could not write cache", path, err)
		return false
	}
	return true
}
