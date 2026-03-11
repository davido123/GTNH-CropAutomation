local shell = require('shell')
local scripts = {
    'setup.lua',
    'action.lua',
    'database.lua',
    'events.lua',
    'gps.lua',
    'scanner.lua',
    'config.lua',
    'breeding_data.lua',
    'autoStat.lua',
    'autoTier.lua',
    'autoSpread.lua',
    'autoBreed.lua',
    'uninstall.lua'
}

-- UNINSTALL
for i=1, #scripts do
    shell.execute(string.format('rm %s', scripts[i]))
    print(string.format('Uninstalled %s', scripts[i]))
end