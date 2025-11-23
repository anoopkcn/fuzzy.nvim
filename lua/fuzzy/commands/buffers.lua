local quickfix = require("fuzzy.quickfix")

local fuzzy_buffers_autocmd_group = vim.api.nvim_create_augroup("FuzzyBuffersLive", { clear = true })
local fuzzy_buffers_updating = false

local function is_real_listed_buffer(bufnr)
    if not bufnr or bufnr < 1 or not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local ok_type, buftype = pcall(vim.api.nvim_get_option_value, "buftype", { buf = bufnr })
    if not ok_type or buftype ~= "" then
        return false
    end

    local ok_listed, listed = pcall(vim.api.nvim_get_option_value, "buflisted", { buf = bufnr })
    return ok_listed and listed
end

local function set_quickfix_buffers()
    local buffers = {}
    for _, buf in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
        if is_real_listed_buffer(buf.bufnr) then
            local name = buf.name ~= "" and buf.name or "[No Name]"
            local label = string.format("[%d] %s", buf.bufnr, name)
            buffers[#buffers + 1] = {
                filename = buf.name ~= "" and name or nil,
                bufnr = buf.name == "" and buf.bufnr or nil,
                lnum = math.max(buf.lnum or 1, 1),
                col = 1,
                text = label,
            }
        end
    end
    return quickfix.update(buffers, {
        title = "FuzzyBuffers",
        command = "FuzzyBuffers",
    })
end

local function refresh_fuzzy_buffers()
    if fuzzy_buffers_updating then return 0 end

    fuzzy_buffers_updating = true
    local ok, count = pcall(set_quickfix_buffers)
    fuzzy_buffers_updating = false

    if not ok then
        vim.notify(string.format("Fuzzy: failed to refresh buffers: %s", count or "unknown"), vim.log.levels.ERROR)
        return 0
    end
    return count or 0
end

local function disable_fuzzy_buffers_live_update()
    vim.api.nvim_clear_autocmds({ group = fuzzy_buffers_autocmd_group })
end

local function enable_fuzzy_buffers_live_update()
    disable_fuzzy_buffers_live_update()
    vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "BufWipeout" }, {
        group = fuzzy_buffers_autocmd_group,
        callback = function()
            vim.schedule(function()
                local current = quickfix.get_quickfix_info({ nr = 0, context = 1, title = 1 })
                if current and quickfix.is_fuzzy_context(current.context, "FuzzyBuffers") then
                    refresh_fuzzy_buffers()
                end
            end)
        end,
        desc = "Refresh FuzzyBuffers quickfix list on buffer changes",
    })
end

local function run(bang)
    if bang then
        enable_fuzzy_buffers_live_update()
    else
        disable_fuzzy_buffers_live_update()
    end

    local count = refresh_fuzzy_buffers()
    if count == 0 then
        vim.notify("FuzzyBuffers: no listed buffers.", vim.log.levels.INFO)
        return
    end

    quickfix.open_quickfix_when_results(count, "FuzzyBuffers: no listed buffers.")
end

return {
    run = run,
}
