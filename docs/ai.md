# The AI

Where the game AI stands, how it is built, why it is built that way, and how we work on it. Written 2026-10-15, at commit `f51fd60 Proto-AI`. Read `docs/principles.md` first. This document assumes it.

The AI is being designed together with the user, one piece at a time, over many sessions. Nothing here was one-shot, and nothing new should be either.

---

## 1. How we work on it

These come from corrections during the sessions so far. They matter as much as the code.

- **Propose, then wait.** "What's next?" means proposing the next step and its open decisions, then stopping. Write code only after an explicit go for that specific step. A plan proposed earlier is not approved just because the user didn't object.
- **Explain with the game first.** The user doesn't read the code before the explanation. Start every explanation from what happens in the game (an army, a town, a turn), then say how the code does it. Missing context was the most frequent complaint ("CONTEXT!!!!"). Give the essentials in one or two lines. Add detail only when asked.
- **An explanation request is read-only.** Don't edit while explaining, even to fix a flaw you notice. List the flaws separately and offer the fix.
- **Shape before code.** For any non-trivial change, first say in a few lines which existing loop, step or record each new piece goes into, naming the precedent already in the file. Then write it in small pieces, never as a sweeping scripted patch.
- **Self-review before showing.** Re-read the diff and ask four questions. Is there a new execution path where an existing one could take the case? Is anything copied? Are there per-kind branches where data would do? Are the names generic or thematic? Then check the explanation too: does it give context to someone who hasn't seen the code? First drafts here drift toward generic defaults (extracted procs, per-kind switches, duplicate blocks), and the user said "every time it needs to be a double take". The double take has to happen before the user sees it.
- **Compact the execution paths.** Different cases (real orders, the hover's forecast, the AI's questions) run through the same loop, told apart by data. This is not about less code, and not about factoring shared behaviour into procs ("that is what procs are for"). Two paths sharing a proc are still two paths. The six procs first written for the questions were rejected for this reason.
- **Comments: only what the code can't say.** Units, ranges, sentinels, a non-obvious rule. Short, no prose, nothing that restates a name. "Mind the comments!" was said more than once.
- **One trial, one report.** When an agreed experiment fails (a custom heap gave no speed-up in debug), report the numbers and stop. Don't go on to try variants.
- **MBs are fine.** Prefer flat worst-case budgets. State the sizes, but don't treat them as a problem.
- **Don't drive the user's game window.** The user runs their own instance (`odin run src`, process `src.bin`), and SDL opens every instance at the same screen position. A test click once landed in the user's game. Check headless or with a harness. If the window really has to be seen, ask the user to look.
- **No lookup procs.** A one-line lookup stays inline. Derived values are stored on records by the one step that computes them.
- **Uniform, mechanical naming.** The AI pipeline (armies, goals, plans, questions, score, select, act) is template-blind. Game verbs (Take, Strike) appear only as data or inside the cases that need them. The user dislikes thematic concepts multiplying: "refuge" and `AI_Candidate` were both rejected.

---

## 2. The aim

- **A competent opponent first.** "If it can beat me, then it can also be tuned down." Personalities and agendas come later, as weights over the same machinery.
- **Not a flat utility AI.** The user said "flat feels hopeless". There is a layer of goals above the orders. Plans are scored, but against goals, not as a bag of actions.
- **Distances are movement.** Never "within N turns" cutoffs. Every distance is movement points through the real map: flood, site graph, voyages.
- **Abstract before rollouts.** Use cheap structured estimates now: a flood, a site graph, a few battle runs. Forked what-if simulations (fork the game, change a fact, step, read the result) are a later tool, for things like the value of a target as a change in a board score.
- **Armies first.** Fielded armies only. Money, offices, mustering and politics come later as more resources the same pipeline allocates.

---

## 3. The one rule: the AI is a player

**`game_step` is the rules. The AI never restates them.** The user put it as: "never, ever EVER duplicate the rules".

