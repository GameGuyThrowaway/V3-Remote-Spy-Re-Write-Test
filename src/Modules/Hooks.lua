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
    local oth_unhook = syn.oth.unhook
    local trampoline_call = syn.trampoline_call

    local spyPaused: boolean, callStackLimit: number, channelKey: number, cmdChannel: BindableFunction, argChannel: BindableEvent, dataChannel: BindableEvent = ...
    local callbackReturnSpoof: BindableFunction = Instance.new("BindableFunction") -- ask me if you want to know why

    local callCount: number = 0
    local oldHooks, callbackHooks, signalHooks = {}, {}, {}
    local connection: RBXScriptConnection

    local function checkparallel()
        return false
    end


    local commands = {
        selfDestruct = function()
            connection:Disconnect()
            -- need to unhook all signals/functions (callbacks included) here

            oth_unhook(Instance.new("RemoteEvent").FireServer, oldHooks.FireServer)
            oth_unhook(Instance.new("RemoteFunction").InvokeServer, oldHooks.InvokeServer)
            oth_unhook(Instance.new("BindableEvent").Fire, oldHooks.Fire)
            oth_unhook(Instance.new("BindableFunction").Invoke, oldHooks.Invoke)

            local mt = getrawmetatable(game)
            oth_unhook(mt.__namecall, oldHooks.Namecall)
            oth_unhook(mt.__index, oldHooks.Index)
            oth_unhook(mt.__newindex, oldHooks.NewIndex)

            for _,v in callbackHooks do
                if getcallbackmember(v.Instance, v.CallbackMethod) == v.ProxyFunction then -- check if our hook is still applied
                    v.Instance[v.CallbackMethod] = v.OriginalFunction -- if it is, get rid of it
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
        updateSpyPauseStatus = function(status: boolean)
            spyPaused = status
        end,
        updateRemoteTypePaused = function(remoteType: string, callback: boolean, status: boolean)
            remoteType[remoteType][callback and "CallbackEnabled" or "CallEnabled"] = status
        end
    }
    connection = dataChannel.Event:Connect(function(commandName: string, data)
        local commandFunction = commands[commandName]

        if commandFunction then -- same channel as used in Backend, no overlapping commands, so this works as a check
            commandFunction(data)
        end
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

        for i,v in data do
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
                partiallySanitizeData(v, deSanitizePaths)
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
        FireServer = {
            Type = "Event",
            IsRemote = true
        },
        fireServer = {
            Type = "Event",
            IsRemote = true
        },
        InvokeServer = {
            Type = "Function",
            IsRemote = true
        },
        invokeServer = {
            Type = "Function",
            IsRemote = true
        },
        Fire = {
            Type = "Event",
            IsRemote = false
        },
        fire = {
            Type = "Event",
            IsRemote = false
        },
        Invoke = {
            Type = "Function",
            IsRemote = false
        },
        invoke = {
            Type = "Function",
            IsRemote = false
        }
    }

    local thread, stack -- used in sanitizeData, globalized so it stays during recursive calls

    local function sanitizeData(data, offThread: boolean, depth: number, deSanitizePaths) -- this replaces unsafe indices, checks for cyclics, or stack overflow attemps, and clonerefs all instances
        depth = depth or 0
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
                if sanitizeData(v, offThread, depth+1, deSanitizePaths) ~= false then -- sanitize, but check for stack overflow/cyclic
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

        local realCallStack = get_call_stack(thread)
        local stackSize: number = (#realCallStack-1) -- -1 cause syn call is the last index
        local iterStart: number = 1 -- base 1=
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

    local blockList = {}
    local ignoreList = { [game.ReplicatedFirst.RemoteEvent:GetDebugId()] = true }

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

    local fire = argChannel.Fire -- task.spawn'ed cause of OTH limitations
    local invoke = cmdChannel.Invoke -- coroutine.wrap'ed cause of OTH limitations

    -- neither callback nor signal hooks need to use task.spawn/coroutine.wrap for bindable calls, as they aren't coming from an OTH thread

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

        local callbackProxy = function(...)
            if not spyPaused then
                local t = tick()

                if not invoke(cmdChannel, "checkIgnored", remoteID, true) then
                    local argSize: number = select("#", ...)
                    local data = {...}
                    local desanitizePaths = partiallySanitizeData(data)

                    callCount += 1
                    local returnKey: string = channelKey .. "|" .. callCount

                    local th: thread = coroutine_running()
                    local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                    fire(dataChannel, "sendMetadata", "onRemoteCallback", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr))
                    fire(argChannel, unpack(data, 1, argSize))
                    desanitizeData(desanitizePaths)

                    if invoke(cmdChannel, "checkBlocked", remoteID) then
                        return
                    else
                        callbackReturnSpoof.OnInvoke = callbackFunc
                        local returnData, returnDataSize = processReturnValue(invoke(callbackReturnSpoof, ...))
                        local desanitizeReturnPaths = partiallySanitizeData(returnData)

                        fire(dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                        fire(argChannel, unpack(returnData, 1, returnDataSize))
                        desanitizeData(desanitizeReturnPaths)

                        return unpack(returnData, 1, returnDataSize)
                    end
                elseif invoke(cmdChannel, "checkBlocked", remoteID, true) then
                    return
                end

                warn("cb", tick() - t)
            end

            callbackReturnSpoof.OnInvoke = callbackFunc
            return invoke(callbackReturnSpoof, ...)
        end

        callbackHooks[remoteID] = setmetatable({
            Instance = cloneRemote,
            CallbackMethod = callbackMethod,
            ProxyFunction = callbackProxy,
            OriginalFunction = callbackFunc
        }, {__mode = "v"})

        return callbackProxy
    end

    local function restoreSignalHook(remote: RemoteEvent | BindableEvent)
        local remoteID: string = get_debug_id(remote)
        local signal: RBXScriptSignal = signalHooks[remoteID]
        if signal then
            restoresignal(signal)
        end
    end

    local function addSignalHook(remote: RemoteEvent | BindableEvent, signal: RBXScriptSignal)
        set_thread_identity(3)

        if not issignalhooked(signal) then
            local remoteID: string = get_debug_id(remote)
            local cloneRemote: RemoteEvent | BindableEvent = cloneref(remote)

            local scriptCache = {} -- global because the hook is repeatedly called, should be cleared after the last hook call
            local iterNumber = 0
            local conCount = -1

            signalHooks[remoteID] = signal

            hooksignal(signal, function(info, ...)
                if not spyPaused then
                    local t = tick()

                    iterNumber += 1

                    if conCount == -1 then
                        conCount = #getconnections(signal)-2
                        if conCount < 1 then -- impossible (unless core signal or smthn)
                            conCount = -1
                            return true, ...
                        end
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
                            conCount = -1
                            iterNumber = 0
                        end
                    elseif (iterNumber == conCount) then -- reset for next signal
                        table_clear(scriptCache)
                        conCount = -1
                        iterNumber = 0
                    end

                    if invoke(cmdChannel, "checkBlocked", remoteID, true) then
                        return false
                    end
                    warn("sig", tick() - t)
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
                NotFilter.new(ArgumentFilter.new(1, safeEventTest)),

                AnyFilter.new({
                    NamecallFilter.new("Fire"),
                    NamecallFilter.new("fire")
                })
            }),
            AllFilter.new({
                InstanceTypeFilter.new(1, "BindableFunction"),
                NotFilter.new(ArgumentFilter.new(1, cmdChannel)),
                NotFilter.new(ArgumentFilter.new(1, callbackReturnSpoof)),
                NotFilter.new(ArgumentFilter.new(1, safeFunctionTest)),

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
                    NotFilter.new(ArgumentFilter.new(1, callbackReturnSpoof)),
                    NotFilter.new(ArgumentFilter.new(1, safeFunctionTest)),

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
                NotFilter.new(ArgumentFilter.new(1, safeEventTest)),

                AnyFilter.new({
                    ArgumentFilter.new(2, "Event"),
                    ArgumentFilter.new(2, "event")
                })
            })
        }),

        BindableEvent = AllFilter.new({
            InstanceTypeFilter.new(1, "BindableEvent"),
            NotFilter.new(ArgumentFilter.new(1, argChannel)),
            NotFilter.new(ArgumentFilter.new(1, dataChannel))
        }),

        BindableFunction = AllFilter.new({
            InstanceTypeFilter.new(1, "BindableFunction"),
            NotFilter.new(ArgumentFilter.new(1, cmdChannel)),
            NotFilter.new(ArgumentFilter.new(1, callbackReturnSpoof))
        }),

        RemoteEvent = InstanceTypeFilter.new(1, "RemoteEvent"),

        RemoteFunction = InstanceTypeFilter.new(1, "RemoteFunction")
    }

    local oldNewIndex
    oldNewIndex = newHookMetamethod(game, "__newindex", newcclosure(function(remote: RemoteFunction | BindableFunction, idx: string, newidx)
        local callbackProxy = addCallbackHook(cloneref(remote), idx, newidx)
        if not callbackProxy then
            return oldNewIndex(remote, idx, newidx)
        end

        return oldNewIndex(remote, idx, callbackProxy)
    end), filters.NewIndex)
    oldHooks.NewIndex = oldNewIndex

    local oldIndex
    oldIndex = newHookMetamethod(game, "__index", newcclosure(function(remote: RemoteEvent | BindableEvent, idx: string)
        local newSignal = oldIndex(remote, idx)
        task_spawn(addSignalHook, cloneref(remote), newSignal)

        return newSignal
    end), filters.Index)
    oldHooks.Index = oldIndex

    local oldNamecall
    oldNamecall = newHookMetamethod(game, "__namecall", newcclosure(function(remote: RemoteEvent | RemoteFunction | BindableEvent | BindableFunction, ...: any)

        local class = classDict[getnamecallmethod()]

        if not spyPaused and not (class.IsRemote and checkparallel()) then
            local t = tick()
            set_thread_identity(3)
            local argSize: number = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: RemoteEvent | RemoteFunction | BindableEvent | BindableFunction = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not coroutine_wrap(invoke)(cmdChannel, "checkIgnored", remoteID, false) then
                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, true, -1)

                    if success then

                        if class.Type == "Function" then -- remotes can't run in parallel
                            local th: thread = oth_get_original_thread()
                            local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                            callCount += 1
                            local returnKey: string = channelKey .. "|" .. callCount

                            task_spawn(fire, dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr) or scr, createCallStack(th, 0))
                            task_spawn(fire, argChannel, unpack(data, 1, argSize))
                            desanitizeData(desanitizePaths)

                            if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                                return
                            else
                                local returnData, returnDataSize = processReturnValue(oldNamecall(remote, ...))
                                local desanitizeReturnPaths = partiallySanitizeData(returnData)

                                task_spawn(fire, dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                                task_spawn(fire, argChannel, unpack(returnData, 1, returnDataSize))
                                desanitizeData(desanitizeReturnPaths)

                                return unpack(returnData, 1, returnDataSize)
                            end
                        else
                            local th: thread = oth_get_original_thread()
                            local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                            task_spawn(fire, dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, nil, typeof(scr) == "Instance" and cloneref(scr), createCallStack(th, 0))
                            task_spawn(fire, argChannel, unpack(data, 1, argSize))
                            desanitizeData(desanitizePaths)

                            if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                                return
                            end
                        end
                    else
                        desanitizeData(desanitizePaths) -- doesn't get blocked if it's an illegal (impossible) call
                    end
                else
                    if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                        return
                    end
                end
            end
            warn("nmc", tick() - t)
        end

        return oldNamecall(remote, ...)
    end), filters.Namecall)
    oldHooks.Namecall = oldNamecall

    local oldFireServer
    oldFireServer = filteredOth(Instance.new("RemoteEvent").FireServer, newcclosure(function(remote: RemoteEvent, ...: any)

        if not spyPaused and not checkparallel() then
            local t = tick()
            set_thread_identity(3)
            local argSize: number = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: RemoteEvent = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not ignoreList[remoteID] then --coroutine_wrap(invoke)(cmdChannel, "checkIgnored", remoteID, false) then
                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, true, -1)

                    if success then
                        local th: thread = oth_get_original_thread()
                        local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                        task_spawn(fire, dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, nil, typeof(scr) == "Instance" and cloneref(scr), createCallStack(th, 0))
                        task_spawn(fire, argChannel, unpack(data, 1, argSize))
                    end

                    desanitizeData(desanitizePaths)
                end

                if blockList[remoteID] then--coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                    return
                end
            end
            warn("fs", tick() - t)
        end

        return oldFireServer(remote, ...)
    end), filters.RemoteEvent)
    oldHooks.FireServer = oldFireServer

    local oldFire
    oldFire = filteredOth(Instance.new("BindableEvent").Fire, newcclosure(function(remote: BindableEvent, ...: any)

        if not spyPaused then
            local t = tick()
            set_thread_identity(3)
            local argSize: number = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: BindableEvent = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not coroutine_wrap(invoke)(cmdChannel, "checkIgnored", remoteID, false) then
                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, true, -1)

                    if success then
                        local th: thread = oth_get_original_thread()
                        local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                        task_spawn(fire, dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, nil, typeof(scr) == "Instance" and cloneref(scr), createCallStack(th, 0))
                        task_spawn(fire, argChannel, unpack(data, 1, argSize))
                    end

                    desanitizeData(desanitizePaths)
                end

                if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                    return
                end
            end
            warn("f", tick() - t)
        end

        return oldFire(remote, ...)
    end), filters.BindableEvent)
    oldHooks.Fire = oldFire

    local oldInvokeServer
    oldInvokeServer = filteredOth(Instance.new("RemoteFunction").InvokeServer, newcclosure(function(remote: RemoteFunction, ...: any)

        if not spyPaused and not checkparallel() then
            local t = tick()
            set_thread_identity(3)
            local argSize: number = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: RemoteFunction = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not coroutine_wrap(invoke)(cmdChannel, "checkIgnored", remoteID, false) then

                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, true, -1)

                    if success then
                        callCount += 1
                        local returnKey: string = channelKey.."|"..callCount

                        local th: thread = oth_get_original_thread()
                        local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                        task_spawn(fire, dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr), createCallStack(th, 0))
                        task_spawn(fire, argChannel, unpack(data, 1, argSize))
                        desanitizeData(desanitizePaths)

                        if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                            return
                        else
                            local returnData, returnDataSize = processReturnValue(oldInvokeServer(remote, ...))
                            local desanitizeReturnPaths = partiallySanitizeData(returnData)

                            task_spawn(fire, dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                            task_spawn(fire, argChannel, unpack(returnData, 1, returnDataSize))
                            desanitizeData(desanitizeReturnPaths)

                            return unpack(returnData, 1, returnDataSize)
                        end
                    else
                        desanitizeData(desanitizePaths)
                    end
                else
                    if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                        return
                    end
                end
            end
            warn("is", tick() - t)
        end

        return oldInvokeServer(remote, ...)
    end), filters.RemoteFunction)
    oldHooks.InvokeServer = oldInvokeServer

    local oldInvoke
    oldInvoke = filteredOth(Instance.new("BindableFunction").Invoke, newcclosure(function(remote: BindableFunction, ...: any)

        if not spyPaused then
            local t = tick()
            set_thread_identity(3)
            local argSize: number = select("#", ...)
            if argSize < 7996 then
                local cloneRemote: BindableEvent = cloneref(remote)
                local remoteID: string = get_debug_id(cloneRemote)

                if not coroutine_wrap(invoke)(cmdChannel, "checkIgnored", remoteID, false) then

                    local data = {...}
                    local success: boolean, desanitizePaths = sanitizeData(data, true, -1)

                    if success then
                        callCount += 1
                        local returnKey: string = channelKey.."|"..callCount

                        local th: thread = oth_get_original_thread()
                        local scr: Instance = issynapsethread(th) and "Synapse" or getcallingscript()

                        task_spawn(fire, dataChannel, "sendMetadata", "onRemoteCall", cloneRemote, remoteID, returnKey, typeof(scr) == "Instance" and cloneref(scr), createCallStack(th, 0))
                        task_spawn(fire, argChannel, unpack(data, 1, argSize))
                        desanitizeData(desanitizePaths)

                        if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                            return
                        else
                            local returnData, returnDataSize = processReturnValue(coroutine_wrap(invoke)(remote, ...))
                            local desanitizeReturnPaths = partiallySanitizeData(returnData)

                            task_spawn(fire, dataChannel, "sendMetadata", "onReturnValueUpdated", returnKey)
                            task_spawn(fire, argChannel, unpack(returnData, 1, returnDataSize))
                            desanitizeData(desanitizeReturnPaths)

                            return unpack(returnData, 1, returnDataSize)
                        end
                    else
                        desanitizeData(desanitizePaths)
                    end
                else
                    if coroutine_wrap(invoke)(cmdChannel, "checkBlocked", remoteID) then
                        return
                    end
                end
            end
            warn("i", tick() - t)
        end

        return oldInvoke(remote, ...)
    end), filters.BindableFunction)
    oldHooks.Invoke = oldInvoke
end