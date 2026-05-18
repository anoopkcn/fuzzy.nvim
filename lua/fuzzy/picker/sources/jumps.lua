local jumps = require("fuzzy.commands.jumps")
local util = require("fuzzy.util")

local M = {}

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local entries = jumps.collect()
    if #entries == 0 then
        vim.notify("FuzzyJumps: jump list is empty.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = entries,
        prompt = "Jumps",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = jumps.format_entry,
        filter_text = jumps.filter_text,
        make_render_context = jumps.make_render_context,
        preview_source = {
            kind = "buffer",
            resolve = function(item)
                if type(item) ~= "table" then return nil end
                return {
                    bufnr = item.bufnr,
                    path = item.abs_path ~= "" and item.abs_path or nil,
                    lnum = item.lnum,
                    col = item.col,
                }
            end,
        },
        on_select = function(item)
            if type(item) ~= "table" then return end
            if item.bufnr and vim.api.nvim_buf_is_valid(item.bufnr) then
                util.switch_to_buffer(item.bufnr)
            elseif item.abs_path ~= "" then
                util.open_file(item.abs_path)
            else
                return
            end
            pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum, math.max(0, item.col - 1) })
        end,
    })
end

return M
