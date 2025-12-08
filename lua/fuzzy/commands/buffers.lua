local config = require("fuzzy.config")
local quickfix = require("fuzzy.quickfix")
local match = require("fuzzy.match")
local util = require("fuzzy.util")

local function get_buffers()
    local bufs = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then bufs[#bufs + 1] = { bufnr = buf, path = name } end
        end
    end
    return bufs
end

local function find_buffer(path)
    local norm = util.normalize_path(path)
    for _, b in ipairs(get_buffers()) do
        if b.path == path or util.normalize_path(b.path) == norm then return b.bufnr end
    end
end

local function switch_to(bufnr)
    util.ensure_normal_window()
    local ok = pcall(vim.api.nvim_set_current_buf, bufnr)
    if not ok then vim.notify("FuzzyBuffers: failed to switch.", vim.log.levels.ERROR) end
    return ok
end

local function run(raw_args, bang)
    local pattern = vim.trim(raw_args or "")

    -- Exact path match
    if pattern ~= "" then
        local buf = find_buffer(pattern)
        if buf then
            if bang or config.get().open_single_result then
                switch_to(buf)
            else
                local items = {{ filename = pattern, lnum = 1, col = 1, text = pattern }}
                quickfix.update(items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
                quickfix.open_if_results(1)
            end
            return
        end
    end

    -- Filter buffers
    local bufs = get_buffers()
    if pattern ~= "" then
        local paths = vim.iter(bufs):map(function(b) return b.path end):totable()
        local scored = match.filter(pattern, paths)
        local by_path = {}
        for _, b in ipairs(bufs) do by_path[b.path] = b end
        bufs = vim.iter(scored):map(function(e) return by_path[e.item] end):filter(function(b) return b end):totable()
    end

    if #bufs == 0 then
        vim.notify("FuzzyBuffers: no matching buffers.", vim.log.levels.INFO)
        return
    end

    if (config.get().open_single_result or bang) and #bufs == 1 then
        switch_to(bufs[1].bufnr)
        return
    end

    local items = vim.iter(bufs):map(function(b)
        return { filename = b.path, lnum = 1, col = 1, text = ("[%d] %s"):format(b.bufnr, b.path) }
    end):totable()
    local count = quickfix.update(items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
    quickfix.open_if_results(count, "FuzzyBuffers: no matching buffers.")
end

return { run = run }
