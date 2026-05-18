local complete = require("fuzzy.complete")
local config = require("fuzzy.config")
local live_grep = require("fuzzy.picker.live_grep")
local parse = require("fuzzy.parse")
local quickfix = require("fuzzy.quickfix")
local runner = require("fuzzy.runner")
local util = require("fuzzy.util")
local HL = require("fuzzy.picker.highlight").HL

local M = {}

-- Render each path as "<basename>  <relative_dir>", omitting the dir part
-- when the file sits in cwd root. Fuzzy filtering still runs against the
-- full path (see `filter_text` below) so a query like "lua/match" still
-- selects `lua/fuzzy/match.lua` despite the inline-name display.
local function files_format_item(item)
    local name = vim.fn.fnamemodify(item, ":t")
    local dir = vim.fn.fnamemodify(item, ":h")
    if dir == "." or dir == "" or dir == name then return name end
    return ("%s  %s"):format(name, dir)
end

local function files_row_highlight(buf, ns, row, item, text, _ctx, prefix_len)
    local name_len = #vim.fn.fnamemodify(item, ":t")
    if name_len + 2 >= #text then return end  -- root file: no dir suffix
    vim.api.nvim_buf_set_extmark(buf, ns, row, prefix_len + name_len + 2, {
        end_col  = prefix_len + #text,
        hl_group = HL.dir,
        priority = 100,
    })
end

---@param opts { initial_query?: string, initial_flags?: string[] }
---@param picker_open fun(opts: table): table
function M.open(opts, picker_open)
    local files_flags = parse.normalize(opts.initial_flags or {})

    local function format_flags() return parse.join(files_flags) end
    local function files_title()
        local f = format_flags()
        return (f == "") and "Files" or ("Files [" .. f .. "]")
    end

    -- Match complete.get_files_sync's --type f default. Only inject when the
    -- user hasn't set their own -t/--type, so e.g. `-t d` works as expected.
    local function build_fd_args()
        local args = {}
        local has_type = false
        for i = 1, #files_flags do
            args[i] = files_flags[i]
            if files_flags[i] == "-t" or files_flags[i] == "--type"
                or files_flags[i]:match("^%-%-type=") then
                has_type = true
            end
        end
        if not has_type then
            args[#args + 1] = "--type"
            args[#args + 1] = "f"
        end
        return args
    end

    local show_dir = config.get().files_show_parent_dir ~= false

    local function run_fd(picker)
        if picker.is_closed() then return end
        picker.set_loading(true)
        runner.fd(build_fd_args(), function(results, code, truncated, _limit, stderr)
            vim.schedule(function()
                if picker.is_closed() then return end
                picker.set_loading(false)
                if code ~= 0 then
                    local msg = (stderr and stderr[1])
                        or ("fd exited with code " .. code)
                    vim.notify("FuzzyFiles: " .. msg, vim.log.levels.ERROR)
                    picker.set_items({})
                    return
                end
                picker.set_items(results)
                if truncated then
                    vim.notify("FuzzyFiles: results truncated.", vim.log.levels.WARN)
                end
            end)
        end, vim.fn.getcwd())
    end

    local initial_items
    if #files_flags == 0 then
        initial_items = complete.get_files_sync() or {}
        if #initial_items == 0 then
            vim.notify("Fuzzy: no files found in cwd.", vim.log.levels.INFO)
            return
        end
    else
        initial_items = {}
    end

    local picker_opts = {
        items = initial_items,
        prompt = "Files",
        title = files_title(),
        initial_query = opts.initial_query,
        highlight_paths = false,
        preview_source = {
            kind = "file",
            resolve = function(p)
                if type(p) ~= "string" or p == "" then return nil end
                return { path = vim.fn.fnamemodify(p, ":p") }
            end,
        },
        on_select = function(path) util.open_file(path) end,
        on_marked = function(marked_items, picked_item)
            util.load_files(marked_items)
            local target = live_grep.pick_marked_target(marked_items, picked_item, function(item) return item end)
            if target then util.open_file(target) end
        end,
        on_quickfix = function(visible_items)
            if #visible_items == 0 then
                vim.notify("Fuzzy: no items to send to quickfix.", vim.log.levels.INFO)
                return
            end
            local qf_items = {}
            for i = 1, #visible_items do
                local path = visible_items[i]
                qf_items[i] = { filename = vim.fn.fnamemodify(path, ":p"), lnum = 1, col = 1, text = path }
            end
            quickfix.update(qf_items, { title = "FuzzyFiles", command = "FuzzyFiles" })
            quickfix.open_if_results(#qf_items)
        end,
        on_setup = function(picker, imap)
            if #files_flags > 0 then run_fd(picker) end
            local edit_key = config.get().edit_files_flags_key
            if not edit_key or edit_key == "" then return end
            imap(edit_key, function()
                vim.ui.input({
                    prompt = "fd flags: ",
                    default = format_flags(),
                }, function(input)
                    vim.schedule(function()
                        if picker.is_closed() then return end
                        if input ~= nil then
                            files_flags = parse.normalize(input)
                            picker.set_title(files_title())
                            run_fd(picker)
                        end
                        vim.cmd("startinsert!")
                    end)
                end)
            end)
        end,
    }

    if show_dir then
        picker_opts.filter_text = function(item) return item end
        picker_opts.format_item = files_format_item
        picker_opts.row_highlight = files_row_highlight
    end

    return picker_open(picker_opts)
end

return M
