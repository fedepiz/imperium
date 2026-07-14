//! The calendar: pure derivations of [`Epoch`], never stored. One epoch is
//! one day; epoch 0 is the dawn of the calendar (Day 1, Month 1, Year 0),
//! before which nothing can be.

use crate::world::Epoch;

pub const DAYS_PER_MONTH: u64 = 30;
pub const MONTHS_PER_YEAR: u64 = 12;
pub const DAYS_PER_YEAR: u64 = DAYS_PER_MONTH * MONTHS_PER_YEAR;

/// Distance between two points on the clock, in days, whichever way
/// around they're given.
pub fn days_between(a: Epoch, b: Epoch) -> u64 {
    a.0.abs_diff(b.0)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Date {
    pub year: u64,
    pub month: u64,
    pub day: u64,
}

impl Date {
    pub fn of(epoch: Epoch) -> Date {
        Date {
            year: epoch.0 / DAYS_PER_YEAR,
            month: epoch.0 % DAYS_PER_YEAR / DAYS_PER_MONTH + 1,
            day: epoch.0 % DAYS_PER_MONTH + 1,
        }
    }
}

impl core::fmt::Display for Date {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(
            f,
            "Day {} of Month {}, {} AUC",
            self.day, self.month, self.year
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_derive_from_the_epoch() {
        // Epoch 0 is the dawn of the calendar, not the start of the sim.
        assert_eq!(
            Date::of(Epoch(0)),
            Date {
                year: 0,
                month: 1,
                day: 1
            }
        );
        assert_eq!(
            Date::of(Epoch(29)),
            Date {
                year: 0,
                month: 1,
                day: 30
            }
        );
        assert_eq!(
            Date::of(Epoch(30)),
            Date {
                year: 0,
                month: 2,
                day: 1
            }
        );
        assert_eq!(
            Date::of(Epoch(360)),
            Date {
                year: 1,
                month: 1,
                day: 1
            }
        );
        assert_eq!(
            Date::of(Epoch(700 * DAYS_PER_YEAR)).to_string(),
            "Day 1 of Month 1, 700 AUC"
        );
    }

    #[test]
    fn days_between_ignores_direction() {
        assert_eq!(days_between(Epoch(10), Epoch(3)), 7);
        assert_eq!(days_between(Epoch(3), Epoch(10)), 7);
        assert_eq!(days_between(Epoch(5), Epoch(5)), 0);
    }
}
