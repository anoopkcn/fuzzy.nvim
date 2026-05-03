-- Highlight group names and default links used by the picker UI.
-- Centralised so the rest of the picker code can stay focused on logic.

local M = {}

M.HL = {
    normal        = "FuzzyPickerNormal",
    border        = "FuzzyPickerBorder",
    title         = "FuzzyPickerTitle",
    count         = "FuzzyPickerCount",
    prompt        = "FuzzyPickerPrompt",
    cursor        = "FuzzyPickerCursor",
    hint          = "FuzzyPickerHint",
    sel           = "FuzzyPickerSelection",
    match         = "FuzzyPickerMatch",
    dir           = "FuzzyPickerDir",
    file          = "FuzzyPickerFile",
    selected      = "FuzzyPickerSelected",
    paletteLabel  = "FuzzyPickerPaletteLabel",
    paletteName   = "FuzzyPickerPaletteName",
    paletteAlias  = "FuzzyPickerPaletteAlias",
    paletteDetail = "FuzzyPickerPaletteDetail",
    paletteSep    = "FuzzyPickerPaletteSep",
}

M.WINHL         = ("Normal:%s,FloatBorder:%s,FloatTitle:%s"):format(M.HL.normal, M.HL.border, M.HL.title)
M.CONTENT_WINHL = ("Normal:%s"):format(M.HL.normal)

local function set_default_hl(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
end

set_default_hl(M.HL.normal,        "NormalFloat")
set_default_hl(M.HL.border,        "FloatBorder")
set_default_hl(M.HL.title,         "FloatTitle")
set_default_hl(M.HL.count,         "Comment")
set_default_hl(M.HL.prompt,        "Function")
set_default_hl(M.HL.cursor,        "CursorLineNr")
set_default_hl(M.HL.hint,          "Comment")
set_default_hl(M.HL.sel,           "PmenuSel")
set_default_hl(M.HL.match,         "IncSearch")
set_default_hl(M.HL.dir,           "Comment")
set_default_hl(M.HL.file,          "Normal")
set_default_hl(M.HL.selected,      "DiagnosticOk")
set_default_hl(M.HL.paletteLabel,  "Type")
set_default_hl(M.HL.paletteName,   "Function")
set_default_hl(M.HL.paletteAlias,  "Constant")
set_default_hl(M.HL.paletteDetail, "Comment")
set_default_hl(M.HL.paletteSep,    "Comment")

return M
