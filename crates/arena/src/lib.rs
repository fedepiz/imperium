use core::mem;
use core::ops::{Deref, DerefMut};

use bumpalo::Bump;

/// A bump allocator that only accepts types without drop glue.
///
/// `Bump` never runs destructors on the values it holds, so allocating a
/// type with a meaningful `Drop` (or one that owns such a type) would
/// silently leak. Every allocation method here rejects those types at
/// compile time via a `const` assertion on `mem::needs_drop`.
#[derive(Default)]
pub struct Arena(Bump);

impl Arena {
    pub fn new() -> Self {
        Arena(Bump::new())
    }

    /// Frees all allocations, retaining the largest chunk for reuse.
    /// Nothing is dropped — only trivially destructible values live here.
    pub fn reset(&mut self) {
        self.0.reset();
    }

    pub fn allocated_bytes(&self) -> usize {
        self.0.allocated_bytes()
    }

    /// ```compile_fail
    /// let arena = arena::Arena::new();
    /// arena.alloc(String::from("has Drop"));
    /// ```
    pub fn alloc<T>(&self, value: T) -> &mut T {
        const {
            assert!(
                !mem::needs_drop::<T>(),
                "Arena cannot hold types that need Drop"
            )
        };
        self.0.alloc(value)
    }

    pub fn alloc_default<T: Default>(&self) -> &mut T {
        self.alloc(T::default())
    }

    pub fn alloc_str(&self, str: &str) -> &mut str {
        self.0.alloc_str(str)
    }

    pub fn alloc_slice_copy<T: Copy>(&self, slice: &[T]) -> &mut [T] {
        self.0.alloc_slice_copy(slice)
    }
}

/// A growable vector backed by an [`Arena`].
///
/// Same compile-time rule as the arena itself: `T` must not need Drop,
/// enforced in the constructors (the only way `T` gets pinned down).
pub struct AVec<'a, T>(bumpalo::collections::Vec<'a, T>);

impl<'a, T> AVec<'a, T> {
    /// ```compile_fail
    /// let arena = arena::Arena::new();
    /// let v: arena::AVec<String> = arena::AVec::new_in(&arena);
    /// ```
    pub fn new_in(arena: &'a Arena) -> Self {
        const { assert!(!mem::needs_drop::<T>(), "AVec cannot hold types that need Drop") };
        AVec(bumpalo::collections::Vec::new_in(&arena.0))
    }

    pub fn with_capacity_in(capacity: usize, arena: &'a Arena) -> Self {
        const { assert!(!mem::needs_drop::<T>(), "AVec cannot hold types that need Drop") };
        AVec(bumpalo::collections::Vec::with_capacity_in(capacity, &arena.0))
    }

    pub fn push(&mut self, value: T) {
        self.0.push(value);
    }

    pub fn pop(&mut self) -> Option<T> {
        self.0.pop()
    }

    pub fn clear(&mut self) {
        self.0.clear();
    }

    pub fn capacity(&self) -> usize {
        self.0.capacity()
    }

    pub fn reserve(&mut self, additional: usize) {
        self.0.reserve(additional);
    }

    /// Consumes the vector, leaving its contents as a slice in the arena.
    pub fn into_slice(self) -> &'a mut [T] {
        self.0.into_bump_slice_mut()
    }
}

impl<'a, T: Copy> AVec<'a, T> {
    pub fn extend_from_slice(&mut self, slice: &[T]) {
        self.0.extend_from_slice_copy(slice);
    }
}

impl<'a, T> Deref for AVec<'a, T> {
    type Target = [T];

    fn deref(&self) -> &[T] {
        &self.0
    }
}

impl<'a, T> DerefMut for AVec<'a, T> {
    fn deref_mut(&mut self) -> &mut [T] {
        &mut self.0
    }
}

impl<'a, T> Extend<T> for AVec<'a, T> {
    fn extend<I: IntoIterator<Item = T>>(&mut self, iter: I) {
        self.0.extend(iter);
    }
}

impl<'a, 'v, T> IntoIterator for &'v AVec<'a, T> {
    type Item = &'v T;
    type IntoIter = core::slice::Iter<'v, T>;

    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

impl<'a, T: core::fmt::Debug> core::fmt::Debug for AVec<'a, T> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        self.0.fmt(f)
    }
}

