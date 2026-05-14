local quickfix = require("fuzzy.quickfix")

local M = {}

---@param opts { initial_query?: string, fuzzy_only?: boolean }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local lists = quickfix.collect_history(opts.fuzzy_only)
    if #lists == 0 then
        vim.notify("No quickfix history.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = lists,
        prompt = "Quickfix",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = function(item) return ("%s (%d items)"):format(item.title, item.size) end,
        filter_text = function(item) return item.title end,
        on_select = function(item)
            quickfix.activate(item.nr)
            vim.cmd.copen()
        end,
    })
end

return M
