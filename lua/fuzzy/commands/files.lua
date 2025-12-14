local config = require("fuzzy.config")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")


local function open_file(path)
    local buf = util.find_buffer_by_path(path)
    if buf and vim.api.nvim_buf_is_valid(buf) then
        local ok = pcall(vim.api.nvim_set_current_buf, buf)
        if not ok then vim.notify("FuzzyFiles: failed to switch to buffer.", vim.log.levels.ERROR) end
        return ok
    end
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then vim.notify(("FuzzyFiles: %s"):format(err), vim.log.levels.ERROR) end
    return ok
end

local function run(raw_args, bang)
    local trimmed = vim.trim(raw_args or "")
    local netrw_dir = util.get_netrw_dir()
    local stat = trimmed ~= "" and vim.uv.fs_stat(trimmed)

    -- Direct file path
    if stat and stat.type == "file" then
        if bang or config.get().open_single_result then
            open_file(trimmed)
        else
            local items = {{ filename = trimmed, lnum = 1, col = 1, text = trimmed }}
            quickfix.update(items, { title = "FuzzyFiles", command = "FuzzyFiles" })
            quickfix.open_if_results(1)
        end
        return
    end

    runner.fd(raw_args, function(files, status, truncated, limit, err_lines)
        if status ~= 0 then
            local msg = (err_lines and #err_lines > 0) and err_lines or files
            vim.notify(table.concat(msg, "\n") or "FuzzyFiles: failed.", vim.log.levels.ERROR)
            return
        end

        local items, first = {}, nil
        for i = 1, math.min(limit or #files, #files) do
            if files[i] ~= "" then
                local filepath = util.with_root(files[i], netrw_dir)
                first = first or filepath
                items[#items + 1] = { filename = filepath, lnum = 1, col = 1, text = files[i] }
            end
        end

        if (config.get().open_single_result or bang) and #items == 1 and first then
            if open_file(first) then return end
        end

        local title = netrw_dir and ("FuzzyFiles [" .. vim.fn.fnamemodify(netrw_dir, ":~") .. "]") or "FuzzyFiles"
        local count = quickfix.update(items, { title = title, command = "FuzzyFiles" })
        if truncated then vim.notify(("FuzzyFiles: showing first %d matches."):format(limit), vim.log.levels.INFO) end
        quickfix.open_if_results(count, "FuzzyFiles: no files matched.")
    end, netrw_dir)
end

return { run = run }
