local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")

local function run(raw_args, dedupe_lines)
    local label = dedupe_lines and "FuzzyGrep" or "FuzzyGrep!"
    local netrw_dir = util.get_netrw_dir()

    runner.rg(raw_args, function(lines, status, err_lines)
        if status > 1 then
            local msg = (err_lines and #err_lines > 0) and err_lines or lines
            vim.notify(table.concat(msg, "\n") or (label .. ": ripgrep failed."), vim.log.levels.ERROR)
            return
        end

        local items, deduped = {}, 0
        if dedupe_lines then
            local seen, order = {}, {}
            for _, line in ipairs(lines) do
                local e = parse.vimgrep(line)
                if e then
                    if netrw_dir then e.filename = netrw_dir .. "/" .. e.filename end
                    local key = e.filename .. ":" .. e.lnum
                    if seen[key] then
                        seen[key].count = seen[key].count + 1
                        if e.col < seen[key].col then seen[key].col = e.col end
                    else
                        e.count = 1
                        seen[key], order[#order + 1] = e, key
                    end
                end
            end
            for _, key in ipairs(order) do
                local e = seen[key]
                if e.count > 1 then
                    deduped = deduped + 1
                    e.user_data = { fuzzy_match_count = e.count }
                end
                e.count = nil
                items[#items + 1] = e
            end
        else
            for _, line in ipairs(lines) do
                local e = parse.vimgrep(line)
                if e then
                    if netrw_dir then e.filename = netrw_dir .. "/" .. e.filename end
                    items[#items + 1] = e
                end
            end
        end

        local title = netrw_dir and (label .. " [" .. vim.fn.fnamemodify(netrw_dir, ":~") .. "]") or label
        local count = quickfix.update(items, { title = title, command = label })
        if deduped > 0 then
            vim.notify(("%s: collapsed duplicate matches on %d line%s."):format(label, deduped, deduped == 1 and "" or "s"), vim.log.levels.INFO)
        end
        quickfix.open_if_results(count, label .. ": no matches found.")
    end, netrw_dir)
end

return { run = run }
