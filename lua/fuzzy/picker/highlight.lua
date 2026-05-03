-- Highlight group names and default links used by the picker UI.
-- Centralised so the rest of the picker code can stay focused on logic.

local M = {}

M.HL = {
    normal        = "FuzzyPickerNormal",
    border        = "FuzzyPickerBorder",
    title         = "FuzzyPickerTitle",
    sel           = "FuzzyPickerSelection",
    match         = "FuzzyPickerMatch",
    dir           = "FuzzyPickerDir",
    file          = "FuzzyPickerFile",
    selected      = "FuzzyPickerSelected",
    paletteLabel  = "FuzzyPickerPaletteLabel",
    paletteName   = "FuzzyPickerPaletteName",
    paletteAlias  = "FuzzyPickerPaletteAlias",
    paletteDetail = "FuzzyPickerPaletteDetail",
}

M.WINHL         = ("Normal:%s,FloatBorder:%s,FloatTitle:%s"):format(M.HL.normal, M.HL.border, M.HL.title)
M.CONTENT_WINHL = ("Normal:%s"):format(M.HL.normal)

local function set_default_hl(name, link)
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
end

set_default_hl(M.HL.normal,        "NormalFloat")
set_default_hl(M.HL.border,        "FloatBorder")
set_default_hl(M.HL.title,         "FloatTitle")
set_default_hl(M.HL.sel,           "PmenuSel")
set_default_hl(M.HL.match,         "Special")
set_default_hl(M.HL.dir,           "Comment")
set_default_hl(M.HL.file,          "Normal")
set_default_hl(M.HL.selected,      "Statement")
set_default_hl(M.HL.paletteLabel,  "Type")
set_default_hl(M.HL.paletteName,   "Function")
set_default_hl(M.HL.paletteAlias,  "Identifier")
set_default_hl(M.HL.paletteDetail, "Comment")

return M
