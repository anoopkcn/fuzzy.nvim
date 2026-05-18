local marks = require("fuzzy.commands.marks")
local util = require("fuzzy.util")

local M = {}

-- Special marks whose name needs to be addressed as `< ` or `> ` etc — vim's
-- ``\``` jump command accepts these directly, but some chars need a backtick
-- escape. Stick to a plain backtick-jump for alphanumeric, manual cursor-set
-- for special marks.
local function is_simple_mark(name)
    if not name or #name ~= 1 then return false end
    local b = name:byte()
    if b >= 65 and b <= 90 then return true end   -- A-Z
    if b >= 97 and b <= 122 then return true end  -- a-z
    if b >= 48 and b <= 57 then return true end   -- 0-9
    return false
end

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local entries = marks.collect()
    if #entries == 0 then
        vim.notify("FuzzyMarks: no marks set.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = entries,
        prompt = "Marks",
        initial_query = opts.initial_query,
        highlight_paths = false,
        format_item = marks.format_entry,
        filter_text = marks.filter_text,
        make_render_context = marks.make_render_context,
        preview_source = {
            kind = "buffer",
            resolve = function(item)
                if type(item) ~= "table" then return nil end
                return {
                    bufnr = item.bufnr ~= 0 and item.bufnr or nil,
                    path = item.abs_path ~= "" and item.abs_path or nil,
                    lnum = item.lnum,
                    col = item.col,
                }
            end,
        },
        on_select = function(item)
            if type(item) ~= "table" then return end
            if is_simple_mark(item.name) then
                -- Backtick-jump preserves global/local mark semantics and
                -- triggers cross-buffer switch when the global mark points
                -- to another file.
                local ok = pcall(vim.cmd, "normal! `" .. item.name)
                if ok then return end
            end
            -- Special marks (e.g. ., ^, [, ], <, >, ', `): switch buffer
            -- manually and place the cursor at the recorded position.
            if item.bufnr ~= 0 and vim.api.nvim_buf_is_valid(item.bufnr) then
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
