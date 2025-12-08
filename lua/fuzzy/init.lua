local M = {}

function M.setup(opts)
    require("fuzzy.config").setup(opts)
    local complete = require("fuzzy.complete")
    local quickfix = require("fuzzy.quickfix")

    local function cmd(name, fn, copts)
        vim.api.nvim_create_user_command(name, fn, copts)
        vim.api.nvim_create_user_command(name:gsub("^Fuzzy", ""), fn, vim.tbl_extend("force", copts, { desc = copts.desc .. " (alias)" }))
    end

    cmd("FuzzyGrep", function(o)
        if o.args ~= "" then require("fuzzy.commands.grep").run(o.args, not o.bang) end
    end, { nargs = "*", bang = true, complete = "file", desc = "Run ripgrep and open quickfix" })

    cmd("FuzzyFiles", function(o)
        if o.args ~= "" then require("fuzzy.commands.files").run(o.args, o.bang) end
    end, { nargs = "*", bang = true, complete = complete.make_file_completer(), desc = "Find files using fd" })

    cmd("FuzzyBuffers", function(o)
        require("fuzzy.commands.buffers").run(o.args, o.bang)
    end, { nargs = "*", bang = true, complete = complete.make_buffer_completer(), desc = "Find open buffers" })

    cmd("FuzzyList", quickfix.select_from_history, { desc = "Pick quickfix from history" })

    vim.api.nvim_create_user_command("FuzzyNext", quickfix.cnext_cycle, { desc = "Next quickfix entry (cycles)" })
    vim.api.nvim_create_user_command("FuzzyPrev", quickfix.cprev_cycle, { desc = "Previous quickfix entry (cycles)" })
end

function M.grep(args, dedupe) require("fuzzy.commands.grep").run(args, dedupe) end

return M
