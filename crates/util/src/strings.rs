//! Owned, contiguous string storage addressed by [`Span`]s.
//!
//! Boundary types that outlive a phase (compiled modules, frame data,
//! long-lived game state) own one [`StrBuf`] each and refer into it with
//! spans instead of borrowing an arena: same flat layout and bulk
//! lifetime, but the containing struct is `'static` — it can be moved,
//! sent across threads, stored, and reloaded by plain reassignment.
//! Drops stay shallow (one `String`), and buffers recycle via
//! [`StrBuf::clear`].

/// A `u32` range into a shared buffer — a [`StrBuf`] or a flat `Vec`.
/// ZII: the zero span is the empty string / empty slice.
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
}

/// An owned, contiguous string table. The zero value is valid and empty;
/// [`StrBuf::clear`] recycles the allocation (and invalidates every span
/// issued so far — spans and their buffer travel together in one struct).
#[derive(Clone, Default, Debug)]
pub struct StrBuf(String);

impl StrBuf {
    /// Appends a string, returning the span that reads it back.
    pub fn push(&mut self, text: &str) -> Span {
        let start = self.0.len() as u32;
        self.0.push_str(text);
        Span {
            start,
            len: text.len() as u32,
        }
    }

    pub fn get(&self, span: Span) -> &str {
        &self.0[span.range()]
    }

    pub fn clear(&mut self) {
        self.0.clear();
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn push_and_get_roundtrip() {
        let mut buf = StrBuf::default();
        let one = buf.push("hello");
        let two = buf.push("");
        let three = buf.push("world");
        assert_eq!(buf.get(one), "hello");
        assert_eq!(buf.get(two), "");
        assert_eq!(buf.get(three), "world");
        assert!(two.is_empty() && !three.is_empty());
    }

    #[test]
    fn zii_zero_span_reads_empty_even_on_empty_buffer() {
        let buf = StrBuf::default();
        assert_eq!(buf.get(Span::default()), "");
        assert!(buf.is_empty());
    }

    #[test]
    fn clear_recycles() {
        let mut buf = StrBuf::default();
        buf.push("stale");
        buf.clear();
        assert!(buf.is_empty());
        let fresh = buf.push("fresh");
        assert_eq!(buf.get(fresh), "fresh");
        assert_eq!(fresh.start, 0);
    }
}
