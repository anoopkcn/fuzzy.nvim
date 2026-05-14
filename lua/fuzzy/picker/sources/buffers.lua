local config = require("fuzzy.config")
local quickfix = require("fuzzy.quickfix")
local util = require("fuzzy.util")

local M = {}

---@param opts { initial_query?: string }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local items, by_path, by_path_abs
    local function build()
        local bufs = util.get_listed_buffers()
        items, by_path, by_path_abs = {}, {}, {}
        for _, b in ipairs(bufs) do
            local rel = vim.fn.fnamemodify(b.path, ":.")
            items[#items + 1] = rel
            by_path[rel] = b.bufnr
            by_path_abs[rel] = b.path
        end
    end
    build()
    if #items == 0 then
        vim.notify("Fuzzy: no listed buffers.", vim.log.levels.INFO)
        return
    end
    return picker_open({
        items = items,
        prompt = "Buffers",
        initial_query = opts.initial_query,
        highlight_paths = false,
        preview_source = {
            kind = "buffer",
            resolve = function(rel)
                if type(rel) ~= "string" then return nil end
                return { bufnr = by_path[rel], path = by_path_abs[rel] }
            end,
        },
        on_select = function(rel)
            local bufnr = by_path[rel]
            if bufnr then util.switch_to_buffer(bufnr) end
        end,
        on_marked = function(marked_items)
            local bufnrs = {}
            for _, rel in ipairs(marked_items) do
                local b = by_path[rel]
                if b and vim.api.nvim_buf_is_valid(b) then
                    bufnrs[#bufnrs + 1] = b
                end
            end
            if #bufnrs == 0 then return end
            util.switch_to_buffer(bufnrs[1])
            if #bufnrs == 1 then return end
            local split_cmd = (config.get().buffer_split_direction == "horizontal")
                and "split" or "vsplit"
            for i = 2, #bufnrs do
                vim.cmd(split_cmd)
                pcall(vim.api.nvim_set_current_buf, bufnrs[i])
            end
        end,
        on_quickfix = function(visible_items)
            if #visible_items == 0 then
                vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                return
            end
            local qf_items = {}
            for i = 1, #visible_items do
                local rel = visible_items[i]
                local bufnr = by_path[rel]
                qf_items[i] = { bufnr = bufnr, filename = by_path_abs[rel] or rel, lnum = 1, col = 1, text = rel }
            end
            quickfix.update(qf_items, { title = "FuzzyBuffers", command = "FuzzyBuffers" })
            quickfix.open_if_results(#qf_items)
        end,
        on_setup = function(picker, imap)
            local close_key = config.get().close_buffer_key
            if not close_key or close_key == "" then return end
            imap(close_key, function()
                local targets = picker.get_marked()
                if #targets == 0 then
                    local cur = picker.get_cursor()
                    if cur ~= nil then targets = { cur } end
                end
                if #targets == 0 then return end

                local target_set = {}
                for _, rel in ipairs(targets) do
                    local b = by_path[rel]
                    if b then target_set[b] = true end
                end

                -- Pick a survivor buffer (a named listed buffer not being
                -- deleted) so windows showing a target can be vacated
                -- cleanly. Empty-name buffers (e.g. the startup [No Name])
                -- are skipped — falling back to :enew below is equivalent
                -- and avoids surfacing them via the close action.
                local survivor = nil
                for _, b in ipairs(vim.api.nvim_list_bufs()) do
                    if not target_set[b]
                        and vim.api.nvim_buf_is_loaded(b)
                        and vim.bo[b].buflisted
                        and vim.api.nvim_buf_get_name(b) ~= ""
                    then
                        survivor = b
                        break
                    end
                end

                -- Swap any non-floating window showing a target onto the
                -- survivor (or a fresh [No Name] if no survivor exists).
                for _, win in ipairs(vim.api.nvim_list_wins()) do
                    local wbuf = vim.api.nvim_win_get_buf(win)
                    if target_set[wbuf]
                        and vim.api.nvim_win_get_config(win).relative == ""
                    then
                        if survivor then
                            vim.api.nvim_win_set_buf(win, survivor)
                        else
                            vim.api.nvim_win_call(win, function() vim.cmd("enew") end)
                            survivor = vim.api.nvim_win_get_buf(win)
                        end
                    end
                end

                local modified_failed, other_failed = {}, {}
                for _, rel in ipairs(targets) do
                    local bufnr = by_path[rel]
                    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
                        local was_modified = vim.bo[bufnr].modified
                        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = false })
                        if not ok then
                            if was_modified then
                                modified_failed[#modified_failed + 1] = rel
                            else
                                other_failed[#other_failed + 1] = rel
                            end
                        end
                    end
                end
                if #modified_failed > 0 then
                    vim.notify(
                        "Fuzzy: unsaved changes: " .. table.concat(modified_failed, ", "),
                        vim.log.levels.WARN
                    )
                end
                if #other_failed > 0 then
                    vim.notify(
                        "Fuzzy: could not close: " .. table.concat(other_failed, ", "),
                        vim.log.levels.WARN
                    )
                end

                build()
                if #items == 0 then
                    vim.notify("Fuzzy: no listed buffers.", vim.log.levels.INFO)
                    picker.close()
                else
                    picker.set_items(items)
                end
            end)
        end,
    })
end

return M
