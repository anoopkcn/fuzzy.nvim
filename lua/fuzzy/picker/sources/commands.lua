local commands = require("fuzzy.commands.commands")

local M = {}

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local entries = commands.collect()
    if #entries == 0 then
        vim.notify("FuzzyCommands: no commands found.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = entries,
        prompt = "Commands",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = commands.format_entry,
        filter_text = commands.filter_text,
        make_render_context = commands.make_render_context,
        row_highlight = function(buf, row_ns, row, entry, text, ctx, prefix_len)
            if not ctx then return end
            for _, range in ipairs(commands.highlight_ranges(entry, ctx, text)) do
                if range.end_col >= range.start_col then
                    vim.api.nvim_buf_set_extmark(buf, row_ns, row, prefix_len + range.start_col - 1, {
                        end_col = prefix_len + range.end_col,
                        hl_group = range.group,
                        priority = 120,
                    })
                end
            end
        end,
        on_select = function(entry)
            commands.prefill_cmdline(entry and entry.cmdline or nil)
        end,
    })
end

return M
