local config = require("fuzzy.config")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")


local function run(raw_args, bang)
    local trimmed = vim.trim(raw_args or "")
    local netrw_dir = util.get_netrw_dir()
    local stat = trimmed ~= "" and vim.uv.fs_stat(trimmed)

    -- Direct file path
    if stat and stat.type == "file" then
        if bang or config.get().open_single_result then
            util.open_file(trimmed)
        else
            local items = {{ filename = trimmed, lnum = 1, col = 1, text = trimmed }}
            quickfix.update(items, { title = "FuzzyFiles", command = "FuzzyFiles" })
            quickfix.open_if_results(1)
        end
        return
    end

    local title = netrw_dir and ("FuzzyFiles [" .. vim.fn.fnamemodify(netrw_dir, ":~") .. "]") or "FuzzyFiles"
    local updater = quickfix.stream_updater({
        command = "FuzzyFiles",
        title = title,
        empty_msg = "FuzzyFiles: no files matched.",
    })

    -- Accumulate lines from libuv thread, schedule batch pushes
    local line_batch = {}
    local batch_scheduled = false
    local first_file = nil

    local function flush_line_batch()
        local batch = line_batch
        line_batch = {}
        batch_scheduled = false
        if #batch == 0 then return end

        local items = {}
        for i = 1, #batch do
            local filepath = util.with_root(batch[i], netrw_dir)
            if not first_file then first_file = filepath end
            items[i] = { filename = filepath, lnum = 1, col = 1, text = batch[i] }
        end
        updater.push(items)
    end

    runner.fd_stream(raw_args, {
        cwd = netrw_dir,
        on_line = function(line)
            if line ~= "" then
                line_batch[#line_batch + 1] = line
            end
            if not batch_scheduled and #line_batch > 0 then
                batch_scheduled = true
                vim.schedule(flush_line_batch)
            end
        end,
        on_exit = function(code, err_lines)
            -- The final stdout chunk is delivered immediately before on_exit, but
            -- its scheduled batch push may not have run yet. Drain it here so the
            -- first picker run includes files that appear in the last fd chunk.
            flush_line_batch()
            if code ~= 0 then
                updater.stop()
                local msg = (err_lines and #err_lines > 0) and table.concat(err_lines, "\n") or "FuzzyFiles: failed."
                vim.notify(msg, vim.log.levels.ERROR)
                return
            end

            local count = updater.count()
            if (config.get().open_single_result or bang) and count == 1 and first_file then
                updater.stop()
                util.open_file(first_file)
            else
                updater.finish()
            end
        end,
    })
end

return { run = run }
