if not _G.remoteSpyHookedState then -- ensuring hooks are never ran twice
    _G.remoteSpyHookedState = true
    
    local task_spawn = task.spawn
    local coroutine_running = coroutine.running
    local coroutine_wrap = coroutine.wrap
    local table_insert = table.insert
    local table_clear = table.clear
    local get_call_stack = debug.getcallstack
    local get_debug_id = game.GetDebugId
    local set_thread_identity = syn.set_thread_identity
    local oth_get_original_thread = syn.oth.get_original_thread
    local oth_hook = syn.oth.hook
    local trampoline_call = syn.trampoline_call
    
    local spyPaused: boolean, callStackLimit: number, channelKey: number, cmdChannel: BindableFunction, argChannel: BindableEvent, dataChannel: BindableEvent = ...

    local callCount: number = 0
    local oldHooks, callbackHooks, signalHooks = {}, {}, {}
    local connection: RBXScriptConnection


    local commands = {
        selfDestruct = function()
            connection:Disconnect()
            -- need to unhook all signals/functions (callbacks included) here
        
            local unHook = syn.oth.unhook
            unHook(Instance.new("RemoteEvent").FireServer, oldHooks.FireServer)
            unHook(Instance.new("RemoteFunction").InvokeServer, oldHooks.InvokeServer)
            unHook(Instance.new("BindableEvent").Fire, oldHooks.Fire)
            unHook(Instance.new("BindableFunction").Invoke, oldHooks.Invoke)
            
            local mt = getrawmetatable(game)
            unHook(mt.__namecall, oldHooks.Namecall)
            unHook(mt.__index, oldHooks.Index)
            unHook(mt.__newindex, oldHooks.NewIndex)
            
            for _,v in callbackHooks do
                if v.Instance and v.OriginalFunction then -- might've gced by now
                    v.Instance[v.CallbackName] = v.OriginalFunction
                end
            end
        
            for _,v: RBXScriptSignal in signalHooks do
                if issignalhooked(v) then
                    restoresignal(v)
                end
            end

            _G.remoteSpyHookedState = false
        end,
        updateCallStackLimit = function(data: number)
            callStackLimit = data
        end,
        updatePauseStatus = function(status: boolean)
            spyPaused = status
        end,
        updateRemoteTypePaused = function(remoteType: string, callback: boolean, status: boolean)
            remoteType[remoteType][callback and "CallbackEnabled" or "CallEnabled"] = status
        end
    }
    connection = dataChannel.Event:Connect(function(commandName: string, data: any)
        local commandFunction = commands[commandName]

        assert(commandFunction, "INVALID COMMAND: ", commandName)

        commandFunction(data)
    end)

    local function desanitizeData(deSanitizePaths) -- this function returns the orginal dangerous values, ensuring the creator doesn't know what happened
        for parentTable, data in deSanitizePaths do
            for _, mod in data.mods do
                rawset(parentTable, mod[2], nil)
                rawset(parentTable, mod[1], mod[3])
            end

            if data.readOnly then setreadonly(parentTable, true) end
        end
    end

    local function partiallySanitizeData(data, deSanitizePaths) -- this is used to cloneref all instances, only to be run on return values, connections, or callbacks
        local first: boolean = false
        if not deSanitizePaths then
            deSanitizePaths = {}
            first = true
        end

        for i,v in next, data do
            local valueType = typeof(v)

            if valueType == "Instance" then -- cloneref all instances so that weak table detections are fully thwarted (all other userdatas are handled by this being sent through a bindable)
                local dataReadOnly: boolean = isreadonly(data)
                if dataReadOnly then setreadonly(data, false) end

                rawset(data, i, cloneref(v))

                if not deSanitizePaths[data] then
                    deSanitizePaths[data] = {
                        mods = { { i, i, v } },
                        readOnly = dataReadOnly
                    }
                else
                    table_insert(deSanitizePaths[data].mods, { i, i, v })
                end
            elseif valueType == "table" then -- recursive checks
                partiallySanitizeData(data, deSanitizePaths)
            end
        end

        if first then
            return deSanitizePaths
        end
    end

    local dataTypes = {
        table = "Table",
        userdata = "void"
    }

    local classDict = {
        FireServer = "RemoteEvent",
        fireServer = "RemoteEvent",
        InvokeServer = "RemoteFunction",
        invokeServer = "RemoteFunction",
        Fire = "BindableEvent",
        fire = "BindableEvent",
        Invoke = "BindableFunction",
        invoke = "BindableFunction",

        OnClientEvent = "RemoteEvent",
        onClientEvent = "RemoteEvent",
        OnClientInvoke = "RemoteFunction",
        onClientInvoke = "RemoteFunction",
        Event = "BindableEvent",
        event = "BindableEvent",
        OnInvoke = "BindableFunction",
        onInvoke = "BindableFunction"
    }

    local thread, stack -- used in sanitizeData, globalized so it stays during recursive calls

    local function sanitizeData(data, offThread: boolean, depth: number, deSanitizePaths) -- this replaces unsafe indices, checks for cyclics, or stack overflow attemps, and clonerefs all instances
        if depth > 298 then return false end

        local deadCall: boolean = false

        local first: boolean = false
        if not deSanitizePaths then
            deSanitizePaths = {}
            first = true
        end

        for i, v in next, data do

            local valueType: string = typeof(v)
            if valueType == "table" then -- recursive checks
                if sanitizeData(v, depth+1, deSanitizePaths) ~= false then -- sanitize, but check for stack overflow/cyclic
                    if not first then
                        return false
                    else
                        deadCall = true
                        break
                    end
                end
            elseif valueType == "Instance" then -- prevent weak table checks
                
                local dataReadOnly: boolean = isreadonly(data)
                if dataReadOnly then setreadonly(data, false) end

                rawset(data, i, cloneref(v))

                if not deSanitizePaths[data] then
                    deSanitizePaths[data] = {
                        mods = { { i, i, v } },
                        readOnly = dataReadOnly
                    }
                else
                    table_insert(deSanitizePaths[data].mods, { i, i, v })
                end
            elseif valueType == "thread" or valueType == "function" then -- threads and functions can't be sent

                local dataReadOnly: boolean = isreadonly(data)
                if dataReadOnly then setreadonly(data, false) end

                rawset(data, i, nil)

                if not deSanitizePaths[data] then
                    deSanitizePaths[data] = {
                        mods = { { i, i, v } },
                        readOnly = dataReadOnly
                    }
                else
                    table_insert(deSanitizePaths[data].mods, { i, i, v })
                end
            end

            if not first then -- the first indices are all numbers
                local indexType = typeof(i)
                if indexType == "thread" then return false end -- threads are illegal, can't be sent as indices, roblox will error otherwise
                local indexTypeSub = dataTypes[indexType]
                if indexTypeSub then -- if it's a userdata/thread
                    local oldMt = getrawmetatable(i)
                    if oldMt then
                        local wasReadOnly: boolean = isreadonly(oldMt)
                        if wasReadOnly then setreadonly(oldMt, false) end
                        local toString = rawget(oldMt, "__tostring")

                        if type(toString) == "function" then

                            if not thread then -- initiate thread and stack globals for this recursive sanitation
                                local th = offThread and oth_get_original_thread() or coroutine_running()

                                thread = { thread = th }
                                stack = get_call_stack(th)

                                local tostringCall = { -- spoof to make the game think namecall/FireServer called tostring, which called __tostring
                                    func = tostring,
                                    currentline = -1
                                }

                                if offThread then
                                    table_insert(stack, tostringCall) -- oth doesn't include getcallstack call because it's the original thread, and callstack was called from hook thread
                                else
                                    stack[#stack-1] = tostringCall -- non oth uses the current (and original) thread, which is the one that called getcallstack, so it needs to get rid of it
                                    -- double check this to make sure it's the only thing that needs to be rid of
                                end
                            end

                            local suc, str = trampoline_call(toString, stack, thread, i)
                            if not suc then return false end -- should never return false, otherwise the call couldn't have gone through

                            local newIndex: string = "<" .. indexType .. "> (" .. str .. ")" -- new index, exactly as the roblox serializer would've made it

                            local dataReadOnly: boolean = isreadonly(data) -- make sure the table isn't frozen
                            if dataReadOnly then setreadonly(data, false) end

                            rawset(data, newIndex, v)
                            rawset(data, i, nil)
                            if not deSanitizePaths[data] then -- cache so that it can be restored later, as we're directly modifying the original args
                                deSanitizePaths[data] = {
                                    mods = { { i, newIndex, v } },
                                    readOnly = dataReadOnly
                                }
                            else
                                table_insert(deSanitizePaths[data].mods, { i, newIndex, v })
                            end
                        end

                        if wasReadOnly then setreadonly(oldMt, true) end
                    end
                end
            end
        end
        
        if first then
            thread, stack = nil, nil -- set thread and stack globals back to nil, to be remade when the next sanitation occurs
            if deadCall then
                return false, deSanitizePaths
            else
                return true, deSanitizePaths
            end
        end
    end

    local function createCallStack(thread: thread, offset: number) -- offset is always 2 in this code, 1 for the hook, 1 because we don't need to log the C function call
        local newCallStack = {}
    
        offset += 1 -- +1 to account for this function
    
        local realCallStack = debug.getcallstack(thread)
        local stackSize = #realCallStack
        local iterStart = 1
        if stackSize > callStackLimit then
            iterStart = stackSize - callStackLimit + 1 -- base 1
        end
    
        for i = iterStart, stackSize do
            local v = realCallStack[i]
    
            local funcInfo = getinfo(v.func)
            local tempScript = rawget(getfenv(v.func), "script")
    
            local varArg = false -- converting is_vararg from 1/0 to true/false
            if funcInfo.is_vararg == 1 then varArg = true end
    
            newCallStack[i-iterStart+1] = {
                Script = typeof(tempScript) == "Instance" and cloneref(tempScript),
                Type = funcInfo.what,
                LineNumber = funcInfo.currentline,
                FunctionName = funcInfo.name,
                ParameterCount = funcInfo.numparams,
                IsVarArg = varArg,
                UpvalueCount = funcInfo.nups
            }
        end
    
        return newCallStack
    end

    local function processReturnValue(...)
        return {...}, select("#", ...)
    end

    local function newHookMetamethod(toHook, mtmethod: string, hookFunction, filter: FilterBase)
        local oldFunction

        local func = getfilter(filter, function(...) 
            return oldFunction(...)
        end, hookFunction)

        restorefunction(getrawmetatable(toHook)[mtmethod]) -- restores any old hooks
        oldFunction = oth_hook(getrawmetatable(toHook)[mtmethod], func) -- hookmetamethod(toHook, mtmethod, func) 
        return oldFunction
    end

    local function filteredOth(toHook, hookFunction, filter: FilterBase)
        local oldFunction

        local func = getfilter(filter, function(...) 
            return oldFunction(...)
        end, hookFunction)

        restorefunction(toHook)
        oldFunction = oth_hook(toHook, func)
        return oldFunction
    end


    local fire = argChannel.Fire
    local invoke = cmdChannel.Invoke
    
    local function addCallbackHook(remote: RemoteFunction | BindableFunction, callbackMethod: string, newCallback): boolean
        set_thread_identity(3)

        local callbackFunc = newCallback -- get the function that will be called
        if type(callbackFunc) ~= "function" then
            local mt = getrawmetatable(newCallback)
            if mt then
                local wasReadOnly = isreadonly(mt)
                if wasReadOnly then
                    setreadonly(mt, false)
                    callbackFunc = mt.__call
                    setreadonly(mt, true)
                else
                    callbackFunc = mt.__call
                end
            end
            if type(callbackFunc) ~= "function" then return false end -- if it still isn't a function after this, it's an invalid call
        end

        local remoteID: string = get_debug_id(remote)
        local cloneRemote: RemoteFunction | BindableFunction = cloneref(remote)

        if not callbackHooks[remoteID] then
            callbackHooks[remoteID] = setmetatable({
                Instance = cloneRemote,
                CallbackMethod = callbackMethod,
                OriginalFunction = newCallback
            }, {__mode = "v"})

            cloneRemote[callbackMethod] = function(...)
                if not spyPaused then
                    if not oldHooks.Invoke(cmdChannel, "checkIgnored", remoteID, true) then
                        local argSize: number = select("#", ...)
                        local data = {...}
                        local desanitizePaths = partiallySanitizeData(data)

                        callCount += 1
                        local returnKey: string = channelKey .. "|" .. callCount

                        local scr: Instance = getcallingscript()
                        oldHooks.Fire(dataChannel, "sendMetadata", "onRemoteCallback", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr))
                        oldHooks.Fire(argChannel, unpack(data, 1, argSize))
                        desanitizeData(desanitizePaths)
                        
                        if oldHooks.Invoke(cmdChannel, "checkBlocked", remoteID) then
                            return
                        else
                            local returnData, returnDataSize = processReturnValue(coroutine_wrap(callbackHooks[remoteID].OriginalFunction)(...))
                            local desanitizeReturnPaths = partiallySanitizeData(returnData)

                            oldHooks.Fire(dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                            oldHooks.Fire(argChannel, unpack(returnData, 1, returnDataSize))
                            desanitizeData(desanitizeReturnPaths)

                            return unpack(returnData, 1, returnDataSize)
                        end
                    else
                        if oldHooks.Invoke(cmdChannel, "checkBlocked", remoteID, true) then
                            return
                        end
                    end
                end

                return coroutine_wrap(callbackHooks[remoteID].OriginalFunction)(...)
            end
        else
            callbackHooks[remoteID].OriginalFunction = newCallback
        end

        return true
    end

    local function addSignalHook(remote: RemoteEvent | BindableEvent, connectionMethod: string, signal: RBXScriptSignal)
        set_thread_identity(3)

        if not issignalhooked(signal) then
            local remoteID: string = get_debug_id(remote)
            local cloneRemote: RemoteEvent | BindableEvent = cloneref(remote)
            
            local scriptCache = {} -- global because the hook is repeatedly called, should be cleared after the last hook call
            local iterNumber = 0
            local conCount = -1

            table_insert(signalHooks, signal)

            hooksignal(signal, function(info, ...)
                if not spyPaused then
                    iterNumber += 1

                    if conCount == -1 then
                        conCount = #getconnections(signal)-1
                    end

                    if not invoke(cmdChannel, "checkIgnored", remoteID, true) then
                        local scr = issynapsethread(coroutine_running()) and "Synapse" or getcallingscript()
                        if typeof(scr) == "Instance" then scr = cloneref(scr) end
                        
                        if scr then
                            if scriptCache[scr] then
                                scriptCache[scr] += 1
                            else
                                scriptCache[scr] = 1
                            end
                        end

                        if (iterNumber == conCount) then
                            local argSize: number = select("#", ...)
                            local data = {...}
                            local desanitizePaths = partiallySanitizeData(data)

                            fire(dataChannel, "sendMetadata", "onRemoteConnection", cloneRemote, remoteID, scriptCache)
                            fire(argChannel, unpack(data, 1, argSize))
                            desanitizeData(desanitizePaths)
                            table_clear(scriptCache)
                            conCount = 0
                            iterNumber = 0
                        end
                    elseif (iterNumber == conCount) then -- reset for next signal
                        table_clear(scriptCache)
                        conCount = 0
                        iterNumber = 0
                    end
                end

                if cmdChannel:Fire("checkBlocked", remoteID, true) then
                    return false
                end

                return true, ...
            end)
        end

    end

    local filters = {
        Namecall = AnyFilter.new({
            AllFilter.new({
                InstanceTypeFilter.new(1, "RemoteEvent"),
                AnyFilter.new({
                    NamecallFilter.new("FireServer"),
                    NamecallFilter.new("fireServer")
                })
            }),
            AllFilter.new({
                InstanceTypeFilter.new(1, "RemoteFunction"),
                AnyFilter.new({
                    NamecallFilter.new("InvokeServer"),
                    NamecallFilter.new("invokeServer")
                })
            }),
            AllFilter.new({
                InstanceTypeFilter.new(1, "BindableEvent"),
                NotFilter.new(ArgumentFilter.new(1, argChannel)),
                NotFilter.new(ArgumentFilter.new(1, dataChannel)),

                AnyFilter.new({
                    NamecallFilter.new("Fire"),
                    NamecallFilter.new("fire")
                })
            }),
            AllFilter.new({
                InstanceTypeFilter.new(1, "BindableFunction"),
                NotFilter.new(ArgumentFilter.new(1, cmdChannel)),

                AnyFilter.new({
                    NamecallFilter.new("Invoke"),
                    NamecallFilter.new("invoke")
                })
            })
        }),

        NewIndex = AllFilter.new({
            AnyFilter.new({
                TypeFilter.new(3, "function"),
                TypeFilter.new(3, "table"),
                UserdataTypeFilter.new(3, newproxy(true))
            }),
            AnyFilter.new({
                AllFilter.new({
                    InstanceTypeFilter.new(1, "RemoteFunction"),
                    AnyFilter.new({
                        ArgumentFilter.new(2, "OnClientInvoke"),
                        ArgumentFilter.new(2, "onClientInvoke")
                    })
                }),
                AllFilter.new({
                    InstanceTypeFilter.new(1, "BindableFunction"),
                    NotFilter.new(ArgumentFilter.new(1, cmdChannel)),

                    AnyFilter.new({
                        ArgumentFilter.new(2, "OnInvoke"),
                        ArgumentFilter.new(2, "onInvoke")
                    })
                })
            })
        }),

        Index = AnyFilter.new({
            AllFilter.new({
                InstanceTypeFilter.new(1, "RemoteEvent"),
                AnyFilter.new({
                    ArgumentFilter.new(2, "OnClientEvent"),
                    ArgumentFilter.new(2, "onClientEvent")
                })
            }),
            AllFilter.new({
                InstanceTypeFilter.new(1, "BindableEvent"),
                NotFilter.new(ArgumentFilter.new(1, argChannel)),
                NotFilter.new(ArgumentFilter.new(1, dataChannel)),

                AnyFilter.new({
                    ArgumentFilter.new(2, "Event"),
                    ArgumentFilter.new(2, "event")
                })
            })
        })
    }

    local oldNewIndex
    oldNewIndex = newHookMetamethod(game, "__newindex", newcclosure(function(remote: RemoteFunction | BindableFunction, idx: string, newidx)
        if not addCallbackHook(cloneref(remote), idx, newidx) then
            return oldNewIndex(remote, idx, newidx)
        end
    end), filters.NewIndex)
    oldHooks.NewIndex = oldNewIndex
    
    local oldIndex
    oldIndex = newHookMetamethod(game, "__index", newcclosure(function(remote: RemoteEvent | BindableEvent, idx: string)
        local newSignal = oldIndex(remote, idx)
        task_spawn(addSignalHook, cloneref(remote), idx, newSignal)
    
        return newSignal
    end), filters.Index)
    oldHooks.Index = oldIndex

    local oldNamecall
    oldNamecall = newHookMetamethod(game, "__namecall", newcclosure(function(remote: RemoteEvent | RemoteFunction | BindableEvent | BindableFunction, ...: any)
        if not checkparallel() and not spyPaused then
            local argSize = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: RemoteEvent | RemoteFunction | BindableEvent | BindableFunction = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not invoke(cmdChannel, "checkIgnored", remoteID, false) then
                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, -1)

                    if success then
                        local className: string = classDict[getnamecallmethod()]

                        if (className == "RemoteFunction" or className == "BindableFunction") then
                            local scr: Instance = getcallingscript()

                            callCount += 1
                            local returnKey: string = channelKey .. "|" .. callCount

                            fire(dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr), createCallStack(oth_get_original_thread(), 0))
                            fire(argChannel, unpack(data, 1, argSize))
                            desanitizeData(desanitizePaths)
                            
                            if invoke(cmdChannel, "checkBlocked", remoteID) then
                                return
                            else
                                local returnData, returnDataSize = processReturnValue(oldNamecall(remote, ...))
                                local desanitizeReturnPaths = partiallySanitizeData(returnData)

                                fire(dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                                fire(argChannel, unpack(returnData, 1, returnDataSize))
                                desanitizeData(desanitizeReturnPaths)

                                return unpack(returnData, 1, returnDataSize)
                            end
                        else
                            local scr: Instance = getcallingscript()
                            fire(dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, nil, typeof(scr) == "Instance" and cloneref(scr), createCallStack(oth_get_original_thread(), 0))
                            fire(argChannel, unpack(data, 1, argSize))

                            if invoke(cmdChannel, "checkBlocked", remoteID) then
                                return
                            end
                        end

                        fire(argChannel, unpack(data, 1, argSize))
                    else
                        desanitizeData(desanitizePaths) -- doesn't get blocked if it's an illegal (impossible) call
                    end
                else
                    if invoke(cmdChannel, "checkBlocked", remoteID) then
                        return
                    end
                end
            end
        end

        return oldNamecall(remote, ...)
    end), filters.Namecall)
    oldHooks.Namecall = oldNamecall


    local oldFireServer
    oldFireServer = filteredOth(Instance.new("RemoteEvent").FireServer, newcclosure(function(remote: RemoteEvent, ...: any)
        if not checkparallel() and not spyPaused then
            local argSize = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: RemoteEvent = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not invoke(cmdChannel, "checkIgnored", remoteID, false) then
                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, -1)

                    if success then
                        local scr: Instance = getcallingscript()
                        fire(dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, nil, typeof(scr) == "Instance" and cloneref(scr), createCallStack(oth_get_original_thread(), 0))
                        fire(argChannel, unpack(data, 1, argSize))
                    end

                    desanitizeData(desanitizePaths)
                end

                if invoke(cmdChannel, "checkBlocked", remoteID) then
                    return
                end
            end
        end

        return oldFireServer(remote, ...)
    end), InstanceTypeFilter.new(1, "RemoteEvent"))
    oldHooks.FireServer = oldFireServer

    local oldFire
    oldFire = filteredOth(Instance.new("BindableEvent").Fire, newcclosure(function(remote: BindableEvent, ...: any)
        if not checkparallel() and not spyPaused then
            local argSize = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: BindableEvent = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not invoke(cmdChannel, "checkIgnored", remoteID, false) then
                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, -1)

                    if success then
                        local scr: Instance = getcallingscript()
                        fire(dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, nil, typeof(scr) == "Instance" and cloneref(scr), createCallStack(oth_get_original_thread(), 0))
                        fire(argChannel, unpack(data, 1, argSize))
                    end

                    desanitizeData(desanitizePaths)
                end

                if invoke(cmdChannel, "checkBlocked", remoteID) then
                    return
                end
            end
        end

        return oldFire(remote, ...)
    end), InstanceTypeFilter.new(1, "BindableEvent"))
    oldHooks.Fire = oldFire

    local oldInvokeServer
    oldInvokeServer = filteredOth(Instance.new("RemoteFunction").InvokeServer, newcclosure(function(remote: RemoteFunction, ...: any)
        if not checkparallel() and not spyPaused then
            local argSize = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: RemoteFunction = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not invoke(cmdChannel, "checkIgnored", remoteID, false) then

                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, -1)

                    if success then
                        callCount += 1
                        local returnKey: string = channelKey.."|"..callCount
                        
                        local scr: Instance = getcallingscript()
                        fire(dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr), createCallStack(oth_get_original_thread(), 0))
                        fire(argChannel, unpack(data, 1, argSize))
                        desanitizeData(desanitizePaths)
                        
                        if invoke(cmdChannel, "checkBlocked", remoteID) then
                            return
                        else
                            local returnData, returnDataSize = processReturnValue(oldInvokeServer(remote, ...))
                            local desanitizeReturnPaths = partiallySanitizeData(returnData)

                            fire(dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                            fire(argChannel, unpack(returnData, 1, returnDataSize))
                            desanitizeData(desanitizeReturnPaths)

                            return unpack(returnData, 1, returnDataSize)
                        end
                    else
                        desanitizeData(desanitizePaths)
                    end
                else
                    if invoke(cmdChannel, "checkBlocked", remoteID) then
                        return
                    end
                end
            end
        end

        return oldInvokeServer(remote, ...)
    end), InstanceTypeFilter.new(1, "RemoteFunction"))
    oldHooks.InvokeServer = oldInvokeServer

    local oldInvoke
    oldInvoke = filteredOth(Instance.new("BindableFunction").Invoke, newcclosure(function(remote: BindableFunction, ...: any)
        if not checkparallel() and not spyPaused then
            local argSize = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: BindableEvent = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not invoke(cmdChannel, "checkIgnored", remoteID, false) then

                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, -1)

                    if success then
                        callCount += 1
                        local returnKey: string = channelKey.."|"..callCount

                        local scr: Instance = getcallingscript()
                        fire(dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr), createCallStack(oth_get_original_thread(), 0))
                        fire(argChannel, unpack(data, 1, argSize))
                        desanitizeData(desanitizePaths)
                        
                        if invoke(cmdChannel, "checkBlocked", remoteID) then
                            return
                        else
                            local returnData, returnDataSize = processReturnValue(oldInvoke(remote, ...))
                            local desanitizeReturnPaths = partiallySanitizeData(returnData)

                            fire(dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                            fire(argChannel, unpack(returnData, 1, returnDataSize))
                            desanitizeData(desanitizeReturnPaths)

                            return unpack(returnData, 1, returnDataSize)
                        end
                    else
                        desanitizeData(desanitizePaths)
                    end
                else
                    if invoke(cmdChannel, "checkBlocked", remoteID) then
                        return
                    end
                end
            end
        end

        return oldInvoke(remote, ...)
    end), InstanceTypeFilter.new(1, "BindableFunction"))
    oldHooks.Invoke = oldInvoke
end