- The AI lives in its own module, `src/game_ai.odin`. It's a player that reads and asks, but never simulates.
- It reads stored facts on `Game`: pieces, towns, `this_turn` flags, `zones`, `site_graph`, `voyages`, `appointment`, `interaction`.
- Everything it needs predicted, it asks through `Game_Questions` (section 5). The step answers in the same loops that run the real moves and battles.
- It acts only through `Game_Order`, the same single order slot the player uses. One order per think. Then it waits for the game to settle before thinking again.

So anything the AI does, the player could do with the same clicks. Anything it predicts, it predicts with the rule the game will actually apply.

---

## 4. Threads and the loop

### Who owns what

Everything lives under one root, `GLOBAL` in `src/main.odin`, grouped by owning thread:

- **Main thread:** `camera`, `render_data`, `pawns`. It handles input, the UI and rendering. It draws only from a `Presentation`.
- **Game thread:** `game`, `game_events`, `questions`, `ai`. It steps at 60 Hz on its own clock (at most `STEPS_AT_ONCE_MAX` steps per wake), presents, and runs the AI.
- **Shared:** `presentations: [3]Presentation`, each held by one thread at a time and handed over by index. `game_thread: Game_Thread` holds what passes between the threads, under its `mutex`.

`Game_Thread` holds:

- `running`;
- `inputs: Game_Inputs` (main → game);
- `ready` (index of the presentation published and not yet taken);
- `fresh`.

`Game_Inputs` is everything the game side reads from the main thread:

- `focus`, `hover`, `pointer`, `map_mode`, `tab`;
- `order`: taken by the next step. A new order waits until the old one is taken.
- `ai_turn`: a one-shot toggle that starts or stops the AI on the side to move;
- `ai_report`: whether the report window is shown, so worth presenting.

A `Presentation` is everything the main thread draws: terrain frame, pawns and their piece ids, cards, the step and orders count. Nothing in it points into the game. Its strings live in its own 4 MB text arena: `present` points the temp allocator at that arena, and the name and description converters clone.

The game thread's own allocations come from the shared `THREAD_ARENA` (`src/stream.odin`). Its default allocator is the panic allocator. Creating the thread through the panic allocator crashed once.

### One game-thread tick, in order (`game_thread_run`)

1. Pace: sleep until at least one step is due.
2. Under the mutex, copy `inputs` and clear the one-shots (`order`, `ai_turn`).
3. **AI on/off.** `ai_turn` toggles `ai.side` between `game.player` and 0, sets `ai.rule = .None` and clears `ai.ordered`. If the side to move is no longer `ai.side` (the turn passed), `ai.side = 0`. The AI plays one side's turn, then switches off.
4. **Is the game waiting for input?** `awaiting := under_way == {} || under_way & {.March, .Ending} == {} && .Battle in under_way`. Either nothing is going on, or a battle report is open and waiting for Next.
5. **While the AI plays:** the player's order is held back. If `awaiting`, `ai_decide` runs and its `ai.order` becomes the step's order. Once the AI's rule is `Wait`, the player's order passes through, so the player ends the turn. "AI turn" never ends the turn by itself; the user asked for that.
6. **Questions:** clear the batch, append the hover as the drawn move question, then `ai_ask` if the AI plays, the game awaits, and the rule is `Ask`.
7. Run the due steps with the order and the questions. The first step takes the order.
8. `present` into the held presentation, then swap it with `ready` under the mutex and set `fresh`.

The main loop takes a fresh presentation when there is one, copies the pawn scene, runs commands, writes `inputs`, and draws. Headless mode (`--headless --commands`) has no game thread. It presents before each command and steps with `questions = nil`, so the AI never runs headless.

---

## 5. Asking the rules: `Game_Questions`

```odin
Game_Questions :: struct {
	moves:   [dynamic; MOVE_QUESTIONS_MAX]Move_Question,     // 2048
	battles: [dynamic; BATTLE_QUESTIONS_MAX]Battle_Question, // 16384
	floods:  [dynamic; FLOOD_QUESTIONS_MAX]Flood_Question,   // 32
}
```

