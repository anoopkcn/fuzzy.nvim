local M = {}

local function pad(text, width)
    text = tostring(text or "")
    if #text >= width then return text end
    return text .. (" "):rep(width - #text)
end

local function truncate(text, max_width)
    text = tostring(text or "")
    if max_width <= 0 then return "" end
    if #text <= max_width then return text end
    if max_width <= 3 then return text:sub(1, max_width) end
    return text:sub(1, max_width - 3) .. "..."
end

-- Standard registers worth showing. Skipped: write-only special (`=`, `_`)
-- and registers that only make sense in their evaluated form. Read-only
-- specials (`/`, `:`, `.`, `%`, `#`) are included since they show useful
-- info. Numbered (0-9) and named (a-z) registers are filtered to non-empty
-- entries below.
local REG_NAMES = (function()
    local names = { '"', "*", "+", "-", "/", ":", ".", "%", "#" }
    for i = 0, 9 do names[#names + 1] = tostring(i) end
    for c = string.byte("a"), string.byte("z") do
        names[#names + 1] = string.char(c)
    end
    return names
end)()

local function regtype_label(t)
    if not t or t == "" then return "?" end
    local first = t:sub(1, 1)
    if first == "v" then return "c" end       -- charwise
    if first == "V" then return "l" end       -- linewise
    if first == "\22" then return "b" end     -- blockwise (Ctrl-V)
    return first
end

local function preview_text(lines)
    if type(lines) ~= "table" or #lines == 0 then return "" end
    if #lines == 1 then return lines[1] or "" end
    return (lines[1] or "") .. " ↵"
end

---@class FuzzyRegEntry
---@field name string
---@field type string         -- raw regtype: "v"|"V"|"\22N"
---@field type_label string   -- "c"|"l"|"b"
---@field lines string[]
---@field preview string
---@field filter_text string

---@return FuzzyRegEntry[]
function M.collect()
    local entries = {}
    for _, name in ipairs(REG_NAMES) do
        local ok, info = pcall(vim.fn.getreginfo, name)
        if ok and type(info) == "table" then
            local contents = info.regcontents
            if type(contents) == "string" then contents = { contents } end
            local has_text = type(contents) == "table"
                and #contents > 0
                and not (#contents == 1 and contents[1] == "")
            if has_text then
                local preview = preview_text(contents)
                entries[#entries + 1] = {
                    name = name,
                    type = info.regtype or "v",
                    type_label = regtype_label(info.regtype),
                    lines = contents,
                    preview = preview,
                    filter_text = name .. " " .. preview,
                }
            end
        end
    end
    return entries
end

function M.filter_text(entry) return entry.filter_text or entry.name or "" end

function M.format_entry(entry, _, width)
    local name = pad(entry.name or "?", 2)
    local kind = pad(entry.type_label or "?", 2)
    local row = name .. " " .. kind .. " "
    local preview = entry.preview or ""
    if width then
        local available = width - #row
        if available > 0 then row = row .. truncate(preview, available) end
    else
        row = row .. preview
    end
    if width and #row > width then return truncate(row, width) end
    return row
end

return M
