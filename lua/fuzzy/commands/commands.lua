local M = {}

local DESCRIPTION_SEP = "  "

local function is_readable_command(name)
    return type(name) == "string" and name:match("^[A-Za-z]") ~= nil
end

local function normalize_description(description)
    if type(description) ~= "string" then return nil end
    description = vim.trim(description:gsub("%s+", " "))
    if description == "" then return nil end
    return description
end

local function format_entry(entry)
    if entry.description then
        return entry.name .. DESCRIPTION_SEP .. entry.description
    end
    return entry.name
end

---@class FuzzyCommandEntry
---@field name string
---@field description? string
---@field display string
---@field cmdline string

---@class FuzzyOptionEntry
---@field name string
---@field display string
---@field cmdline string

local function option_cmdline(name, value, info)
    if info.type == "boolean" then
        return "set " .. (value and ("no" .. name) or name)
    end

    return "set " .. name .. "=" .. vim.fn.escape(tostring(value), "\\ ")
end

local function format_option_entry(info, value)
    local label = info.name
    if type(info.shortname) == "string" and info.shortname ~= "" then
        label = label .. " (" .. info.shortname .. ")"
    end
    return ("%s%soption=%s"):format(label, DESCRIPTION_SEP, tostring(value))
end

---Collect readable Ex/user/plugin command entries available in the current session.
---@return FuzzyCommandEntry[]
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
        local entry = {
            name = name,
            description = normalize_description(meta and meta.definition),
            cmdline = name,
        }
        entry.display = format_entry(entry)

        by_name[name] = entry
        entries[#entries + 1] = entry
    end

    for _, name in ipairs(names) do
        add(name)
    end

    for name in pairs(user_commands) do
        add(name)
    end

    table.sort(entries, function(a, b)
        local al = a.name:lower()
        local bl = b.name:lower()
        if al ~= bl then return al < bl end
        return a.name < b.name
    end)

    return entries
end

---Collect Neovim option entries with their current values.
---@return FuzzyOptionEntry[]
function M.collect_options()
    local ok_options, options = pcall(vim.api.nvim_get_all_options_info)
    if not ok_options or type(options) ~= "table" then return {} end

    local entries = {}
    for _, info in pairs(options) do
        local ok_value, value = pcall(vim.api.nvim_get_option_value, info.name, {})
        if ok_value then
            entries[#entries + 1] = {
                name = info.name,
                display = format_option_entry(info, value),
                cmdline = option_cmdline(info.name, value, info),
            }
        end
    end

    table.sort(entries, function(a, b)
        local al = a.name:lower()
        local bl = b.name:lower()
        if al ~= bl then return al < bl end
        return a.name < b.name
    end)

    return entries
end

---Collect command palette entries.
---@return (FuzzyCommandEntry|FuzzyOptionEntry)[]
function M.collect()
    local entries = M.collect_commands()
    vim.list_extend(entries, M.collect_options())
    return entries
end

---@param entries (FuzzyCommandEntry|FuzzyOptionEntry)[]
---@return string[] display_items
---@return table<string, string> display_to_cmdline
function M.to_display_items(entries)
    local display_items = {}
    local display_to_cmdline = {}

    for _, entry in ipairs(entries) do
        display_items[#display_items + 1] = entry.display
        display_to_cmdline[entry.display] = entry.cmdline
    end

    return display_items, display_to_cmdline
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
