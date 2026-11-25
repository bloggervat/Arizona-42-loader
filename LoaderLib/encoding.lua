local toUtf8 = assert(__az_cp1251_to_utf8, "CP1251 to UTF-8 converter is unavailable")
local toCp1251 = assert(__az_utf8_to_cp1251, "UTF-8 to CP1251 converter is unavailable")

local function makeEncoding(convert, reverse)
    return setmetatable({}, {
        __call = function(_, value)
            return convert(tostring(value or ""))
        end,
        __index = {
            decode = function(_, value)
                return convert(tostring(value or ""))
            end,
            encode = function(_, value)
                return reverse(tostring(value or ""))
            end
        }
    })
end

return {
    default = "CP1251",
    UTF8 = makeEncoding(toUtf8, toCp1251),
    CP1251 = makeEncoding(toCp1251, toUtf8)
}
