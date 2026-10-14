# Principles

## State

- **One source per fact.** A fact lives in one place. Anything derived from it is written by one step and only read elsewhere: generals from title holders, `contains` from `inside`, `Region.owner` from the capital, `Character.office` from `Office.holder`.
- **No mirrored state kept by hand.** If two fields must agree, one of them is derived. Don't patch a copy at every place an event happens.
- **Store derived values; don't wrap lookups in procs.** A one-line lookup stays inline. A value needed in several places is stored on its record by the step that computes it (`movement_left`, `army.temperament`, `office.wealth`).
- **No intermediate fields.** A field with a single reader goes inside that reader's step (`town.locked`).
- **Refer to things by their id.** Characters are `Character_Id` everywhere, never a row index in some presentation list.

## The step

- **`game_step` is a list of `// Step:` blocks, each doing one job.**
- **Order:** orders first, reading the facts stored at the end of the last step. Then battle and removals, movement, the derived steps, the turn-end steps, and the turn change.
- **Orders only apply.** They check stored facts and change state; they derive nothing.
- **Derived steps rebuild from the sources every step.** They also reconcile records that follow from others: titles are created and destroyed from buildings and owners.
- **One thing per step.** For example, pieces are removed in a single step, fed by a list.
- **Loading is the start step.** Parse records, take a start step (`game.step == 0`), query the world, write the scenario's links, then take one more step to settle. Don't extract derive procs to share between load and step.
- **A one-step lag is fine** when a fact is read before the step that writes it.

## Rules

- **Each rule is written once, in the simulation.** "Can it be ordered now" is stored, with every condition included, your turn and nothing under way among them: `building_orders`, `can_mobilise`, `dismissal`, `can_appoint`, `can_move`, `endable`.
- **Orders check the stored fact. The presenter enables buttons from the same fact.**

## Presentation

- **The simulation decides, the presenter formats, the UI draws.**
- **The UI does no game arithmetic** and reads no simulation constants.
- **Tooltips have one format:** labelled terms, signed after the first, with a total when they add up, like combat. No sentence notes.

## One way per thing

- **One order slot:** the `Game_Order` union, End turn and Next included.
- **One click type:** `Card_Click`. Menus live in `Card.menus` and are opened by id.
- **One field drawer:** `field_ui`. Shared styles come from `Card_Theme`.
- **Repeated logic becomes a small pure proc** only when it has several callers: `men_toward_full`, `seed_from`, `scenario_file`, `row_check`.

## Budgets

- **Fixed caps everywhere,** clamped at append. Caps that depend on each other are defined from each other: Court rows equal the per-faction character cap, and `OFFICES_MAX` is factions times the per-faction office cap.
- **Scratch memory comes from the temp allocator.**

## Data

- **Every key in a data file is a struct field.** A mistyped key stops loading rather than reading as 0. Keys without a default are required.
- **A data file opens with a commented example record:** every key in order, each annotated, with its default or marked required. Records give the required keys, and defaulted keys only when they differ, in the example's order (`army_types.txt`).

## Code

- **Comments only for what the code can't say:** units, ranges, sentinels, a non-obvious rule. No comment that restates a name.
- **Names say what they are:** `Building_Orders` not `Slot_Orders`, `muster_at` not `at`, `pieces_to_remove`.
