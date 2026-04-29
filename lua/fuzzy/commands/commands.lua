local M = {}

local GAP = "  "
local LABEL_WIDTH = 3
local NAME_WIDTH_FRACTION = 0.35
local SHORTNAME_WIDTH_FRACTION = 0.1

local HL = {
    label  = "FuzzyPickerPaletteLabel",
    name   = "FuzzyPickerPaletteName",
    alias  = "FuzzyPickerPaletteAlias",
    detail = "FuzzyPickerPaletteDetail",
}

local KIND_LABEL = {
    command = "CMD",
    option = "OPT",
}

local function is_readable_command(name)
    return type(name) == "string" and name:match("^[A-Za-z]") ~= nil
end

local function normalize_text(text)
    if type(text) ~= "string" then return nil end
    text = vim.trim(text:gsub("%s+", " "))
    if text == "" then return nil end
    return text
end

local function value_text(value)
    if type(value) == "table" then
        return normalize_text(vim.inspect(value)) or "{}"
    end
    return normalize_text(tostring(value)) or ""
end

local function truncate(text, max_width)
    text = tostring(text or "")
    if max_width <= 0 then return "" end
    if #text <= max_width then return text end
    if max_width <= 3 then return text:sub(1, max_width) end
    return text:sub(1, max_width - 3) .. "..."
end

