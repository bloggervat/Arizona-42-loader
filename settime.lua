script_name("SetTime & API Test")
script_author("bloggervat")
script_version("1.1")

local sampev = require("samp.events")
local inicfg = require("inicfg")
local encoding = require("encoding")
encoding.default = "CP1251"
local u8 = encoding.UTF8

local cfg = inicfg.load({
    world = { hour = 12, weather = 1 }
}, "settime.ini")

function sampev.onServerMessage(color, text)
    if text:find("Неизвестная команда") then
        print("[Hook] Поймано сообщение от сервера: " .. text)
    end
end

function cmdSetTime(arg)
    local hour = tonumber(arg)
    if not hour or hour < 0 or hour > 23 then
        sampAddChatMessage("[SetTime] Использование: /settime [0-23]", 0xFF9B59B6)
        return
    end
    setTimeOfDay(hour, 0)
    cfg.world.hour = hour
    inicfg.save(cfg, "settime.ini")
    az.vibrate(1)
    sampAddChatMessage(string.format("[SetTime] Время изменено на %02d:00", hour), 0xFF9B59B6)
end

function cmdSetWeather(arg)
    local id = tonumber(arg)
    if not id then
        sampAddChatMessage("[SetWeather] Использование: /setweather [ID]", 0xFF9B59B6)
        return
    end
    forceWeatherNow(id)
    cfg.world.weather = id
    inicfg.save(cfg, "settime.ini")
    sampAddChatMessage("[SetWeather] Погода изменена на ID: " .. id, 0xFF9B59B6)
end

function main()
    while not isSampAvailable() do
        wait(100)
    end

    setTimeOfDay(cfg.world.hour, 0)
    forceWeatherNow(cfg.world.weather)

    sampRegisterChatCommand("settime", cmdSetTime)
    sampRegisterChatCommand("setweather", cmdSetWeather)

    sampAddChatMessage("[42Loader] Скрипт загружен! Пиши /SETTIME [0-23] в чат игры.", 0xFF9B59B6)

    while true do
        wait(0)
    end
end