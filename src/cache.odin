#+private
package main

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"

// Precomputed data kept between runs: cache/<name>.bin holds the key it was made under, then its bytes

@(private = "file")
CACHE_DIRECTORY :: "cache"

// One fnv64a over all of them, in order
hash_bytes :: proc(parts: ..[]u8) -> u64 {
	key := hash.fnv64a(nil)
	for part in parts do key = hash.fnv64a(part, key)
	return key
}

// Out: out. False when the file is missing, made under another key, or not len(out) bytes long
cache_read :: proc(name: string, key: u64, out: []u8) -> bool {
	file, error := os.read_entire_file_from_path(fmt.tprintf("%s/%s.bin", CACHE_DIRECTORY, name), context.temp_allocator)
	if error != nil || len(file) != size_of(u64) + len(out) do return false
	stored: u64
	copy(mem.ptr_to_bytes(&stored), file)
	if stored != key do return false
	copy(out, file[size_of(u64):])
	return true
}

// Failing only costs the next run the computation
cache_write :: proc(name: string, key: u64, data: []u8) {
	path := fmt.tprintf("%s/%s.bin", CACHE_DIRECTORY, name)
	os.make_directory(CACHE_DIRECTORY)
	file := make([]u8, size_of(u64) + len(data), context.temp_allocator)
	key := key
	copy(file, mem.ptr_to_bytes(&key))
	copy(file[size_of(u64):], data)
	if error := os.write_entire_file(path, file); error != nil do fmt.eprintln("Could not write", path, error)
}
