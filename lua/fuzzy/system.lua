local function system_lines(command, callback)
    local handle, err = vim.system(command, { text = true }, function(obj)
        local stdout_lines = vim.split(obj.stdout or "", "\n", { trimempty = true })
        local stderr_lines = vim.split(obj.stderr or "", "\n", { trimempty = true })
        vim.schedule(function()
            callback(stdout_lines, obj.code or 0, stderr_lines)
        end)
    end)

    if not handle then
        vim.schedule(function()
            vim.notify(string.format("Fuzzy: failed to start command: %s", err or "unknown"), vim.log.levels.ERROR)
            callback({ err or "failed to execute command" }, 1, {})
        end)
    end
end

return {
    system_lines = system_lines,
}
