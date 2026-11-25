local json = {}
local null = setmetatable({}, { __tostring = function() return "null" end })
local arrayMetatable = { __json_array = true }
json.null = null

function json.array(value)
    value = value or {}
    assert(type(value) == "table", "json.array expects a table")
    return setmetatable(value, arrayMetatable)
end

local function encodeValue(value, seen)
    local kind = type(value)
    if value == null or value == nil then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("non-finite numbers are not valid JSON", 2)
        end
        return tostring(value)
    end
    if kind == "string" then
        return '"' .. value:gsub("\\", "\\\\")
            :gsub('"', '\\"')
            :gsub("\b", "\\b")
            :gsub("\f", "\\f")
            :gsub("\n", "\\n")
            :gsub("\r", "\\r")
            :gsub("\t", "\\t")
            :gsub("%c", function(char)
                return string.format("\\u%04x", char:byte())
            end) .. '"'
    end
    if kind ~= "table" then
        error("unsupported value in JSON encode: " .. kind, 2)
    end

    if seen[value] then error("cycle in JSON value", 2) end
    seen[value] = true
    local metatable = getmetatable(value)
    local isArray = type(metatable) == "table" and metatable.__json_array == true
    local count, highest = 0, 0
    if isArray then
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                error("json.array values must use dense positive integer keys", 2)
            end
            count = count + 1
            highest = math.max(highest, key)
        end
        if count ~= highest then
            error("json.array values must use dense positive integer keys", 2)
        end
    else
        isArray = true
        for key in pairs(value) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
                isArray = false
                break
            end
            count = count + 1
            highest = math.max(highest, key)
        end
        isArray = isArray and count > 0 and count == highest
    end
    local parts = {}
    if isArray then
        for index = 1, highest do
            parts[#parts + 1] = encodeValue(value[index], seen)
        end
        seen[value] = nil
        return "[" .. table.concat(parts, ",") .. "]"
    end
    for key, item in pairs(value) do
        parts[#parts + 1] = encodeValue(tostring(key), seen) .. ":" ..
            encodeValue(item, seen)
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

function json.encode(value)
    return encodeValue(value, {})
end

function json.decode(source)
    if type(source) ~= "string" then
        error("JSON decode expects a string", 2)
    end

    local index, length = 1, #source
    local function fail(message)
        error("JSON decode error at byte " .. index .. ": " .. message, 0)
    end
    local function skipWhitespace()
        while index <= length and source:sub(index, index):match("%s") do
            index = index + 1
        end
    end
    local function parseString()
        if source:sub(index, index) ~= '"' then fail("expected string") end
        index = index + 1
        local pieces, start = {}, index
        while index <= length do
            local char = source:sub(index, index)
            if char == '"' then
                pieces[#pieces + 1] = source:sub(start, index - 1)
                index = index + 1
                return table.concat(pieces)
            elseif char == "\\" then
                pieces[#pieces + 1] = source:sub(start, index - 1)
                index = index + 1
                local escaped = source:sub(index, index)
                local simple = {
                    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
                    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t"
                }
                if simple[escaped] then
                    pieces[#pieces + 1] = simple[escaped]
                    index = index + 1
                elseif escaped == "u" then
                    local hex = source:sub(index + 1, index + 4)
                    local codepoint = tonumber(hex, 16)
                    if #hex ~= 4 or not codepoint then fail("invalid unicode escape") end
                    index = index + 5
                    if codepoint >= 0xD800 and codepoint <= 0xDBFF
                        and source:sub(index, index + 1) == "\\u" then
                        local lowHex = source:sub(index + 2, index + 5)
                        local low = tonumber(lowHex, 16)
                        if not low or low < 0xDC00 or low > 0xDFFF then
                            fail("invalid surrogate pair")
                        end
                        codepoint = 0x10000 + (codepoint - 0xD800) * 0x400 + low - 0xDC00
                        index = index + 6
                    elseif codepoint >= 0xD800 and codepoint <= 0xDFFF then
                        fail("unpaired surrogate")
                    end
                    pieces[#pieces + 1] = utf8.char(codepoint)
                else
                    fail("invalid string escape")
                end
                start = index
            elseif char:byte() < 32 then
                fail("control character in string")
            else
                index = index + 1
            end
        end
        fail("unterminated string")
    end

    local parseValue
    parseValue = function()
        skipWhitespace()
        local char = source:sub(index, index)
        if char == '"' then return parseString() end
        if char == "{" then
            index = index + 1
            skipWhitespace()
            local object = {}
            if source:sub(index, index) == "}" then
                index = index + 1
                return object
            end
            while true do
                skipWhitespace()
                local key = parseString()
                skipWhitespace()
                if source:sub(index, index) ~= ":" then fail("expected ':'") end
                index = index + 1
                object[key] = parseValue()
                skipWhitespace()
                local separator = source:sub(index, index)
                index = index + 1
                if separator == "}" then return object end
                if separator ~= "," then fail("expected ',' or '}'") end
            end
        end
        if char == "[" then
            index = index + 1
            skipWhitespace()
            local array = json.array()
            if source:sub(index, index) == "]" then
                index = index + 1
                return array
            end
            while true do
                array[#array + 1] = parseValue()
                skipWhitespace()
                local separator = source:sub(index, index)
                index = index + 1
                if separator == "]" then return array end
                if separator ~= "," then fail("expected ',' or ']'") end
            end
        end
        if source:sub(index, index + 3) == "true" then
            index = index + 4
            return true
        end
        if source:sub(index, index + 4) == "false" then
            index = index + 5
            return false
        end
        if source:sub(index, index + 3) == "null" then
            index = index + 4
            return null
        end

        local token = source:sub(index):match("^-?%d+%.?%d*[eE]?[%+%-]?%d*")
        local valid = token and (
            token:match("^-?%d+$") or
            token:match("^-?%d+%.%d+$") or
            token:match("^-?%d+[eE][%+%-]?%d+$") or
            token:match("^-?%d+%.%d+[eE][%+%-]?%d+$"))
        if valid and not token:match("^-?0%d") then
            local number = tonumber(token)
            if number and number ~= math.huge and number ~= -math.huge then
                index = index + #token
                return number
            end
        end
        fail("expected a JSON value")
    end

    local value = parseValue()
    skipWhitespace()
    if index <= length then fail("trailing data") end
    return value
end

return json
