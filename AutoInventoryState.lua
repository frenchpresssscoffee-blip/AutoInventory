AutoInventory = AutoInventory or {}
local AI = AutoInventory

local function GetStableId64String(id64Value)
    if id64Value == nil then
        return nil
    end

    if Id64ToString then
        local stable = Id64ToString(id64Value)
        if stable ~= nil and stable ~= "" and stable ~= "0" then
            return stable
        end
    end

    local fallback = tostring(id64Value)
    if fallback == nil or fallback == "" or fallback == "0" then
        return nil
    end

    if fallback:find("[eE][%+%-]") or fallback:find("%.") then
        return nil
    end

    return fallback
end

function AI.BagSlotHasItem(bagId, slotIndex)
    return bagId ~= nil and slotIndex ~= nil and GetItemId(bagId, slotIndex) ~= 0
end

function AI.GetItemStorageKey(bagId, slotIndex, itemId)
    if bagId ~= nil and slotIndex ~= nil and AI.BagSlotHasItem(bagId, slotIndex) then
        local uniqueId = nil
        local stableUniqueId = nil

        if GetItemUniqueId then
            uniqueId = GetItemUniqueId(bagId, slotIndex)
            stableUniqueId = GetStableId64String(uniqueId)
        end

        if stableUniqueId == nil and GetItemInstanceId then
            uniqueId = GetItemInstanceId(bagId, slotIndex)
            stableUniqueId = GetStableId64String(uniqueId)
        end

        if stableUniqueId ~= nil then
            return "item:" .. stableUniqueId
        end
    end

    return nil
end

function AI.GetItemSessionKey(bagId, slotIndex, itemId)
    if bagId == nil or slotIndex == nil or not AI.BagSlotHasItem(bagId, slotIndex) then
        return nil
    end

    local currentItemId = itemId or GetItemId(bagId, slotIndex)
    local itemLink = GetItemLink(bagId, slotIndex) or ""
    return string.format("session:%s:%s:%s:%s", tostring(bagId), tostring(slotIndex), tostring(currentItemId or 0), tostring(itemLink))
end

function AI.PruneSessionCategories()
    AI.sessionItems = AI.sessionItems or {}

    for key in pairs(AI.sessionItems) do
        local bagId, slotIndex, itemId, itemLink = key:match("^session:([^:]+):([^:]+):([^:]+):(.*)$")
        bagId = tonumber(bagId)
        slotIndex = tonumber(slotIndex)

        local keepEntry = false
        if bagId ~= nil and slotIndex ~= nil and AI.BagSlotHasItem(bagId, slotIndex) then
            local currentItemId = tostring(GetItemId(bagId, slotIndex) or 0)
            local currentItemLink = tostring(GetItemLink(bagId, slotIndex) or "")
            keepEntry = currentItemId == tostring(itemId or "") and currentItemLink == tostring(itemLink or "")
        end

        if not keepEntry then
            AI.sessionItems[key] = nil
        end
    end
end

function AI.GetLegacyAssignmentCount()
    if not AI.sv or not AI.sv.legacyItems then
        return 0
    end

    local count = 0
    for _ in pairs(AI.sv.legacyItems) do
        count = count + 1
    end
    return count
end

function AI.ClearAllCategories()
    if not AI.sv then
        return
    end

    AI.sv.items = {}
    AI.sv.legacyItems = {}
    AI.sessionItems = {}

    if AI.RefreshVisibleInventoryIndicators then
        AI.RefreshVisibleInventoryIndicators()
    end

    if AI.Manager and AI.Manager.OnInventoryChanged then
        AI.Manager.OnInventoryChanged()
    end
end

function AI.MigrateLegacyCategoryAssignments()
    if not AI.sv then
        return
    end

    AI.sv.items = AI.sv.items or {}
    AI.sv.legacyItems = AI.sv.legacyItems or {}

    local migratedCount = 0
    for key, category in pairs(AI.sv.items) do
        local keyString = tostring(key)
        local suffix = keyString:sub(6)
        local isUnsafeItemKey = keyString:sub(1, 5) == "item:" and not suffix:match("^%d+$")
        local isLegacyReviewCategory = category == "review"

        if isLegacyReviewCategory then
            AI.sv.items[key] = nil
            migratedCount = migratedCount + 1
        elseif keyString:sub(1, 5) ~= "item:" or isUnsafeItemKey then
            AI.sv.legacyItems[keyString] = category
            AI.sv.items[key] = nil
            migratedCount = migratedCount + 1
        end
    end

    if migratedCount > 0 then
        d(string.format("AutoInventory: Quarantined %d legacy category assignment(s) to prevent unsafe auto-actions", migratedCount))
    end
