local registers = require("fuzzy.commands.registers")

local M = {}

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local entries = registers.collect()
    if #entries == 0 then
        vim.notify("FuzzyReg: no registers with content.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = entries,
        prompt = "Registers",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = registers.format_entry,
        filter_text = registers.filter_text,
        on_select = function(item)
            if type(item) ~= "table" then return end
            local text = table.concat(item.lines or {}, "\n")
            local ok, err = pcall(vim.fn.setreg, "+", text, item.type or "v")
            if not ok then
                vim.notify(("FuzzyReg: %s"):format(err), vim.log.levels.ERROR)
                return
            end
            vim.notify(("FuzzyReg: copied register %s to system clipboard."):format(item.name),
                vim.log.levels.INFO)
        end,
    })
end

return M
