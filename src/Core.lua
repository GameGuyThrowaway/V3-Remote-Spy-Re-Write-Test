--[[
    -- I suggest turning on line wrapping to read my massive single line comments
    -- I should probably add more sanity checks for basic stuff, but I figure most of this stuff should be impossible to break in real world conditions, so the only way it would fail the sanity check is if I wrote the code wrong, in which case might as well error

    -- Need to make interface compatible
    -- Add support for pausing types in the backend?  It'd help with performance.
    -- NewIndex/Index hooks aren't good on performance (in one specificly tested game)
    -- Add an actual interface
]]

local mainSourceFolder: string, require = ...

local taskSignalLibrary = require("Libraries/TaskSignal.lua")

local interface = require("Modules/Interface.lua")
local backend = require("Modules/Backend.lua")
local pseudocodeGenerator = require("Modules/PseudocodeGenerator.lua")
local settingsModule = require("Modules/Settings.lua")
local Settings = settingsModule.Settings

local hookCode: string = game:HttpGetAsync(mainSourceFolder .. "Modules/Hooks.lua")

local task_spawn = task.spawn
local table_insert = table.insert
local clear_table = table.clear
local table_foreach = table.foreach
local table_remove = table.remove

local callBlockList = {} -- list of blocked calls
local callIgnoreList = { [game.ReplicatedFirst.RemoteEvent:GetDebugId()] = true } -- list of ignored calls
local callList = {} -- list of calls

local callbackBlockList = {} -- list of blocked callbacks and connections
local callbackIgnoreList = {} -- list of ignored callbacks and connections
local callbackList = {} -- list of callbacks and connections

_G.cL = callList
_G.cbL = callbackList
_G.psG = pseudocodeGenerator

local returnValuePointerList = {} -- hashmap used that points a update key to a table


local dataList = {
    RemoteEvent = {
        Signal = "OnClientEvent",
        Namecall = "FireServer"
    },
    RemoteFunction = {
        Callback = "OnClientInvoke",
        Namecall = "InvokeServer"
    },
    BindableEvent = {
        Signal = "Event",
        Namecall = "Fire"
    },
    BindableFunction = {
        Callback = "OnInvoke",
        Namecall = "Invoke"
    }
}

local typeList = {
    RemoteEvent = "Remotes",
    RemoteFunction = "Remotes",

    BindableEvent = "Bindables",
    BindableFunction = "Bindables"
}


local function logCall(remote: Instance, remoteID: string, returnValueKey: string, callingScript: Instance, callStack, args, argCount: number)
    local log = {
        Args = args,
        ArgCount = argCount,
        CallingScript = callingScript,
        CallStack = callStack,
        ReturnValue = false -- signifying that it will never return
    }
    local listEntry = callList[remoteID]

    if returnValueKey then
        log.ReturnValue = nil -- showing that it's just waiting to return
        returnValuePointerList[returnValueKey] = { Call = log, RemoteID = remoteID }
    end

    if not listEntry then
        callList[remoteID] = {
            DestroyedConnection = remote.Destroying:Connect(function()
                callList[remoteID].DestroyedConnection:Disconnect()
                callList[remoteID].Destroyed = true
            end),
            Destroyed = false,
            ID = remoteID,
            Remote = remote,
            Calls = { log }
        }
    else
        local calls = listEntry.Calls
        table_insert(calls, log)
        if calls[Settings.MaxCallAmount] then
            local callOverflow = #calls - Settings.MaxCallAmount
            for _ = 1, callOverflow do
                table_remove(calls, 1)
                interface.EventPipe:Fire("onCallRemoved", listEntry.RemoteID, 1)
            end
        end
    end

    return log
end

local function logCallback(remote: Instance, remoteID: string, returnValueKey: string, callbackCreator: Instance, args, argCount: number)
    local log = {
        Args = args,
        ArgCount = argCount,
        CallbackCreator = callbackCreator
    }
    local listEntry = callbackList[remoteID]

    returnValuePointerList[returnValueKey] = { Call = log, RemoteID = remoteID }

    if not listEntry then
        callbackList[remoteID] = {
            DestroyedConnection = remote.Destroying:Connect(function()
                callbackList[remoteID].DestroyedConnection:Disconnect()
                callbackList[remoteID].Destroyed = true
            end),
            Destroyed = false,
            ID = remoteID,
            Remote = remote,
            Calls = { log }
        }
    else
        local calls = listEntry.Calls
        table_insert(calls, log)
        if calls[Settings.MaxCallAmount] then
            local callOverflow = #calls - Settings.MaxCallAmount
            for _ = 1, callOverflow do
                table_remove(calls, 1)
                interface.EventPipe:Fire("onCallbackRemoved", listEntry.RemoteID, 1)
            end
        end
    end

    return log
end

