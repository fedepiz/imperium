/// xorshift64*-style PRNG, one u64 of state. ZII: state 0 is valid —
/// `next_u64` remaps it to a fixed odd constant first, so a zeroed Rng is
/// just one particular seed. Deterministic by construction: sim state that
/// must live inside the world, never a global.
#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
pub struct Rng(pub u64);

/// splitmix64's finalizer: a bijective scramble, zero maps to zero.
fn mix(x: u64) -> u64 {
    let mut z = x;
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

impl Rng {
    /// The rng of one derived stream: a pure function of its key, so a
    /// draw anywhere is reproducible without threading rng state through
    /// the world — and streams with different keys are independent of
    /// each other and of draw order. The all-zero key yields state 0,
    /// which `next_u64` remaps like any zeroed Rng (ZII holds).
    pub fn at(seed: u64, turn: u64, n: u64) -> Rng {
        Rng(mix(mix(mix(seed).wrapping_add(turn)).wrapping_add(n)))
    }

    pub fn next_u64(&mut self) -> u64 {
        if self.0 == 0 {
            self.0 = 0x9E37_79B9_7F4A_7C15;
        }
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform in [0, 1): the top 24 bits, so every value is exact in f32.
    pub fn next_f32(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }

    /// True with probability `p`. `p <= 0.0` is never, `p >= 1.0` always;
    /// NaN reads as never.
    pub fn chance(&mut self, p: f32) -> bool {
        self.next_f32() < p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_seed_gives_a_fixed_sequence() {
        let mut a = Rng(42);
        let mut b = Rng(42);
        let first: Vec<u64> = (0..8).map(|_| a.next_u64()).collect();
        let second: Vec<u64> = (0..8).map(|_| b.next_u64()).collect();
        assert_eq!(first, second);
        // And actually varies.
        assert!(first.windows(2).any(|w| w[0] != w[1]));
    }

    #[test]
    fn zero_state_is_a_valid_seed() {
        let mut zeroed = Rng::default();
        let mut remapped = Rng(0x9E37_79B9_7F4A_7C15);
        assert_eq!(zeroed.next_u64(), remapped.next_u64());
        assert_eq!(zeroed.next_u64(), remapped.next_u64());
        // The state never returns to 0, so the stream never restarts.
        assert_ne!(zeroed.0, 0);
    }

    #[test]
    fn next_f32_stays_in_the_half_open_unit_interval() {
        let mut rng = Rng(7);
        for _ in 0..10_000 {
            let x = rng.next_f32();
            assert!((0.0..1.0).contains(&x));
        }
    }

    #[test]
    fn derived_streams_are_reproducible_and_independent() {
        // Same key, same stream.
        let mut a = Rng::at(7, 100, 3);
        let mut b = Rng::at(7, 100, 3);
        assert_eq!(a.next_u64(), b.next_u64());

        // Any word of the key differing diverges the stream.
        let base = Rng::at(7, 100, 3).next_u64();
        assert_ne!(Rng::at(8, 100, 3).next_u64(), base);
        assert_ne!(Rng::at(7, 101, 3).next_u64(), base);
        assert_ne!(Rng::at(7, 100, 4).next_u64(), base);

        // The all-zero key is the zeroed Rng: valid, ZII.
        assert_eq!(Rng::at(0, 0, 0), Rng::default());
    }

    #[test]
    fn chance_extremes_are_certain() {
        let mut rng = Rng(7);
        for _ in 0..1_000 {
            assert!(!rng.chance(0.0));
            assert!(!rng.chance(-1.0));
            assert!(!rng.chance(f32::NAN));
            assert!(rng.chance(1.0));
            assert!(rng.chance(2.0));
        }
    }
}