The caller fills in what is asked. The step that takes the batch writes the answers in place. Three kinds:

- **`Move_Question{order, runs, drawn}`.** "If this move were ordered now, what happens?"
  - **Answers:** `refusal` (nil means it can be ordered now, so the target is in reach this turn); `arrival` (where the piece would end, with what movement, readiness and statuses); `outcomes` (shares of `runs` battles per `Battle_Forecast`, with the mover attacking from its arrival state).
  - `drawn = true` marks **the hover**: the move a right click would give. At most one. It is also predicted in full on `game.movement` for the UI's arrow and forecast. The UI's hover was the first question; the AI's are more of the same.
- **`Battle_Question{attacker, defender, runs}`.** "If the attacker were rested and in contact with the defender as it is, how would it go?" Rested means:
  - readiness at its supply level;
  - resting, not seasick;
  - Spent only as that readiness implies;
  - not having attacked this turn.

  **Answers:** `outcomes`. The AI uses it as the plan's long-run odds, separate from how the army would arrive today.
- **`Flood_Question{army}`.** "Where can this army get to, at what cost?" It floods the army's 256×256-cell box with the zones and bodies around it as they are, not capped by its movement left.
  - **Answers:** `corner` (top-left cell of the box); `cost` per box cell (INF: not reached); `sites`: the movement to each site inside the box (INF: outside it or not reached).
  - This is the AI's first leg: real, with live zones. Far legs come from the site graph.

**Where they are answered.** They are not a separate pass. They are more entries in loops that already exist:

- **Step: March plans.** One walk-entry list holds every move question's walk, every flood question's flood, then the planned marches. Questions share one scratch `March`, since each answer is read as it is walked. The real move's flood goes last, so it stays for the reach display.
- **Step: Battles.** One battle-entry list holds the real contacts (run once with their seed), the hover forecast, each move question's battle (mover as it would arrive), and each battle question's battle (attacker rested). Each entry carries a pointer to the `outcomes` it tallies into. There is no per-kind switch and no post-pass.

**Why the planning block runs before Battles.** Move questions need their arrival from March plans, and Battles reads it. So one step answers a whole batch, and one think needs a single step.

**Adding a prediction** means adding a question kind and feeding it into the loop that already does that work. It never means a new proc that re-runs a rule on the side.

---

## 6. Space: sites, distances, fields

A full-map flood per army per think is too slow, and reasoning "from cell to cell" is too fine. So space comes in three tools: a site graph for far distances, the army's own flood for the first leg, and fields for "what is it like here".

### Sites and the site graph (built at load, cached)

- **Sites** (`game.sites`, max 256, 0 = none) are the settlements, then the beaches (`beach.site` links each beach to its site). Each is moved to the nearest land cell within `SITE_LAND_REACH`. Sites are derived, not authored. The user agreed: settlements plus beaches are enough for now.
- **`Site_Graph`**, whose bytes are its cache:
  - `land[s][t]`: movement over land from site s to site t, INF for no way. It is filled by one whole-map flood from each site, with nobody on the map. The dense table means no adjacency needs authoring.
  - `cell_site` (`Field(Site_Id, 1)`): each cell's nearest site by land movement.
  - `cell_distance` (`Field(f32, 1)`): the movement from that site. Both come from one multi-source flood.
- **Cache:** `cache/roman_sites.bin`, under the key `hash_bytes(SITES_CACHE_VERSION, SITES_MAX, MAP_CELLS, land grid, sites)`. Bump `SITES_CACHE_VERSION` when the floods change how they compute. `cache_read` / `cache_write` in `src/cache.odin` store the key, then raw bytes. A failed write only costs the next run the computation.
- **Size:** about 5.3 MB: `land` 256 KB, plus two full-resolution fields.

### Voyages (each step, for the side to move)

`game.voyages[b]` is the set of beaches one voyage reaches from beach b. It is computed each step (Step: Voyages) from the sea rule `sea_voyage`: along the lanes, through the owner's beaches only, within `SEA_RANGE`. Ownership changes are therefore always current, and no sea data is cached.