local function logConnection(remote: Instance, remoteID: string, connectedScripts, args, argCount: number)
    local log = {
        Args = args,
        ArgCount = argCount,
        ConnectedScripts = connectedScripts,
        ReturnValue = false -- never returns
    }
    local listEntry = callbackList[remoteID]

    if not listEntry then
        callbackList[remoteID] = {
            DestroyedConnection = remote.Destroying:Connect(function()
                callbackList[remoteID].DestroyedConnection:Disconnect()
                callbackList[remoteID].Destroyed = true
            end),
            Destroyed = false,
            ID = remoteID,
            Remote = remote,
            Calls = { log }
        }
    else
        local calls = listEntry.Calls
        table_insert(calls, log)
        if calls[Settings.MaxCallAmount] then
            local callOverflow = #calls - Settings.MaxCallAmount
            for _ = 1, callOverflow do
                table_remove(calls, 1)
                interface.EventPipe:Fire("onConnectionRemoved", listEntry.RemoteID, 1)
            end
        end
    end

    return log
end

local function updateReturnValue(returnValueKey: string, returnValue, returnCount: number)
    local returnEntry = returnValuePointerList[returnValueKey]
    local callEntry = returnEntry.Call
    local remoteID = returnEntry.RemoteID

    callEntry.ReturnValue = returnValue
    callEntry.ReturnCount = returnCount
    returnValuePointerList[returnValueKey] = nil

    return callEntry, remoteID
end

local function optimizedRepeatCall(remote: Instance, callback: boolean, amount: number, ...)
    local remData = dataList[remote.ClassName]
    if callback then
        local conName = remData.Signal
        if conName then
            local signal = remote[conName]
            for _ = 1, amount do
                cfiresignal(signal, ...)
            end
        else
            local callbackMember = getcallbackmember(remote, remData.Callback)
            for _ = 1, amount do
                task_spawn(callbackMember, ...)
            end
        end
    else
        if remData.Signal then
            local callFunc = remote[remData.Namecall]
            for _ = 1, amount do
                callFunc(remote, ...)
            end
        else
            local invokeCallFunc = remote[remData.Namecall]
            for _ = 1, amount do
                task_spawn(invokeCallFunc, remote, ...)
            end
        end
    end
end

