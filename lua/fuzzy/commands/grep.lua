local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")

local function run(raw_args)
    local dedupe_lines = require("fuzzy.config").get().grep_dedupe
    local label = dedupe_lines and "FuzzyGrep" or "FuzzyGrep!"
    local netrw_dir = util.get_netrw_dir()

    local title = netrw_dir and (label .. " [" .. vim.fn.fnamemodify(netrw_dir, ":~") .. "]") or label
    local updater = quickfix.stream_updater({
        command = label,
        title = title,
        empty_msg = label .. ": no matches found.",
    })

    -- Dedup state persists across batches
    local seen = dedupe_lines and {} or nil

    -- Accumulate lines from libuv thread, schedule batch pushes
    local line_batch = {}
    local batch_scheduled = false

    runner.rg_stream(raw_args, {
        cwd = netrw_dir,
        on_line = function(line)
            line_batch[#line_batch + 1] = line
            if not batch_scheduled then
                batch_scheduled = true
                vim.schedule(function()
                    local batch = line_batch
                    line_batch = {}
                    batch_scheduled = false
                    local items = {}
                    for _, raw_line in ipairs(batch) do
                        local e = parse.vimgrep(raw_line)
                        if e then
                            e.filename = util.with_root(e.filename, netrw_dir)
                            if seen then
                                local key = e.filename .. ":" .. e.lnum
                                if not seen[key] then
                                    seen[key] = true
                                    items[#items + 1] = e
                                end
                            else
                                items[#items + 1] = e
                            end
                        end
                    end
                    if #items > 0 then
                        updater.push(items)
                    end
                end)
            end
        end,
        on_exit = function(code, err_lines)
            if code > 1 then
                updater.stop()
                local msg = (err_lines and #err_lines > 0) and table.concat(err_lines, "\n") or (label .. ": ripgrep failed.")
                vim.notify(msg, vim.log.levels.ERROR)
                return
            end
            updater.finish()
        end,
    })
end

return { run = run }
