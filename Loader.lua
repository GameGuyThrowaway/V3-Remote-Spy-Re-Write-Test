local mainSourceFolder = "https://github.com/GameGuyThrowaway/V3-Remote-Spy-Re-Write-Test/main/src/"
local coreModule = mainSourceFolder .. "Core.lua"

local loadedModules = {} -- used for caching loaded modules so that a module can be required twice and the same table will return both times
local function require(moduleName)
    local module = loadedModules[moduleName]
    if module then
        return module
    else
        local str = game:HttpGetAsync(mainSourceFolder .. moduleName)
        assert(str, "MODULE NOT FOUND")

        local func, err = loadstring(str, moduleName)
        assert(func, err)
        
        local newModule = func()
        loadedModules[moduleName] = newModule
        return newModule
    end
end

loadstring(game:HttpGetAsync(coreModule), "Core.lua")(mainSourceFolder, require) -- load core, passing require function