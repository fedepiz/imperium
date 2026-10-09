package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sync"
import "core:thread"

STREAM_RING_BYTES :: 1 << 22

Stream_Kind :: enum {
	Rules,
}

Stream_Format :: #type proc(w: ^Json_Writer, tag: u32, payload: []u8)

@(private = "file")
RECORD_ALIGN :: 16
@(private = "file")
WRAP_TAG :: max(u32)
@(private = "file")
FLUSH_AT :: JSON_BUFFER_MAX / 2
@(private = "file")
THREAD_MEMORY_BYTES :: 4096

@(private = "file")
Record_Header :: struct {
	tag:  u32,
	size: u32,
	_:    [2]u32,
}
#assert(size_of(Record_Header) == RECORD_ALIGN)

@(private = "file")
Stream :: struct #align (RECORD_ALIGN) {
	ring:    [STREAM_RING_BYTES]u8,
	head:    int,
	tail:    int,
	used:    int,
	closing: bool,
	mutex:   sync.Mutex,
	changed: sync.Cond,
	file:    ^os.File,
	format:  Stream_Format,
	thread:  ^thread.Thread,
	writer:  Json_Writer,
}

@(private = "file")
STREAMS: [Stream_Kind]Stream

@(private = "file")
THREAD_MEMORY: [THREAD_MEMORY_BYTES]u8
@(private = "file")
THREAD_ARENA: mem.Arena

stream_open :: proc(kind: Stream_Kind, path: string, format: Stream_Format) -> bool {
	stream := &STREAMS[kind]
	if path == "-" {
		stream.file = os.stdout
	} else {
		file, err := os.open(path, {.Write, .Create, .Trunc}, os.Permissions_Default_File)
		if err != nil {
			fmt.eprintln("Could not open", path, err)
			return false
		}
		stream.file = file
	}
	stream.format = format

	if THREAD_ARENA.data == nil do mem.arena_init(&THREAD_ARENA, THREAD_MEMORY[:])
	drain_context := context
	context.allocator = mem.arena_allocator(&THREAD_ARENA)
	stream.thread = thread.create_and_start_with_poly_data(stream, stream_drain, drain_context)
	context.allocator = mem.panic_allocator()
	return stream.thread != nil
}

stream_close :: proc(kind: Stream_Kind) {
	stream := &STREAMS[kind]
	if stream.thread == nil do return
	sync.mutex_lock(&stream.mutex)
	stream.closing = true
	sync.cond_broadcast(&stream.changed)
	sync.mutex_unlock(&stream.mutex)

	thread.join(stream.thread)
	context.allocator = mem.arena_allocator(&THREAD_ARENA)
	thread.destroy(stream.thread)
	stream.thread = nil
	if stream.file != os.stdout do os.close(stream.file)
}

stream_push :: proc(kind: Stream_Kind, tag: u32, payload: []u8) {
	stream := &STREAMS[kind]
	assert(stream.thread != nil)
	total := mem.align_forward_int(size_of(Record_Header) + len(payload), RECORD_ALIGN)
	assert(total <= STREAM_RING_BYTES / 2)

	sync.mutex_lock(&stream.mutex)
	defer sync.mutex_unlock(&stream.mutex)

	for {
		to_end := STREAM_RING_BYTES - stream.head
		needed := total <= to_end ? total : to_end + total
		if STREAM_RING_BYTES - stream.used >= needed do break
		sync.cond_wait(&stream.changed, &stream.mutex)
	}
	if total > STREAM_RING_BYTES - stream.head {
		(^Record_Header)(&stream.ring[stream.head])^ = {
			tag = WRAP_TAG,
		}
		stream.used += STREAM_RING_BYTES - stream.head
		stream.head = 0
	}
	(^Record_Header)(&stream.ring[stream.head])^ = {
		tag  = tag,
		size = u32(len(payload)),
	}
	copy(stream.ring[stream.head + size_of(Record_Header):], payload)
	stream.head = (stream.head + total) % STREAM_RING_BYTES
	stream.used += total
	sync.cond_broadcast(&stream.changed)
}

@(private = "file")
stream_drain :: proc(stream: ^Stream) {
	for {
		sync.mutex_lock(&stream.mutex)
		for stream.used == 0 && !stream.closing do sync.cond_wait(&stream.changed, &stream.mutex)
		if stream.used == 0 {
			sync.mutex_unlock(&stream.mutex)
			break
		}
		header := (^Record_Header)(&stream.ring[stream.tail])^
		sync.mutex_unlock(&stream.mutex)

		consumed := STREAM_RING_BYTES - stream.tail
		if header.tag != WRAP_TAG {
			payload := stream.ring[stream.tail + size_of(Record_Header):][:header.size]
			stream.format(&stream.writer, header.tag, payload)
			consumed = mem.align_forward_int(
				size_of(Record_Header) + int(header.size),
				RECORD_ALIGN,
			)
		}
		if len(stream.writer.buffer) >= FLUSH_AT do stream_flush(stream)

		sync.mutex_lock(&stream.mutex)
		stream.tail = (stream.tail + consumed) % STREAM_RING_BYTES
		stream.used -= consumed
		drained := stream.used == 0
		sync.cond_broadcast(&stream.changed)
		sync.mutex_unlock(&stream.mutex)

		if drained do stream_flush(stream)
	}
	stream_flush(stream)
}

@(private = "file")
stream_flush :: proc(stream: ^Stream) {
	if len(stream.writer.buffer) == 0 do return
	_, _ = os.write(stream.file, stream.writer.buffer[:])
	clear(&stream.writer.buffer)
}
