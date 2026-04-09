AutoInventory = AutoInventory or {}
local AI = AutoInventory

AI.name = "AutoInventory"
AI.version = "1.0.0"
AI.sv = nil
AI.sessionItems = AI.sessionItems or {}

AI.categories = {
    KEEP = "keep",
    BANK = "bank",
    RETRIEVE = "retrieve",
    TRASH = "trash",
    AUCTION = "auction",
}

AI.defaultSettings = {
    autoSort = true,
    autoBank = true,
    autoSell = true,
    confirmBeforeSelling = true,
    sellConfirmationThreshold = 100,
    bagSpaceBuffer = 5,
    sortOrder = { "quality", "type", "level", "name" },
    showCategoryIcons = true,
    debugManagerSelection = false,
    allowEpicTrash = false,
    allowLegendaryTrash = false,
}

local STORE_AUTO_SELL_DELAY_MS = 200
local STORE_AUTO_SELL_RETRY_MS = 250
local STORE_AUTO_SELL_MAX_ATTEMPTS = 12
local UPDATE_KEY_PREFIX = "AutoInventoryUpdate:"
local UPDATE_KEY_CONTEXT_MENU = UPDATE_KEY_PREFIX .. "ContextMenuInit"
local UPDATE_KEY_TRADING_HOUSE_AUCTION = UPDATE_KEY_PREFIX .. "TradingHouseAuction"
local UPDATE_KEY_BANK_QUEUE = UPDATE_KEY_PREFIX .. "BankQueue"
local UPDATE_KEY_STORE_WATCHER = UPDATE_KEY_PREFIX .. "StoreWatcher"

function AI.Initialize()
    AI.sessionItems = {}
    AI.sv = ZO_SavedVars:NewAccountWide("AutoInventorySV", 1, GetWorldName and GetWorldName() or nil, {
        items = {},
        legacyItems = {},
        debugLog = {},
        operationLog = {},
        settings = ZO_DeepTableCopy(AI.defaultSettings),
    })

    AI.MigrateLegacyCategoryAssignments()

    AI.InitializeSettings()
    AI.InitializeCore()
    AI.InitializeUI()
    AI.RegisterEvents()

    local ok, err = pcall(function()
        AI.InitializeManager()
    end)
    if not ok then
        d("AutoInventory: Manager failed to initialize: " .. tostring(err))
    end

    d("AutoInventory v" .. AI.version .. " loaded")

    if AI.GetLegacyAssignmentCount and AI.GetLegacyAssignmentCount() > 0 then
        AI.Notify(string.format("AutoInventory: %d legacy category assignment(s) are quarantined and will not be auto-applied until you re-tag those items", AI.GetLegacyAssignmentCount()))
    end
end

function AI.CancelScheduledUpdate(updateKey)
    if not updateKey then
        return
    end

    EVENT_MANAGER:UnregisterForUpdate(updateKey)
end

function AI.ScheduleSingleUpdate(updateKey, delayMs, callback)
    if not updateKey or not callback then
        return
    end

    AI.CancelScheduledUpdate(updateKey)
    EVENT_MANAGER:RegisterForUpdate(updateKey, delayMs, function()
        AI.CancelScheduledUpdate(updateKey)
        callback()
    end)
end

function AI.RegisterEvents()
    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_OPEN_BANK, AI.OnOpenBank)
    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_CLOSE_BANK, AI.OnCloseBank)

    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_OPEN_STORE, AI.OnOpenStore)
    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_CLOSE_STORE, AI.OnCloseStore)
    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_OPEN_TRADING_HOUSE, AI.OnOpenTradingHouse)
    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_CLOSE_TRADING_HOUSE, AI.OnCloseTradingHouse)

    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_INVENTORY_SINGLE_SLOT_UPDATE, AI.OnInventoryUpdate)
    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_INVENTORY_FULL_UPDATE, AI.OnInventoryFullUpdate)

    EVENT_MANAGER:RegisterForEvent(AI.name, EVENT_PLAYER_ACTIVATED, function()
        AI.ScheduleSingleUpdate(UPDATE_KEY_CONTEXT_MENU, 2000, function()
            if AI.InitializeInventoryContextMenu then
                AI.InitializeInventoryContextMenu()
            end
        end)
    end)
