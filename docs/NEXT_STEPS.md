# Next steps

What is left to do, as of 2026-10-12, after the "Public order" commit. Grouped by area. Each item says what is already
decided, what is still open, and where it touches the code. All numbers in the data files are temporary.

## Where we are

The economy layer exists end to end, in a first version:

- **Towns** (`Town` on settlement pieces):
  - Population staffs buildings and drifts toward what its food supports (5% of the gap a turn, growth capped at 2%).
  - Fertility (1–4) is copied from the region.
  - Food, labour, income, upkeep and public order are flows summed from the buildings each step, each shown as a
    balance bar on the Town tab.
- **Buildings** (`buildings.txt`):
  - Wheat, cattle and sheep chains of three levels, plus stables, barracks, palace, praetorium and curia.
  - Upgrade links, per-culture build lists (`cultures.txt`), descriptions, and slots: 4 for towns, 8 for cities.
- **Construction:** one project per slot (build, upgrade, demolish, cancel) from the tile popups. Projects advance a
  turn at the owner's turn end and fire project events.
- **Treasury:** income (curias, livestock, mills), scaled by control; upkeep from buildings and recruited armies.
- **Control:**
  - Palaces and praetoria radiate it, summed, flooded over land travel cost (`CONTROL_DECAY` 1 per unit).
  - It stays inside the faction's own regions and is built together with supply at load and each turn change.
  - Control map mode and a Control bar.
- **Armies** (`army_types.txt`):
  - Types with scope (Local or Global), stats, `recruit_requires` features, costs and descriptions.
  - Recruiting is immediate, at 20% strength, next to the town.
  - Global armies cost coin; local ones draw labour from their home town and reinforce only in their home region.
  - Scenario armies are built from types.

## Economy

### 1. Public order: what it does (economy step 5)

Decided:

- Buildings give it, through the `public_order` key: positive keeps order, negative stirs unrest. A town sums the
  values as given, with no scaling.
- Religion's primary role is public order (see 3).

Open:

- **Effects.** Today it is only a number. Candidates: low order reduces outputs or control; very low order leads to
  revolt, which ties into the politics layer (a disloyal local magnate, local troops). Order "controls the ability to
  rule locally".
- **Other inputs.** Candidates:
  - a labour deficit (overwork), and possibly a labour surplus in big towns (idle hands);
  - food shortage;
  - religious alignment;
  - garrisons;
  - control;
  - tax pressure.
- **Scale.** Whether order is a raw sum, as now, or a 0–100 level that moves toward a target, like readiness and
  population.

### 2. Labour: what it is for

Decided:

