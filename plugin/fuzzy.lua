-- plugin/fuzzy.lua — registers :Fuzzy* commands lazily.
-- Loaded automatically by Neovim on startup; calling require("fuzzy").setup()
-- is optional and only needed to override config defaults.

if vim.g.loaded_fuzzy == 1 then return end
vim.g.loaded_fuzzy = 1

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
end, {
    nargs = "*", bang = true,
    complete = function(a) return require("fuzzy.complete").complete_files(a) end,
    desc = "Find files using fd",
})

cmd("FuzzyBuffers", function(o)
    if o.bang then
        require("fuzzy.picker").open_for("buffers", {
            initial_query = o.args ~= "" and o.args or nil,
        })
    else
        require("fuzzy.commands.buffers").run(o.args, false)
    end
end, {
    nargs = "*", bang = true,
    complete = function(a) return require("fuzzy.complete").complete_buffers(a) end,
    desc = "Find open buffers",
})

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

cmd("FuzzyJumps", function(o)
    require("fuzzy.picker").open_for("jumps", {
        initial_query = o.args ~= "" and o.args or nil,
    })
end, { nargs = "*", desc = "Browse the jump list" })

cmd("FuzzyMarks", function(o)
    require("fuzzy.picker").open_for("marks", {
        initial_query = o.args ~= "" and o.args or nil,
    })
end, { nargs = "*", desc = "Browse marks (global + buffer-local)" })

cmd("FuzzyReg", function(o)
    require("fuzzy.picker").open_for("registers", {
        initial_query = o.args ~= "" and o.args or nil,
    })
end, { nargs = "*", desc = "Browse registers (CR copies to system clipboard)" })

cmd("FuzzyLspSymbols", function(o)
    if o.bang then
        require("fuzzy.picker").open_for("lsp_symbols", {
            initial_query = o.args ~= "" and o.args or nil,
        })
    else
        require("fuzzy.commands.lsp_symbols").run(o.args)
    end
end, { nargs = "*", bang = true, desc = "LSP document symbols (current buffer)" })

cmd("FuzzyLspProjectSymbols", function(o)
    if o.bang then
        require("fuzzy.picker").open_for("lsp_project_symbols", {
            initial_query = o.args ~= "" and o.args or nil,
        })
    else
        require("fuzzy.commands.lsp_project_symbols").run(o.args)
    end
end, { nargs = "*", bang = true, desc = "LSP workspace symbols (project)" })

cmd("FuzzyList", function(o)
    require("fuzzy.picker").open_for("qflist", { fuzzy_only = o.bang })
end, { bang = true, desc = "Pick quickfix from history" })

git_cmd("Branches", "git_branches", "Browse and switch Git branches")
git_cmd("Worktrees", "git_worktrees", "Browse and switch Git worktrees")

cmd("FuzzyNext", function() require("fuzzy.quickfix").cnext_cycle() end,
    { desc = "Next quickfix entry (cycles)" })
cmd("FuzzyPrev", function() require("fuzzy.quickfix").cprev_cycle() end,
    { desc = "Previous quickfix entry (cycles)" })
cmd("FuzzyHelp", function(o)
    require("fuzzy.picker").open_for("helptags", {
        initial_query = o.args ~= "" and o.args or nil,
    })
end, { nargs = "*", complete = "help", desc = "Browse and open help tags" })

-- Warm the file completion cache on startup / cwd change so :FuzzyFiles<Tab>
-- is responsive on first use. Opt out with `vim.g.fuzzy_warm_cache = false`
-- set before this file is sourced.
if vim.g.fuzzy_warm_cache ~= false then
    vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
        group = vim.api.nvim_create_augroup("FuzzyComplete", { clear = true }),
        callback = function()
            pcall(function() require("fuzzy.complete").warm_cache() end)
        end,
    })
end

-- Re-apply syntax highlights when a quickfix window is (re)entered:
-- covers :cclose/:copen, switching to it from another window, and
-- :colder/:cnewer (which fire BufWinEnter on the qf buffer). The early
-- buftype guard keeps the hook free in non-qf buffers.
vim.api.nvim_create_autocmd("BufWinEnter", {
    group = vim.api.nvim_create_augroup("FuzzyQfHighlight", { clear = true }),
    callback = function(args)
        if vim.bo[args.buf].buftype ~= "quickfix" then return end
        pcall(function() require("fuzzy.qf_highlight").maybe_refresh() end)
    end,
})
