//! A fixed-size bit set, sized in whole `u64` words. ZII: the default is
//! all zeroes — no bits set — and that's a fully valid, meaningful value.

/// `N * 64` flags packed into `N` words, flat and `Copy`, fit for inlining
/// into fat structs and arena-resident data (no `Drop`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct BitSet<const N: usize> {
    words: [u64; N],
}

/// By hand only because `derive` can't see through `[u64; N]`.
impl<const N: usize> Default for BitSet<N> {
    fn default() -> Self {
        BitSet { words: [0; N] }
    }
}

impl<const N: usize> BitSet<N> {
    /// How many bits fit; indices must stay below this.
    pub const CAPACITY: usize = N * 64;

    pub fn get(&self, index: usize) -> bool {
        self.words[index / 64] & 1 << (index % 64) != 0
    }

    pub fn set(&mut self, index: usize, value: bool) {
        let bit = 1 << (index % 64);
        if value {
            self.words[index / 64] |= bit;
        } else {
            self.words[index / 64] &= !bit;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_is_empty_and_bits_set_and_clear() {
        let mut bits = BitSet::<2>::default();
        assert_eq!(BitSet::<2>::CAPACITY, 128);
        assert!(!bits.get(0));
        assert!(!bits.get(127));

        bits.set(0, true);
        bits.set(63, true);
        bits.set(64, true);
        assert!(bits.get(0));
        assert!(bits.get(63));
        assert!(bits.get(64));
        assert!(!bits.get(1));

        bits.set(63, false);
        assert!(!bits.get(63));
        assert!(bits.get(0));
        assert!(bits.get(64));
    }

    #[test]
    #[should_panic]
    fn out_of_range_bits_panic() {
        BitSet::<1>::default().get(64);
    }
}
