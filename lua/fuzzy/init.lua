local M = {}

function M.setup(opts)
    require("fuzzy.config").setup(opts)
    local config = require("fuzzy.config")
    local complete = require("fuzzy.complete")
    local quickfix = require("fuzzy.quickfix")

    local function cmd(name, fn, copts)
        vim.api.nvim_create_user_command(name, fn, copts)
        vim.api.nvim_create_user_command(name:gsub("^Fuzzy", ""), fn, vim.tbl_extend("force", copts, { desc = copts.desc .. " (alias)" }))
    end

    cmd("FuzzyGrepIn", function(o)
        local parse = require("fuzzy.parse")
        local dir_raw, rest_raw = parse.split_first(o.args)
        if not dir_raw then
            vim.notify("FuzzyGrepIn: provide a directory.", vim.log.levels.INFO)
            return
        end
        local dir = vim.fn.fnamemodify(vim.fn.expand(dir_raw), ":p"):gsub("[/\\]+$", "")
        local stat = vim.uv.fs_stat(dir)
        if not stat or stat.type ~= "directory" then
            vim.notify("FuzzyGrepIn: '" .. dir_raw .. "' is not a valid directory.", vim.log.levels.ERROR)
            return
        end
        if o.bang then
            local initial_query, initial_flags = parse.split_grep_picker_args(rest_raw)
            require("fuzzy.picker").open_for("grep_in", {
                dir = dir,
                initial_query = initial_query,
                initial_flags = initial_flags,
            })
        elseif rest_raw ~= "" then
            require("fuzzy.commands.grep_in").run(dir, rest_raw)
        else
            vim.notify("FuzzyGrepIn: provide a search pattern.", vim.log.levels.INFO)
        end
    end, { nargs = "+", bang = true, complete = "file", desc = "Run ripgrep in a specific directory" })

    cmd("FuzzyGrep", function(o)
        if o.bang then
            local parse = require("fuzzy.parse")
            local initial_query, initial_flags = parse.split_grep_picker_args(o.args)
            require("fuzzy.picker").open_for("grep", {
                initial_query = initial_query,
                initial_flags = initial_flags,
            })
        elseif o.args ~= "" then
            require("fuzzy.commands.grep").run(o.args)
        else
            vim.notify("FuzzyGrep: provide a search pattern.", vim.log.levels.INFO)
        end
    end, { nargs = "*", bang = true, complete = "file", desc = "Run ripgrep and open quickfix" })

    cmd("FuzzyFiles", function(o)
        if o.bang then
            require("fuzzy.picker").open_for("files", {
                initial_query = o.args ~= "" and o.args or nil,
            })
        else
            require("fuzzy.commands.files").run(o.args, false)
        end
    end, { nargs = "*", bang = true, complete = complete.make_file_completer(), desc = "Find files using fd" })

    cmd("FuzzyBuffers", function(o)
        if o.bang then
            require("fuzzy.picker").open_for("buffers", {
                initial_query = o.args ~= "" and o.args or nil,
            })
        else
            require("fuzzy.commands.buffers").run(o.args, false)
        end
    end, { nargs = "*", bang = true, complete = complete.make_buffer_completer(), desc = "Find open buffers" })

    cmd("FuzzyCommands", function(o)
        require("fuzzy.picker").open_for("commands", {
            initial_query = o.args ~= "" and o.args or nil,
        })
    end, { nargs = "*", complete = "command", desc = "Browse and stage commands" })

    cmd("FuzzyList", function(o)
        quickfix.select_from_history(o.bang)
    end, { bang = true, desc = "Pick quickfix from history" })

    vim.api.nvim_create_user_command("FuzzyNext", quickfix.cnext_cycle, { desc = "Next quickfix entry (cycles)" })
    vim.api.nvim_create_user_command("FuzzyPrev", quickfix.cprev_cycle, { desc = "Previous quickfix entry (cycles)" })
    vim.api.nvim_create_user_command("FuzzyHelp", function(o)
        require("fuzzy.picker").open_for("helptags", {
            initial_query = o.args ~= "" and o.args or nil,
        })
    end, { nargs = "*", complete = "help", desc = "Browse and open help tags" })

    -- Warm file completion cache asynchronously
    vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
        group = vim.api.nvim_create_augroup("FuzzyComplete", { clear = true }),
        callback = function() complete.warm_cache() end,
    })
end

function M.grep(args) require("fuzzy.commands.grep").run(args) end

function M.grep_in(dir, args)
    local expanded = vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("[/\\]+$", "")
    local stat = vim.uv.fs_stat(expanded)
    if not stat or stat.type ~= "directory" then
        vim.notify("fuzzy.grep_in: '" .. dir .. "' is not a valid directory.", vim.log.levels.ERROR)
        return
    end
    require("fuzzy.commands.grep_in").run(expanded, args)
end

return M
