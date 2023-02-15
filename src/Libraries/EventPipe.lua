--- EventPipe libray
-- Light weight "socket" implementation that provides two way communication between modules
-- Written by topit 

local EventPipe = {} 
do 
    EventPipe._class = 'EventPipe'
    EventPipe.__index = EventPipe 

    -- Registers a new callback to the event `eventName`
    function EventPipe:ListenToEvent(eventName: string, callback: any)
        if ( not table.find(self._validEvents, eventName) ) then
            return false, 'Not a valid event!'
        end
        
        self._events[eventName] = callback 
    end

    -- Fires the callback connected to `eventName` with the passed args, and returns the call result 
    function EventPipe:Fire(eventName: string, ...)
        local func = self._events[eventName]
        
        if ( func ) then
            return func(...) -- task.spawn(func, ...)
        end
        
        return false, 'No matching event callback'
    end
    
    -- Destroys this EventPipe instance 
    function EventPipe:Destroy() 
        self._events = nil 
        self._validEvents = nil 
        
        setmetatable(self, nil)
    end
    
    -- Creates a new EventPipe instance with an array of valid events. If no array gets passed on creation, any event can be listened to.
    function EventPipe.new(validEvents)
        assert(validEvents, "Events Table Must Be Passed")

        local self = setmetatable({}, EventPipe)

        self._events = {} 
        self._validEvents = validEvents 

        return self
    end
end