local quickfix = require("fuzzy.quickfix")
local match = require("fuzzy.match")

--- Check if path matches a loaded buffer
---@param path string
---@return number|nil bufnr if found
local function find_buffer_by_path(path)
    if not path or path == "" then
        return nil
    end

    local normalized = vim.fs.normalize(path)
    local listed = vim.fn.getbufinfo({ buflisted = 1 })

    for _, info in ipairs(listed) do
        local bufnr = info.bufnr
        if bufnr and bufnr > 0 and info.loaded == 1 then
            local name = info.name or ""
            if name ~= "" then
                if name == path or vim.fs.normalize(name) == normalized then
                    return bufnr
                end
            end
        end
    end
    return nil
end

--- Switch to buffer by bufnr
---@param bufnr number
---@return boolean success
local function switch_to_buffer(bufnr)
    local ok = pcall(vim.api.nvim_set_current_buf, bufnr)
    if not ok then
        vim.notify(string.format("FuzzyBuffers: failed to switch to buffer %d.", bufnr), vim.log.levels.ERROR)
        return false
    end
    return true
end

--- Build quickfix items from buffer list
---@param buffers table list of buffer info
---@return table items, string|nil first_file
local function build_buffer_quickfix_items(buffers)
    local items = {}
    local first_file = nil

    for _, info in ipairs(buffers) do
        local name = info.name or ""
        local has_name = name ~= ""
        local display_name = has_name and name or "[No Name]"
        local label = string.format("[%d] %s", info.bufnr, display_name)

        first_file = first_file or (has_name and name or nil)

        items[#items + 1] = {
            filename = has_name and name or nil,
            bufnr = has_name and nil or info.bufnr,
            lnum = (info.lnum and info.lnum > 0) and info.lnum or 1,
            col = 1,
            text = label,
        }
    end

    return items, first_file
end

--- Get filtered list of buffers
---@param pattern string|nil fuzzy pattern to filter by
---@return table list of matching buffer info
local function get_filtered_buffers(pattern)
    local listed = vim.fn.getbufinfo({ buflisted = 1 })
    local buffers = {}

    -- First collect valid buffers
    for _, info in ipairs(listed) do
        local bufnr = info.bufnr
        if bufnr and bufnr > 0 and info.loaded == 1 then
            local buftype = vim.bo[bufnr].buftype
            if buftype == "" then
                buffers[#buffers + 1] = info
            end
        end
    end

    -- If no pattern, return all
    if not pattern or pattern == "" then
        return buffers
    end

    -- Fuzzy filter by name
    local names = vim.iter(buffers):map(function(b)
        return b.name or ""
    end):totable()

    local scored = match.filter(pattern, names)

    -- Map back to buffer info, preserving fuzzy order
    local name_to_info = {}
    for _, info in ipairs(buffers) do
        name_to_info[info.name or ""] = info
    end

    local filtered = {}
    for _, entry in ipairs(scored) do
        local info = name_to_info[entry.item]
        if info then
            filtered[#filtered + 1] = info
        end
    end

    return filtered
end

--- Run FuzzyBuffers command
---@param raw_args string|nil pattern to filter buffers
---@param bang boolean if true, switch directly to single match
local function run(raw_args, bang)
    local pattern = vim.trim(raw_args or "")

    -- If pattern matches an existing buffer path exactly, switch to it
    if pattern ~= "" then
        local exact_bufnr = find_buffer_by_path(pattern)
        if exact_bufnr then
            if bang then
                switch_to_buffer(exact_bufnr)
                return
            end
        end
    end

    local buffers = get_filtered_buffers(pattern)

    if #buffers == 0 then
        vim.notify("FuzzyBuffers: no matching buffers.", vim.log.levels.INFO)
        return
    end

    -- If single match and bang, switch directly
    if bang and #buffers == 1 then
        local info = buffers[1]
        if info.bufnr then
            switch_to_buffer(info.bufnr)
            return
        end
    end

    local items, first_file = build_buffer_quickfix_items(buffers)

    local count = quickfix.update(items, {
        title = "FuzzyBuffers",
        command = "FuzzyBuffers",
    })

    quickfix.open_quickfix_when_results(count, "FuzzyBuffers: no matching buffers.")
end

return {
    run = run,
}
