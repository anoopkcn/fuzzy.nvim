-- Shared utility functions

local M = {}

--- Normalize path using realpath or fs.normalize fallback
---@param path string
---@return string|nil
function M.normalize_path(path)
    if not path or path == "" then return nil end
    return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Get all listed, loaded buffers with names
---@return { bufnr: integer, path: string }[]
function M.get_listed_buffers()
    local bufs = {}
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" then bufs[#bufs + 1] = { bufnr = buf, path = name } end
        end
    end
    return bufs
end

--- Find buffer by path (exact or normalized match)
---@param path string
---@param opts? { listed?: boolean, loaded?: boolean }
---@return integer|nil bufnr
function M.find_buffer_by_path(path, opts)
    opts = opts or {}
    local norm = M.normalize_path(path)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf)
            and (opts.listed ~= true or vim.bo[buf].buflisted)
            and (opts.loaded ~= true or vim.api.nvim_buf_is_loaded(buf))
        then
            local name = vim.api.nvim_buf_get_name(buf)
            if name ~= "" and (name == path or M.normalize_path(name) == norm) then
                return buf
            end
        end
    end
end

--- Join path with optional root directory
---@param path string
---@param root? string
---@return string
function M.with_root(path, root)
    return root and vim.fs.joinpath(root, path) or path
end

--- Get netrw directory if current buffer is netrw, otherwise nil
---@return string|nil
function M.get_netrw_dir()
    if vim.bo.filetype == "netrw" then
        local dir = vim.b.netrw_curdir
        if dir and dir ~= "" then
            return dir
        end
    end
    return nil
end

--- Open a file: switch to existing buffer if loaded, else :edit
---@param path string
---@return boolean success
function M.open_file(path)
    local buf = M.find_buffer_by_path(path)
    if buf and vim.api.nvim_buf_is_valid(buf) then
        local ok = M.switch_to_buffer(buf)
        if not ok then vim.notify("Fuzzy: failed to switch to buffer.", vim.log.levels.ERROR) end
        return ok
    end
    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then vim.notify(("Fuzzy: %s"):format(err), vim.log.levels.ERROR) end
    return ok
end

--- Load files as buffers without switching to them.
---@param paths string[]
---@return boolean success
function M.load_files(paths)
    local seen = {}
    local ok_all = true

    for _, path in ipairs(paths or {}) do
        if type(path) == "string" and path ~= "" then
            local abs = vim.fn.fnamemodify(path, ":p")
            local key = M.normalize_path(abs) or abs
            if not seen[key] then
                seen[key] = true
                local buf = M.find_buffer_by_path(abs)
                if not buf then
                    local ok, err = pcall(vim.cmd, "badd " .. vim.fn.fnameescape(abs))
                    if not ok then
                        ok_all = false
                        vim.notify(("Fuzzy: %s"):format(err), vim.log.levels.ERROR)
                    end
                    buf = M.find_buffer_by_path(abs)
                end
                if not buf or buf <= 0 then
                    ok_all = false
                    vim.notify(("Fuzzy: failed to add buffer for %s"):format(abs), vim.log.levels.ERROR)
                else
                    vim.bo[buf].buflisted = true
                    if not vim.api.nvim_buf_is_loaded(buf) then
                        local ok, err = pcall(vim.fn.bufload, buf)
                        if not ok then
                            ok_all = false
                            vim.notify(("Fuzzy: %s"):format(err), vim.log.levels.ERROR)
                        end
                    end
                end
            end
        end
    end

    return ok_all
end

--- Switch to a buffer, reusing existing window if visible
---@param bufnr integer
---@return boolean success
function M.switch_to_buffer(bufnr)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            vim.api.nvim_set_current_win(win)
            return true
        end
    end
    return pcall(vim.api.nvim_set_current_buf, bufnr)
end

return M
