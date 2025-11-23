local FUZZY_CONTEXT_KEY = "fuzzy_owner"
local FUZZY_CONTEXT_VALUE = "lua/fuzzy"

local quickfix_ids = {}

local function is_fuzzy_context(ctx, command)
    return type(ctx) == "table"
        and ctx[FUZZY_CONTEXT_KEY] == FUZZY_CONTEXT_VALUE
        and (command == nil or ctx.command == command)
end

local function get_quickfix_info(opts)
    local ok, info = pcall(vim.fn.getqflist, opts)
    return ok and type(info) == "table" and info or nil
end

local function get_quickfix_info_by_id(id, command)
    if not id then return nil end
    local info = get_quickfix_info({ id = id, context = 1, nr = 0, title = 1 })
    if info and is_fuzzy_context(info.context, command) then
        info.id = id
        return info
    end
end

local function get_quickfix_info_by_nr(nr, command)
    local info = get_quickfix_info({ nr = nr, context = 1, id = 0, title = 1 })
    return info and is_fuzzy_context(info.context, command) and info or nil
end

local function get_quickfix_stack_size()
    local info = get_quickfix_info({ nr = "$" })
    return info and info.nr or 0
end

local function find_existing_fuzzy_quickfix(command)
    local max_nr = get_quickfix_stack_size()
    for nr = max_nr, 1, -1 do
        local info = get_quickfix_info_by_nr(nr, command)
        if info then return info end
    end
end

local function create_fuzzy_quickfix(command, title)
    local ok, err = pcall(vim.fn.setqflist, {}, " ", {
        nr = "$",
        title = title or command or "Fuzzy",
        context = { [FUZZY_CONTEXT_KEY] = FUZZY_CONTEXT_VALUE, command = command },
        items = {},
    })
    if not ok then
        vim.notify(string.format("Fuzzy: failed to prepare quickfix list: %s", err), vim.log.levels.ERROR)
        return nil
    end
    local current = get_quickfix_info({ nr = 0 })
    return current and get_quickfix_info_by_nr(current.nr, command)
end

local function ensure_fuzzy_quickfix(command, title)
    command = command or "Fuzzy"
    local info = get_quickfix_info_by_id(quickfix_ids[command], command)
        or find_existing_fuzzy_quickfix(command)
        or create_fuzzy_quickfix(command, title)
    if info then
        quickfix_ids[command] = info.id
    end
    return info
end

local function activate_quickfix_nr(target_nr)
    if not target_nr then return end
    local current = get_quickfix_info({ nr = 0 })
    if not current then return end

    local delta = target_nr - (current.nr or 0)
    if delta == 0 then return end

    local cmd = delta > 0
        and string.format("silent! cnewer %d", delta)
        or string.format("silent! colder %d", -delta)
    pcall(vim.cmd, cmd)
end

local function collect_quickfix_lists(exclude_command)
    local max_nr = get_quickfix_stack_size()
    local lists = {}
    for nr = max_nr, 1, -1 do
        local info = get_quickfix_info({ nr = nr, context = 1, id = 0, title = 1, size = 1 })
        if info then
            local ctx_command = info.context and info.context.command
            if not (ctx_command and ctx_command == exclude_command) then
                local title = (info.title and info.title ~= "")
                    and info.title
                    or string.format("Quickfix %d", nr)
                lists[#lists + 1] = {
                    nr = info.nr or nr,
                    title = title,
                    size = info.size or 0,
                    command = ctx_command,
                }
            end
        end
    end
    return lists
end

local function select_quickfix_from_history()
    local lists = collect_quickfix_lists("FuzzyList")
    if #lists == 0 then
        vim.notify("FuzzyList: no quickfix history.", vim.log.levels.INFO)
        return
    end

    local output_lines = {}
    for idx, item in ipairs(lists) do
        local show_command = item.command and item.command ~= "" and item.command ~= item.title
        local prefix = show_command and string.format("[%s] ", item.command) or ""
        output_lines[#output_lines + 1] = string.format("%d: %s%s (%d items)", idx, prefix, item.title, item.size or 0)
    end

    local echo_chunks = vim.tbl_map(function(line) return { line .. "\n", "None" } end, output_lines)
    vim.api.nvim_echo(echo_chunks, false, {})

    local choice_idx = tonumber(vim.fn.input("Select Quickfix: "), 10)
    if choice_idx and choice_idx >= 1 and choice_idx <= #lists then
        activate_quickfix_nr(lists[choice_idx].nr)
        vim.cmd("copen")
    end
end

local M = {}

function M.update(items, opts)
    opts = opts or {}
    local command = opts.command or "Fuzzy"
    local info = ensure_fuzzy_quickfix(command, opts.title)
    if not info then return 0 end

    local context = {
        [FUZZY_CONTEXT_KEY] = FUZZY_CONTEXT_VALUE,
        command = command,
    }

    local ok, err = pcall(vim.fn.setqflist, {}, "r", {
        id = info.id,
        items = items,
        title = opts.title,
        context = context,
    })
    if not ok then
        vim.notify(string.format("Fuzzy: failed to update quickfix list: %s", err), vim.log.levels.ERROR)
        return 0
    end

    local refreshed = get_quickfix_info_by_id(info.id, command) or info
    activate_quickfix_nr(refreshed.nr)
    return #items
end

function M.open_quickfix_when_results(match_count, empty_message)
    if match_count == 0 then
        vim.notify(empty_message or "No matches found.", vim.log.levels.INFO)
    else
        vim.cmd("copen")
    end
end

function M.select_from_history()
    select_quickfix_from_history()
end

function M.is_fuzzy_context(ctx, command)
    return is_fuzzy_context(ctx, command)
end

function M.get_quickfix_info(opts)
    return get_quickfix_info(opts)
end

return M
