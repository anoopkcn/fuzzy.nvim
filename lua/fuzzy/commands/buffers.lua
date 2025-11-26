-- FuzzyBuffers: fuzzy find and switch between open buffers
-- Mirrors FuzzyFiles logic but for loaded buffers instead of files on disk

local config = require("fuzzy.config")
local quickfix = require("fuzzy.quickfix")
local match = require("fuzzy.match")

--- Normalize path for comparison
local function normalize_path(path)
    if not path or path == "" then
        return nil
    end
    local real = vim.uv.fs_realpath(path)
    return real or vim.fs.normalize(path)
end

--- Check if we're in a quickfix window
local function is_quickfix_window(winid)
    local ok, buf = pcall(vim.api.nvim_win_get_buf, winid)
    if not ok then return false end
    local ok2, buftype = pcall(vim.api.nvim_get_option_value, "buftype", { buf = buf })
    return ok2 and buftype == "quickfix"
end

--- Get all listed buffer paths
---@return table list of {bufnr, path} pairs
local function get_listed_buffers()
    local buffers = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            local buftype = vim.bo[buf].buftype
            if buftype == "" then
                local name = vim.api.nvim_buf_get_name(buf)
                if name ~= "" then
                    buffers[#buffers + 1] = { bufnr = buf, path = name }
                end
            end
        end
    end
    return buffers
end

--- Find buffer by path (exact match)
---@param path string
---@return number|nil bufnr
local function find_buffer_by_path(path)
    if not path or path == "" then
        return nil
    end
    local normalized = normalize_path(path)
    for _, buf in ipairs(get_listed_buffers()) do
        if buf.path == path or normalize_path(buf.path) == normalized then
            return buf.bufnr
        end
    end
    return nil
end

--- Switch to buffer, handling quickfix window
---@param bufnr number
---@return boolean success
local function switch_to_buffer(bufnr)
    -- If in quickfix window, switch to a normal window first
    if is_quickfix_window(vim.api.nvim_get_current_win()) then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if not is_quickfix_window(win) then
                vim.api.nvim_set_current_win(win)
                break
            end
        end
        -- If still in quickfix, create a split
        if is_quickfix_window(vim.api.nvim_get_current_win()) then
            vim.cmd.split()
        end
    end

    local ok = pcall(vim.api.nvim_set_current_buf, bufnr)
    if not ok then
        vim.notify(string.format("FuzzyBuffers: failed to switch to buffer %d.", bufnr), vim.log.levels.ERROR)
        return false
    end
    return true
end

--- Build quickfix items from buffer list
---@param buffers table list of {bufnr, path}
---@return table items
---@return string|nil first_path
local function build_quickfix_items(buffers)
    local items = {}
    local first_path = nil

    for _, buf in ipairs(buffers) do
        first_path = first_path or buf.path
        items[#items + 1] = {
            filename = buf.path,
            lnum = 1,
            col = 1,
            text = string.format("[%d] %s", buf.bufnr, buf.path),
        }
    end

    return items, first_path
end

--- Filter buffers using fuzzy matching
---@param pattern string
---@param buffers table list of {bufnr, path}
---@return table filtered buffers
local function filter_buffers(pattern, buffers)
    if not pattern or pattern == "" then
        return buffers
    end

    -- Extract paths for matching
    local paths = vim.iter(buffers):map(function(b) return b.path end):totable()
    local scored = match.filter(pattern, paths)

    -- Map back to buffer info
    local path_to_buf = {}
    for _, buf in ipairs(buffers) do
        path_to_buf[buf.path] = buf
    end

    local filtered = {}
    for _, entry in ipairs(scored) do
        local buf = path_to_buf[entry.item]
        if buf then
            filtered[#filtered + 1] = buf
        end
    end

    return filtered
end

--- Run FuzzyBuffers command
---@param raw_args string pattern to filter buffers
---@param bang boolean if true, switch directly to single match
local function run(raw_args, bang)
    local pattern = vim.trim(raw_args or "")

    -- If pattern matches an existing buffer path exactly, switch to it
    if pattern ~= "" then
        local exact_bufnr = find_buffer_by_path(pattern)
        if exact_bufnr then
            if bang or config.get().open_single_result then
                switch_to_buffer(exact_bufnr)
                return
            end
            -- Show single buffer in quickfix if not using bang
            local items = {{ filename = pattern, lnum = 1, col = 1, text = pattern }}
            quickfix.update(items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
            quickfix.open_quickfix_when_results(1, "FuzzyBuffers: no matching buffers.")
            return
        end
    end

    -- Get and filter buffers
    local buffers = get_listed_buffers()
    local filtered = filter_buffers(pattern, buffers)

    if #filtered == 0 then
        vim.notify("FuzzyBuffers: no matching buffers.", vim.log.levels.INFO)
        return
    end

    -- If single match and bang/config, switch directly
    local prefer_direct = (config.get().open_single_result or bang) and #filtered == 1
    if prefer_direct then
        switch_to_buffer(filtered[1].bufnr)
        return
    end

    -- Show in quickfix
    local items, first_path = build_quickfix_items(filtered)
    local count = quickfix.update(items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
    quickfix.open_quickfix_when_results(count, "FuzzyBuffers: no matching buffers.")
end

return {
    run = run,
}
