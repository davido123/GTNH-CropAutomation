-- autoBreed: breed toward config.targetCropName using preferred parent pairs,
-- then spread target when acquired. Uses breeding_data.lua (installed with cropbot).
--
-- breeding_data lists only the *best* (highest-probability) parent pairs per crop.
-- The game still allows all valid mutations (any parent pair with positive ratio);
-- many lower-chance pairs are not in our data. So chain breeding from e.g. tier-1
-- crops works: we prefer listed pairs when we have them, but any crossbreeding can
-- produce useful mutations over time, including ones not in the data.
local action = require('action')
local database = require('database')
local gps = require('gps')
local scanner = require('scanner')
local config = require('config')
local events = require('events')

local breedRound = 0
local targetCrop          -- current target (top of stack) for preferred-parent lookups
local mainTarget          -- final goal from config; spread phase only spreads this
local targetStack = {}    -- stack of targets: [mainTarget] or [mainTarget, subGoal1, ...]
local breedingData
local spreadPhase = false
local emptySlot

-- ===================== LOAD BREEDING DATA =====================
-- breeding_data.lua is installed once with the rest of the cropbot (e.g. via setup.lua).

local function loadBreedingData()
    package.loaded['breeding_data'] = nil
    local ok, data = pcall(require, 'breeding_data')
    if not ok or not data then
        error('autoBreed: Could not load breeding_data.lua (install with setup.lua)')
    end
    return data
end

-- ===================== TARGET & PREFERRED PAIRS =====================

-- Normalize name for comparison (game may use "saltyRoot", data has "Salty Root")
local function norm(name)
    if not name or name == '' then return '' end
    return string.lower(name):gsub('%s+', '')
end

-- Case-insensitive lookup: return (breeding entry, canonical key) for target name
local function getBreedingEntry(name)
    if not name or not breedingData then return nil, nil end
    local n = norm(name)
    for k, v in pairs(breedingData) do
        if norm(k) == n then return v, k end
    end
    return nil, nil
end

local function isTargetCrop(name)
    return name and targetCrop and norm(name) == norm(targetCrop)
end

local function isMainTarget(name)
    return name and mainTarget and norm(name) == norm(mainTarget)
end

-- Is any crop with this name (case-insensitive) on the working farm?
local function hasCropOnFarm(name)
    if not name or name == '' then return false end
    local farm = database.getFarm()
    local n = norm(name)
    for slot = 1, config.workingFarmArea do
        local c = farm[slot]
        if c and c.name and norm(c.name) == n and c.name ~= 'air' and c.name ~= 'emptyCrop' then
            return true
        end
    end
    return false
end