do -- initialize

    interface.setupEvents(taskSignalLibrary)
    backend.setupEvents(taskSignalLibrary)

    _G.destroySpy = function()
        backend.EventPipe:Fire("selfDestruct")
        _G.destroySpy = nil
    end

    _G.pauseSpy = function(status: boolean)
        backend.EventPipe:Fire("spyPaused", status)
    end

    -- block event, unnecessary if it gets the list passed directly
    interface.EventPipe:ListenToEvent("onRemoteBlocked", function(remoteID: string, callback: boolean, status: boolean)
        local list = callback and callbackBlockList or callBlockList

        list[remoteID] = status
    end)

    -- ignore event, unnecessary if it gets the list passed directly
    interface.EventPipe:ListenToEvent("onRemoteIgnored", function(remoteID: string, callback: boolean, status: boolean)
        local list = callback and callbackIgnoreList or callIgnoreList

        list[remoteID] = status
    end)

    -- special case for updating callstack limit (needs to be sent to all lua states)
    interface.EventPipe:ListenToEvent("onCallStackLimitChanged", function(newLimit: number)
        backend.EventPipe:Fire("updateCallStackLimit", newLimit)
    end)

    -- interface requests
    interface.EventPipe:ListenToEvent("generatePseudocode", function(remoteID: string, callback: boolean, callIndex: number, receiving: boolean)
        local list = callback and callbackList or callList
        local remoteInfo = list[remoteID]
        local call = remoteInfo and remoteInfo.Calls[callIndex]

        if call then
            if receiving then
                return pseudocodeGenerator.generateReceivingCode(remoteInfo.Remote, call)
            else
                return pseudocodeGenerator.generateCode(remoteInfo.Remote, callback, call)
            end
        else
            return false
        end
    end)
    interface.EventPipe:ListenToEvent("generatePseudoCallStack", function(remoteID: string, callIndex: number)
        return pseudocodeGenerator.generateCallStack(callList[remoteID].Calls[callIndex].CallStack)
    end)
    interface.EventPipe:ListenToEvent("generateConnectedScriptsList", function(remoteID: string, callIndex: number)
        return pseudocodeGenerator.generateConnectedScriptsList(callbackList[remoteID].Calls[callIndex].ConnectedScripts)
    end)
    interface.EventPipe:ListenToEvent("generatePseudoReturnValue", function(remoteID: string, callback: boolean, callIndex: number)
        local list = callback and callbackList or callList

        return pseudocodeGenerator.generateReturnValue(list[remoteID].Calls[callIndex].ReturnValue)
    end)
    interface.EventPipe:ListenToEvent("getScriptPath", function(remoteID: string, callback: boolean, callIndex: number)
        if callback then
            local remoteInfo = callbackList[remoteID]
            local call = remoteInfo and remoteInfo.Calls[callIndex]
            if call and call.CallbackCreator then
                return pseudocodeGenerator.getInstancePath(call.CallbackCreator)
            else
                return false
            end
        else
            local remoteInfo = callList[remoteID]
            local call = remoteInfo and remoteInfo.Calls[callIndex]
            if call and call.CallingScript then
                return pseudocodeGenerator.getInstancePath(call.CallingScript)
            else
                return false
            end
        end
    end)
    interface.EventPipe:ListenToEvent("decompileScript", function(remoteID: string, callback: boolean, callIndex: number)
        if callback then
            local remoteInfo = callbackList[remoteID]
            local call = remoteInfo and remoteInfo.Calls[callIndex]
            if call and call.CallbackCreator then
                return decompile(call.CallbackCreator)
            else
                return false
            end
        else
            local remoteInfo = callList[remoteID]
            local call = remoteInfo and remoteInfo.Calls[callIndex]
            if call and call.CallingScript then
                return decompile(call.CallingScript)
            else
                return false
            end
        end
    end)
    interface.EventPipe:ListenToEvent("getRemotePath", function(remoteID: string)
        local remoteInfo = callList[remoteID] or callbackList[remoteID]
        if remoteInfo then
            return pseudocodeGenerator.getInstancePath(remoteInfo.Remote)
        else
            return false
        end
    end)
    interface.EventPipe:ListenToEvent("repeatCall", function(remoteID: string, callback: boolean, callIndex: number, amount: number)
        local list = callback and callbackList or callList
        local remoteInfo = list[remoteID]
        local remote = remoteInfo.Remote
        local call = remoteInfo.Calls[callIndex]

        amount = amount or 1

        optimizedRepeatCall(remote, callback, amount, unpack(call.Args, 1, call.ArgCount))
    end)
    interface.EventPipe:ListenToEvent("clearRemoteCalls", function(remoteID: string, callback: boolean)
        local list = callback and callbackList or callList
        local remoteInfo = list[remoteID]
        if remoteInfo.Destroyed then
            callList[remoteID] = nil
        else
            clear_table(remoteInfo.Calls) -- clear actual calls, not remote data though
        end
    end)
    interface.EventPipe:ListenToEvent("clearAllCalls", function()
        table_foreach(callList, function(call)
            call.DestroyedConnection:Disconnect()
        end)
        clear_table(callList)

        table_foreach(callbackList, function(call)
            call.DestroyedConnection:Disconnect()
        end)
        clear_table(callbackList)
    end)

    -- backend events
    backend.EventPipe:ListenToEvent("onRemoteCall", function(args, argCount: number, remote: Instance, remoteID: string, returnValueKey: string, callingScript: Instance, callStack)
        if not Settings.Paused then
            local class = remote.ClassName
            if Settings[dataList[class].Namecall] and Settings[typeList[class]] then
                local log = logCall(remote, remoteID, returnValueKey, callingScript, callStack, args, argCount)
                interface.EventPipe:Fire("onNewCall", remoteID, log)
            end
        end
    end)
    backend.EventPipe:ListenToEvent("onRemoteCallback", function(args, argCount: number, remote: Instance, remoteID: string, returnValueKey: string, callbackCreator: Instance)
        if Settings.Callbacks and not Settings.Paused and Settings[dataList[remote.ClassName].Callback] then
            local log = logCallback(remote, remoteID, returnValueKey, callbackCreator, args, argCount)
            interface.EventPipe:Fire("onNewCallback", remoteID, log)
        end
    end)
    backend.EventPipe:ListenToEvent("onRemoteConnection", function(args, argCount: number, remote: Instance, remoteID: string, connectedScripts)
        if Settings.Callbacks and not Settings.Paused and Settings[dataList[remote.ClassName].Signal] then
            local log = logConnection(remote, remoteID, connectedScripts, args, argCount)
            interface.EventPipe:Fire("onNewConnection", remoteID, log)
        end
    end)
    backend.EventPipe:ListenToEvent("onReturnValueUpdated", function(returnData, returnCount: number, returnKey: string)
        local log, remoteID: string = updateReturnValue(returnKey, returnData, returnCount)
        interface.EventPipe:Fire("onReturnValueUpdated", remoteID, log)
    end)

    settingsModule.loadSettings()
    interface.initiateModule(callList, callbackList, callBlockList, callIgnoreList, callbackBlockList, callbackIgnoreList, Settings)
    pseudocodeGenerator.initiateModule(Settings)
    backend.initiateModule(callBlockList, callIgnoreList, callbackBlockList, callbackIgnoreList, Settings.Paused, Settings.CallStackSizeLimit, hookCode)
end