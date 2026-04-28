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

    cmd("FuzzyGrep", function(o)
        if o.bang then
            require("fuzzy.picker").open_for("grep", {
                initial_query = o.args ~= "" and o.args or nil,
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

    cmd("FuzzyList", function(o)
        quickfix.select_from_history(o.bang)
    end, { bang = true, desc = "Pick quickfix from history" })

    vim.api.nvim_create_user_command("FuzzyNext", quickfix.cnext_cycle, { desc = "Next quickfix entry (cycles)" })
    vim.api.nvim_create_user_command("FuzzyPrev", quickfix.cprev_cycle, { desc = "Previous quickfix entry (cycles)" })

    -- Warm file completion cache asynchronously
    vim.api.nvim_create_autocmd({ "VimEnter", "DirChanged" }, {
        group = vim.api.nvim_create_augroup("FuzzyComplete", { clear = true }),
        callback = function() complete.warm_cache() end,
    })
end

function M.grep(args) require("fuzzy.commands.grep").run(args) end

return M
