local M = {}

---@class FuzzyQfContext
---@field fuzzy boolean Always true for fuzzy quickfix lists
---@field cmd string Command that created this list

local CONTEXT = { fuzzy = true }
---@type table<string, integer> Command name -> quickfix ID cache
local qf_ids = {}

local function get_info(opts)
    local ok, info = pcall(vim.fn.getqflist, opts)
    return ok and info or nil
end

local function is_fuzzy(ctx)
    return type(ctx) == "table" and ctx.fuzzy
end

local function create_new(cmd)
    vim.fn.setqflist({}, " ", { nr = "$", title = cmd, context = vim.tbl_extend("force", CONTEXT, { cmd = cmd }) })
    local info = get_info({ nr = 0, id = 0 })
    if info then qf_ids[cmd] = info.id end
    return info
end

local function find_or_create(cmd)
    -- Try cached id first (O(1) lookup)
    if qf_ids[cmd] then
        local info = get_info({ id = qf_ids[cmd], context = 1 })
        if info and is_fuzzy(info.context) then return info end
        qf_ids[cmd] = nil -- Cache invalid, clear it
    end

    -- Skip O(n) search - just create new list
    -- Old lists will be reused if user manually navigates to them
    return create_new(cmd)
end

local function activate(nr)
    local cur = (get_info({ nr = 0 }) or {}).nr or 0
    local delta = nr - cur
    if delta > 0 then pcall(vim.cmd, "silent! cnewer " .. delta)
    elseif delta < 0 then pcall(vim.cmd, "silent! colder " .. -delta) end
end

---@param items table[] Quickfix items
---@param opts? { title?: string, command?: string }
---@return integer count Number of items
function M.update(items, opts)
    opts = opts or {}
    local cmd = opts.command or "Fuzzy"
    local info = find_or_create(cmd)
    if not info then return 0 end

    local ctx = vim.tbl_extend("force", CONTEXT, { cmd = cmd })
    pcall(vim.fn.setqflist, {}, "r", { id = info.id, items = items, title = opts.title or cmd, context = ctx })
    activate((get_info({ id = info.id, nr = 0 }) or info).nr)
    return #items
end

---@param count integer Number of results
---@param empty_msg? string Message to show if no results
function M.open_if_results(count, empty_msg)
    if count == 0 then
        vim.notify(empty_msg or "No matches.", vim.log.levels.INFO)
    else
        vim.cmd.copen()
    end
end

--- Show quickfix history selector
---@param fuzzy_only? boolean Only show fuzzy-created lists
function M.select_from_history(fuzzy_only)
    local max = (get_info({ nr = "$" }) or {}).nr or 0
    local lists = {}
    for nr = max, 1, -1 do
        local info = get_info({ nr = nr, context = 1, title = 1, size = 1 })
        if info and not (is_fuzzy(info.context) and info.context.cmd == "FuzzyList") then
            if not fuzzy_only or is_fuzzy(info.context) then
                lists[#lists + 1] = { nr = nr, title = info.title or ("Quickfix " .. nr), size = info.size or 0 }
            end
        end
    end

    if #lists == 0 then
        vim.notify("No quickfix history.", vim.log.levels.INFO)
        return
    end

    vim.ui.select(lists, {
        prompt = "Select Quickfix",
        format_item = function(item) return ("%s (%d items)"):format(item.title, item.size) end,
    }, function(choice)
        if choice then activate(choice.nr); vim.cmd.copen() end
    end)
end

--- Go to next quickfix entry, cycling to first if at end
function M.cnext_cycle()
    local info = get_info({ size = 0, idx = 0 })
    if not info or info.size == 0 then return end
    local before = info.idx
    vim.cmd("silent! cnext")
    if (get_info({ idx = 0 }) or {}).idx == before then vim.cmd("silent! cfirst") end
end

--- Go to previous quickfix entry, cycling to last if at beginning
function M.cprev_cycle()
    local info = get_info({ size = 0, idx = 0 })
    if not info or info.size == 0 then return end
    local before = info.idx
    vim.cmd("silent! cprev")
    if (get_info({ idx = 0 }) or {}).idx == before then vim.cmd("silent! clast") end
end

return M