- Labour is a produced flow (buildings' `labour` key), separate from population.
- It is never split or rationed. Consumers and projects run in full, and using more than is made only shows a deficit.
- Use it or lose it: unspent labour is wasted.

Open:

- **What a deficit implies.** Nothing yet; probably public order (see 1).
- **Its local uses.** So far: the curia (labour into income), construction, and local army upkeep. Candidates:
  - fortification upkeep (see Combat);
  - public order uses;
  - local security.
- **Construction is a pulse,** not a steady flow, so the Labour bar jumps while building. One idea: construction costs
  time plus coin, and labour is kept for steady uses only. Undecided.
- **Removing labour entirely,** with population as the local resource, was discussed and not chosen.

### 3. Religion

Decided, the user's design:

- **Each town** has a religion breakdown, its faiths' shares. Each faction has a state religion.
- **The primary role is public order:** a bonus for the state religion matching the town's faiths.
- **Conversion:** churches and temples shift the breakdown toward their faith over time.
- **Secondary role, religious buildings' own costs and benefits:**
  - Latin and Greek Christianity give a control bonus at a fixed coin cost ("a religion for the centralised world").
  - Arianism gives less control, for less coin or a labour cost.
  - Other religions are to be decided.
- **East and West have the same rules;** their difference should come from economics (who can pay for bureaucracy).

To build:

- A `Religion` enum, or data-driven ids like cultures.
- `Town.faiths: [Religion]f32` and `Faction.religion`.
- A `religion` key on buildings, filtering who can build them, and a `converts` effect.
- Starting breakdowns in `pieces.txt`.
- Display on the Town tab, and possibly a map mode.

### 4. Grain pool and granaries (economy step 6)

Decided:

- Large empires concentrate food: big cities can be fed by the wider empire.
- A faction granary (stock), and local granaries (capped stock).

Deferred, then postponed:

- A `grain` building key: global, scaled by control, into `Faction.granary`. The open question is whether exports are
  fixed (they can starve the town, as requisition did) or come only from surplus.
- How the granary is spent: feeding cities beyond their local food, with priorities.
- Local granaries smoothing food swings.

### 5. Treasury in debt (bankruptcy)

Deferred by the user ("ignore it for now"). Today the treasury can go negative with no effect.

The proposal discussed: upkeep is paid at the ratio of available to owed, and buildings with upkeep run at that
ratio. Unpaid offices would then lose control while bishoprics paid in labour keep theirs: the fall of the West
emerging from economics.

### 6. Food shortage

Today a shortage only makes the population shrink, slowly: 5% of the gap per turn, the same rate as growth. Open:

- **Decline speed:** should starvation be faster than growth (a separate decline rate)?
- **Other effects:** public order, staffing collapse.

### 7. Garrisons as army types

Settlement garrisons are still hand-set men and proficiency in `pieces.txt`, using `ARMY_FORAGING_DEFAULT` and
`ARMY_MOBILITY_DEFAULT`. Option: garrison army types, perhaps one per settlement size, written out in full like other
types.

### 8. Control, follow-ups

- **Culture:** the decay could differ by culture (Roman bureaucracy reaching further).
- **Blockers:** whether enemy armies should block control as they block supply.
- **Timing:** control is rebuilt only at load and each turn change, so a palace finished mid-turn counts from the next
  turn.
- **Map:** it shows only the playing faction's control.
- **Starting data:** Roma's praetorium is partly redundant next to Ravenna's palace, and the south (Rhegium,
  Syracusae) is dark.

### 9. Construction and recruitment, follow-ups

- **Commands:** town orders (build, upgrade, demolish, cancel, recruit) come only from clicks; there is no command
  for them, so they cannot be scripted or tested headless.
- **Rules log:** project and recruit events write building kinds and army types as numeric ids, not names.
- **Recruits:** they appear on the first land cell around the town, and can move in the turn they are raised.
- **Army tab:** it does not show a local army's home region.
- **Generals:** new armies have none, until the politics layer appoints them.

## Combat (parked topics)

Parked by the user to discuss, not implement:

- **Readiness in battle:** it should matter "a bit" more than now. Options raised: lower odds, fewer men engaged,
  heavier losses.
- **Fortification and participant caps:** built once, then rolled back. The preferred shape if it returns: high means
  fortified; a scale rather than an absolute cap; a fact about armies that settlements supply; siegecraft lowering it.
  - New link: maintaining walls could be a steady labour sink in towns, giving labour a military payoff.

## Politics layer (the final pillar)

The user's vision:

- **The elites:** named characters make up your elites, and there is a general view of them.
- **Roles:** they are needed to run towns, armies and the central state's offices.
- **Traits:** they have loyalty and capabilities.
- **The minigame:** keeping them loyal by respecting the pecking order.
- **A threat as well:** they are the people on the ground, and the souls of rebellions.

Proposed first slice, not yet agreed:

1. A roster of named elites per faction, each with rank, loyalty and one or two capabilities.
2. Appointing governors to towns and generals to armies.
3. One economic effect (for example a governor's loyalty scaling his town's income) and one political rule
   (appointing over someone's head costs his loyalty).
4. Revolt: very low loyalty plus low public order means the governor takes his town.

Where it meets the economy:

- Local power (local armies, local control) is efficient but held by local elites.
- Global power (coin armies, offices) is costly but loyal to the throne.
- Coin, land and offices become political currency.

## Diplomacy

A possible mini-pillar. Not designed yet.

## Known limitations and technical debt

- **Fixed card height:** `FOCUS_ROWS` (7) is a fixed row count for the focus card. Adding a row to a tab can spill
  past it.
- **Wrapping:** long Features lists, and long names in the stats column, can wrap and overflow the fixed height.
- **Breakdown budget:** `CARD_BREAKDOWNS_MAX` (128) bounds the hover tooltips per card. Every build option and recruit
  option takes one.
- **Tooltip lingering:** decided from the contents (buttons, inputs, keyed text, scrolling). A tooltip whose only hover
  target is a plain keyed panel or meter would not count as reachable.
- **Features:** a compile-time enum (`Horses`, `Drill`, `Court`); adding one needs code.
- **Visual checks:** checking the windowed game needs Accessibility permission for the click helper, and fails when
  the game window opens behind the terminal.
