script_name("test_all_api")
script_version("1.0")

local hooksEnabled = false
local renderEnabled = false
local imguiWindow = imgui and imgui.ImBool and imgui.ImBool(false) or false
local sliderVal = imgui and imgui.ImFloat and imgui.ImFloat(50.0) or 50.0
local iniFile = "test_all_api.ini"

local function msg(text, color)
    sampAddChatMessage("[42-Test] " .. tostring(text), color or 0xFF9B59B6)
end

function main()
    sampRegisterChatCommand("t_help", cmdHelp)
    sampRegisterChatCommand("t_chat", cmdChat)
    sampRegisterChatCommand("t_send", cmdSend)
    sampRegisterChatCommand("t_dialog", cmdDialog)
    sampRegisterChatCommand("t_hooks", cmdHooks)
    sampRegisterChatCommand("t_thread", cmdThread)
    sampRegisterChatCommand("t_vibe", cmdVibe)
    sampRegisterChatCommand("t_clip", cmdClip)
    sampRegisterChatCommand("t_notify", cmdNotify)
    sampRegisterChatCommand("t_push", cmdPush)
    sampRegisterChatCommand("t_ram", cmdRam)
    sampRegisterChatCommand("t_imgui", cmdImgui)
    sampRegisterChatCommand("t_render", cmdRender)
    sampRegisterChatCommand("t_json", cmdJson)
    sampRegisterChatCommand("t_ini", cmdIni)
    sampRegisterChatCommand("t_http", cmdHttp)
    sampRegisterChatCommand("t_override", cmdOverride, true)

    msg("Скрипт загружен. Список команд: /t_help", 0xFF2ECC71)

    while true do
        wait(0)
        if renderEnabled then
            renderDrawBox(40, 260, 260, 110, 0xAA14141E)
            renderDrawLine(40, 260, 300, 260, 2, 0xFF9B59B6)
            renderDrawCircle(275, 315, 18, 24, 0xFF9B59B6)
            renderDrawText("Arizona-42 2D Render OK", 52, 275, 0xFFFFFFFF)
            renderDrawText("RAM: " .. tostring(az.getLoaderRAM()), 52, 305, 0xFFBDC3C7)
        end
    end
end

function cmdHelp()
    msg("Команды: /t_chat, /t_send, /t_dialog, /t_hooks, /t_thread, /t_override")
    msg("iOS/UI: /t_vibe, /t_clip, /t_notify, /t_push, /t_ram, /t_imgui, /t_render")
    msg("Данные/Сеть: /t_json, /t_ini, /t_http")
end

function cmdChat()
    sampAddChatMessage("[42-Test] Стандартный цвет", 0xFFFFFFFF)
    sampAddChatMessage("[42-Test] Фиолетовый акцент", 0xFF9B59B6)
    sampAddChatMessage("[42-Test] Зелёный статус", 0xFF2ECC71)
end

