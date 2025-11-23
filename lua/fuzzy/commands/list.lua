local quickfix = require("fuzzy.quickfix")

local function run()
    quickfix.select_from_history()
end

return {
    run = run,
}
