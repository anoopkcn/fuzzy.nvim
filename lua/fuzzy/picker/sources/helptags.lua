local helptags = require("fuzzy.commands.helptags")
local quickfix = require("fuzzy.quickfix")

local M = {}

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local tag_entries = helptags.collect()
    if #tag_entries == 0 then
        vim.notify("FuzzyHelp: no help tags found.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = tag_entries,
        prompt = "Help",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = function(entry) return entry.tag .. "  " .. entry.filename_short end,
        filter_text = function(entry) return entry.tag .. "  " .. entry.filename_short end,
        preview_source = {
            kind = "help",
            resolve = function(entry)
                if type(entry) ~= "table" or not entry.file then return nil end
                local t = helptags.excmd_to_qf_target(entry.excmd or "")
                return { path = entry.file, lnum = t and t.lnum, pattern = t and t.pattern }
            end,
        },
        on_select = function(entry)
            local ok, err = pcall(vim.cmd, { cmd = "help", args = { entry.tag } })
            if not ok then
                vim.notify("FuzzyHelp: " .. tostring(err), vim.log.levels.ERROR)
            end
        end,
        on_quickfix = function(visible_items)
            if #visible_items == 0 then
                vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                return
            end
            local qf_items = helptags.to_qf_items(visible_items)
            quickfix.update(qf_items, { title = "FuzzyHelp", command = "FuzzyHelp" })
            quickfix.open_if_results(#qf_items)
        end,
    })
end

return M