### `sites_distance(game, start, distance)`

Dijkstra over the sites. Input is a start cost per site (INF: not a start). Edges are the dense `land` table plus the voyages. A voyage costs one turn's movement, `army_template.movement_per_turn` (30). Output is movement to every site. Cost: 256 sites, dense, trivially cheap.

### Distance from an army to a target (what the AI does)

1. The army's flood question gives the movement to each site in its box: the first leg, live.
2. `sites_distance` from those costs gives the movement to every site: the far legs, static.
3. The target's `cell_site` and `cell_distance` close the last leg: `distance = through[target's site] + cell_distance[target]`.

Enemy zones count only in the first leg. Far legs ignore them for now (agreed).

### Fields

```odin
Field :: struct($T: typeid, $SCALE: int) { values: [(MAP_WIDTH / SCALE) * (MAP_HEIGHT / SCALE)]T }
```

A value per field cell, where one field cell covers SCALE × SCALE map cells (the map is 1024 × 1024). How a field aggregates its cells is up to its producer (the step). Sampling is uniform:

- `field_sample_nearest(field, pos) -> T`: the field cell holding the position, clamped to the map.
- `field_sample_bilinear(field, pos) -> f32`: blended from the four nearest field-cell centres. INF neighbours are left out, and all-INF gives INF.

This is the user's idea for spatial reasoning: fields are values per cell, combined by weight rows ("purposes": rest, advance, …), then an argmax over reachable cells. The combination is never stored. It replaced earlier one-off concepts (refuges, withdraw points, "toward").

| Field | Type, scale | Built | For whom | What |
|---|---|---|---|---|
| `supply_network` | u8, 1 | load, turn change | side to move | supply 0..100, kept out of enemy zones |
| `control_network` | u8, 1 | load, turn change | side to move (every faction at the start step, for `town.control`) | control 0..100 within its regions |
| `enemy_distance` | f32, 1 | load, turn change | side to move | movement from the nearest enemy army, **capped at `ENEMY_DISTANCE_MAX` = 150** (5 turns); INF beyond |
| `zones` | u8, `ZONES_SCALE` = 2 | every step | side to move | 1 where an army ending its turn would meet an enemy army's zone, in any cell of the block |
| `focus_distance` | f32, `FOCUS_DISTANCE_SCALE` = 4 | when its key changes | — | movement from the focused piece to each cell, through the sites; key = hash(focus, its position, voyages) |
| `site_graph.cell_site`, `cell_distance` | 1 | load (cached) | — | see above |

**Control** goes through one loop over factions: `if !starting && owner != game.player do continue`. The start step and later steps share one code path, as the user asked. One `control_network` map is stored, for the side to move. Every faction's `town.control` is written at the start.

**The enemy-distance cap** came from a stutter on End turn. The uncapped flood took 242 ms in debug. Capped, it takes about 26 ms, and a turn change went from about 300 ms to about 38 ms. Past 5 turns of movement, no enemy counts as near.

### Map modes for seeing them

Map modes come in two rows of buttons, all the same size:

- **Row 0:** Political, Control, Supply, Fertility, Plain.
- **Row 1** (added for the AI):
  - **Sites:** circles on every site.
  - **Zones:** wash of `zones`.
  - **Enemies:** wash of `enemy_distance`, fading over 150.
  - **Distance:** wash of `focus_distance` from the selected piece, fading over 150.

---

## 7. The AI module (`src/game_ai.odin`)

### Vocabulary

- **Army** (`AI_Army`): one of the side's field armies: `.Has_Army`, with a `domain`, owned by the side. `acted`: it moved by land or sea or fought this turn, so it gets no more orders. Army `a` asks flood question `floods_first + a`.
- **Template** (`AI_Template`): a kind of goal. The `AI_TEMPLATES` table says which pieces a template targets: `AI_Targets{flags, enemy}`. Today there is one: `.Take = {flags = {.Capturable}, enemy = true}`.
- **Goal** (`AI_Goal`): one template applied to one target piece, with its value. The value is a sum of named `value_terms` (`AI_Value_Term`: Coin, Food), kept as terms for the report.
- **Plan** (`AI_Plan`): one army toward one goal. Plan `p` asks move question `moves_first + p` (the move onto the target, with `runs` battles) and battle question `battles_first + p` (rested, `runs` battles). The program gives each plan a rule (`AI_Plan_Rule`: Give_Up, Strike, Approach), a score made of named terms (`AI_Score_Term`: Value, Odds, Distance, Continuity), and a selection (`AI_Selection`).
- **Think** (`AI_Think`): what one think asked and decided: armies, goals, plans, where its questions start in the batch, and which plan it ordered (`acting`, -1 for none).
- **Rule** (`AI_Rule`): the AI's last decision, and the status line in the UI: None "Starting", Read_Report "Reads the report", Appoint "Appoints", Ask "Thinks", Act "Acts", Wait "Waits".

Indexing is positional and one-to-one: army ↔ flood, plan ↔ move and battle question. There are no ids inside the batch.

### `Game_AI`

```odin
Game_AI :: struct {
	weights: AI_Weights,                    // from ai.txt
	side:    Faction_Id,                    // the side it plays until its turn ends; 0: off
	rule:    AI_Rule,
	order:   Game_Order,
	thinks:  [2]AI_Think,                   // the decided one is shown while the other is asked
	decided: int,
	kept:    [dynamic; AI_ARMIES_MAX]AI_Plan_Key, // chosen at the last think
	ordered: [dynamic; AI_ARMIES_MAX]AI_Plan_Key, // ordered since it started on the side
}
AI_Plan_Key :: struct { template: AI_Template, target: Piece_Id, army: Piece_Id }
```

`AI_Plan_Key` identifies a plan across thinks, since plan indices don't survive from one think to the next.

### A think takes two ticks

Questions are answered by the step, so asking and deciding fall in different ticks:

- **Tick N:** `ai_ask` fills `thinks[1 - decided]` and appends its questions to the batch after the hover. The step answers them.
- **Tick N+1:** `ai_decide` reads the answers still in `GLOBAL.questions` (the batch is cleared only after it), decides on `thinks[1 - decided]`, then flips `decided`.

There are two thinks so the report always shows a whole, decided think while the next one is being asked. Clearing the plans on ask used to make the report flicker.

`ai_decide` first checks, in order:

1. A report is open (`game.interaction.actor != {}`) → rule Read_Report, order `Next_Order`.
2. A vacancy can be filled (`appointment.office != {}`, `can_appoint`, candidates) → rule Appoint, appointing the first candidate.
3. The rule is Wait → nothing. The turn is the player's to end.
4. The rule is not Ask → set it to Ask and return. The game thread then calls `ai_ask` this tick.
5. Otherwise the batch holds this think's answers → run the phases below.

Over a turn, then:

- Ask → decide and Act (one order) → the march runs, nothing awaits → Ask → decide and Act → …
- When no chosen plan has an order left → Wait, and the player ends the turn.
- Battle reports and vacancies are handled whenever they come up.

### `ai_ask`: Armies → Goals → Plans

1. **Armies:** the side's field armies. Each one appends a flood question.
2. **Goals:** for each template, each piece matching its targets. A template's flags must all be in the piece's flags (`targets.flags - piece.flags == {}`) and ownership must match `enemy`. Value terms:
   - Coin = `(town.income + town.wealth) × w.coin`;
   - Food = `town.food × w.food`;
   - value = their sum.
3. **Plans:** every goal × every army. `kept` is set if the plan's key is in `ai.kept`. Each plan appends a move question (onto the target, `runs = w.runs`) and a battle question (rested, `runs = w.runs`).

Each phase breaks when its fixed array is full (`append(...) == 0`).

### `ai_decide`: Distances → Program → Score → Select → Act

1. **Distances.** For each army: `sites_distance` from its flood's `sites`, giving `through[a]`, its movement to every site.
2. **Program.** For each plan, the first rule that holds, top down:
   - `distance = through[army][target's cell_site] + target's cell_distance` (INF if the target has no site);
   - `reached`: the move question has no refusal;
   - `strike_odds`: Clear_Win + Close_Win of the move question;
   - `rested_odds`: Clear_Win + Close_Win of the battle question;
   - **Give_Up** if the target is gone, there is no way (`distance == INF`), or `rested_odds < w.give_up`;
   - **Strike** if `reached && strike_odds >= w.strike`;
   - **Approach** otherwise.
3. **Score** (not for Give_Up), as terms:
   - Value = `goal.value`;
   - Odds = `value × (rested_odds − 1)`, so Value + Odds = value × rested odds;
   - Distance = `−distance × w.distance`;
   - Continuity = `w.continuity` if the plan was chosen at the last think;
   - score = the sum, i.e. **score = value × rested_odds − distance × w.distance + continuity**.
4. **Select.** Greedy, best score first. Each goal takes at most one army and each army at most one goal:
   - score ≤ 0 → Not_Worth;
   - goal already taken → Goal_Taken;
   - army already taken → Army_Taken;
   - otherwise Chosen, and its key goes into `ai.kept`, rebuilt from scratch.
5. **Act.** Walking the ranking, take the first Chosen plan whose army hasn't acted and which yields an order:
   - **Strike:** `Move_Order{piece = army, target = goal.target}`, a move onto the target.
   - **Approach**, in two parts:
     - *Waypoint:* run `sites_distance` from the target's site. Of the sites the army's flood reaches, the waypoint is the one nearest the target through the site graph.
     - *Spot:* of the flood's cells within the army's `movement_left` and outside enemy zones (`zones == 0`), the spot is the one nearest the waypoint in straight line. Order `Move_Order{destination = spot centre, snap = 1}`, unless the spot is the army's own cell.
   - On an order: rule Act, `think.acting = plan`, and the plan's key goes into `ai.ordered`. If no plan yields an order, the rule is Wait.

One order per think. The army's `this_turn` flags then mark it as acted, so each army gets **one order per turn**.

### Budgets

| Cap | Value | Note |
|---|---|---|
| `AI_ARMIES_MAX` | `FLOOD_QUESTIONS_MAX` = 32 | one flood each, 256 KB each, so 8 MB of flood answers |
| `AI_GOALS_MAX` | 256 | |
| `AI_PLANS_MAX` | 1024 | goals × armies, clamped |
| `MOVE_QUESTIONS_MAX` | 2048 | hover + plans |
| `BATTLE_QUESTIONS_MAX` | 16384 | |
| `AI_REPORT_ROWS_MAX` | `AI_PLANS_MAX` | |

Scratch arrays inside a think (`through`, the ranking, the taken flags) come from the temp allocator, which the game thread frees each tick.

---

## 8. Weights: `assets/scenarios/roman/ai.txt`

`ai_load(&GLOBAL.ai, "roman")` reads one `ai = { ... }` record into `AI_Weights`. Every key is a struct field and every key is required, through `row_check` and `scenario_file` like the other data files. It is called after both `game_load` calls (windowed and headless). The file opens with the commented example record, per the data principles.

| Key | Now | Meaning | In game terms |
|---|---|---|---|
| `coin` | 1 | value per coin a target makes a turn (income + wealth) | |
| `food` | 0.5 | value per food a target makes a turn | food dominates most targets' value today |
| `distance` | 0.05 | score lost per movement point to the target | an army moves 30 a turn, so **a turn of marching costs 1.5** |
| `continuity` | 2 | added to a plan chosen at the last think | stops flip-flopping between near-equal plans |
| `give_up` | 0.2 | rested odds below which a plan is given up | |
| `strike` | 0.6 | odds on arrival from which an army strikes rather than approaches | |
| `runs` | 32 | battles run for each odds estimate | two estimates per plan |

Thresholds and weights go in this file, not in code. New ones go here too, with the struct and the header kept in the same order.

---

## 9. Seeing what it does

The user wants every decision visible. The report was designed together, column by column.

### Status card

- **Row 0:** "End turn", then "AI turn" (reads "Stop AI" while it plays), placed next to End turn as asked.
- **Row 1:** "Court", "AI report".
- **Field "AI":** the rule title while the AI plays ("Thinks", "Acts", "Waits", …), "Off" otherwise.

Buttons are laid out in rows through `Card_Action.row`.

### The AI report window (`ai_report_ui` in `src/cards.odin`)

A big overlay window like the court, sharing `Card_Theme.window`, built by `game_cards` only while it is shown. It contains:

- **Title:** "AI plans of <faction>". Next to it, Close.
- **Decision line:** the rule title.
- **A scroll panel** with one row per plan of the last decided think.

**Columns:**

1. **Goal:** "Take Mediolanum" (template title + target name).
2. **Army:** a narrow column (`AI_REPORT_ARMY_EM`).
3. **Order box:**
   - **red** (`BAD_INK`): not chosen;
   - **empty paper:** chosen, not yet ordered;
   - **blinking** green/paper at 2 Hz: its order is under way (the acting plan while `under_way != {}`);
   - **solid green** (`GOOD_INK`): ordered and done.

   Solid black was explicitly kept free. The user reserved it for "not chosen", then preferred the common red ink for that.
4. **Status:**
   - "Chosen, approach" / "Chosen, strike";
   - "Given up: no way there";
   - "Given up: rested odds N%";
   - "Not worth it";
   - "Target already chosen";
   - "Army busy on a better plan".
5. **Score:** `field_ui` with a breakdown tooltip: Coin, Food, Odds, Distance, Continuity, then the total. One tooltip format, as in combat.

**Order:** chosen rows first, then by score, given up last. Unchosen rows are in faded ink. Order states come from `ai.ordered`: ordered gives Under_Way or Done; otherwise chosen gives Pending; otherwise Not_Chosen.

The army column will become a **resource** column once offices and money are allocated the same way. "We can worry about generalisation later."

---

## 10. How it behaves now

With the current weights, almost every side's armies target **Mediolanum** (value about 26). The causes:

- Food dominates value.
- Distance is cheap: a turn of marching costs 1.5, so a 26-value target is worth about 17 turns of marching.
- Goals are every capturable enemy piece on the map, not just the near ones.

The user's suggestion for later: consider **only bordering targets**. That is not decided.

---

## 11. Known limits

- **Odds mean "win this assault", not "take the town".** A capture needs the cohesion rule to break the defender: below 25 readiness or below 30% men, then a roll. A won assault can leave the town standing, so the AI may keep striking.
- **One army per goal.** No combined plans, no siege with support.
- **One order per army per turn.** An army that approaches can't also strike that turn. An army that only moves a little has still acted.
- **No resting, recovering, defending or retreating.** Armies don't care about their own supply, readiness or the enemy's reach.
- **No sea orders.** Distances count voyages, but Approach only ever walks. An army whose best way is by sea walks to the beach and stops there.
- **Value ignores control, threat and position.** It is just the target's economy.
- **The far legs ignore enemy zones.**
- **The waypoint spot is a straight-line nearest,** not a field argmax yet.
- **Takes every capturable enemy piece as a goal,** however far.
- **It plays only the side to move when the button is pressed,** for that turn. No faction is AI-controlled by default.

---

## 12. Roadmap (discussed, not started; each needs its own design talk first)

1. **Rest and recover.** The first use of fields as weight rows: choose a spot by combining supply, enemy distance and zones over the flood's reachable cells, with an argmax. Needs a "purpose" weight row in `ai.txt`.
2. **Bordering targets,** or another way to bound goals by reach, so far targets stop pulling.
3. **Destroy enemy armies:** a template whose targets are enemy armies.
4. **Hold threatened settlements:** a template on own settlements. Its value needs threat, for example enemy strength reachable next turn, as a field (exposure).
5. **Sea crossings:** Approach that sails when the waypoint is across a voyage.
6. **Multi-army plans:** several armies on one goal, and supporting armies.
7. **Score(Board) and what-ifs:** a goal's value as the change in a board score, found by forking the game, changing a fact and stepping. Rollouts come after the abstract layer works.
8. **Economy and offices as resources:** the same goals → plans → select pipeline allocating money, buildings, appointments and mustering. The army column becomes a resource column.
9. **Observability:** the earlier idea of saving a think's snapshot to disk and replaying it headless.

**Parked, discuss before touching:** the combat questions (readiness recovery, readiness in battle, participant caps). See the combat-open-topics memory.

---

## 13. Verifying changes

Nothing here has tests in the repo. Changes have been checked in four ways. All the harness files lived in a session scratchpad and are gone, so they need recreating.

- **Headless replays, byte for byte.** Two command files drove the rules without the AI:
  - `march.jsonl`: `order_move` / `order_target` between long `step` runs, with `appoint` / `next` at each turn;
  - `sail.jsonl`: the same with a sea move.

  Run the old and the new build with `--headless --commands <file> --rules-log <out>`, then compare the logs with `cmp`. Any rules change that should change nothing must give identical logs. Command types are in `src/commands.odin`.
- **Question harness:** asked fixed questions in a loop and printed the answers, so they could be compared before and after a change.
- **Threaded harness:** a copy of `src/` in the scratchpad, with a branch in `main` behind an env var (`THREAD_CHECK`). It starts the game thread with pacing sped up 20× and plays a command file through `inputs`. Build with `-sanitize:thread` to check the handover under the thread sanitizer.
- **AI harness:** the same pattern behind `AI_CHECK`. It loads, sets `inputs.ai_turn` and `inputs.ai_report`, runs the game thread, and on each fresh presentation prints the chosen rows' goal, army and order state whenever they change, until the decision reads "Waits". Then it prints the report's rows with their totals. This is how the report and Act were checked without opening a window.

Keep harnesses out of the game code: they live in a scratchpad copy of `src/`, never as hooks in the game.

---

## 14. Where things are

| File | What |
|---|---|
| `src/game_ai.odin` | the AI: types, `ai_load`, `ai_decide`, `ai_ask` |
| `assets/scenarios/roman/ai.txt` | its weights |
| `src/game_step.odin` | `Game_Questions` and the question types; their answers in Step: March plans and Step: Battles; Step: Voyages, Zones, Focus distance; `game_networks_build` (supply, control, enemy distance); `sites_distance`, `sea_voyage`; `ENEMY_DISTANCE_MAX` |
| `src/game.odin` | `Game` fields (`sites`, `site_graph`, `voyages`, fields); site building and its cache at load; `SITES_MAX`, `ZONES_SCALE`, `FOCUS_DISTANCE_SCALE`, `SITES_CACHE_VERSION`; `scenario_file`, `row_check` |
| `src/field.odin` | `Field`, `field_sample_nearest`, `field_sample_bilinear` |
| `src/cache.odin` | `hash_bytes`, `cache_read`, `cache_write` |
| `src/pathfinding.odin` | `Pathfind`, floods, `pathfind_distance` (with cap), `pathfind_spread`; `PATHFIND_FLOOD_SIZE` = 256 |
| `src/main.odin` | `GLOBAL`, `Game_Thread`, `Game_Inputs`, `Presentation`, `present`, `game_thread_run`, the main loop, `ai_load` calls |
| `src/game_present.odin` | map modes (Sites, Zones, Enemies, Distance); status card AI buttons and line; `AI_Report` and its rows; the AI titles tables |
| `src/cards.odin` | `ai_report_ui`, order box colours, `Card_Action.row`, `Card_Theme.window` |
| `src/stream.odin` | `THREAD_MEMORY` / `THREAD_ARENA` |
| `docs/principles.md` | the code principles every change follows |
