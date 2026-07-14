# Imperium — design document

The game's concept and direction. This is a living document: it evolves
alongside the game, and decisions recorded here should be updated when
play or taste proves them wrong. Technical and code-style matters live
elsewhere (CLAUDE.md); this file is only about what the game *is*.

## The concept

Imperium is a character-driven strategy sim in the spirit of Romance of
the Three Kingdoms VII: **you are one person inside the world, not a
faction**. The player character has a body, a location, a household, a
reputation, and relationships — and climbs (or falls) through them. You
might begin as a wandering sword, a younger son, a village strongman;
you might end a king, an exile, or a name in someone else's saga.

The world keeps living around you. Other characters pursue their own
ambitions with the same verbs the player has; the player is not the
protagonist of the simulation, only of their own story.

## The setting: a heroic age

The working essence, more important than any particular century:

- **Power is personal, not institutional.** The state is a man and his
  household/retinue. Authority dies with its holder; every succession is
  a crisis.
- **Politics is face-to-face.** Oaths, marriages, feuds, hostages,
  gift-exchange, hospitality. There is no bureaucracy to act through —
  if you want something done, you deal with a person.
- **A fragile, small-scale world in the shadow of a greater order** —
  fallen or not yet risen. Rome has receded, or civilization hasn't
  arrived yet; either way, people build small and remember (or imagine)
  big.
- **History shading into legend.** The events of play should feel like
  the raw material sagas are made of. Deeds outlive men; reputation is a
  currency.

Candidate settings that fit the essence (not yet committed):

- Post-Roman Britain (the current working flavor — the UI mocks say
  "Dumnonia, 493" and the visual language is manuscript vellum and
  oxblood).
- Late antiquity more broadly.
- Bronze Age Near East / Mycenaean world.
- Early or pre-Roman Italy.

Despite the code-name, the setting is **not** imperial Rome itself —
Rome is the shadow, not the stage.

## Pillars

1. **One person, fully situated.** Everything the player does routes
   through who they are, where they are, and whom they know. No
   disembodied faction-level clicking.
2. **Relationships are the terrain.** Bonds, grudges, debts and oaths
   are the map on which ambition moves. Improving a relationship is as
   strategic an act as raising troops.
3. **A living cast.** NPCs act on their own ambitions, remember what
   was done to them, and are playable-shaped: anything an NPC does, the
   player could in principle do in their place.
4. **Legible consequence.** The world reacts in ways the player can
   trace back to people: *he* refused because *you* shamed his brother.
   Not opaque global modifiers.

## Scale and texture

- A cast of a few thousand living entities — characters, settlements,
  factions — small enough that individuals matter, large enough that the
  world doesn't revolve around the player.
- Time flows in coarse, deliberate ticks (days), with the player free to
  pause and set the pace. The intended rhythm is thoughtful, not
  twitchy.
- Presentation leans on the manuscript world: the game reads like a
  chronicle being written about you — vellum, ink, oxblood — rather
  than a command console.

## Open questions

- Which setting to commit to (post-Roman Britain currently leading).
- What the player's verb set is at each station of life (retainer,
  householder, lord...).
- How reputation/legend is measured and what it buys.
- What "winning" means, if anything, beyond the story of a life.
