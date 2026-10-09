package main

// T -> payload type
// N -> max num of payloads
// HT -> "handle type"
Slot_Map :: struct($T: typeid, $N: u32, $HT: typeid) {
	// Value of elements in the slotmap
	payloads:    [N]T,
	// Generation of value in. Even = empty, Odd = used
	generations: [N]u32,
	// Free list
	free:        [dynamic; N]u32,
	// Last used (to have a zeroed-out free list)
	used:        u32,
	// Number of valid items
	count:       u32,
}

Slot_Map_Key :: struct {
	index:      u32,
	generation: u32,
}

slot_map_insert :: proc(sm: ^$SM/Slot_Map($T, $N, $HT), value: T) -> HT {
	if sm.count == N {return {}}
	idx: u32
	if len(sm.free) == 0 {
		idx = sm.used
		sm.used += 1
	} else {
		idx = pop(&sm.free)
	}
	assert(sm.generations[idx] % 2 == 0)
	sm.generations[idx] += 1
	sm.payloads[idx] = value
	sm.count += 1
	return {index = idx, generation = sm.generations[idx]}
}

slot_map_remove :: proc(sm: ^$SM/Slot_Map($T, $N, $HT), key: HT) -> (ok: bool) {
	if key.generation != 0 && key.index < N && sm.generations[key.index] == key.generation {
		assert(key.generation % 2 == 1)
		sm.generations[key.index] += 1
		append(&sm.free, key.index)
		ok = true
		sm.count -= 1
	}
	return
}

slot_map_get :: proc(sm: ^$SM/Slot_Map($T, $N, $HT), key: HT) -> ^T {
	if key.generation == 0 || key.index >= N || sm.generations[key.index] != key.generation do return nil
	return &sm.payloads[key.index]
}

// Walks the used slots: `it := slot_map_iterator(&sm); for value, key in slot_map_iterate(&it)`.
// Removing while iterating is safe; inserting is not (a reused slot may be visited or not)
Slot_Map_Iterator :: struct($T: typeid, $N: u32, $HT: typeid) {
	sm:  ^Slot_Map(T, N, HT),
	// Next slot to look at
	idx: u32,
}

slot_map_iterator :: proc(sm: ^$SM/Slot_Map($T, $N, $HT)) -> Slot_Map_Iterator(T, N, HT) {
	return {sm = sm}
}

// In/out: it.
// The next used slot's payload and key. False when none are left
slot_map_iterate :: proc(it: ^Slot_Map_Iterator($T, $N, $HT)) -> (value: ^T, key: HT, ok: bool) {
	for it.idx < it.sm.used {
		idx := it.idx
		it.idx += 1
		if it.sm.generations[idx] % 2 == 0 do continue
		return &it.sm.payloads[idx], {index = idx, generation = it.sm.generations[idx]}, true
	}
	return
}
