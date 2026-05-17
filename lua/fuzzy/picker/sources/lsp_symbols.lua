local lsp = require("fuzzy.lsp")
local quickfix = require("fuzzy.quickfix")
local util = require("fuzzy.util")
local doc_symbols = require("fuzzy.commands.lsp_symbols")
local live_grep = require("fuzzy.picker.live_grep")

local COMMAND_NAME = doc_symbols.COMMAND_NAME
local METHOD = doc_symbols.METHOD

local M = {}

local function jump_to(entry)
    local qf = entry and entry.qf
    if not qf or not qf.filename then return end
    if not util.open_file(qf.filename) then return end
    pcall(vim.api.nvim_win_set_cursor, 0, { qf.lnum or 1, math.max((qf.col or 1) - 1, 0) })
    pcall(vim.cmd, "normal! zv")
end

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local bufnr = vim.api.nvim_get_current_buf()
    if not lsp.require_clients(bufnr, METHOD, COMMAND_NAME) then return end

    lsp.request_document_symbols(bufnr, function(items, err)
        if err then
            vim.notify(COMMAND_NAME .. ": " .. err, vim.log.levels.WARN)
            return
        end
        if #items == 0 then
            vim.notify(COMMAND_NAME .. ": no symbols.", vim.log.levels.INFO)
            return
        end
        local entries = {}
        for i, item in ipairs(items) do entries[i] = lsp.make_entry(item) end

        picker_open({
            items = entries,
            prompt = "DocSymbols",
            initial_query = opts.initial_query,
            highlight_paths = false,
            format_item = doc_symbols.format_entry,
            filter_text = doc_symbols.filter_text,
            make_render_context = doc_symbols.make_render_context,
            row_highlight = function(buf, ns, row, entry, text, ctx, prefix_len)
                if not ctx then return end
                for _, range in ipairs(doc_symbols.highlight_ranges(entry, ctx, text)) do
                    if range.end_col >= range.start_col then
                        vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len + range.start_col - 1, {
                            end_col = prefix_len + range.end_col,
                            hl_group = range.group,
                            priority = 120,
                        })
                    end
                end
            end,
            preview_source = {
                kind = "file",
                resolve = function(entry)
                    local qf = entry and entry.qf
                    if not qf or not qf.filename then return nil end
                    return { path = qf.filename, lnum = qf.lnum, col = qf.col }
                end,
            },
            on_select = function(entry) jump_to(entry) end,
            on_marked = function(marked, picked)
                local paths = vim.iter(marked)
                    :map(function(e) return e.qf and e.qf.filename or nil end)
                    :filter(function(p) return p ~= nil end)
                    :totable()
                util.load_files(paths)
                local target = live_grep.pick_marked_target(marked, picked, function(e)
                    return e.qf and e.qf.filename or nil
                end)
                if target then jump_to(target) end
            end,
            on_quickfix = function(visible)
                if #visible == 0 then
                    vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                    return
                end
                local qf_items = vim.iter(visible)
                    :map(function(e) return e.qf end)
                    :filter(function(qf) return qf ~= nil end)
                    :totable()
                quickfix.update(qf_items, { title = COMMAND_NAME, command = COMMAND_NAME })
                quickfix.open_if_results(#qf_items)
            end,
        })
    end)
end

return M
