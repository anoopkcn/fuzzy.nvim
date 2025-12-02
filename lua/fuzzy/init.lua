-- LICENSE: MIT
-- by @anoopkcn
-- Description: Neovim fuzzy helpers for grep, files, and buffers that feed the quickfix list.
-- Provides commands:
--   :FuzzyGrep[!] [pattern] [rg options] - Runs ripgrep with the given pattern and populates the quickfix list with results.
--                                          Add ! to show greedy matches as seperate entries in the results.
--   :FuzzyFiles[!] [fd arguments]        - Runs fd with the supplied arguments (use --noignore to include gitignored files).
--                                          Add ! to open a single match directly.
--   :FuzzyBuffers[!] [pattern]           - Fuzzy find open buffers (! switches directly to single match).
--   :FuzzyList                           - Pick a quickfix list from history (excluding the selector itself) and open it.
--   :FuzzyNext                           - Go to next quickfix entry (cycles to first at end).
--   :FuzzyPrev                           - Go to previous quickfix entry (cycles to last at beginning).

local M = {}

local function create_alias(name, fn, opts)
    local alias_opts = vim.tbl_extend("force", {}, opts or {})
    if alias_opts.desc then
        alias_opts.desc = alias_opts.desc .. " (alias)"
    end
    vim.api.nvim_create_user_command(name, fn, alias_opts)
end

function M.setup(user_opts)
    require("fuzzy.config").setup(user_opts)

    local function run_fuzzy_grep(opts)
        local args = opts.args
        if args == "" then
            return
        end
        require("fuzzy.commands.grep").run(args, not opts.bang)
    end

    local function run_fuzzy_files(opts)
        local args = opts.args
        if args == "" then
            return
        end
        local raw_args = vim.trim(args or "")
        require("fuzzy.commands.files").run(raw_args, opts.bang)
    end

    local function run_fuzzy_buffers(opts)
        local raw_args = vim.trim(opts.args or "")
        require("fuzzy.commands.buffers").run(raw_args, opts.bang)
    end

    local function run_fuzzy_list()
        require("fuzzy.quickfix").select_from_history()
    end

    local grep_opts = {
        nargs = "*",
        desc = "Run ripgrep and open quickfix list with matches",
        bang = true,
        complete = "file",
    }
    vim.api.nvim_create_user_command("FuzzyGrep", run_fuzzy_grep, grep_opts)
    create_alias("Grep", run_fuzzy_grep, grep_opts)

    local files_opts = {
        nargs = "*",
        desc = "Fuzzy find files using fd (--noignore to include gitignored files, add ! to open a single match)",
        bang = true,
        complete = require("fuzzy.complete").make_file_completer(),
    }
    vim.api.nvim_create_user_command("FuzzyFiles", run_fuzzy_files, files_opts)
    create_alias("Files", run_fuzzy_files, files_opts)

    local buffers_opts = {
        nargs = "*",
        desc = "Fuzzy find open buffers (! switches directly to single match)",
        bang = true,
        complete = require("fuzzy.complete").make_buffer_completer(),
    }
    vim.api.nvim_create_user_command("FuzzyBuffers", run_fuzzy_buffers, buffers_opts)
    create_alias("Buffers", run_fuzzy_buffers, buffers_opts)

    local list_opts = {
        desc = "Pick a quickfix list from history and open it",
    }
    vim.api.nvim_create_user_command("FuzzyList", run_fuzzy_list, list_opts)
    create_alias("List", run_fuzzy_list, list_opts)

    local quickfix = require("fuzzy.quickfix")
    vim.api.nvim_create_user_command("FuzzyNext", quickfix.cnext_cycle, {
        desc = "Go to next quickfix entry (cycles to first at end)",
    })
    vim.api.nvim_create_user_command("FuzzyPrev", quickfix.cprev_cycle, {
        desc = "Go to previous quickfix entry (cycles to last at beginning)",
    })

    -- Interactive picker commands
    local picker = require("fuzzy.picker")
    local runner = require("fuzzy.runner")

    local function run_files_interactive()
        runner.run_fd({}, function(files)
            vim.schedule(function()
                picker.open({
                    source = files,
                    title = " Files ",
                    on_select = function(file)
                        if file and file ~= "" then
                            vim.cmd("edit " .. vim.fn.fnameescape(file))
                        end
                    end,
                })
            end)
        end)
    end

    local function run_grep_interactive()
        picker.open({
            title = " Grep ",
            filter_locally = false,
            debounce_ms = 200,
            source = function(query, callback)
                if query == "" then
                    callback({})
                    return
                end
                runner.run_rg(query, function(lines, status)
                    local items = {}
                    for _, line in ipairs(lines or {}) do
                        if line ~= "" then
                            items[#items + 1] = line
                        end
                    end
                    callback(items)
                end)
            end,
            on_select = function(item)
                if not item or item == "" then
                    return
                end
                local parsed = require("fuzzy.parse").parse_vimgrep_line(item)
                if parsed then
                    vim.cmd("edit " .. vim.fn.fnameescape(parsed.filename))
                    vim.api.nvim_win_set_cursor(0, { parsed.lnum, (parsed.col or 1) - 1 })
                end
            end,
        })
    end

    local function run_buffers_interactive()
        local buffers = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted and vim.bo[buf].buftype == "" then
                local name = vim.api.nvim_buf_get_name(buf)
                if name ~= "" then
                    buffers[#buffers + 1] = vim.fn.fnamemodify(name, ":.")
                end
            end
        end
        picker.open({
            source = buffers,
            title = " Buffers ",
            on_select = function(file)
                if file and file ~= "" then
                    vim.cmd("edit " .. vim.fn.fnameescape(file))
                end
            end,
        })
    end

    vim.api.nvim_create_user_command("FuzzyFilesI", run_files_interactive, {
        desc = "Interactive fuzzy file picker",
    })
    create_alias("FilesI", run_files_interactive, { desc = "Interactive fuzzy file picker" })

    vim.api.nvim_create_user_command("FuzzyGrepI", run_grep_interactive, {
        desc = "Interactive grep with live results",
    })
    create_alias("GrepI", run_grep_interactive, { desc = "Interactive grep with live results" })

    vim.api.nvim_create_user_command("FuzzyBuffersI", run_buffers_interactive, {
        desc = "Interactive buffer picker",
    })
    create_alias("BuffersI", run_buffers_interactive, { desc = "Interactive buffer picker" })
end

function M.grep(args, dedupe_lines)
    require("fuzzy.commands.grep").run(args, dedupe_lines)
end

-- Expose picker for custom interactive pickers
M.pick = function(opts)
    require("fuzzy.picker").open(opts)
end

return M
