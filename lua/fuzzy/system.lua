--- Run command asynchronously and collect output lines
---@param cmd string[] Command and arguments
---@param callback fun(lines: string[], code: integer, stderr: string[])
---@param opts? { cwd?: string }
---@return vim.SystemObj|nil handle
local function run(cmd, callback, opts)
    local stdout, stderr = {}, {}
    local out_buf, err_buf = "", ""

    local function collect(buf, acc, data)
        if not data then return buf end
        local lines = vim.split(buf .. data, "\n", { plain = true })
        buf = table.remove(lines) or ""
        for _, line in ipairs(lines) do
            if line ~= "" then acc[#acc + 1] = line end
        end
        return buf
    end

    opts = opts or {}
    local handle, err = vim.system(cmd, {
        text = true,
        cwd = opts.cwd,
        stdout = function(_, data) out_buf = collect(out_buf, stdout, data) end,
        stderr = function(_, data) err_buf = collect(err_buf, stderr, data) end,
    }, function(obj)
        if out_buf ~= "" then stdout[#stdout + 1] = out_buf end
        if err_buf ~= "" then stderr[#stderr + 1] = err_buf end
        vim.schedule(function() callback(stdout, obj.code or 0, stderr) end)
    end)

    if not handle then
        vim.schedule(function()
            vim.notify("Fuzzy: " .. (err or "command failed"), vim.log.levels.ERROR)
            callback({}, 1, {})
        end)
    end
    return handle
end

return { run = run }
