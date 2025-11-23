local function prompt_input(prompt, default)
    vim.fn.inputsave()
    local ok, result = pcall(vim.fn.input, prompt, default or "")
    vim.fn.inputrestore()
    return ok and vim.trim(result) or ""
end

return {
    prompt_input = prompt_input,
}
