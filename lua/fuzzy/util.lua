-- Shared utility functions

local M = {}

--- Normalize path using realpath or fs.normalize fallback
---@param path string
---@return string|nil
function M.normalize_path(path)
    if not path or path == "" then return nil end
    return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
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

--- Check if window is a quickfix window
---@param winid number
---@return boolean
function M.is_quickfix_window(winid)
    local ok, buf = pcall(vim.api.nvim_win_get_buf, winid)
    return ok and vim.bo[buf].buftype == "quickfix"
end

--- Switch to a normal window from quickfix, creating split if needed
function M.ensure_normal_window()
    if not M.is_quickfix_window(vim.api.nvim_get_current_win()) then
        return
    end
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if not M.is_quickfix_window(win) then
            vim.api.nvim_set_current_win(win)
            return
        end
    end
    vim.cmd.split()
end

return M
