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

The setting is **committed: sub-Roman Britain**, late 5th century —
the migration period, Britons and incoming Anglo-Saxons after the
legions left. The UI mocks say "Dumnonia, 493"; the visual language
is manuscript vellum and oxblood; names and places are Anglo-Saxon
(for now made up, e.g. Cenred of Wealdham). Other eras that fit the
essence (late antiquity broadly, the Mycenaean world, pre-Roman
Italy) informed the pillars but are no longer candidates.

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

## The map

Taken, like much else, from ROTK VII: the world is a grid of square
cells, and the map is the authored truth about space.

- Every cell is painted as one of: part of a settlement or other
  location (settlements are *blobs* — a contiguous group of cells
  bearing the same place), road, or impassable. Blobs are always
  odd-sided squares — 1x1 or 3x3 in practice — so every place has an
  exact center cell, its *anchor*, where arriving people stand.
- Underneath lies a logical graph — places as nodes, road-cell chains
  as edges — but it is *derived* from the painted grid, never authored
  separately, so the two cannot disagree.
- Position is a cell, not a graph node. A traveler is on some road cell
  partway between places — visible, meetable, interruptible — and
  "being in a settlement" simply means standing on one of its cells.
  The graph answers questions (distance, direction); bodies live on
  the grid.
- Passability is a movement *cost*, not a boolean, with zero meaning
  impassable — so later variation (water travel for those who can
  sail, trackless wilds) is a tweak, not a redesign. For now,
  impassable is absolute.
- Cell scale is tentatively 5–10 km — a few road cells per day of
  walking, so multi-day journeys show progress each tick. Not yet
  committed.
- Travel: an activity whose target is a *cell* — ordering
  travel to a settlement means ordering travel to its anchor. One cell
  per day, along the cheapest route; nobody remembers a route (each day
  re-asks from where they stand, so redirection and interruption are
  free), and arriving — or finding no way there — ends the activity,
  which for the player also pauses time. Clicking a settlement on the
  map is how the order is given.

## Interactions

The game's fundamental choice mechanism, underpinning conversations
with characters, events, dealings with towns — any moment where the
sim stops to offer options and someone picks one.

- An interaction is modal sim state: a prompt and a set of options
  (possibly parameterized — a target person, an amount). While one is
  open for the player, time is force-paused; the pick arrives as a
  command like any other input, so interaction-heavy play is still
  seed + command stream — replays and exemplar runs never need to
  know interactions exist.
- Resolution is continuation-passing in style: resolving an option
  transforms the world and may hand back the *next* interaction. A
  chain, never a stack — the current interaction is replaced or
  cleared, never suspended and resumed. Usually the option names its
  successor directly (conversation flow); the sim can also raise
  interactions unprompted (encounters, arrivals, events).
- An open interaction is *not* authoritative world state: it lives
  beside the world (in Game, not World), and the game cannot be saved
  mid-interaction — a save is always a world between choices. An
  unanswered interaction needn't be persisted or resolved; it can
  simply be re-raised. (Architecturally this also lets the
  interaction and the world be borrowed separately.)
- Interactions are instants — the moment of choice, not the activity.
  An option can *order* an activity ("stay the night" → rest a day);
  choice and time stay orthogonal.
- Authoring: built in code first; data-driven interaction content is
  the likely endgame (events are content, content wants to be data),
  but the effect-language gets designed after a few interactions exist
  by hand, not before.
- Whether NPC AI chooses through the same option structures (one
  definition of a situation, player picks by click, NPC picks by
  scoring) is attractive but uncommitted — see open questions.

Relationships and opinions are not a separate system on top: they are
world state that interactions read (who will say what to whom) and
write (what a conversation did to a bond).

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

- The map cell scale (5–10 km is the working guess), and with it how
  many cells a day's travel covers.
- What the player's verb set is at each station of life (retainer,
  householder, lord...).
- How reputation/legend is measured and what it buys.
- What "winning" means, if anything, beyond the story of a life.
- Whether NPCs decide through the same interaction structures the
  player does, or through separate AI machinery.
