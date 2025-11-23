local config = require("fuzzy.config")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")

local function build_file_quickfix_items(files, match_limit)
    match_limit = match_limit or config.get_file_match_limit()
    local items = {}
    local first_file = nil

    for idx = 1, math.min(match_limit, #files) do
        local file = files[idx]
        if file ~= "" then
            first_file = first_file or file
            items[#items + 1] = {
                filename = file,
                lnum = 1,
                col = 1,
                text = file,
            }
        end
    end
    return items, first_file
end

local function set_quickfix_files(items)
    return quickfix.update(items, {
        title = "FuzzyFiles",
        command = "FuzzyFiles",
    })
end

local function open_single_file(first_file)
    -- If we're in a quickfix window, switch to a normal window first
    local wininfo_list = vim.fn.getwininfo(vim.fn.win_getid())
    local wininfo = wininfo_list and wininfo_list[1]
    if wininfo and wininfo.quickfix == 1 then
        -- Find a non-quickfix window to open the file in
        local found_normal_win = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
            local info_list = vim.fn.getwininfo(win)
            local info = info_list and info_list[1]
            if info and info.quickfix == 0 then
                vim.api.nvim_set_current_win(win)
                found_normal_win = true
                break
            end
        end
        -- If no normal window exists, create a split above quickfix
        if not found_normal_win then
            vim.cmd.wincmd("k") -- Try to go up
            -- If still in quickfix, create a new split
            local check_list = vim.fn.getwininfo(vim.fn.win_getid())
            local check_info = check_list and check_list[1]
            local still_qf = check_info and check_info.quickfix == 1
            if still_qf then
                vim.cmd.split()
            end
        end
    end

    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(first_file))
    if not ok then
        vim.notify(string.format("FuzzyFiles: failed to open '%s': %s", first_file, err), vim.log.levels.ERROR)
        return false
    end
    return true
end

local function run(raw_args, bang)
    runner.run_fd(raw_args, function(files, status, truncated, match_limit, err_lines)
        if status ~= 0 then
            local message_lines = (err_lines and #err_lines > 0) and err_lines or files
            local message = table.concat(message_lines, "\n")
            vim.notify(message ~= "" and message or "FuzzyFiles: failed to list files.", vim.log.levels.ERROR)
            return
        end

        local items, first_file = build_file_quickfix_items(files, match_limit)
        local count = #items
        local prefer_direct = (config.get().open_single_result or bang) and count == 1

        if prefer_direct and first_file then
            local opened = open_single_file(first_file)
            if opened then
                return
            end
        end

        local qf_count = set_quickfix_files(items)
        if truncated and match_limit then
            vim.notify(string.format("FuzzyFiles: showing first %d matches.", match_limit), vim.log.levels.INFO)
        end
        quickfix.open_quickfix_when_results(qf_count, "FuzzyFiles: no files matched.")
    end)
end

return {
    run = run,
}
