local native = assert(require("imgui"), "native ImGui API is unavailable")
local mimgui = setmetatable({}, { __index = native })
local subscriptions = {}
local initializeCallbacks = {}
local initialized = false

local function cell(value)
    return setmetatable({ v = value }, {
        __index = function(self, key)
            if key == 0 then return rawget(self, "v") end
        end,
        __newindex = function(self, key, item)
            if key == 0 then
                rawset(self, "v", item)
            else
                rawset(self, key, item)
            end
        end
    })
end

mimgui.new = {
    bool = function(value) return cell(not not value) end,
    int = function(value) return cell(math.floor(tonumber(value) or 0)) end,
    float = function(value) return cell(tonumber(value) or 0.0) end
}

function mimgui.OnInitialize(callback)
    assert(type(callback) == "function", "OnInitialize expects a function")
    local subscription = { callback = callback, active = not initialized }
    if initialized then
        callback()
    else
        initializeCallbacks[#initializeCallbacks + 1] = subscription
    end
    function subscription:Unsubscribe()
        self.active = false
    end
    return subscription
end

local function runInitializers()
    if initialized then return end
    initialized = true
    local pending = initializeCallbacks
    initializeCallbacks = {}
    for _, subscription in ipairs(pending) do
        if subscription.active then subscription.callback() end
    end
end

local function installDispatcher()
    local anyActive = false
    for _, subscription in ipairs(subscriptions) do
        if subscription.active then
            anyActive = true
            break
        end
    end
    native.Process = anyActive
    if not anyActive then return end

    native.OnFrame(function()
        runInitializers()
        local frameSubscriptions = {}
        for _, subscription in ipairs(subscriptions) do
            if subscription.active then
                frameSubscriptions[#frameSubscriptions + 1] = subscription
            end
        end
        for _, subscription in ipairs(frameSubscriptions) do
            local visible
            if type(subscription.condition) == "function" then
                visible = not not subscription.condition()
            else
                visible = subscription.condition
            end
            if visible then
                if subscription.before then subscription.before() end
                subscription.draw()
            end
        end
    end)
end

function mimgui.OnFrame(condition, beforeFrame, drawFrame)
    if type(condition) == "function" and beforeFrame == nil then
        drawFrame = condition
        condition = true
    elseif type(condition) == "function" and type(beforeFrame) == "function"
        and drawFrame == nil then
        drawFrame = beforeFrame
        beforeFrame = nil
    end

    assert(type(condition) == "function" or type(condition) == "boolean",
        "OnFrame condition must be a boolean or function")
    assert(type(drawFrame) == "function", "OnFrame expects a draw callback")
    if beforeFrame ~= nil then
        assert(type(beforeFrame) == "function", "before-frame callback must be a function")
    end

    local subscription = {
        condition = condition,
        before = beforeFrame,
        draw = drawFrame,
        active = true
    }
    function subscription:Unsubscribe()
        if not self.active then return end
        self.active = false
        installDispatcher()
    end
    function subscription:IsActive()
        return self.active
    end
    subscriptions[#subscriptions + 1] = subscription
    installDispatcher()
    return subscription
end

mimgui._VERSION = "42Loader mimgui compatibility"
return mimgui
