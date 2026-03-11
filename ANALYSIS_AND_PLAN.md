# GTNH-CropAutomation: Analysis & Plan for "Breed Specific Crops"

## How the Program Works

### Architecture (Lua, OpenComputers robot)
- **config.lua** – Farm sizes, thresholds, slot/position constants.
- **database.lua** – In-memory state: working farm slots → crop data; storage farm list; `existInStorage(crop)` by `crop.name`.
- **scanner.lua** – Geolyzer `analyze(sides.down)`: returns `{ isCrop, name, gr, ga, re, tier, size, max }` or air/emptyCrop/block. `isWeed(crop, 'working'|'storage')` uses config max growth/resistance.
- **gps.lua** – Robot navigation: working farm slot ↔ position (checkerboard), storage slot ↔ position, `go()`, `save()/resume()` for detours.
- **action.lua** – Low-level ops: charge, restock sticks, dump inventory, placeCropStick, deweed, harvest, **transplant** (binder + dislocator), cleanUp, initWork, analyzeStorage.
- **events.lua** – Keyboard (Q/C) exit and cleanup flags.

### Farm layout
- **Working farm**: checkerboard. Odd slots = “parent” positions, even = “child” (crossbreed results). Robot scans each slot; even slots trigger child logic (replace low tier/stat, move to storage, or deweed).
- **Target crop**: In **autoStat** and **autoSpread**, target = `database.getFarm()[1].name` (crop in slot 1 at first run). All logic is “improve/spread this one crop.”
- **autoTier**: No single target; tier-up everything. New (unknown) crops go to storage; known crops replace lowest-tier (or lowest-stat) parent. Stops when tier ≥ threshold or storage full.
- **autoStat**: Target from slot 1. Replace lowest-stat parent with better stat **target** child; non-target children are weeds (or stored if keepMutations). Stops when all parents meet stat threshold.
- **autoSpread**: Target from slot 1. Target children above threshold go to storage (or harvest if no storage farm); good target can also fill empty parent slots. Non-target = weed (or store if keepMutations).

### Breeding model in code
- Breeding is **implicit**: the game does crossbreeding between adjacent crop sticks. The script only:
  - Maintains checkerboard (parents on odd, children on even).
  - Scans after growth; decides per child: keep (transplant to parent slot or storage), or deweed and place new sticks.
- There is **no in-script notion of “parent A + parent B → preferred mutation”**. Target is by **name only**; which parents sit where is not chosen to maximize chance for a specific crop.

---

## Gap for “Breed Specific Crops”

- **Current**: User places initial seeds; target is “whatever is in slot 1.” Scripts optimize tier, then stats, then spread—but do not choose parent **combinations** to favor a desired crop.
- **Desired**: User specifies a **target crop name** (e.g. `diareed`); the bot should try to **maximize chance of that crop** by controlling which parents are adjacent (e.g. oilberry + bobsyeruncleranks for diareed).

---

## Plan for Adding “Breed Specific Crops”