end

function AI.OnOpenBank()
    if AI.sv.settings.autoBank then
        AI.QueueBankTransactionProcessing(false)
    end
end

function AI.OnCloseBank()
end

function AI.OnOpenStore()
    if AI.CloseSellConfirmation then
        AI.CloseSellConfirmation()
    end

    AI._storeSellHandledThisSession = false
    AI._sellConfirmationPending = false
    AI._storeSellFailureRetryCount = 0

    if AI.sv.settings.autoSell then
        AI.StartStoreSellWatcher()
    end
end

function AI.OnCloseStore()
    AI._storeSellHandledThisSession = false
    AI._sellConfirmationPending = false
    AI._storeSellFailureRetryCount = 0
    AI.StopStoreSellWatcher()
    if AI.CloseSellConfirmation then
        AI.CloseSellConfirmation()
    end
end

function AI.OnOpenTradingHouse()
    AI._tradingHouseOpen = true

    local auctionItems = AI.GetBagItemsByCategory and AI.GetBagItemsByCategory(BAG_BACKPACK, AI.categories.AUCTION) or {}
    if auctionItems and #auctionItems > 0 then
        AI.Notify(string.format("AutoInventory: %d trader-prep item(s) are in your backpack and ready to list. Guild trader posting is manual.", #auctionItems))
        if AI.Manager and AI.Manager.ShowAuctionItems then
            AI.ScheduleSingleUpdate(UPDATE_KEY_TRADING_HOUSE_AUCTION, 150, function()
                if AI.IsTradingHouseInteractionActive and AI.IsTradingHouseInteractionActive() then
                    AI.Manager.ShowAuctionItems()
                end
            end)
        end
    end

    if AI.Manager and AI.Manager.OnInventoryChanged then
        AI.Manager.OnInventoryChanged()
    end
end

function AI.OnCloseTradingHouse()
    AI._tradingHouseOpen = false
    AI.CancelScheduledUpdate(UPDATE_KEY_TRADING_HOUSE_AUCTION)

    if AI.Manager and AI.Manager.OnInventoryChanged then
        AI.Manager.OnInventoryChanged()
    end
end

function AI.OnInventoryUpdate(eventCode, bagId)
    if AI.PruneSessionCategories then
        AI.PruneSessionCategories()
    end

    if AI.sv
        and AI.sv.settings
        and AI.sv.settings.autoSell
        and not AI._sellConfirmationPending
        and AI.IsMerchantInteractionActive
        and AI.IsMerchantInteractionActive()
        and AI.StartStoreSellWatcher then
        local sellableTrashItems = AI.GetSellableTrashItems and select(1, AI.GetSellableTrashItems()) or nil
        if sellableTrashItems and #sellableTrashItems > 0 then
            AI._storeSellHandledThisSession = false
            AI.StartStoreSellWatcher()
        end
    end

    if AI.Manager and AI.Manager.OnInventoryChanged then
        AI.Manager.OnInventoryChanged(bagId)
    end
end

function AI.OnInventoryFullUpdate()
    if AI.PruneSessionCategories then
        AI.PruneSessionCategories()
    end

    if AI.sv
        and AI.sv.settings
        and AI.sv.settings.autoSell
        and not AI._sellConfirmationPending
        and AI.IsMerchantInteractionActive
        and AI.IsMerchantInteractionActive()
        and AI.StartStoreSellWatcher then
        local sellableTrashItems = AI.GetSellableTrashItems and select(1, AI.GetSellableTrashItems()) or nil
        if sellableTrashItems and #sellableTrashItems > 0 then
            AI._storeSellHandledThisSession = false
            AI.StartStoreSellWatcher()
        end
    end

    if AI.Manager and AI.Manager.OnInventoryChanged then
        AI.Manager.OnInventoryChanged()
    end
end

function AI.Notify(message, soundId, options)
    if message == nil or message == "" then
        return
    end

    options = options or {}

    AI.LogOperation(message)

    if ZO_Alert and UI_ALERT_CATEGORY_ALERT then
        ZO_Alert(UI_ALERT_CATEGORY_ALERT, soundId, message)
    end

    if options.chat ~= false then
        d(message)
    end
end

function AI.LogOperation(message)
    if not AI.sv then
        return
    end

    AI.sv.operationLog = AI.sv.operationLog or {}
    table.insert(AI.sv.operationLog, string.format("[%s] %s", GetTimeString and GetTimeString() or "time", tostring(message)))
    if #AI.sv.operationLog > 100 then
        table.remove(AI.sv.operationLog, 1)
    end
end

function AI.IsManagerDebugEnabled()
    return AI.sv
        and AI.sv.settings
        and AI.sv.settings.debugManagerSelection == true
end

function AI.DebugManagerLog(message)
    if not AI.IsManagerDebugEnabled() then
        return
    end

    local formatted = string.format("AutoInventory[ManagerDebug]: %s", tostring(message or ""))

    AI.sv.debugLog = AI.sv.debugLog or {}
    table.insert(AI.sv.debugLog, formatted)
    if #AI.sv.debugLog > 200 then
        table.remove(AI.sv.debugLog, 1)
    end

    d(formatted)
end

function AI.IsMerchantInteractionActive()
    if GetInteractionType and INTERACTION_VENDOR then
        return GetInteractionType() == INTERACTION_VENDOR
    end

    return AI.IsStoreWindowOpen()
end

function AI.IsSellWindowActive()
    return AI.IsMerchantInteractionActive()
end

function AI.IsStoreWindowOpen()
    if STORE_WINDOW and STORE_WINDOW.control and STORE_WINDOW.control.IsHidden then
        return not STORE_WINDOW.control:IsHidden()
    end
    if ZO_StoreWindowTopLevel and ZO_StoreWindowTopLevel.IsHidden then
        return not ZO_StoreWindowTopLevel:IsHidden()
    end
    return false
end

function AI.IsTradingHouseInteractionActive()
    if TRADING_HOUSE and TRADING_HOUSE.control and TRADING_HOUSE.control.IsHidden then
        return not TRADING_HOUSE.control:IsHidden()
    end

    if ZO_TradingHouseTopLevel and ZO_TradingHouseTopLevel.IsHidden then
        return not ZO_TradingHouseTopLevel:IsHidden()
    end

    if AI._tradingHouseOpen ~= nil then
        return AI._tradingHouseOpen == true
    end

    return false
end

function AI.StopStoreSellWatcher()
    AI._storeSellWatcherAttempt = nil
    AI.CancelScheduledUpdate(UPDATE_KEY_STORE_WATCHER)
end

function AI.QueueBankTransactionProcessing(forceWithdrawAll, callback)
    if not IsBankOpen() then
        return false
    end

    AI._bankTransactionsQueued = true
    AI._bankTransactionsForceWithdrawAll = AI._bankTransactionsForceWithdrawAll or forceWithdrawAll or false
    if forceWithdrawAll then
        AI._bankTransactionsForceWithdrawAll = true
    end

    if callback then
        AI._bankTransactionCallbacks = AI._bankTransactionCallbacks or {}
        table.insert(AI._bankTransactionCallbacks, callback)
    end

    if AI._bankTransactionsPending then
        return true
    end

    AI._bankTransactionsPending = true
    AI.ScheduleSingleUpdate(UPDATE_KEY_BANK_QUEUE, 180, function()
        AI._bankTransactionsPending = false

        if not IsBankOpen() then
            local queuedCallbacks = AI._bankTransactionCallbacks or {}
            AI._bankTransactionsQueued = false
            AI._bankTransactionsForceWithdrawAll = false
            AI._bankTransactionCallbacks = nil
            for _, queuedCallback in ipairs(queuedCallbacks) do
                queuedCallback({
                    aborted = true,
                    reason = "bank_closed",
                })
            end
            return
        end

        local queuedCallbacks = AI._bankTransactionCallbacks or {}
        local forceWithdraw = AI._bankTransactionsForceWithdrawAll == true
        AI._bankTransactionsQueued = false
        AI._bankTransactionsForceWithdrawAll = false
        AI._bankTransactionCallbacks = nil

        AI.ProcessBankTransactions({
            forceWithdrawAll = forceWithdraw,
            callback = function(results)
                for _, queuedCallback in ipairs(queuedCallbacks) do
                    queuedCallback(results)
                end
            end,
        })
    end)

    return true
end

function AI.StartStoreSellWatcher()
    AI.StopStoreSellWatcher()
    AI._storeSellWatcherAttempt = 0

    local function TryProcessAutoSell()
        if not (AI.sv and AI.sv.settings and AI.sv.settings.autoSell) then
            AI.StopStoreSellWatcher()
            return
        end

        if AI._storeSellHandledThisSession then
            AI.StopStoreSellWatcher()
            return
        end

        if AI._sellConfirmationPending then
            AI.StopStoreSellWatcher()
            return
        end

        AI._storeSellWatcherAttempt = (AI._storeSellWatcherAttempt or 0) + 1

        local sellStatus = AI.IsMerchantInteractionActive() and AI.ProcessAutoSell(false) or false
        if sellStatus == "started" then
            AI.StopStoreSellWatcher()
            return
        end

        if sellStatus == "dialog" then
            AI.StopStoreSellWatcher()
            return
        end

        if sellStatus == "handled" then
            AI.StopStoreSellWatcher()
            return
        end

        if AI._storeSellWatcherAttempt >= STORE_AUTO_SELL_MAX_ATTEMPTS then
            AI.StopStoreSellWatcher()
            return
        end

        AI.ScheduleSingleUpdate(UPDATE_KEY_STORE_WATCHER, STORE_AUTO_SELL_RETRY_MS, TryProcessAutoSell)
    end

    AI.ScheduleSingleUpdate(UPDATE_KEY_STORE_WATCHER, STORE_AUTO_SELL_DELAY_MS, TryProcessAutoSell)
end

function AI.IsBackpackVisible()
    if ZO_PlayerInventoryBackpack and ZO_PlayerInventoryBackpack.IsHidden then
        return not ZO_PlayerInventoryBackpack:IsHidden()
    end

    local inventories = PLAYER_INVENTORY and PLAYER_INVENTORY.inventories
    local backpackInventory = inventories and inventories[INVENTORY_BACKPACK]
    if backpackInventory then
        if backpackInventory.control and backpackInventory.control.IsHidden then
            return not backpackInventory.control:IsHidden()
        end

        if backpackInventory.list and backpackInventory.list.control and backpackInventory.list.control.IsHidden then
            return not backpackInventory.list.control:IsHidden()
        end
    end

    return false
end

function AI.QueueAutoTrashSweep()
    -- Trash is vendor-only now. Keep the function as a harmless no-op so
    -- any older call sites or saved callbacks don't destroy inventory items.
    return
end

function AI.CanDepositItemToBank(bagId, slotIndex)
    if bagId ~= BAG_BACKPACK or not AI.BagSlotHasItem(bagId, slotIndex) then
        return false, nil, nil, nil
    end

    if not IsBankOpen() then
        return false, nil, nil, nil
    end

    if IsItemStolen and IsItemStolen(bagId, slotIndex) then
        return false, nil, nil, nil
    end

    if AI.CanMoveItemToBag then
        local canMoveToBank, destSlot, consumesNewSlot = AI.CanMoveItemToBag(bagId, slotIndex, BAG_BANK)
        if canMoveToBank then
            return true, BAG_BANK, destSlot, consumesNewSlot
        end

        if IsESOPlusSubscriber() then
            local canMoveToSubscriberBank, subscriberSlot, subscriberConsumesNewSlot = AI.CanMoveItemToBag(bagId, slotIndex, BAG_SUBSCRIBER_BANK)
            if canMoveToSubscriberBank then
                return true, BAG_SUBSCRIBER_BANK, subscriberSlot, subscriberConsumesNewSlot
            end
        end
    end

    return false, nil, nil, nil
end

function AI.IsBankDepositBlocked(bagId, slotIndex)
    if bagId ~= BAG_BACKPACK or not AI.BagSlotHasItem(bagId, slotIndex) then
        return true
    end

    if IsItemStolen and IsItemStolen(bagId, slotIndex) then
        return true
    end

    return false
end

EVENT_MANAGER:RegisterForEvent("AutoInventory", EVENT_ADD_ON_LOADED, function(_, addonName)
    if addonName ~= AI.name then
        return
    end

    EVENT_MANAGER:UnregisterForEvent("AutoInventory", EVENT_ADD_ON_LOADED)
    AI.Initialize()
end)
