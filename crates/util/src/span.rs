//! Flat, contiguous storage addressed by [`Span`]s.
//!
//! Boundary types that outlive a phase (compiled modules, frame data,
//! long-lived game state) keep their variable-length data in linear
//! buffers — a flat `Vec<T>` for records, a `String` for text — and
//! refer into them with spans instead of borrowing an arena: same flat
//! layout and bulk lifetime, but the containing struct is `'static` — it
//! can be moved, sent across threads, stored, and reloaded by plain
//! reassignment. Drops stay shallow, and buffers recycle via `clear`
//! (which invalidates every span issued so far — spans and their buffer
//! travel together in one struct).
//!
//! A bare span doesn't say which buffer it reads; give each role a typed
//! wrapper (`struct NameStr(pub Span);`) at the owning module.

/// A `u32` range into a shared linear buffer — a flat `Vec` or a
/// `String`. ZII: the zero span is the empty slice / empty string.
#[derive(Clone, Copy, Default, Debug, PartialEq, Eq)]
pub struct Span {
    pub start: u32,
    pub len: u32,
}

impl Span {
    pub fn is_empty(self) -> bool {
        self.len == 0
    }

    pub fn range(self) -> core::ops::Range<usize> {
        self.start as usize..(self.start + self.len) as usize
    }

    /// The span's part of a flat buffer.
    pub fn slice<T>(self, buffer: &[T]) -> &[T] {
        &buffer[self.range()]
    }

    pub fn slice_mut<T>(self, buffer: &mut [T]) -> &mut [T] {
        &mut buffer[self.range()]
    }

    /// The span's part of a string buffer.
    pub fn str(self, buffer: &str) -> &str {
        &buffer[self.range()]
    }

    pub fn str_mut(self, buffer: &mut str) -> &mut str {
        &mut buffer[self.range()]
    }

    /// Appends one item, returning the span that reads it back. Grow a
    /// multi-item span by widening `len` as contiguous pushes land.
    pub fn push<T>(buffer: &mut Vec<T>, item: T) -> Span {
        let start = buffer.len() as u32;
        buffer.push(item);
        Span { start, len: 1 }
    }

    /// Appends a string, returning the span that reads it back.
    pub fn push_str(buffer: &mut String, text: &str) -> Span {
        let start = buffer.len() as u32;
        buffer.push_str(text);
        Span {
            start,
            len: text.len() as u32,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_str_and_read_roundtrip() {
        let mut buf = String::new();
        let one = Span::push_str(&mut buf, "hello");
        let two = Span::push_str(&mut buf, "");
        let three = Span::push_str(&mut buf, "world");
        assert_eq!(one.str(&buf), "hello");
        assert_eq!(two.str(&buf), "");
        assert_eq!(three.str(&buf), "world");
        assert!(two.is_empty() && !three.is_empty());
        one.str_mut(&mut buf).make_ascii_uppercase();
        assert_eq!(one.str(&buf), "HELLO");
    }

    #[test]
    fn spans_slice_flat_vecs() {
        let mut table = vec![10, 20, 30];
        let span = Span { start: 1, len: 2 };
        assert_eq!(span.slice(&table), [20, 30]);
        span.slice_mut(&mut table)[0] = 25;
        assert_eq!(table, [10, 25, 30]);

        let mut one = Span::push(&mut table, 40);
        assert_eq!(one.slice(&table), [40]);
        // Contiguous pushes widen into one span.
        Span::push(&mut table, 50);
        one.len += 1;
        assert_eq!(one.slice(&table), [40, 50]);
    }

    #[test]
    fn zii_zero_span_reads_empty_even_on_empty_buffers() {
        assert_eq!(Span::default().str(""), "");
        assert_eq!(Span::default().slice(&[] as &[i32]), []);
    }

    #[test]
    fn clear_recycles() {
        let mut buf = String::new();
        Span::push_str(&mut buf, "stale");
        buf.clear();
        assert!(buf.is_empty());
        let fresh = Span::push_str(&mut buf, "fresh");
        assert_eq!(fresh.str(&buf), "fresh");
        assert_eq!(fresh.start, 0);
    }
}
