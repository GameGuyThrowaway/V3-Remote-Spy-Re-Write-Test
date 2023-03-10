local SettingsModule = {}

local httpService = cloneref(game:GetService("HttpService"))

local defaultSettings = {
    -- core options
    FireServer = true,
    InvokeServer = true,
    Fire = false,
    Invoke = false,

    OnClientEvent = false,
    OnClientInvoke = false,
    Event = false,
    OnInvoke = false,

    Callbacks = false,
    Bindables = false,
    Remotes = true,

    CallStackSizeLimit = 10,
    CacheLimit = true,
    MaxCallAmount = 1000,
    Paused = false,
    -- end of core

    -- pseudocode options
    MakeCallingScriptUseCallStack = false,
    CallStackOptions = {
        Script = true,
        Type = true,
        LineNumber = true,
        FunctionName = true,

        ParameterCount = false,
        IsVararg = false,
        UpvalueCount = false
    },

    PseudocodeLuaUTypes = false,
    PseudocodeWatermark = true,
    PseudocodeFormatTables = true,
    PsuedocodeHiddenNils = false,
    PseudocodeInlining = {
        boolean = false,
        number = false,
        string = false,
        table = true,
        userdata = true,

        Remote = false,
        HiddenNils = false
    }
    -- end of pseudocode options
}

SettingsModule.Settings = defaultSettings
local Settings = SettingsModule.Settings -- localize the Settings table

function SettingsModule.loadSettings()
    if not isfolder("Remote Spy") then
        makefolder("Remote Spy")
    end
    if not isfile("Remote Spy/Settings.json") then
        SettingsModule.saveSettings()
        return
    end

    local tempSettings = httpService:JSONDecode(readfile("Remote Spy/Settings.json"))
    for i,v in tempSettings do -- this is in case I add new settings
        if type(Settings[i]) == type(v) then
            Settings[i] = v
        end
    end
end

function SettingsModule.saveSettings()
    if not isfolder("Remote Spy") then
        makefolder("Remote Spy")
    end
    writefile("Remote Spy/Settings.json", httpService:JSONEncode(Settings))
end

return SettingsModule