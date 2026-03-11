-- autoBreed: breed toward config.targetCropName using preferred parent pairs,
-- then spread target when acquired. Fetches breeding data from config.breedingDataURL.
local action = require('action')
local database = require('database')
local gps = require('gps')
local scanner = require('scanner')
local config = require('config')
local events = require('events')
local shell = require('shell')

local breedRound = 0
local targetCrop
local breedingData
local spreadPhase = false
local emptySlot

-- ===================== FETCH BREEDING DATA =====================

local function fetchBreedingData()
    if config.breedingDataURL and config.breedingDataURL ~= '' then
        print('autoBreed: Fetching breeding data...')
        local ok, err = pcall(function()
            shell.execute(string.format('wget -f %s breeding_data.lua', config.breedingDataURL))
        end)
        if not ok then
            print('autoBreed: Fetch failed, using local breeding_data')
        end
    end
    package.loaded['breeding_data'] = nil
    local ok, data = pcall(require, 'breeding_data')
    if not ok or not data then
        error('autoBreed: Could not load breeding_data.lua')
    end
    return data
end

-- ===================== TARGET & PREFERRED PAIRS =====================

-- Case-insensitive lookup: return (breeding entry, canonical key) for target name
local function getBreedingEntry(name)
    if not name or not breedingData then return nil, nil end
    local lower = string.lower(name)
    for k, v in pairs(breedingData) do
        if string.lower(k) == lower then return v, k end
    end
    return nil, nil
end

local function isTargetCrop(name)
    return name and targetCrop and string.lower(name) == string.lower(targetCrop)
end

local function isPreferredParent(name)
    local entry = getBreedingEntry(targetCrop)
    if not entry then return false end
    local lower = name and string.lower(name)
    for _, pair in ipairs(entry) do
        if (pair[1] and string.lower(pair[1]) == lower) or (pair[2] and string.lower(pair[2]) == lower) then
            return true
        end
    end
    return false
end

-- Other parent in pair for given crop name (case-insensitive)
local function otherInPair(name)
    local entry = getBreedingEntry(targetCrop)
    if not entry then return nil end
    local lower = name and string.lower(name)
    for _, pair in ipairs(entry) do
        if pair[1] and string.lower(pair[1]) == lower then return pair[2] end
        if pair[2] and string.lower(pair[2]) == lower then return pair[1] end
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
        if name == 'air' or name == 'emptyCrop' or (want and name and string.lower(name) == string.lower(want)) then
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
    elseif isTargetCrop(crop.name) then
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
    -- Target acquired -> switch to spread
    if isTargetCrop(crop.name) then
        return false
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
    targetCrop = config.targetCropName
    if not targetCrop or targetCrop == '' then
        print('autoBreed: Set config.targetCropName (e.g. diareed, saltyRoot)')
        return
    end
    targetCrop = targetCrop:gsub('^%s+', ''):gsub('%s+$', '')

    action.initWork()
    print('autoBreed: Scanning farm...')

    -- First scan
    for slot = 1, config.workingFarmArea do
        gps.go(gps.workingSlotToPos(slot))
        local crop = scanner.scan()
        database.updateFarm(slot, crop)
    end

    breedingData = fetchBreedingData()
    local entry, canonical = getBreedingEntry(targetCrop)
    if canonical then targetCrop = canonical end
    if not entry then
        print(string.format('autoBreed: No breeding data for "%s"; will use any crossbreeding.', targetCrop))
    else
        print(string.format('autoBreed: Using preferred parent pairs for "%s"', targetCrop))
    end

    -- If target already on farm, go to spread
    if targetOnFarm() then
        print('autoBreed: Target already on farm – starting spread phase')
        spreadPhase = true
    end

    action.analyzeStorage(true)
    action.restockAll()

    -- Breed phase loop
    while not spreadPhase do
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
