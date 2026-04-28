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
        if o.args ~= "" then
            require("fuzzy.commands.grep").run(o.args, not o.bang)
        else
            require("fuzzy.picker").open_for("grep", { bang = o.bang })
        end
    end, { nargs = "*", bang = true, complete = "file", desc = "Run ripgrep and open quickfix" })

    cmd("FuzzyFiles", function(o)
        if o.args ~= "" then
            require("fuzzy.commands.files").run(o.args, o.bang)
        else
            require("fuzzy.picker").open_for("files")
        end
    end, { nargs = "*", bang = true, complete = complete.make_file_completer(), desc = "Find files using fd" })

    cmd("FuzzyBuffers", function(o)
        if o.args == "" then
            require("fuzzy.picker").open_for("buffers")
        else
            require("fuzzy.commands.buffers").run(o.args, o.bang)
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

    -- <Tab> on `:Grep ` / `:Files ` / `:Buffers ` (empty arg-lead) opens a live fuzzy picker
    if config.get().cmdline_tab_picker then
        vim.keymap.set("c", "<Tab>", function()
            if vim.fn.getcmdtype() ~= ":" then return "<Tab>" end
            local cname, bang, rest = vim.fn.getcmdline():match("^%s*(%a+)(!?)%s+(.*)$")
            if not cname then return "<Tab>" end
            local lower = cname:lower()
            local kind
            if lower == "grep" or lower == "fuzzygrep" then
                kind = "grep"
            elseif lower == "files" or lower == "fuzzyfiles" then
                kind = "files"
            elseif lower == "buffers" or lower == "fuzzybuffers" then
                kind = "buffers"
            end
            if not kind or rest ~= "" then return "<Tab>" end
            vim.schedule(function() require("fuzzy.picker").open_for(kind, { bang = bang == "!" }) end)
            return "<C-c>"
        end, { expr = true, desc = "Fuzzy picker for :Grep / :Files / :Buffers" })
    end
end

function M.grep(args, dedupe) require("fuzzy.commands.grep").run(args, dedupe) end

return M
