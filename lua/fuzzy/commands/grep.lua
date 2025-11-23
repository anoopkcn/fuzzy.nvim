local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")

local function set_quickfix_from_lines(lines, dedupe_lines)
    local items = {}
    local deduped_lines = 0

    if dedupe_lines then
        local seen, order = {}, {}
        for _, line in ipairs(lines) do
            local entry = parse.parse_vimgrep_line(line)
            if entry then
                local key = string.format("%s:%d", entry.filename, entry.lnum)
                local existing = seen[key]
                if existing then
                    existing.count = existing.count + 1
                    if entry.col < existing.col then
                        existing.col = entry.col
                    end
                else
                    entry.count = 1
                    seen[key] = entry
                    order[#order + 1] = key
                end
            end
        end

        for _, key in ipairs(order) do
            local entry = seen[key]
            if entry.count and entry.count > 1 then
                deduped_lines = deduped_lines + 1
                entry.user_data = { fuzzy_match_count = entry.count }
            end
            entry.count = nil
            items[#items + 1] = entry
        end
    else
        for _, line in ipairs(lines) do
            local entry = parse.parse_vimgrep_line(line)
            if entry then
                items[#items + 1] = entry
            end
        end
    end

    local count = quickfix.update(items, {
        title = "FuzzyGrep",
        command = "FuzzyGrep",
    })
    return count, deduped_lines
end

local function run_fuzzy_grep(raw_args, dedupe_lines)
    runner.run_rg(raw_args, function(lines, status, err_lines)
        if status > 1 then
            local message_lines = (err_lines and #err_lines > 0) and err_lines or lines
            local message = table.concat(message_lines, "\n")
            vim.notify(message ~= "" and message or "FuzzyGrep: ripgrep failed.", vim.log.levels.ERROR)
            return
        end

        local count, deduped_lines = set_quickfix_from_lines(lines, dedupe_lines)
        if dedupe_lines and deduped_lines > 0 then
            vim.notify(string.format("FuzzyGrep!: collapsed duplicate matches on %d line%s.", deduped_lines, deduped_lines == 1 and "" or "s"), vim.log.levels.INFO)
        end
        quickfix.open_quickfix_when_results(count, dedupe_lines and "FuzzyGrep!: no matches found." or "FuzzyGrep: no matches found.")
    end)
end

return {
    run = run_fuzzy_grep,
}
