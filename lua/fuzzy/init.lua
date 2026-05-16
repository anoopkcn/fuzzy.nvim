local M = {}

function M.setup(opts)
    require("fuzzy.config").setup(opts)
    local complete = require("fuzzy.complete")
    local quickfix = require("fuzzy.quickfix")

    local function cmd(name, fn, copts)
        vim.api.nvim_create_user_command(name, fn, copts)
    end

    local function git_cmd(name, kind, desc)
        vim.api.nvim_create_user_command("FuzzyGit" .. name, function(o)
            require("fuzzy.picker").open_for(kind, {
                initial_query = o.args ~= "" and o.args or nil,
            })
        end, {
            nargs = "*",
            complete = nil,
            desc = desc,
        })
    end

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
            local parse = require("fuzzy.parse")
            local initial_query, initial_flags = parse.split_fd_picker_args(o.args)
            require("fuzzy.picker").open_for("files", {
                initial_query = initial_query,
                initial_flags = initial_flags,
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

    cmd("FuzzyMap", function(o)
        require("fuzzy.picker").open_for("keymaps", {
            initial_query = o.args ~= "" and o.args or nil,
        })
    end, { nargs = "*", desc = "Browse keymaps (global + buffer-local, all modes)" })

    cmd("FuzzyList", function(o)
        require("fuzzy.picker").open_for("qflist", { fuzzy_only = o.bang })
    end, { bang = true, desc = "Pick quickfix from history" })

    git_cmd("Branches", "git_branches", "Browse and switch Git branches")
    git_cmd("Worktrees", "git_worktrees", "Browse and switch Git worktrees")

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

return M