/// A growable UTF-8 string backed by an [`Arena`].
///
/// Contents are plain bytes, so no Drop guard is needed here.
pub struct AString<'a>(bumpalo::collections::String<'a>);

impl<'a> AString<'a> {
    pub fn new_in(arena: &'a Arena) -> Self {
        AString(bumpalo::collections::String::new_in(&arena.0))
    }

    pub fn with_capacity_in(capacity: usize, arena: &'a Arena) -> Self {
        AString(bumpalo::collections::String::with_capacity_in(capacity, &arena.0))
    }

    pub fn from_str_in(str: &str, arena: &'a Arena) -> Self {
        AString(bumpalo::collections::String::from_str_in(str, &arena.0))
    }

    pub fn push(&mut self, ch: char) {
        self.0.push(ch);
    }

    pub fn push_str(&mut self, str: &str) {
        self.0.push_str(str);
    }

    pub fn pop(&mut self) -> Option<char> {
        self.0.pop()
    }

    pub fn clear(&mut self) {
        self.0.clear();
    }

    pub fn capacity(&self) -> usize {
        self.0.capacity()
    }

    pub fn reserve(&mut self, additional: usize) {
        self.0.reserve(additional);
    }

    pub fn as_str(&self) -> &str {
        self.0.as_str()
    }

    /// Consumes the string, leaving its contents as a `&str` in the arena.
    pub fn into_str(self) -> &'a str {
        self.0.into_bump_str()
    }
}

impl<'a> Deref for AString<'a> {
    type Target = str;

    fn deref(&self) -> &str {
        self.0.as_str()
    }
}

impl<'a> core::fmt::Write for AString<'a> {
    fn write_str(&mut self, s: &str) -> core::fmt::Result {
        self.0.push_str(s);
        Ok(())
    }
}

impl<'a> core::fmt::Display for AString<'a> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        core::fmt::Display::fmt(self.as_str(), f)
    }
}

impl<'a> core::fmt::Debug for AString<'a> {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        core::fmt::Debug::fmt(self.as_str(), f)
    }
}

impl<'a> PartialEq<str> for AString<'a> {
    fn eq(&self, other: &str) -> bool {
        self.as_str() == other
    }
}

impl<'a> PartialEq<&str> for AString<'a> {
    fn eq(&self, other: &&str) -> bool {
        self.as_str() == *other
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn alloc_and_mutate() {
        let arena = Arena::new();
        let x = arena.alloc(41u64);
        *x += 1;
        assert_eq!(*x, 42);
    }

    #[test]
    fn alloc_default() {
        let arena = Arena::new();
        assert_eq!(*arena.alloc_default::<u32>(), 0);
    }

    #[test]
    fn alloc_str_and_slice() {
        let arena = Arena::new();
        assert_eq!(arena.alloc_str("hello"), "hello");
        assert_eq!(arena.alloc_slice_copy(&[1, 2, 3]), &[1, 2, 3]);
    }

    #[test]
    fn avec_push_index_iterate() {
        let arena = Arena::new();
        let mut v = AVec::new_in(&arena);
        v.push(1u32);
        v.push(2);
        v.extend_from_slice(&[3, 4]);
        assert_eq!(v.len(), 4);
        assert_eq!(v[2], 3);
        assert_eq!(v.iter().sum::<u32>(), 10);
        assert_eq!(v.pop(), Some(4));
        let slice = v.into_slice();
        assert_eq!(slice, &[1, 2, 3]);
    }

    #[test]
    fn astring_build_and_freeze() {
        use core::fmt::Write;

        let arena = Arena::new();
        let mut s = AString::from_str_in("hello", &arena);
        s.push(',');
        s.push_str(" world");
        write!(s, " #{}", 1).unwrap();
        assert_eq!(s, "hello, world #1");
        assert!(s.starts_with("hello"));
        let frozen: &str = s.into_str();
        assert_eq!(frozen, "hello, world #1");
    }

    #[test]
    fn reset_allows_reuse() {
        let mut arena = Arena::new();
        arena.alloc(1u8);
        arena.reset();
        assert_eq!(*arena.alloc(7u32), 7);
    }
}