function cmdSend(arg)
    local text = (arg and #arg > 0) and arg or "Тест sampSendChat из LuaLoader"
    sampSendChat(text)
    msg("Отправлено в чат: " .. text)
end

function cmdDialog(arg)
    local id, btn, list, input = arg:match("^(%d+)%s*(%d*)%s*(%d*)%s*(.*)$")
    if not id then
        msg("Использование: /t_dialog [dialogId] [button] [listitem] [input]")
        return
    end
    btn = tonumber(btn) or 1
    list = tonumber(list) or 0
    input = input or ""
    sampSendDialogResponse(tonumber(id), btn, list, input)
    msg(string.format("DialogResponse -> id=%d, btn=%d, list=%d, text='%s'", id, btn, list, input))
end

function cmdHooks()
    hooksEnabled = not hooksEnabled
    msg("Логирование onServerMessage и onShowDialog: " .. (hooksEnabled and "ВКЛ" or "ВЫКЛ"))
end

function cmdThread()
    lua_thread.create(function()
        msg("Поток запущен (шаг 1/3)...")
        wait(1000)
        msg("Поток работает (шаг 2/3)...")
        wait(1000)
        msg("Поток завершён (шаг 3/3).", 0xFF2ECC71)
    end)
end

function cmdVibe(arg)
    local style = tonumber(arg)
    if style then
        az.vibrate(style)
        msg("Вибрация style=" .. style)
    else
        lua_thread.create(function()
            for s = 0, 2 do
                az.vibrate(s)
                msg("Вибрация style=" .. s)
                wait(450)
            end
        end)
    end
end

function cmdClip(arg)
    local sample = (arg and #arg > 0) and arg or ("Arizona42_" .. os.time())
    az.setClipboard(sample)
    local readBack = az.getClipboard()
    msg("Записано: " .. sample .. " | Прочитано: " .. tostring(readBack))
end

function cmdNotify()
    az.notify("Arizona-42", "Проверка az.notify прошла успешно")
    msg("Вызван az.notify")
end

function cmdPush(arg)
    local delay = tonumber(arg) or 3
    sendLocalNotification("Arizona-42 Loader", "Тестовое push-уведомление с задержкой " .. delay .. "с", delay)
    msg("Push запланирован через " .. delay .. " сек.")
end

function cmdRam()
    local ram = az.getLoaderRAM()
    msg("Память лоадера (az.getLoaderRAM): " .. tostring(ram))
end

function cmdImgui()
    if type(imguiWindow) == "table" then
        imguiWindow.v = not imguiWindow.v
        imgui.Process = imguiWindow.v
    else
        imguiWindow = not imguiWindow
        imgui.Process = imguiWindow
    end
    local state = (type(imguiWindow) == "table") and imguiWindow.v or imguiWindow
    msg("Окно ImGui: " .. (state and "ОТКРЫТО" or "ЗАКРЫТО"))
end

function cmdRender()
    renderEnabled = not renderEnabled
    msg("2D-рендер оверлея: " .. (renderEnabled and "ВКЛ" or "ВЫКЛ"))
end

function cmdJson()
    local lib = json or cjson
    local raw = lib.encode({ loader = "Arizona-42", active = true, version = 1 })
    local parsed = lib.decode(raw)
    msg("JSON encode: " .. raw)
    msg("JSON decode -> loader=" .. tostring(parsed.loader) .. ", active=" .. tostring(parsed.active))
end

function cmdIni()
    local cfg = inicfg.load({
        main = { runs = 0, last_test = "none" }
    }, iniFile)
    cfg.main.runs = (tonumber(cfg.main.runs) or 0) + 1
    cfg.main.last_test = os.date("%H:%M:%S")
    local saved = inicfg.save(cfg, iniFile)
    msg(string.format("INI save=%s | runs=%d | last=%s", tostring(saved), cfg.main.runs, cfg.main.last_test))
end

function cmdHttp(arg)
    local url = (arg and #arg > 0) and arg or "https://httpbin.org/get"
    msg("HTTP GET -> " .. url)
    asyncHttpRequest("GET", url, nil,
        function(response)
            local code = response and response.status_code or "ok"
            local body = response and response.text or tostring(response)
            msg("HTTP ответ [" .. tostring(code) .. "]: " .. body:sub(1, 90))
        end,
        function(err)
            msg("HTTP ошибка: " .. tostring(err), 0xFFE74C3C)
        end
    )
end

function cmdOverride(arg)
    msg("Перехваченная команда /t_override с аргументом: " .. tostring(arg), 0xFFF1C40F)
end

function onServerMessage(color, text)
    if hooksEnabled and not text:find("%[42%-Test%]") then
        msg(string.format("[Hook Msg 0x%X] %s", color or 0, text:sub(1, 80)), 0xFF95A5A6)
    end
end

function onShowDialog(dialogId, style, title, button1, button2, text)
    if hooksEnabled then
        msg(string.format("[Hook Dialog] id=%d style=%d title='%s'", dialogId, style, tostring(title)), 0xFF95A5A6)
    end
end

if imgui then
    function imgui.OnDrawFrame()
        local isOpen = (type(imguiWindow) == "table") and imguiWindow.v or imguiWindow
        if not isOpen then return end

        imgui.Begin("Arizona-42 API Test", type(imguiWindow) == "table" and imguiWindow or nil)
        imgui.Text("RAM: " .. tostring(az.getLoaderRAM()))

        if type(sliderVal) == "table" and imgui.SliderFloat then
            imgui.SliderFloat("Test Slider", sliderVal, 0.0, 100.0)
        elseif imgui.Slider then
            sliderVal = imgui.Slider("Test Slider", sliderVal, 0.0, 100.0)
        end

        if imgui.Button("Vibrate") then az.vibrate(1) end
        imgui.SameLine()
        if imgui.Button("Notify") then az.notify("ImGui", "Кнопка нажата") end
        imgui.SameLine()
        if imgui.Button("Toggle 2D Render") then renderEnabled = not renderEnabled end

        if imgui.Button("Test JSON + INI") then
            cmdJson()
            cmdIni()
        end
        imgui.End()
    end
end