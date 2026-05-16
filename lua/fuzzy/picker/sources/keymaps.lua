local keymaps = require("fuzzy.commands.keymaps")

local M = {}

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local entries = keymaps.collect()
    if #entries == 0 then
        vim.notify("FuzzyMap: no keymaps found.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = entries,
        prompt = "Keymaps",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = keymaps.format_entry,
        filter_text = keymaps.filter_text,
        make_render_context = keymaps.make_render_context,
        row_highlight = function(buf, row_ns, row, entry, text, ctx, prefix_len)
            if not ctx then return end
            for _, range in ipairs(keymaps.highlight_ranges(entry, ctx, text)) do
                if range.end_col >= range.start_col then
                    vim.api.nvim_buf_set_extmark(buf, row_ns, row, prefix_len + range.start_col - 1, {
                        end_col = prefix_len + range.end_col,
                        hl_group = range.group,
                        priority = 120,
                    })
                end
            end
        end,
        on_select = function() end,
    })
end

return M
