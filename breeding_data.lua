-- IC2 crop mutation data for GTNH: target crop -> preferred parent pairs (best chance).
-- Fetched/updated via config.breedingDataURL in autoBreed, or use this embedded set.
-- Names must match geolyzer crop:name (typically lowercase).
return {
    -- README: diareed best from oilberry + bobsyeruncleranks
    diareed = { {"oilberry", "bobsyeruncleranks"} },
    bobsyeruncleranks = { {"ferru", "aurelia"}, {"oilberry", "ferru"} },
    oilberry = { {"reed", "reed"}, {"stickreed", "stickreed"} },
    stickreed = { {"reed", "wheat"}, {"reed", "carrots"} },
    -- Common targets and suggested parents (same-tier crossbreeding also works)
    enderbloom = { {"enderbloom", "enderbloom"}, {"bloom", "enderweed"} },
    spruce = { {"oak", "fern"}, {"oak", "spruce"} },
    netherStonelilly = { {"stonelilly", "netherwart"}, {"blackStonelilly", "netherwart"} },
    blackStonelilly = { {"stonelilly", "coal"}, {"yellowStonelilly", "coal"} },
    yellowStonelilly = { {"stonelilly", "glowstone"}, {"netherStonelilly", "glowstone"} },
    sugarbeet = { {"beet", "sugarcane"}, {"beet", "reed"} },
    tearstalks = { {"reed", "cactus"}, {"stickreed", "cactus"} },
    saltyRoot = { {"carrots", "cactus"}, {"potato", "cactus"} },
    glowingEarthCoral = { {"coral", "glowstone"}, {"redstone", "coral"} },
    rape = { {"wheat", "reed"}, {"stickreed", "wheat"} },
    goldfishPlant = { {"reed", "yellowStonelilly"}, {"stickreed", "netherStonelilly"} },
    transformium = { {"bobsyeruncleranks", "diareed"}, {"emerald", "diareed"} },
    venomilia = { {"weed", "flower"}, {"reed", "flower"} },
    aurelia = { {"flower", "yellowFlower"}, {"rose", "dandelion"} },
    ferru = { {"wheat", "iron"}, {"reed", "wheat"} },
    reed = { {"wheat", "sugarcane"}, {"wheat", "reed"} },
    weed = { {"wheat", "wheat"}, {"carrots", "potato"} },
}
