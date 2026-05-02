local git = require("fuzzy.git")

local M = {}

M.prompt = "Git Worktrees"
M.empty_message = "FuzzyGitWorktrees: no worktrees found."
M.highlight_paths = false

local function display_path(path)
    return vim.fn.fnamemodify(path or "", ":~")
end

local function short_branch(ref)
    if not ref or ref == "" then return "" end
    return ref:gsub("^refs/heads/", ""):gsub("^refs/remotes/", "")
end

local function finalize_entry(entry, items, current_root)
    if not entry or not entry.path or entry.path == "" then return end
    entry.branch = short_branch(entry.branch)
    entry.detached = entry.detached == true or entry.branch == ""
    entry.current = current_root ~= nil and vim.fs.normalize(entry.path) == current_root
    items[#items + 1] = entry
end

local function parse_porcelain(stdout, current_root)
    local items = {}
    local entry = nil

    for _, line in ipairs(vim.split(stdout or "", "\n", { plain = true })) do
        if line == "" then
            finalize_entry(entry, items, current_root)
            entry = nil
        else
            local key, value = line:match("^(%S+)%s*(.*)$")
            if key == "worktree" then
                finalize_entry(entry, items, current_root)
                entry = { path = value }
            elseif entry then
                if key == "HEAD" then
                    entry.head = value
                elseif key == "branch" then
                    entry.branch = value
                elseif key == "detached" then
                    entry.detached = true
                elseif key == "bare" then
                    entry.bare = true
                elseif key == "prunable" then
                    entry.prunable = value ~= "" and value or true
                end
            end
        end
    end

    finalize_entry(entry, items, current_root)
    return items
end

function M.collect(callback)
    git.ensure_repo(function(ok)
        if not ok then return end

        git.toplevel(function(root)
            local current_root = root and vim.fs.normalize(root) or nil
            git.run({ "worktree", "list", "--porcelain" }, {}, function(result)
                if result.code ~= 0 then
                    git.notify_error("FuzzyGitWorktrees", result)
                    return
                end

                callback(parse_porcelain(result.stdout, current_root))
            end)
        end)
    end)
end

function M.format_entry(entry, _, width)
    local marker = entry.current and "*" or " "
    local name
    if entry.bare then
        name = "bare"
    elseif entry.detached then
        name = entry.head and entry.head:sub(1, 12) or "detached"
    else
        name = entry.branch or ""
    end

    local state = entry.prunable and "prunable" or (entry.bare and "bare" or (entry.detached and "detached" or "branch"))
    local text = ("%s %-32s %-10s %s"):format(marker, display_path(entry.path), state, name)
    if width and #text > width then
        text = text:sub(1, math.max(0, width - 1)) .. "…"
    end
    return text
end

function M.filter_text(entry)
    return table.concat({
        entry.path or "",
        display_path(entry.path),
        entry.branch or "",
        entry.head or "",
        entry.bare and "bare" or "",
        entry.detached and "detached" or "",
        entry.prunable and "prunable" or "",
    }, " ")
end

function M.select(entry, callback)
    if not entry or not entry.path or entry.path == "" then return end

    if entry.current then
        vim.notify("FuzzyGitWorktrees: already in " .. display_path(entry.path), vim.log.levels.INFO)
        if callback then callback(true) end
        return
    end

    local ok, err = pcall(vim.cmd.cd, vim.fn.fnameescape(entry.path))
    if not ok then
        vim.notify("FuzzyGitWorktrees: " .. tostring(err), vim.log.levels.ERROR)
        if callback then callback(false, err) end
        return
    end

    vim.notify("FuzzyGitWorktrees: switched to " .. display_path(entry.path), vim.log.levels.INFO)
    if callback then callback(true) end
end

return M
