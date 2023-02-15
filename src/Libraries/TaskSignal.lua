local TaskSignal = {}

TaskSignal._class = "TaskSignal"
TaskSignal.__index = TaskSignal

function TaskSignal:ListenToEvent(eventName: string, callback: any)
    if ( not table.find(self._validEvents, eventName) ) then
        return false, "Not a valid event!"
    end

    self._events[eventName] = callback
end

function TaskSignal:Fire(eventName: string, ...)
    local func = self._events[eventName]

    if ( func ) then
        return func(...)
    end

    return false, "No matching event callback"
end

function TaskSignal.new(validEvents)
    local self = setmetatable({}, TaskSignal)

    self._events = {}
    self._validEvents = validEvents

    return self
end

return TaskSignal