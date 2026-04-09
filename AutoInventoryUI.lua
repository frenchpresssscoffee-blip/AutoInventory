AutoInventory = AutoInventory or {}
local AI = AutoInventory

-- String trim helper (Lua doesn't have native trim)
local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function ParseToggleValue(value)
    if value == "on" or value == "true" or value == "yes" or value == "1" then
        return true
    end

    if value == "off" or value == "false" or value == "no" or value == "0" then
        return false
    end

    return nil
end

local function HandleAllowTrashCommand(cmd)
    local _, _, target, state = cmd:find("^allowtrash%s+(%S+)%s+(%S+)$")

    if cmd == "allowtrash" or cmd == "allowtrash status" then
        d(string.format(
            "AutoInventory: High-end trash protection status - purple: %s, legendary: %s",
            AI.sv.settings.allowEpicTrash and "allowed" or "protected",
            AI.sv.settings.allowLegendaryTrash and "allowed" or "protected"
        ))
        return true
    end

    if not target or not state then
        d("AutoInventory: Use /ai allowtrash epic|legendary|all on|off")
        return true
    end

    local enabled = ParseToggleValue(state)
    if enabled == nil then
        d("AutoInventory: Use on/off for allowtrash")
        return true
    end

    if target == "epic" or target == "purple" then
        AI.sv.settings.allowEpicTrash = enabled
        d(string.format("AutoInventory: Purple trashing is now %s", enabled and "allowed" or "protected"))
        return true
    end

    if target == "legendary" or target == "gold" then
        AI.sv.settings.allowLegendaryTrash = enabled
        d(string.format("AutoInventory: Legendary trashing is now %s", enabled and "allowed" or "protected"))
        return true
    end

    if target == "all" then
        AI.sv.settings.allowEpicTrash = enabled
        AI.sv.settings.allowLegendaryTrash = enabled
        d(string.format("AutoInventory: Purple and legendary trashing are now %s", enabled and "allowed" or "protected"))
        return true
    end

    d("AutoInventory: Use epic, legendary, or all with /ai allowtrash")
    return true
end

local function ResolveInventorySlotBagAndIndex(inventorySlot)
    local control = inventorySlot
    local depth = 0

    while control and depth < 8 do
        if ZO_Inventory_GetBagAndIndex then
            local bagId, slotIndex = ZO_Inventory_GetBagAndIndex(control)
            if bagId ~= nil and slotIndex ~= nil then
                return bagId, slotIndex
            end
        end

        local data = control.dataEntry and control.dataEntry.data or control.data
        if data and data.bagId ~= nil and data.slotIndex ~= nil then
            return data.bagId, data.slotIndex
        end

        if control.GetNamedChild then
            local slotChild = control:GetNamedChild("Slot")
            if slotChild and slotChild ~= control then
                if ZO_Inventory_GetBagAndIndex then
                    local slotBagId, slotSlotIndex = ZO_Inventory_GetBagAndIndex(slotChild)
                    if slotBagId ~= nil and slotSlotIndex ~= nil then
                        return slotBagId, slotSlotIndex
                    end
                end

                local slotData = slotChild.dataEntry and slotChild.dataEntry.data or slotChild.data
                if slotData and slotData.bagId ~= nil and slotData.slotIndex ~= nil then
                    return slotData.bagId, slotData.slotIndex
                end
            end
        end

        control = control.GetParent and control:GetParent() or nil
        depth = depth + 1
    end

    return nil, nil
end

local function AddInventoryMenuItem(label, callback, itemType)
    if AddCustomMenuItem then
        AddCustomMenuItem(label, callback, itemType)
        return true
    end

    if AddMenuItem then
        AddMenuItem(label, callback or function() end, itemType)
        return true
    end

    return false
end

local function NotifyCategoryChangeResult(success, mode, successMessage, failureMessage)
    if success then
        if mode == "session" then
            d(successMessage .. " (session only)")
        else
            d(successMessage)
        end
    else
        d(failureMessage or "AutoInventory: Could not save category for this item")
    end
end

-- Context menu entries
function AI.InitializeInventoryContextMenu()
    if AI._contextMenuHooked then
        return
    end

    AI._contextMenuInitAttempts = (AI._contextMenuInitAttempts or 0) + 1

    local function BuildInventoryContextMenu(inventorySlot)
        if not inventorySlot then
            return
        end

        local bagId, slotIndex = ResolveInventorySlotBagAndIndex(inventorySlot)
        if bagId == nil or slotIndex == nil or not AI.BagSlotHasItem(bagId, slotIndex) then
            return
        end

        local itemId = GetItemId(bagId, slotIndex)
        local currentCategory = AI.GetItemCategory(bagId, slotIndex, itemId)

        if not AddInventoryMenuItem("-", function() end) then
            d("AutoInventory: Inventory context menu is not available right now")
            return
        end

        AddInventoryMenuItem("AutoInventory", function() end, MENU_ADD_OPTION_HEADER)

        for _, category in ipairs(AI.GetAssignableCategories and AI.GetAssignableCategories() or {
            AI.categories.KEEP,
            AI.categories.BANK,
            AI.categories.RETRIEVE,
            AI.categories.AUCTION,
            AI.categories.TRASH
        }) do
            local displayName = AI.GetCategoryDisplayName(category)
            local color = AI.GetCategoryColor(category)
            local label = color:Colorize(displayName)

            if category == currentCategory then
                label = label .. " |c66CC66(*)|r"
            end

            AddInventoryMenuItem(label, function()
                local itemName = GetItemLinkName(GetItemLink(bagId, slotIndex))
                local saved, mode = AI.SetItemCategory(bagId, slotIndex, category, itemId, { applyEffects = false })
                NotifyCategoryChangeResult(
                    saved,
                    mode,
                    "AutoInventory: Set " .. itemName .. " to " .. displayName,
                    "AutoInventory: Could not set " .. itemName .. " to " .. displayName
                )
                if AI.RefreshVisibleInventoryIndicators then
                    AI.RefreshVisibleInventoryIndicators()
                end
                if AI.Manager and AI.Manager.OnInventoryChanged then
                    AI.Manager.OnInventoryChanged()
                end
            end)
        end

        AddInventoryMenuItem("Remove Category", function()
            local itemName = GetItemLinkName(GetItemLink(bagId, slotIndex))
            local cleared, mode = AI.SetItemCategory(bagId, slotIndex, nil, itemId, { applyEffects = false })
            NotifyCategoryChangeResult(
                cleared,
                mode,
                "AutoInventory: Cleared category for " .. itemName,
                "AutoInventory: Could not clear category for " .. itemName
            )
            if AI.RefreshVisibleInventoryIndicators then
                AI.RefreshVisibleInventoryIndicators()
            end
            if AI.Manager and AI.Manager.OnInventoryChanged then
                AI.Manager.OnInventoryChanged()
            end
        end)

        local currentColor = AI.GetCategoryColor(currentCategory)
        AddInventoryMenuItem("Current: " .. currentColor:Colorize(AI.GetCategoryDisplayName(currentCategory)), function() end)
    end

    if LibCustomMenu and LibCustomMenu.RegisterContextMenu then
        LibCustomMenu:RegisterContextMenu(function(inventorySlot)
            BuildInventoryContextMenu(inventorySlot)
        end, LibCustomMenu.CATEGORY_LATE)
        AI._contextMenuHooked = true
        return
    end

    if AI._contextMenuInitAttempts < 4 and AI.ScheduleSingleUpdate then
        AI.ScheduleSingleUpdate("AutoInventoryUpdate:ContextMenuRetry", 500, function()
            AI.InitializeInventoryContextMenu()
        end)
        return
    end

    if not AI._contextMenuFallbackHooked then
        ZO_PreHook("ZO_InventorySlot_ShowContextMenu", function(inventorySlot)
            BuildInventoryContextMenu(inventorySlot)
            return false
        end)
        AI._contextMenuFallbackHooked = true
        AI._contextMenuHooked = true
    else
        AI._contextMenuHooked = true
    end
end

-- Create category indicator overlay for inventory slots
function AI.CreateCategoryIndicator(parent)
    local indicator = parent:CreateControl("$(parent)AutoInventoryIndicator", CT_TEXTURE)
    indicator:SetDimensions(16, 16)
    indicator:SetAnchor(TOPLEFT, parent, TOPLEFT, 2, 2)
    indicator:SetDrawLayer(DL_OVERLAY)
    indicator:SetMouseEnabled(false)
    indicator:SetHidden(true)
    return indicator
end

-- Update category indicator for a slot
function AI.UpdateSlotIndicator(inventorySlot, bagId, slotIndex)
    local indicator = inventorySlot:GetNamedChild("AutoInventoryIndicator")
    if not AI.sv.settings.showCategoryIcons then
        if indicator then
            indicator:SetHidden(true)
        end
        return
    end

    if not indicator then
        indicator = AI.CreateCategoryIndicator(inventorySlot)
    end

    if AI.BagSlotHasItem(bagId, slotIndex) then
        local itemId = GetItemId(bagId, slotIndex)
        local category = AI.GetItemCategory(bagId, slotIndex, itemId)

        if category ~= nil and category ~= AI.categories.KEEP then
            local color = AI.GetCategoryColor(category)
            indicator:SetColor(color:UnpackRGB())

            -- Set texture based on category
            local texture = "/esoui/art/inventory/inventory_trait_activated_icon.dds"
            if category == AI.categories.BANK then
                texture = "/esoui/art/icons/servicemappins_servicemapicon_bank.dds"
            elseif category == AI.categories.TRASH then
                texture = "/esoui/art/inventory/inventory_tabicon_junk_up.dds"
            elseif category == AI.categories.AUCTION then
                texture = "/esoui/art/inventory/inventory_tabicon_crafting_up.dds"
            elseif category == AI.categories.RETRIEVE then
                texture = "/esoui/art/inventory/inventory_tabicon_items_up.dds"
            end

            indicator:SetTexture(texture)
            indicator:SetHidden(false)
        else
            indicator:SetHidden(true)
        end
    else
        indicator:SetHidden(true)
    end
end

function AI.RefreshVisibleInventoryIndicators()
    local inventories = PLAYER_INVENTORY and PLAYER_INVENTORY.inventories or {}
    for _, inventoryType in ipairs({ INVENTORY_BACKPACK, INVENTORY_BANK, INVENTORY_GUILD_BANK }) do
        local inventoryData = inventories[inventoryType]
        local list = inventoryData and inventoryData.list
        if list and ZO_ScrollList_RefreshVisible then
            ZO_ScrollList_RefreshVisible(list)
        end
    end
end

-- Hook inventory list updates to show category indicators
function AI.HookInventoryUpdates()
    -- Hook the inventory list's data type setup
    local function HookInventoryList(list)
        if not list or not list.dataTypes then return end

        for _, dataType in pairs(list.dataTypes) do
            if dataType and dataType.setupCallback and not dataType.autoInventorySetupWrapped then
                local originalSetupCallback = dataType.setupCallback
                dataType.autoInventorySetupWrapped = true

                dataType.setupCallback = function(control, data)
                    originalSetupCallback(control, data)

                    local bagId = data and data.bagId
                    local slotIndex = data and data.slotIndex

                    if bagId and slotIndex then
                        AI.UpdateSlotIndicator(control, bagId, slotIndex)
                    end
                end
            end
        end
    end

    local inventories = PLAYER_INVENTORY and PLAYER_INVENTORY.inventories or {}
    for _, inventoryType in ipairs({ INVENTORY_BACKPACK, INVENTORY_BANK, INVENTORY_GUILD_BANK }) do
        local inventoryData = inventories[inventoryType]
        local list = inventoryData and inventoryData.list
        if list then
            HookInventoryList(list)
        end
    end
end

-- Slash commands
SLASH_COMMANDS["/ai"] = function(arg)
    local cmd = trim(arg:lower())

    if cmd == "help" or cmd == "" then
        d("AutoInventory Commands:")
        d("/ai help - Show this help")
        d("/ai manager - Open the category manager UI")
        d("/ai bank - Process bank transactions now")
        d("/ai sell - Sell trash items now")
        d("/ai allowtrash epic|legendary|all on|off - Allow high-end trash selling/deleting")
        d("/ai allowtrash status - Show high-end trash protection status")
        d("/ai ops - Show recent AutoInventory operations")
        d("/ai ops clear - Clear recent AutoInventory operations")
        d("/ai clear - Clear all item categories")
        d("/ai settings - Open settings panel")
        d("/ai debug on|off - Toggle manager selection debug logging")
        d("/ai debug clear - Clear manager debug logging")
    elseif cmd:find("^allowtrash") == 1 then
        HandleAllowTrashCommand(cmd)
    elseif cmd == "bank" then
        if IsBankOpen() then
            if AI.QueueBankTransactionProcessing then
                AI.QueueBankTransactionProcessing(true)
            else
                AI.ProcessBankTransactions({ forceWithdrawAll = true })
            end
        else
            d("AutoInventory: Bank must be open")
        end
    elseif cmd == "sell" then
        if AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive() then
            AI.ProcessAutoSell()
        else
            d("AutoInventory: Merchant must be open")
        end
    elseif cmd == "ops" then
        local operationLog = AI.sv and AI.sv.operationLog or {}
        if not operationLog or #operationLog == 0 then
            d("AutoInventory: No recent operations logged")
        else
            d("AutoInventory: Recent operations")
            local startIndex = math.max(1, #operationLog - 9)
            for index = startIndex, #operationLog do
                d(operationLog[index])
            end
        end
    elseif cmd == "ops clear" then
        AI.sv.operationLog = {}
        d("AutoInventory: Operation log cleared")
    elseif cmd == "clear" then
        if AI.ClearAllCategories then
            AI.ClearAllCategories()
        else
            AI.sv.items = {}
            AI.sv.legacyItems = {}
        end
        d("AutoInventory: All item categories cleared")
    elseif cmd == "settings" then
        if LibAddonMenu2 and AI.settingsPanel then
            LibAddonMenu2:OpenToPanel(AI.settingsPanel)
        else
            d("AutoInventory: Settings panel not available")
        end
    elseif cmd == "manager" then
        if AI.Manager and AI.Manager.Toggle then
            AI.Manager.Toggle()
        else
            d("AutoInventory: Manager not loaded")
        end
    elseif cmd == "debug on" then
        AI.sv.settings.debugManagerSelection = true
        AI.sv.debugLog = {}
        d("AutoInventory: Manager debug logging enabled")
    elseif cmd == "debug off" then
        AI.sv.settings.debugManagerSelection = false
        d("AutoInventory: Manager debug logging disabled")
    elseif cmd == "debug clear" then
        AI.sv.debugLog = {}
        d("AutoInventory: Manager debug log cleared")
    else
        d("AutoInventory: Unknown command. Use /ai help")
    end
end

-- Initialize UI module
function AI.InitializeUI()
    if AI.InitializeInventoryContextMenu then
        AI.InitializeInventoryContextMenu()
    end

    -- Delay hooking inventory to ensure UI is ready
    if AI.ScheduleSingleUpdate then
        AI.ScheduleSingleUpdate("AutoInventoryUpdate:UIInit", 3000, function()
            if AI.InitializeInventoryContextMenu then
                AI.InitializeInventoryContextMenu()
            end
            AI.HookInventoryUpdates()
        end)
    else
        zo_callLater(function()
            if AI.InitializeInventoryContextMenu then
                AI.InitializeInventoryContextMenu()
            end
            AI.HookInventoryUpdates()
        end, 3000)
    end
end