### 1. Data: Target crop → preferred parent pairs (optional: probabilities)
- Add a **data module** (e.g. `crop_breeding.lua` or `breeding_data.lua`) that encodes:
  - For each target crop (by name): one or more **preferred parent pairs** `{ parentA, parentB }` (order may not matter).
  - Source: GTNH wiki / community (e.g. [IC2 Crops List](https://wiki.gtnewhorizons.com/wiki/IC2_Crops_List)), or a simplified list for the most common targets.
- Keep it as a simple Lua table so it can be extended without changing core logic.

### 2. Config
- **config.lua**: Add e.g. `targetCropName = nil` (or `""`). If set, breeding logic can prefer placing/keeping parents that match a preferred pair for this target.
- Optional: `breedingMode = "autoTier" | "autoStat" | "autoSpread" | "autoBreed"` if we add a dedicated mode.

### 3. Strategy: Where to enforce “specific crop” logic
- **Option A – New program `autoBreed.lua`**
  - Single purpose: “Fill working farm with preferred parent pairs for `config.targetCropName`, then run tier/stat/spread only for that crop.”
  - Pros: Clear separation, no risk to existing autoTier/autoStat/autoSpread.  
  - Cons: Duplicates some loop/scan logic unless factored into a shared “main loop” helper.
- **Option B – Extend autoTier (and optionally autoStat/autoSpread)**
  - When `config.targetCropName` is set and we have breeding data:
    - In autoTier: when choosing which “lowest tier” slot to replace, **prefer** replacing a slot such that the resulting **parent pair** (after transplant) is a preferred pair for the target crop.
    - Similarly in autoStat/autoSpread: prefer keeping/placing parents that form a preferred pair for the target.
  - Pros: One codebase path; user still runs `autoTier` / `autoStat` / `autoSpread`.  
  - Cons: Logic becomes more complex; need to map “slot” ↔ “neighbors” (checkerboard adjacency).

### 4. Recommended approach (short term)
- **Add `breeding_data.lua`**: table `preferredParents[cropName] = { { "parent1", "parent2" }, ... }` for a small set of crops (e.g. diareed, stickreed, enderbloom, etc.) from wiki.
- **Add `config.targetCropName`**: optional string; when set, programs can consult `breeding_data`.
- **Implement Option B in autoTier first**:
  - In `updateLowest()` / slot choice: when replacing a parent, consider “if I put this child here, do I form a preferred pair with a neighbor?” Prefer slots that form a preferred pair for `config.targetCropName`.
  - If no preferred pair exists yet, fall back to current behavior (lowest tier / lowest stat).
- **Then** (optional) add **autoBreed.lua**: a wrapper that sets or enforces target crop and runs autoTier (and optionally autoStat && autoSpread) with that target, or a dedicated loop that only places/keeps preferred parents until the target appears.

### 5. Slot ↔ adjacency (checkerboard)
- Working farm slots are in a 2D grid; “child” slots (even) have 2 or 4 adjacent “parent” slots (odd). So for each even slot we know the two parents that produced the child.  
- To “prefer preferred pairs”: when deciding where to transplant a new parent (in autoTier/autoStat), among candidate slots, prefer one that has a neighbor such that `{ currentNeighborName, newCropName }` (or vice versa) is in `preferredParents[targetCropName]`.  
- Helper in **gps.lua** or a new **breeding.lua**: `getParentSlots(childSlot)` → list of odd slots adjacent to this even slot; then from farm DB get their names.

### 6. Files to add/change
| File | Change |
|------|--------|
| **breeding_data.lua** (new) | Table of target crop → list of preferred parent pairs. |
| **config.lua** | Add `targetCropName = nil`. |
| **gps.lua** (or new **breeding.lua**) | Add `getParentSlots(slot)` / `getNeighborParents(slot, getFarm)` for checkerboard. |
| **autoTier.lua** | When choosing replacement slot, prefer slot that creates a preferred pair for `config.targetCropName`. |
| **autoStat.lua** (optional) | When choosing replacement slot, prefer preferred pair. |
| **autoSpread.lua** (optional) | Same. |
| **setup.lua** | Add `breeding_data.lua` (and `breeding.lua` if created) to script list. |

### 7. Testing
- Without a real robot: possible to unit-test slot↔adjacency and “preferred slot” logic with mock `database.getFarm()` and `config.targetCropName`.
- With robot: run autoTier with a target (e.g. stickreed) and verify that parent layout tends toward preferred pairs when available.

---

## Summary
- **Current behavior**: Target crop = crop in slot 1; scripts improve tier/stats and spread that crop without considering which parent pairs maximize its mutation chance.
- **Planned behavior**: Optional `config.targetCropName` + **breeding_data.lua** (preferred parent pairs). In autoTier (and optionally autoStat/autoSpread), when choosing where to place a new parent, prefer positions that form a preferred pair for the target crop. Optional dedicated **autoBreed.lua** can wrap this for “breed only this crop” workflows.
