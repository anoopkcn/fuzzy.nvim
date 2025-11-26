local quickfix = require("fuzzy.quickfix")

local function set_quickfix_buffers()
    local buffers = {}
    local listed = vim.fn.getbufinfo({ buflisted = 1 })

    for _, info in ipairs(listed) do
        local bufnr = info.bufnr
        if bufnr and bufnr > 0 and info.loaded == 1 then
            local ok_type, buftype = pcall(function()
                return vim.bo[bufnr].buftype
            end)
            if ok_type and buftype == "" then
                local name = info.name or ""
                local has_name = name ~= ""
                local display_name = has_name and name or "[No Name]"
                local label = string.format("[%d] %s", bufnr, display_name)
                buffers[#buffers + 1] = {
                    filename = has_name and name or nil,
                    bufnr = has_name and nil or bufnr,
                    lnum = (info.lnum and info.lnum > 0) and info.lnum or 1,
                    col = 1,
                    text = label,
                }
            end
        end
    end
    return quickfix.update(buffers, {
        title = "FuzzyBuffers",
        command = "FuzzyBuffers",
    })
end

local function run()
    local count = set_quickfix_buffers()
    if count == 0 then
        vim.notify("FuzzyBuffers: no listed buffers.", vim.log.levels.INFO)
        return
    end
    quickfix.open_quickfix_when_results(count, "FuzzyBuffers: no listed buffers.")
end

return {
    run = run,
}