-- Names from first acquisition pair for target (parents that can produce target without having it)
local function getRequiredParentsFromFirstPair(targetName)
    local entry = getBreedingEntry(targetName)
    if not entry or #entry == 0 then return {} end
    local seen = {}
    for _, pair in ipairs(entry) do
        local a, b = pair[1], pair[2]
        if a and b and norm(a) ~= norm(targetName) and norm(b) ~= norm(targetName) then
            if not seen[norm(a)] then seen[norm(a)] = a end
            if not seen[norm(b)] then seen[norm(b)] = b end
            break
        end
    end
    local out = {}
    for _, v in pairs(seen) do out[#out + 1] = v end
    return out
end

-- Tree breeding: for main target only, first 2 acquisition parents (e.g. ferru, Iron Oreberry for Salty Root)
local function getTreeSubGoals(targetName)
    if not targetName or not mainTarget or norm(targetName) ~= norm(mainTarget) then return {} end
    local entry = getBreedingEntry(targetName)
    if not entry or #entry == 0 then return {} end
    local order = {}
    local seen = {}
    for _, pair in ipairs(entry) do
        local a, b = pair[1], pair[2]
        if a and b and norm(a) ~= norm(targetName) and norm(b) ~= norm(targetName) then
            for _, p in ipairs({ a, b }) do
                if not seen[norm(p)] then
                    local _, canon = getBreedingEntry(p)
                    local name = canon or p
                    seen[norm(p)] = name
                    order[#order + 1] = name
                    if #order >= 2 then break end
                end
            end
            if #order >= 2 then break end
        end
    end
    return order
end

-- Are all tree sub-goals for main target on the farm? (used to sub-breed both simultaneously)
local function haveAllTreeSubGoalsOnFarm()
    local tree = getTreeSubGoals(mainTarget)
    if #tree == 0 then return true end
    for _, name in ipairs(tree) do
        if not hasCropOnFarm(name) then return false end
    end
    return true
end

-- Is any preferred parent for this target on the farm?
local function hasPreferredParentOnFarm(targetName)
    local entry = getBreedingEntry(targetName)
    if not entry then return false end
    for _, pair in ipairs(entry) do
        for i = 1, 2 do
            local p = pair[i]
            if p and hasCropOnFarm(p) then return true end
        end
    end
    return false
end

-- Is name already in the target stack (avoid pushing same sub-goal twice)?
local function isInTargetStack(name)
    if not name then return false end
    local n = norm(name)
    for i = 1, #targetStack do
        if norm(targetStack[i]) == n then return true end
    end
    return false
end

local function isPreferredParent(name)
    local entry = getBreedingEntry(targetCrop)
    if not entry then return false end
    local n = norm(name)
    for _, pair in ipairs(entry) do
        if (pair[1] and norm(pair[1]) == n) or (pair[2] and norm(pair[2]) == n) then
            return true
        end
    end
    return false
end

-- Other parent in pair for given crop name (case-insensitive)
local function otherInPair(name)
    local entry = getBreedingEntry(targetCrop)
    if not entry then return nil end
    local n = norm(name)
    for _, pair in ipairs(entry) do
        if pair[1] and norm(pair[1]) == n then return pair[2] end
        if pair[2] and norm(pair[2]) == n then return pair[1] end
    end
    return nil
end

-- Parent slots (odd) adjacent to child slot
local function parentSlotsOfChild(childSlot)
    local out = {}
    for _, s in ipairs(gps.getAdjacentWorkingSlots(childSlot)) do
        if s % 2 == 1 then
            out[#out + 1] = s
        end
    end
    return out
end

-- Best parent slot to transplant child crop into: prefer slot that forms preferred pair
local function bestParentSlotForChild(childSlot, childName)
    local farm = database.getFarm()
    local want = otherInPair(childName)
    for _, pSlot in ipairs(parentSlotsOfChild(childSlot)) do
        local c = farm[pSlot]
        local name = c and c.name
        if name == 'air' or name == 'emptyCrop' or (want and name and norm(name) == norm(want)) then
            return pSlot
        end
    end
    return nil
end

-- ===================== SPREAD PHASE (same as autoSpread) =====================

local function findEmpty()
    local farm = database.getFarm()
    for slot = 1, config.workingFarmArea, 2 do
        local crop = farm[slot]
        if crop ~= nil and (crop.name == 'air' or crop.name == 'emptyCrop') then
            emptySlot = slot
            return true
        end
    end
    return false
end

local function spreadCheckChild(slot, crop)
    if not crop.isCrop or crop.name == 'emptyCrop' then return end

    if crop.name == 'air' then
        action.placeCropStick(2)
    elseif scanner.isWeed(crop, 'storage') then
        action.deweed()
        action.placeCropStick()
    elseif isMainTarget(crop.name) then
        local stat = crop.gr + crop.ga - crop.re
        if stat >= config.autoStatThreshold and findEmpty() and crop.gr <= config.workingMaxGrowth and crop.re <= config.workingMaxResistance then
            action.transplant(gps.workingSlotToPos(slot), gps.workingSlotToPos(emptySlot))
            action.placeCropStick(2)
            database.updateFarm(emptySlot, crop)
        elseif stat >= config.autoSpreadThreshold then
            if config.useStorageFarm then
                action.transplant(gps.workingSlotToPos(slot), gps.storageSlotToPos(database.nextStorageSlot()))
                database.addToStorage(crop)
                action.placeCropStick(2)
            elseif crop.size and crop.max and crop.size >= crop.max - 1 then
                action.harvest()
                action.placeCropStick(2)
            end
        else
            action.deweed()
            action.placeCropStick()
        end
    elseif config.keepMutations and (not database.existInStorage(crop)) then
        action.transplant(gps.workingSlotToPos(slot), gps.storageSlotToPos(database.nextStorageSlot()))
        action.placeCropStick(2)
        database.addToStorage(crop)
    else
        action.deweed()
        action.placeCropStick()
    end
end

local function spreadCheckParent(slot, crop)
    if crop.isCrop and crop.name ~= 'air' and crop.name ~= 'emptyCrop' then
        if scanner.isWeed(crop, 'working') then
            action.deweed()
            database.updateFarm(slot, { isCrop = true, name = 'emptyCrop' })
        end
    end
end

local function spreadOnce()
    for slot = 1, config.workingFarmArea do
        if breedRound > config.maxBreedRound then
            print('autoBreed: Max breeding round reached (spread)')
            return false
        end
        if #database.getStorage() >= config.storageFarmArea then
            print('autoBreed: Storage full')
            return false
        end
        if events.needExit() then return false end

        gps.go(gps.workingSlotToPos(slot))
        local crop = scanner.scan()
        database.updateFarm(slot, crop)

        if slot % 2 == 0 then
            spreadCheckChild(slot, crop)
        else
            spreadCheckParent(slot, crop)
        end

        if action.needCharge() then action.charge() end
    end
    return true
end

-- ===================== BREED PHASE =====================

local function targetOnFarm()
    local farm = database.getFarm()
    for slot = 1, config.workingFarmArea do
        local c = farm[slot]
        if c and isTargetCrop(c.name) then return true end
    end
    return false
end

local function breedCheckChild(slot, crop)
    if not crop.isCrop or crop.name == 'emptyCrop' then return true end  -- true = stay in breed phase

    if crop.name == 'air' then
        action.placeCropStick(2)
        return true
    end
    if scanner.isWeed(crop, 'working') then
        action.deweed()
        action.placeCropStick()
        return true
    end
    -- Current target acquired: pop sub-goal or switch to spread
    if isTargetCrop(crop.name) then
        if #targetStack > 1 then
            table.remove(targetStack)
            targetCrop = targetStack[#targetStack]
            print(string.format('autoBreed: Sub-goal acquired, now breeding for "%s"', targetCrop))
            return true
        else
            return false
        end
    end
    -- Preferred parent: transplant to best parent slot to maximize pair
    if isPreferredParent(crop.name) then
        local best = bestParentSlotForChild(slot, crop.name)
        if best then
            action.transplant(gps.workingSlotToPos(slot), gps.workingSlotToPos(best))
            action.placeCropStick(2)
            database.updateFarm(best, crop)
            database.updateFarm(slot, { isCrop = true, name = 'emptyCrop' })
            return true
        end
    end
    -- Other crop: deweed or keep
    if config.keepMutations and (not database.existInStorage(crop)) then
        action.transplant(gps.workingSlotToPos(slot), gps.storageSlotToPos(database.nextStorageSlot()))
        action.placeCropStick(2)
        database.addToStorage(crop)
    else
        action.deweed()
        action.placeCropStick()
    end
    return true
end

local function breedCheckParent(slot, crop)
    if crop.isCrop and crop.name ~= 'air' and crop.name ~= 'emptyCrop' then
        if scanner.isWeed(crop, 'working') then
            action.deweed()
            database.updateFarm(slot, { isCrop = true, name = 'emptyCrop' })
        end
    end
end

local function breedOnce()
    for slot = 1, config.workingFarmArea do
        if breedRound > config.maxBreedRound then
            print('autoBreed: Max breeding round reached (breed)')
            return false, true
        end
        if events.needExit() then
            return false, true
        end

        gps.go(gps.workingSlotToPos(slot))
        local crop = scanner.scan()
        database.updateFarm(slot, crop)

        if slot % 2 == 0 then
            local stay = breedCheckChild(slot, crop)
            if not stay then
                return false, false  -- switch to spread
            end
        else
            breedCheckParent(slot, crop)
        end

        if action.needCharge() then action.charge() end
    end
    return true, true
end

-- ===================== MAIN =====================

local function main()
    -- Load config from current directory so edits are always picked up (require path may differ on robot)
    local fn, err = loadfile('config.lua')
    if fn then
        local ok, c = pcall(fn)
        if ok and c and type(c) == 'table' then
            config = c
        end
    end
    if not config or not config.workingFarmSize then
        package.loaded['config'] = nil
        config = require('config')
    end
    targetCrop = config.targetCropName
    print(string.format('autoBreed: targetCropName = %s', tostring(targetCrop)))
    if not targetCrop or targetCrop == '' then
        print('autoBreed: Set config.targetCropName (e.g. diareed, saltyRoot)')
        return
    end
    if type(targetCrop) ~= 'string' then
        targetCrop = tostring(targetCrop or '')
    end
    targetCrop = targetCrop:gsub('^%s+', ''):gsub('%s+$', '')
    if targetCrop == '' then
        print('autoBreed: Set config.targetCropName (e.g. diareed, saltyRoot)')
        return
    end

    action.initWork()
    print('autoBreed: Scanning farm...')

    -- First scan
    for slot = 1, config.workingFarmArea do
        gps.go(gps.workingSlotToPos(slot))
        local crop = scanner.scan()
        database.updateFarm(slot, crop)
    end

    breedingData = loadBreedingData()
    local entry, canonical = getBreedingEntry(targetCrop)
    if canonical then targetCrop = canonical end
    mainTarget = targetCrop
    targetStack = { mainTarget }
    if not entry then
        print(string.format('autoBreed: No breeding data for "%s"; will use any crossbreeding.', targetCrop))
    else
        print(string.format('autoBreed: Using preferred parent pairs for "%s"', targetCrop))
    end

    -- If main target already on farm, go to spread
    if targetOnFarm() then
        print('autoBreed: Target already on farm – starting spread phase')
        spreadPhase = true
    end

    action.analyzeStorage(true)
    action.restockAll()

    -- Breed phase loop (with sub-goal push/pop)
    while not spreadPhase do
        -- Sub-goal done: current target appeared on farm (e.g. from restock or last round)
        if targetOnFarm() then
            if #targetStack > 1 then
                table.remove(targetStack)
                targetCrop = targetStack[#targetStack]
                print(string.format('autoBreed: Sub-goal on farm, now breeding for "%s"', targetCrop))
            else
                spreadPhase = true
                print('autoBreed: Target acquired – starting spread phase')
                break
            end
        end
        -- No preferred parent on farm (or tree: need both first-2 sub-goals): push a sub-goal (if it has breeding_data)
        local needSubGoal = not hasPreferredParentOnFarm(targetCrop)
        if not needSubGoal and #targetStack == 1 and mainTarget then
            needSubGoal = not haveAllTreeSubGoalsOnFarm()
        end
        if needSubGoal then
            local required
            if #targetStack == 1 and mainTarget then
                required = getTreeSubGoals(mainTarget)
            else
                required = getRequiredParentsFromFirstPair(targetCrop)
            end
            local pushed = false
            for _, r in ipairs(required) do
                if not hasCropOnFarm(r) and not isInTargetStack(r) then
                    local subEntry = getBreedingEntry(r)
                    if subEntry and #subEntry > 0 then
                        local _, subCanon = getBreedingEntry(r)
                        targetStack[#targetStack + 1] = subCanon or r
                        targetCrop = targetStack[#targetStack]
                        print(string.format('autoBreed: Sub-goal: breeding for "%s" first', targetCrop))
                        pushed = true
                        break
                    end
                end
            end
            if not pushed and #required > 0 then
                -- Have data but can't push (e.g. sub-goal has no data); keep breeding, rely on mutation
            end
        end

        local cont, stay = breedOnce()
        if not stay then
            spreadPhase = true
            print('autoBreed: Target acquired – starting spread phase')
            break
        end
        if not cont then break end
        breedRound = breedRound + 1
        action.restockAll()
    end

    -- Spread phase loop
    while spreadPhase do
        if not spreadOnce() then break end
        breedRound = breedRound + 1
        action.restockAll()
    end

    if events.needExit() then
        action.restockAll()
    end

    if config.cleanUp then
        action.cleanUp()
    end

    events.unhookEvents()
    print('autoBreed: Complete!')
end

main()
