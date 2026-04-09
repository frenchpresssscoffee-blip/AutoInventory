AutoInventory = AutoInventory or {}
local AI = AutoInventory

local function BuildCategoryDescriptionText()
    local lines = {
        "Right-click items in your inventory to set their category:",
        "",
        "|cD2C79AKeep|r - Items you intentionally want to keep in your normal inventory flow",
        "|c5E9CC6Bank|r - Automatically deposit to bank",
        "|c7AA57APull From Bank|r - Mark banked items to come back into your backpack",
        "|c9A7CC2Trader Prep|r - Mark items you want ready for guild trader listing",
        "|cC86A63Trash|r - Sell to NPC merchants",
        "",
        "Use |cCFC9BCRemove Category|r to clear any tag and send the item back to the unassigned state shown under All.",
    }

    return table.concat(lines, "\n")
end

local function ApplyAutoSellSetting(value)
    AI.sv.settings.autoSell = value
    if not value then
        if AI.StopStoreSellWatcher then
            AI.StopStoreSellWatcher()
        end
        if AI.CloseSellConfirmation then
            AI.CloseSellConfirmation()
        end
        AI._storeSellHandledThisSession = true
        return
    end

    if AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive() and AI.StartStoreSellWatcher then
        AI._storeSellHandledThisSession = false
        AI.StartStoreSellWatcher()
    end
end

local function ApplyShowCategoryIconsSetting(value)
    AI.sv.settings.showCategoryIcons = value
    if AI.RefreshVisibleInventoryIndicators then
        AI.RefreshVisibleInventoryIndicators()
    end
end

function AI.InitializeSettings()
    if not LibAddonMenu2 then
        d("AutoInventory: LibAddonMenu-2.0 not found. Settings panel disabled.")
        return
    end

    local LAM = LibAddonMenu2

    local panelData = {
        type = "panel",
        name = "AutoInventory",
        displayName = "AutoInventory",
        author = "AutoInventory Team",
        version = AI.version,
        registerForRefresh = true,
        registerForDefaults = true,
    }

    AI.defaultSettingsCopy = ZO_DeepTableCopy(AI.defaultSettings)

    local optionsData = {
        {
            type = "header",
            name = "General Settings",
        },
        {
            type = "checkbox",
            name = "Enable Auto-Bank",
            tooltip = "Automatically deposit/withdraw items when opening the bank",
            getFunc = function() return AI.sv.settings.autoBank end,
            setFunc = function(value) AI.sv.settings.autoBank = value end,
            default = AI.defaultSettingsCopy.autoBank,
        },
        {
            type = "checkbox",
            name = "Enable Auto-Sell",
            tooltip = "Automatically sell trash items when visiting merchants",
            getFunc = function() return AI.sv.settings.autoSell end,
            setFunc = ApplyAutoSellSetting,
            default = AI.defaultSettingsCopy.autoSell,
        },
        {
            type = "checkbox",
            name = "Enable Auto-Sort",
            tooltip = "Enable inventory sorting features",
            getFunc = function() return AI.sv.settings.autoSort end,
            setFunc = function(value) AI.sv.settings.autoSort = value end,
            default = AI.defaultSettingsCopy.autoSort,
        },
        {
            type = "checkbox",
            name = "Show Category Icons",
            tooltip = "Show category icons on inventory items",
            getFunc = function() return AI.sv.settings.showCategoryIcons end,
            setFunc = ApplyShowCategoryIconsSetting,
            default = AI.defaultSettingsCopy.showCategoryIcons,
        },
        {
            type = "header",
            name = "Auto-Sell Settings",
        },
        {
            type = "checkbox",
            name = "Confirm Before Selling",
            tooltip = "Show a confirmation dialog before auto-selling trash items at merchants",
            getFunc = function() return AI.sv.settings.confirmBeforeSelling end,
            setFunc = function(value) AI.sv.settings.confirmBeforeSelling = value end,
            default = AI.defaultSettingsCopy.confirmBeforeSelling,
        },
        {
            type = "slider",
            name = "Sell Confirmation Threshold",
            tooltip = "Any trash item worth at least this much gold will force the sell confirmation dialog",
            min = 0,
            max = 1000,
            step = 10,
            getFunc = function() return AI.sv.settings.sellConfirmationThreshold end,
            setFunc = function(value) AI.sv.settings.sellConfirmationThreshold = value end,
            default = AI.defaultSettingsCopy.sellConfirmationThreshold,
        },
        {
            type = "header",
            name = "Bag Management",
        },
        {
            type = "slider",
            name = "Bag Space Buffer",
            tooltip = "Minimum free slots to keep when withdrawing from bank",
            min = 0,
            max = 20,
            step = 1,
            getFunc = function() return AI.sv.settings.bagSpaceBuffer end,
            setFunc = function(value) AI.sv.settings.bagSpaceBuffer = value end,
            default = AI.defaultSettingsCopy.bagSpaceBuffer,
        },
        {
            type = "header",
            name = "Item Categories",
        },
        {
            type = "description",
            text = BuildCategoryDescriptionText(),
        },
        {
            type = "header",
            name = "Management",
        },
        {
            type = "button",
            name = "Clear All Categories",
            tooltip = "Remove all item category assignments",
            func = function()
                if AI.ClearAllCategories then
                    AI.ClearAllCategories()
                else
                    AI.sv.items = {}
                    AI.sv.legacyItems = {}
                end
                d("AutoInventory: All item categories cleared")
            end,
            warning = "This will reset all item categories. Are you sure?",
        },
        {
            type = "button",
            name = "Reset to Defaults",
            tooltip = "Reset all settings to default values",
            func = function()
                local defaults = ZO_DeepTableCopy(AI.defaultSettingsCopy)
                AI.sv.settings = defaults

                ApplyAutoSellSetting(defaults.autoSell)
                ApplyShowCategoryIconsSetting(defaults.showCategoryIcons)
                if AI.Manager and AI.Manager.OnInventoryChanged then
                    AI.Manager.OnInventoryChanged()
                end
                d("AutoInventory: Settings reset to defaults")
            end,
            warning = "This will reset all settings. Are you sure?",
        },
    }

    AI.settingsPanel = LAM:RegisterAddonPanel("AutoInventoryPanel", panelData)
    LAM:RegisterOptionControls("AutoInventoryPanel", optionsData)
end