local function pad(text, width)
    text = tostring(text or "")
    if #text >= width then return text end
    return text .. (" "):rep(width - #text)
end

local function join_filter_text(parts)
    return table.concat(vim.tbl_filter(function(part)
        return type(part) == "string" and part ~= ""
    end, parts), " ")
end

---@class FuzzyPaletteEntry
---@field kind "command"|"option"
---@field name string
---@field shortname? string
---@field detail? string
---@field cmdline string
---@field filter_text string

local function sort_entries(entries)
    table.sort(entries, function(a, b)
        local al = a.name:lower()
        local bl = b.name:lower()
        if al ~= bl then return al < bl end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.name < b.name
    end)
end

local function option_cmdline(name, value, info)
    if info.type == "boolean" then
        return "set " .. (value and ("no" .. name) or name)
    end

    return "set " .. name .. "=" .. vim.fn.escape(tostring(value), "\\ ")
end

---@return FuzzyPaletteEntry[]
function M.collect_commands()
    local ok_names, names = pcall(vim.fn.getcompletion, "", "command")
    if not ok_names or type(names) ~= "table" then names = {} end

    local ok_user, user_commands = pcall(vim.api.nvim_get_commands, { builtin = false })
    if not ok_user or type(user_commands) ~= "table" then user_commands = {} end

    local by_name = {}
    local entries = {}

    local function add(name)
        if by_name[name] or not is_readable_command(name) then return end

        local meta = user_commands[name]
        local detail = normalize_text(meta and meta.definition)
        local entry = {
            kind = "command",
            name = name,
            detail = detail,
            cmdline = name,
        }
        entry.filter_text = join_filter_text({ entry.name, entry.detail, entry.cmdline })

        by_name[name] = true
        entries[#entries + 1] = entry
    end

    for _, name in ipairs(names) do
        add(name)
    end

    for name in pairs(user_commands) do
        add(name)
    end

    sort_entries(entries)
    return entries
end

---@return FuzzyPaletteEntry[]
function M.collect_options()
    local ok_options, options = pcall(vim.api.nvim_get_all_options_info)
    if not ok_options or type(options) ~= "table" then return {} end

    local entries = {}
    for _, info in pairs(options) do
        local ok_value, value = pcall(vim.api.nvim_get_option_value, info.name, {})
        if ok_value then
            local shortname = normalize_text(info.shortname)
            local detail = value_text(value)
            local entry = {
                kind = "option",
                name = info.name,
                shortname = shortname,
                detail = detail,
                cmdline = option_cmdline(info.name, value, info),
            }
            entry.filter_text = join_filter_text({
                entry.name,
                entry.shortname,
                entry.detail,
                entry.cmdline,
            })
            entries[#entries + 1] = entry
        end
    end

    sort_entries(entries)
    return entries
end

---@return FuzzyPaletteEntry[]
function M.collect()
    local entries = M.collect_commands()
    vim.list_extend(entries, M.collect_options())
    sort_entries(entries)
    return entries
end

---@param entry FuzzyPaletteEntry
---@return string
function M.filter_text(entry)
    return entry.filter_text or entry.name or ""
end

---@param entries FuzzyPaletteEntry[]
---@param width integer
---@return { name_width: integer, shortname_width: integer, has_shortname: boolean }
function M.make_render_context(entries, width)
    local max_name = 0
    local max_shortname = 0

    for _, entry in ipairs(entries) do
        max_name = math.max(max_name, #(entry.name or ""))
        max_shortname = math.max(max_shortname, #(entry.shortname or ""))
    end

    local name_width = math.max(8, math.floor(width * NAME_WIDTH_FRACTION))
    local shortname_width = 0
    if max_shortname > 0 then
        shortname_width = math.max(2, math.floor(width * SHORTNAME_WIDTH_FRACTION))
    end

    return {
        name_width = math.min(max_name, name_width),
        shortname_width = math.min(max_shortname, shortname_width),
        has_shortname = max_shortname > 0,
    }
end

---@param entry FuzzyPaletteEntry
---@param ctx? { name_width: integer, shortname_width: integer, has_shortname: boolean }
---@param width? integer
---@return string
function M.format_entry(entry, ctx, width)
    ctx = ctx or {
        name_width = #(entry.name or ""),
        shortname_width = #(entry.shortname or ""),
        has_shortname = entry.shortname ~= nil and entry.shortname ~= "",
    }

    local label = KIND_LABEL[entry.kind] or "CMD"
    local name = truncate(entry.name or "", math.max(1, ctx.name_width))
    local row = label .. GAP .. name

    if entry.detail then
        row = label .. GAP .. pad(name, math.max(1, ctx.name_width))
        if ctx.has_shortname then
            row = row .. GAP .. pad(truncate(entry.shortname or "", math.max(1, ctx.shortname_width)), ctx.shortname_width)
        end
        if width then
            local available = width - #row - #GAP
            if available > 0 then
                row = row .. GAP .. truncate(entry.detail, available)
            end
        else
            row = row .. GAP .. (entry.detail or "")
        end
        return row
    end

    if ctx.has_shortname and entry.shortname then
        row = label .. GAP .. pad(name, math.max(1, ctx.name_width))
            .. GAP .. pad(truncate(entry.shortname, math.max(1, ctx.shortname_width)), ctx.shortname_width)
    end

    if width and #row > width then
        return truncate(row, width)
    end
    return row
end

---@param entry FuzzyPaletteEntry
---@param ctx { name_width: integer, shortname_width: integer, has_shortname: boolean }
---@param text string
---@return { start_col: integer, end_col: integer, group: string }[]
function M.highlight_ranges(entry, ctx, text)
    local ranges = {}
    local label = KIND_LABEL[entry.kind] or "CMD"
    local col = 1

    ranges[#ranges + 1] = { start_col = col, end_col = #label, group = HL.label }
    col = LABEL_WIDTH + #GAP + 1

    local name_width = math.max(1, ctx.name_width)
    local name_text = truncate(entry.name or "", name_width)
    ranges[#ranges + 1] = {
        start_col = col,
        end_col = math.min(#text, col + #name_text - 1),
        group = HL.name,
    }
    col = col + name_width

    if entry.detail and ctx.has_shortname then
        col = col + #GAP
        local short_text = truncate(entry.shortname or "", math.max(1, ctx.shortname_width))
        if short_text ~= "" then
            ranges[#ranges + 1] = {
                start_col = col,
                end_col = math.min(#text, col + #short_text - 1),
                group = HL.alias,
            }
        end
        col = col + ctx.shortname_width
    elseif entry.shortname and ctx.has_shortname then
        col = col + #GAP
        local short_text = truncate(entry.shortname, math.max(1, ctx.shortname_width))
        ranges[#ranges + 1] = {
            start_col = col,
            end_col = math.min(#text, col + #short_text - 1),
            group = HL.alias,
        }
        col = col + ctx.shortname_width
    end

    if entry.detail then
        local detail_start = col + #GAP
        if detail_start <= #text then
            ranges[#ranges + 1] = {
                start_col = detail_start,
                end_col = #text,
                group = HL.detail,
            }
        end
    end

    return ranges
end

---@param cmdline string
function M.prefill_cmdline(cmdline)
    if not cmdline or cmdline == "" then return end
    vim.schedule(function()
        local keys = vim.api.nvim_replace_termcodes(":" .. cmdline .. " ", true, false, true)
        vim.api.nvim_feedkeys(keys, "n", false)
    end)
end

return M
