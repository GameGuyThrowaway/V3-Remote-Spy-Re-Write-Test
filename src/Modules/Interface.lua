local interfaceModule = {}

local EventPipe, callList, callbackList, callBlockList, callIgnoreList, callbackBlockList, callbackIgnoreList, Settings

function interfaceModule.initiateModule(CallList, CallbackList, CallBlockList, CallIgnoreList, CallbackBlockList, CallbackIgnoreList, SettingsTable)
    callList = CallList
    callbackList = CallbackList
    callBlockList = CallBlockList
    callIgnoreList = CallIgnoreList
    callbackBlockList = CallbackBlockList
    callbackIgnoreList = CallbackIgnoreList

    Settings = SettingsTable
end

function interfaceModule.setupEvents(TaskSignalLibrary)
    assert(not EventPipe, "Events Already Setup")

    EventPipe = TaskSignalLibrary.new({
        -- incoming data
        "onNewCall",
        "onNewCallback",
        "onNewConnection",
        "onReturnValueUpdated",

        -- outgoing data
        "onRemoteBlocked",
        "onRemoteIgnored",
        "onCallStackLimitChanged",

        -- core requests
        "generatePseudocode",
        "generatePseudoCallStack",
        "generatePseudoReturnValue",
        "getCallingScriptPath",
        "decompileCallingScript",
        "getRemotePath",
        "repeatCall",
        "clearRemoteCalls"
    })

    _G.blockRem = function(remoteID: string, callback: boolean, status: boolean)
        EventPipe:Fire("onRemoteBlocked", remoteID, callback, status)
    end

    _G.ignoreRem = function(remoteID: string, callback: boolean, status: boolean)
        EventPipe:Fire("onRemoteIgnored", remoteID, callback, status)
    end

    do -- initialize incoming requests
        EventPipe:ListenToEvent("onNewCall", function(remoteID: string, call)
            print("New Call:", remoteID, " | ", call.ArgCount)
        end)
        EventPipe:ListenToEvent("onNewCallback", function(remoteID: string, call)
            print("New Callback:", remoteID, " | ", call.ArgCount)
        end)
        EventPipe:ListenToEvent("onNewConnection", function(remoteID: string, call)
            print("New Connection:", remoteID, " | ", call.ArgCount)
        end)

        EventPipe:ListenToEvent("onReturnValueUpdated", function(remoteID: string, call)
            print("New ReturnValue:", remoteID, " | ", call.ReturnCount)
        end)
    end

    interfaceModule.EventPipe = EventPipe
end

return interfaceModule