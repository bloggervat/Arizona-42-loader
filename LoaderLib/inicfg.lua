local inicfg = {}
local configDir = getWorkingDirectory() .. "/config"

if not doesDirectoryExist(configDir) then
    createDirectory(configDir)
end

local function resolvePath(filename)
    filename = tostring(filename or "default.ini")
    filename = filename:gsub("\\", "/")
    if filename:sub(1, 1) == "/" then
        return filename
    end
    if not filename:lower():match("%.ini$") then
        filename = filename .. ".ini"
    end
    return configDir .. "/" .. filename
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for key, item in pairs(value) do
        result[key] = deepCopy(item)
    end
    return result
end

local function parseValue(value)
    local lowered = value:lower()
    if lowered == "true" then return true end
    if lowered == "false" then return false end
    return tonumber(value) or value
end

function inicfg.load(defaults, filename)
    local data = deepCopy(defaults or {})
    local file, err = io.open(resolvePath(filename), "r")
    if not file then
        if err and not err:match("No such file") then
            return data, err
        end
        return data
    end

    local section
    for line in file:lines() do
        line = line:gsub("\r$", "")
        local name = line:match("^%s*%[([^%]]+)%]%s*$")
        if name then
            section = name
            if type(data[section]) ~= "table" then
                data[section] = {}
            end
        else
            local key, value = line:match("^%s*([^=;#]+)%s*=%s*(.-)%s*$")
            if key and value then
                local target = section and data[section] or data
                target[key:gsub("%s+$", "")] = parseValue(value)
            end
        end
    end
    file:close()
    return data
end

function inicfg.save(data, filename)
    assert(type(data) == "table", "inicfg.save expects a table")
    local file, err = io.open(resolvePath(filename), "w")
    if not file then return false, err end

    for key, value in pairs(data) do
        if type(value) == "table" then
            file:write("[", tostring(key), "]\n")
            for subkey, subvalue in pairs(value) do
                file:write(tostring(subkey), "=", tostring(subvalue), "\n")
            end
            file:write("\n")
        else
            file:write(tostring(key), "=", tostring(value), "\n")
        end
    end

    local ok, closeErr = file:close()
    if ok == nil then return false, closeErr end
    return true
end

return inicfg
