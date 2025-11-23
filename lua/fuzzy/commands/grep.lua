local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")

local function set_quickfix_from_lines(lines)
    local items = {}
    for _, line in ipairs(lines) do
        local entry = parse.parse_vimgrep_line(line)
        if entry then
            items[#items + 1] = entry
        end
    end
    return quickfix.update(items, {
        title = "FuzzyGrep",
        command = "FuzzyGrep",
    })
end

local function run_fuzzy_grep(raw_args)
    runner.run_rg(raw_args, function(lines, status, err_lines)
        if status > 1 then
            local message_lines = (err_lines and #err_lines > 0) and err_lines or lines
            local message = table.concat(message_lines, "\n")
            vim.notify(message ~= "" and message or "FuzzyGrep: ripgrep failed.", vim.log.levels.ERROR)
            return
        end

        local count = set_quickfix_from_lines(lines)
        quickfix.open_quickfix_when_results(count, "FuzzyGrep: no matches found.")
    end)
end

return {
    run = run_fuzzy_grep,
}
