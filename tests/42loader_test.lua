-- Arizona 42Loader diagnostic script.
-- Copy to Documents/lua_loader/scripts, then run /42test from Arizona chat
-- or the Loader Commands tab to verify local command dispatch.
-- HTTP is asynchronous and requires network access on the device.

local testState = {
    started = false,
    command = false,
    coroutine = false,
    http = "pending",
    buttonClicks = 0,
}
local frameSubscription

local function report(label, ok, detail)
    local status = ok and "PASS" or "FAIL"
    local suffix = detail and (": " .. tostring(detail)) or ""
    print("[42loader_test] " .. status .. " " .. label .. suffix)
    if az and az.notify then
        az.notify("42Loader test", status .. " " .. label .. suffix, 4)
    end
end

sampRegisterChatCommand("42test", function(args)
    testState.command = true
    report("local command callback", true, args ~= "" and args or "no arguments")
end)

mimgui = require("mimgui")
local detailsVisible = mimgui.new.bool(true)
local sliderValue = mimgui.new.int(42)
frameSubscription = mimgui.OnFrame(function()
    return true
end, function()
    if mimgui.Begin("42Loader diagnostic test") then
        mimgui.Text("Runtime checks are written to the Loader console.")
        mimgui.Text("HTTP: " .. testState.http)
        mimgui.Checkbox("Show extra diagnostics", detailsVisible)
        if detailsVisible.v then
            mimgui.Text("Checkbox touch handling: active")
            mimgui.SliderInt("Touch slider", sliderValue, 0, 100)
        end
        if mimgui.Button("Test notification and vibration") then
            testState.buttonClicks = testState.buttonClicks + 1
            az.notify("42Loader test", "ImGui button callback ran", 3)
            az.vibrate(0)
            report("ImGui Button callback", true)
        end
        if mimgui.Button("Run /42test sample") then
            sampProcessChatInput("/42test from ImGui")
        end
        if mimgui.Button("Toggle menu with local /loader") then
            local ok, err = pcall(sampProcessChatInput, "/loader")
            report("local /loader command", ok, err)
        end
    end
    mimgui.End()
end)

function main()
    testState.started = true
    report("script chunk and main", true)
    frameSubscription = mimgui.OnFrame(function()
        return false
    end, function()
    end)

    local encoded = json.encode({ answer = 42, enabled = true })
    local decoded = json.decode(encoded)
    report("JSON encode/decode", decoded.answer == 42 and decoded.enabled == true)
    local emptyArray = json.decode("[]")
    report("JSON empty array round-trip", json.encode(emptyArray) == "[]")
    local cjson = require("cjson")
    report("cjson compatibility alias", cjson.decode(cjson.encode({ value = 42 })).value == 42)

    local encodingModule = require("encoding")
    local roundTrip = encodingModule.UTF8:encode(encodingModule.UTF8:decode("42Loader"))
    report("encoding module round-trip", roundTrip == "42Loader")

    local monet = require("monetloader")
    report("MonetLoader constants module",
        monet.touch_events.POP == 1 and monet.touch_events.PUSH == 2 and monet.touch_events.MOVE == 3)

    local cfg = { diagnostic = { value = 42, enabled = true } }
    local saved = inicfg.save(cfg, "42loader_test")
    local loaded = inicfg.load({}, "42loader_test")
    report("INI save/load", saved and loaded.diagnostic ~= nil
        and tonumber(loaded.diagnostic.value) == 42
        and loaded.diagnostic.enabled == true)

    local worker = lua_thread.create(function()
        wait(25)
        testState.coroutine = true
        report("lua_thread.create and wait", true)
        while true do wait(1000) end
    end)
    report("coroutine handle", worker ~= nil and worker:isActive())

    asyncHttpRequest("GET", "https://example.com", nil,
        function(response)
            testState.http = "completed (" .. tostring(response.status_code) .. ")"
            report("HTTP GET callback", response.status_code >= 200 and response.status_code < 400)
        end,
        function(err)
            testState.http = "error"
            report("HTTP GET callback", false, err)
        end,
        nil, 20)

    wait(100)
    report("coroutine resumed after wait", testState.coroutine)
    report("local command registration", sampIsChatCommandDefined("42test"))
    report("external mimgui module loaded", type(mimgui) == "table")
    report("mimgui frame subscription active",
        frameSubscription ~= nil and frameSubscription:IsActive())
    report("ImGui render callback enabled", imgui.Process == true)
    report("notification API", type(az.notify) == "function")
    report("vibration API", type(az.vibrate) == "function")
    local stoppedThreads = terminateAllThreads()
    report("stop active Lua threads", stoppedThreads >= 2, stoppedThreads)
    print("[42loader_test] Run /42test in Arizona chat or the Loader Commands tab; tap the ImGui buttons to check input.")
    print("[42loader_test] The local command callback PASS appears after /42test is consumed by Loader.")
    print("[42loader_test] NOT SUPPORTED: stopping/unloading this script from Lua; disable it in the Loader Scripts tab.")
    print("[42loader_test] NOT SUPPORTED: mimgui before-frame callback cannot run before NewFrame because the Metal renderer owns frame creation.")
    print("[42loader_test] NOT SUPPORTED: local text output in Arizona chat; no verified display API is bundled.")
end
