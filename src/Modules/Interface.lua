local interfaceModule = {}

local EventPipe, RemoteList, BlockList, IgnoreList, Settings

function interfaceModule.initiateModule(remoteList, blockList, ignoreList, settings)
    RemoteList = remoteList
    BlockList = blockList
    IgnoreList = ignoreList
    Settings = settings
end

function interfaceModule.setupEvents(EventPipe)
    assert(not EventPipe, "Events Already Setup")
    
    EventPipe = EventPipe.new({
        -- incoming data
        'onNewCall',
        'onReturnValueUpdated',

        -- outgoing data
        'onRemoteBlocked', 
        'onRemoteIgnored',
        'onCallStackLimitChanged', 

        -- core requests
        'generatePseudocode',
        'generatePseudoCallStack',
        'generatePseudoReturnValue',
        'getCallingScriptPath',
        'decompileCallingScript',
        'getRemotePath',
        'repeatCall',
        'clearRemoteCalls'
    })

    do -- initialize incoming requests
        EventPipe:ListenToEvent('onNewCall', function(remoteID: string, call)
            rconsolewarn("New Call: " .. remoteID .. " | " .. call.ArgCount)
        end)

        EventPipe:ListenToEvent('onReturnValueUpdated', function(remoteID: string, call)
            rconsolewarn("New ReturnValue: " .. remoteID .. " | " .. call.ReturnCount)
        end)
    end

    interfaceModule.EventPipe = EventPipe
end

return interfaceModule