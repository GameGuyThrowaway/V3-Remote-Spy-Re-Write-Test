local backendModule = {}

--[[
    * Currently I send the pause status and callstack limit to the hooks, but I could make the hooks fetch it every time using the BindableFunction
    * I could also send the entire ignore/block list to the spy as opposed to fetching each time
    * Should I put the Settings on a lower level?  (Pass whether callbacks/bindables/specific types are enabled or not, as to safe hook performance)
]]

local task_spawn = task.spawn

local callIgnoreList, callBlockList, callbackIgnoreList, callbackBlockList, callStackLimit: number, paused: boolean, hookCode: string -- initialize variables, later to be used to point to the real values
local metadata -- this is used to store metadata while the args are still being sent, due to a Bindable limitation, I need to split metadata from args
local EventPipe
local actorCon: SynConnection, dataCon: RBXScriptConnection, argCon: RBXScriptConnection

-- I could swap out this mutli channel system for a single SynGlobalSignal if I rewrote to use an identifier (need to Fire back instead of returning data)
local cmdChannel: BindableFunction, argChannel: BindableEvent, dataChannel: BindableEvent = Instance.new("BindableFunction"), Instance.new("BindableEvent"), Instance.new("BindableEvent")
-- cmdChannel is used for hooks sending a command and requesting data, arg is used to safely send args, dataChannel is used for one way data (metadata) from the hooks, and one way data (remote types being blocked) from the core

local commands = {
    checkBlocked = function(remoteID: string, callback: boolean)
        local list = callback and callbackBlockList or callBlockList

        return list[remoteID]
    end,
    checkIgnored = function(remoteID: string, callback: boolean)
        local list = callback and callbackIgnoreList or callIgnoreList

        return list[remoteID]
    end
}

cmdChannel.OnInvoke = function(callType: string, ...)
    return commands[callType](...)
end

dataCon = dataChannel.Event:Connect(function(callType: string, ...)
    warn(callType, "recv")
    if callType == "sendMetadata" then
        metadata = {...}
    end
end)

argCon = argChannel.Event:Connect(function(...)
    warn("args recv")
    assert(metadata, "FATAL ERROR, REPORT IMMEDIATELY")
    local callType = metadata[1]

    task_spawn(function(...)
        EventPipe:Fire(callType, {...}, select("#", ...), unpack(metadata, 2, #metadata))

        metadata = nil
    end, ...)
end)

local channelNumber: number = 0 -- used in return value keys

local function handleState(state: LuaStateProxy)
    state:Execute(hookCode, paused, callStackLimit, channelNumber, cmdChannel, argChannel, dataChannel)
    channelNumber += 1
end

function backendModule.initiateModule(CallBlockList, CallIgnoreList, CallbackBlockList, CallbackIgnoreList, Paused: boolean, CallStackLimit: number, HookCode: string)
    callIgnoreList = CallIgnoreList
    callBlockList = CallBlockList
    callbackIgnoreList = CallbackIgnoreList
    callbackBlockList = CallbackBlockList

    paused = Paused
    callStackLimit = CallStackLimit
    hookCode = HookCode

    actorCon = syn.on_actor_state_created:Connect(function(actor: Actor)
        handleState(getluastate(actor))
    end)

    handleState(getgamestate()) -- load the global state (channel 0)
    for _, v: LuaStateProxy in getactorstates() do
        handleState(v)
    end
end

function backendModule.setupEvents(TaskSignalLibrary)
    assert(not EventPipe, "Events Already Setup")
    EventPipe = TaskSignalLibrary.new({
        "onRemoteCall",
        "onRemoteCallback",
        "onRemoteConnection",
        "onReturnValueUpdated",
        "spyPaused",
        "updateCallStackLimit",
        "selfDestruct"
    })

    EventPipe:ListenToEvent("selfDestruct", function()
        actorCon:Disconnect()
        argCon:Disconnect()
        dataCon:Disconnect()
        dataChannel:Fire("selfDestruct")

        argChannel:Destroy()
        dataChannel:Destroy()
        cmdChannel:Destroy()
    end)

    EventPipe:ListenToEvent("updateCallStackLimit", function(newLimit: number)
        callStackLimit = newLimit
        dataChannel:Fire("updateCallStackLimit", newLimit)
    end)

    EventPipe:ListenToEvent("spyPaused", function(newState: boolean)
        paused = newState
        dataChannel:Fire("updateSpyPauseStatus", newState)
    end)

    backendModule.EventPipe = EventPipe
end

return backendModule
