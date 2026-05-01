local git = require("fuzzy.git")

local M = {}

M.prompt = "Git Branches"
M.empty_message = "FuzzyGitBranches: no branches found."
M.highlight_paths = false

local function normalize_remote_name(name)
    return (name or ""):gsub("^remotes/", "")
end

local function parse_line(line)
    local fields = vim.split(line, "\t", { plain = true })
    local head = fields[1] or ""
    local refname = fields[2] or ""
    local short = fields[3] or ""
    local upstream = fields[4] or ""
    local sha = fields[5] or ""

    if short == "" then return nil end

    local kind
    local name = short
    if refname:match("^refs/heads/") then
        kind = "local"
    elseif refname:match("^refs/remotes/") then
        kind = "remote"
        name = normalize_remote_name(short)
    else
        -- Fallback for older or unusual Git output.
        if short:match("^remotes/") then
            kind = "remote"
            name = normalize_remote_name(short)
        else
            kind = "local"
        end
    end

    if name == "" or name:match("/HEAD$") then return nil end

    return {
        name = name,
        kind = kind,
        current = head == "*",
        upstream = normalize_remote_name(upstream),
        sha = sha,
    }
end

function M.collect(callback)
    git.ensure_repo(function(ok)
        if not ok then return end

        git.run({
            "branch",
            "--all",
            "--format=%(HEAD)%09%(refname)%09%(refname:short)%09%(upstream:short)%09%(objectname:short)",
        }, {}, function(result)
            if result.code ~= 0 then
                git.notify_error("FuzzyGitBranches", result)
                return
            end

            local items = {}
            local seen = {}
            for _, line in ipairs(vim.split(result.stdout or "", "\n", { plain = true })) do
                if line ~= "" then
                    local entry = parse_line(line)
                    if entry then
                        local key = entry.kind .. ":" .. entry.name
                        if not seen[key] then
                            seen[key] = true
                            items[#items + 1] = entry
                        end
                    end
                end
            end
            callback(items)
        end)
    end)
end

function M.format_entry(entry, _, width)
    local marker = entry.current and "*" or " "
    local text = ("%s %-24s %-10s"):format(marker, entry.name, entry.kind)
    if entry.upstream and entry.upstream ~= "" then
        text = text .. " " .. entry.upstream
    end
    if width and #text > width then
        text = text:sub(1, math.max(0, width - 1)) .. "…"
    end
    return text
end

function M.filter_text(entry)
    return table.concat({
        entry.name or "",
        entry.kind or "",
        entry.upstream or "",
        entry.sha or "",
    }, " ")
end

function M.select(entry, callback)
    if not entry then return end

    if entry.current then
        vim.notify("FuzzyGitBranches: already on " .. entry.name, vim.log.levels.INFO)
        if callback then callback(true) end
        return
    end

    local args
    if entry.kind == "remote" then
        args = { "switch", "--track", entry.name }
    else
        args = { "switch", entry.name }
    end

    git.run(args, {}, function(result)
        if result.code ~= 0 then
            git.notify_error("FuzzyGitBranches", result)
            if callback then callback(false, result) end
            return
        end
        vim.notify("FuzzyGitBranches: switched to " .. entry.name, vim.log.levels.INFO)
        if callback then callback(true, result) end
    end)
end

return M