end

function AI.GetItemCategory(bagId, slotIndex, itemId)
    local storageKey = AI.GetItemStorageKey(bagId, slotIndex, itemId)
    if storageKey and AI.sv.items[storageKey] then
        return AI.sv.items[storageKey]
    end

    local sessionKey = AI.GetItemSessionKey and AI.GetItemSessionKey(bagId, slotIndex, itemId)
    if sessionKey and AI.sessionItems and AI.sessionItems[sessionKey] then
        return AI.sessionItems[sessionKey]
    end

    return nil
end

function AI.IsBankManagedCategory(category)
    return category == AI.categories.BANK
        or category == AI.categories.RETRIEVE
        or category == AI.categories.AUCTION
end

function AI.GetAssignableCategories()
    return {
        AI.categories.KEEP,
        AI.categories.BANK,
        AI.categories.RETRIEVE,
        AI.categories.AUCTION,
        AI.categories.TRASH,
    }
end

function AI.HandleCategoryAssignmentEffects(category)
    if category == AI.categories.TRASH
        and AI.sv
        and AI.sv.settings
        and AI.sv.settings.autoSell
        and AI.IsMerchantInteractionActive
        and AI.IsMerchantInteractionActive()
        and AI.StartStoreSellWatcher then
        AI._storeSellHandledThisSession = false
        AI.StartStoreSellWatcher()
        return
    end

    if AI.IsBankManagedCategory(category)
        and AI.QueueBankTransactionProcessing
        and IsBankOpen() then
        AI.QueueBankTransactionProcessing(true)
    end
end

function AI.SetItemCategory(bagId, slotIndex, category, itemId, options)
    options = options or {}
    local storageKey = AI.GetItemStorageKey(bagId, slotIndex, itemId)
    local sessionKey = AI.GetItemSessionKey and AI.GetItemSessionKey(bagId, slotIndex, itemId)
    if storageKey then
        if sessionKey and AI.sessionItems then
            AI.sessionItems[sessionKey] = nil
        end

        if category == nil or category == "" then
            AI.sv.items[storageKey] = nil
            return true, "persistent"
        end

        AI.sv.items[storageKey] = category
        if options.applyEffects ~= false then
            AI.HandleCategoryAssignmentEffects(category)
        end

        return true, "persistent"
    end

    if sessionKey then
        AI.sessionItems = AI.sessionItems or {}
        if category == nil or category == "" then
            AI.sessionItems[sessionKey] = nil
            return true, "session"
        end

        AI.sessionItems[sessionKey] = category
        if options.applyEffects ~= false then
            AI.HandleCategoryAssignmentEffects(category)
        end

        return true, "session"
    end

    return false
end

function AI.GetCategoryDisplayName(category)
    local names = {
        [AI.categories.KEEP] = "Keep",
        [AI.categories.BANK] = "Bank",
        [AI.categories.RETRIEVE] = "Pull From Bank",
        [AI.categories.TRASH] = "Trash",
        [AI.categories.AUCTION] = "Trader Prep",
    }

    return names[category] or "Unassigned"
end

function AI.GetCategoryTabLabel(category)
    local names = {
        [AI.categories.KEEP] = "Keep",
        [AI.categories.BANK] = "Bank",
        [AI.categories.RETRIEVE] = "Pull",
        [AI.categories.TRASH] = "Trash",
        [AI.categories.AUCTION] = "Trader",
    }

    return names[category] or AI.GetCategoryDisplayName(category)
end

function AI.GetCategoryColor(category)
    local colors = {
        [AI.categories.KEEP] = ZO_ColorDef:New("D2C79A"),
        [AI.categories.BANK] = ZO_ColorDef:New("5E9CC6"),
        [AI.categories.RETRIEVE] = ZO_ColorDef:New("7AA57A"),
        [AI.categories.TRASH] = ZO_ColorDef:New("C86A63"),
        [AI.categories.AUCTION] = ZO_ColorDef:New("9A7CC2"),
    }

    return colors[category] or ZO_ColorDef:New("8F8B81")
end
