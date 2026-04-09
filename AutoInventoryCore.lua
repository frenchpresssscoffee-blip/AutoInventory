AutoInventory = AutoInventory or {}
local AI = AutoInventory

local BAG_BACKPACK = BAG_BACKPACK
local BAG_BANK = BAG_BANK
local BAG_SUBSCRIBER_BANK = BAG_SUBSCRIBER_BANK
local SELL_CONFIRM_DIALOG = "AUTOINVENTORY_CONFIRM_SELL"
local VENDOR_TRANSACTION_LIMIT = 50
local SELL_REQUEST_DELAY_MS = 350
local delayedUpdateCounter = 0

local function RunDelayedOnce(prefix, delayMs, callback)
    if not callback then
        return
    end

    if EVENT_MANAGER and EVENT_MANAGER.RegisterForUpdate and EVENT_MANAGER.UnregisterForUpdate then
        delayedUpdateCounter = delayedUpdateCounter + 1
        local updateKey = string.format("AutoInventory:%s:%d", tostring(prefix or "delay"), delayedUpdateCounter)
        EVENT_MANAGER:RegisterForUpdate(updateKey, delayMs, function()
            EVENT_MANAGER:UnregisterForUpdate(updateKey)
            callback()
        end)
        return
    end

    zo_callLater(callback, delayMs)
end

local function IsBankBag(bagId)
    return bagId == BAG_BANK or bagId == BAG_SUBSCRIBER_BANK
end

local function GetItemMaxStackCountForSlot(bagId, slotIndex)
    if not AI.BagSlotHasItem(bagId, slotIndex) then
        return 1
    end

    if GetItemLinkStacks then
        local maxStack = GetItemLinkStacks(GetItemLink(bagId, slotIndex))
        if maxStack and maxStack > 0 then
            return maxStack
        end
    end

    return 1
end

local function CanMergeIntoSlot(sourceBag, sourceSlot, destBag, destSlot)
    if not AI.BagSlotHasItem(sourceBag, sourceSlot) or not AI.BagSlotHasItem(destBag, destSlot) then
        return false
    end

    if GetItemLink(sourceBag, sourceSlot) ~= GetItemLink(destBag, destSlot) then
        return false
    end

    local destStack = GetSlotStackSize(destBag, destSlot) or 0
    return destStack < GetItemMaxStackCountForSlot(destBag, destSlot)
end

local function FindFirstMergeableSlot(sourceBag, sourceSlot, destBag)
    local destSlot = ZO_GetNextBagSlotIndex(destBag, nil)
    while destSlot do
        if CanMergeIntoSlot(sourceBag, sourceSlot, destBag, destSlot) then
            return destSlot
        end
        destSlot = ZO_GetNextBagSlotIndex(destBag, destSlot)
    end

    return nil
end

local function FindMoveDestinationSlot(sourceBag, sourceSlot, destBag)
    local mergeSlot = FindFirstMergeableSlot(sourceBag, sourceSlot, destBag)
    if mergeSlot ~= nil then
        return mergeSlot, false
    end

    local emptySlot = FindFirstEmptySlotInBag(destBag)
    if emptySlot ~= nil then
        return emptySlot, true
    end

    return nil, nil
end

local function FindBankDepositDestination(sourceBag, sourceSlot)
    local bankSlot, bankConsumes = FindMoveDestinationSlot(sourceBag, sourceSlot, BAG_BANK)
    if bankSlot ~= nil then
        return BAG_BANK, bankSlot, bankConsumes
    end

    if IsESOPlusSubscriber() then
        local subscriberSlot, subscriberConsumes = FindMoveDestinationSlot(sourceBag, sourceSlot, BAG_SUBSCRIBER_BANK)
        if subscriberSlot ~= nil then
            return BAG_SUBSCRIBER_BANK, subscriberSlot, subscriberConsumes
        end
    end

    return nil, nil, nil
end

function AI.CanMoveItemToBag(sourceBag, sourceSlot, destBag)
    if not AI.BagSlotHasItem(sourceBag, sourceSlot) then
        return false, nil, nil
    end

    local destSlot, consumesNewSlot = FindMoveDestinationSlot(sourceBag, sourceSlot, destBag)
    return destSlot ~= nil, destSlot, consumesNewSlot
end

local function FinishMoveRequest(sourceBag, sourceSlot, originalItemId, originalStackCount, callback)
    RunDelayedOnce("FinishMoveRequest", 320, function()
        local moved = not AI.BagSlotHasItem(sourceBag, sourceSlot)
        if not moved and originalItemId ~= nil and AI.BagSlotHasItem(sourceBag, sourceSlot) then
            local currentItemId = GetItemId(sourceBag, sourceSlot)
            local currentStackCount = GetSlotStackSize(sourceBag, sourceSlot) or 0
            moved = currentItemId ~= originalItemId or currentStackCount < (originalStackCount or 0)
        end

        if callback then
            callback(moved, moved and nil or "request_not_applied")
        end
    end, 320)
end

local function FinishSellRequest(bagId, slotIndex, originalItemId, originalStackCount, callback)
    RunDelayedOnce("FinishSellRequest", SELL_REQUEST_DELAY_MS, function()
        local sold = not AI.BagSlotHasItem(bagId, slotIndex)
        if not sold and AI.BagSlotHasItem(bagId, slotIndex) then
            local currentItemId = GetItemId(bagId, slotIndex)
            local currentStackCount = GetSlotStackSize(bagId, slotIndex) or 0
            sold = currentItemId ~= originalItemId or currentStackCount < (originalStackCount or 0)
        end

        if callback then
            callback(sold, sold and nil or "sale_not_applied")
        end
    end, SELL_REQUEST_DELAY_MS)
end

local function MoveBagItem(sourceBag, sourceSlot, destBag, callback)
    if not AI.BagSlotHasItem(sourceBag, sourceSlot) then
        if callback then
            callback(false, "missing_source_item")
        end
        return false
    end

    local destSlot = FindMoveDestinationSlot(sourceBag, sourceSlot, destBag)
    if destSlot == nil then
        if callback then
            callback(false, "no_destination_slot")
        end
        return false
    end

    local stackCount = GetSlotStackSize(sourceBag, sourceSlot)
    if not stackCount or stackCount <= 0 then
        if callback then
            callback(false, "empty_stack")
        end
        return false
    end

    local originalItemId = GetItemId(sourceBag, sourceSlot)
    local originalStackCount = stackCount
    CallSecureProtected("RequestMoveItem", sourceBag, sourceSlot, destBag, destSlot, stackCount)

    if callback then
        FinishMoveRequest(sourceBag, sourceSlot, originalItemId, originalStackCount, callback)
    end

    return true
end

local function CreateBatchResult(kind, requestedCount, deferredCount)
    return {
        kind = kind,
        requestedCount = requestedCount or 0,
        movedCount = 0,
        failedCount = 0,
        deferredCount = deferredCount or 0,
        failureReasons = {},
    }
end

local function RecordFailureReason(batchResult, reason)
    if not batchResult then
        return
    end

    reason = reason or "unknown"
    batchResult.failureReasons[reason] = (batchResult.failureReasons[reason] or 0) + 1
end

local function MoveEntriesSequentially(entries, moveFunc, callback, batchResult, index)
    batchResult = batchResult or CreateBatchResult("move", #entries, 0)
    index = index or 1

    if index > #entries then
        if callback then
            callback(batchResult)
        end
        return
    end

    local entry = entries[index]
    if not entry then
        batchResult.failedCount = batchResult.failedCount + 1
        RecordFailureReason(batchResult, "missing_entry")
        return MoveEntriesSequentially(entries, moveFunc, callback, batchResult, index + 1)
    end

    moveFunc(entry, function(success, reason)
        if success then
            batchResult.movedCount = batchResult.movedCount + 1
        else
            batchResult.failedCount = batchResult.failedCount + 1
            RecordFailureReason(batchResult, reason)
        end

        MoveEntriesSequentially(
            entries,
            moveFunc,
            callback,
            batchResult,
            index + 1
        )
    end)
end

local function BuildFailureReasonSummary(batchResult)
    if not batchResult or not batchResult.failureReasons then
        return nil
    end

    local parts = {}
    for reason, count in pairs(batchResult.failureReasons) do
        parts[#parts + 1] = string.format("%s=%d", tostring(reason), tonumber(count) or 0)
    end

    table.sort(parts)
    if #parts == 0 then
        return nil
    end

    return table.concat(parts, ", ")
end

local function CreateSellResult(requestedCount, skippedUnsellable)
    return {
        requestedCount = requestedCount or 0,
        soldStackCount = 0,
        soldEntryCount = 0,
        failedCount = 0,
        skippedUnsellable = skippedUnsellable or 0,
        skippedProtected = 0,
        totalValue = 0,
        failureReasons = {},
    }
end

local function GetTrashSellSkipReason(bagId, slotIndex)
    if bagId ~= BAG_BACKPACK or not AI.BagSlotHasItem(bagId, slotIndex) then
        return "missing_item"
    end

    local itemId = GetItemId(bagId, slotIndex)
    if AI.GetItemCategory(bagId, slotIndex, itemId) ~= AI.categories.TRASH then
        return "not_trash"
    end

    if IsItemPlayerLocked and IsItemPlayerLocked(bagId, slotIndex) then
        return "locked"
    end

    if IsItemStolen and IsItemStolen(bagId, slotIndex) then
        return "stolen"
    end

    if AI.IsProtectedTrashItem and AI.IsProtectedTrashItem(bagId, slotIndex) then
        return "protected"
    end

    local sellPrice = GetItemSellValueWithBonuses(bagId, slotIndex)
    if sellPrice == nil or sellPrice <= 0 then
        return "unsellable"
    end

    return nil
end

local function NotifyProtectedTrashSkipMessage(protectedCount)
    if not protectedCount or protectedCount <= 0 then
        return
    end

    if protectedCount == 1 then
        AI.Notify("AutoInventory: Skipped rare item protected", nil, { chat = false })
    else
        AI.Notify(string.format("AutoInventory: Skipped %d protected rare/legendary trash item(s)", protectedCount), nil, { chat = false })
    end
end

local function SellEntriesSequentially(entries, callback, sellResult, index)
    sellResult = sellResult or CreateSellResult(#entries, 0)
    index = index or 1

    if index > #entries then
        if callback then
            callback(sellResult)
        end
        return
    end

    local entry = entries[index]
    if not entry then
        sellResult.failedCount = sellResult.failedCount + 1
        RecordFailureReason(sellResult, "missing_entry")
        return SellEntriesSequentially(entries, callback, sellResult, index + 1)
    end

    local stackCount = entry.stackCount or GetSlotStackSize(entry.bagId, entry.slotIndex) or 1
    local sellPrice = entry.sellPrice
    if sellPrice == nil then
        sellPrice = GetItemSellValueWithBonuses(entry.bagId, entry.slotIndex) or 0
    end

    entry.stackCount = stackCount
    entry.sellPrice = sellPrice
    entry.totalValue = entry.totalValue or (sellPrice * stackCount)

    AI.SellItem(entry.bagId, entry.slotIndex, function(success, reason)
        if success then
            sellResult.soldEntryCount = sellResult.soldEntryCount + 1
            sellResult.soldStackCount = sellResult.soldStackCount + stackCount
            sellResult.totalValue = sellResult.totalValue + (entry.totalValue or 0)
        else
            sellResult.failedCount = sellResult.failedCount + 1
            RecordFailureReason(sellResult, reason)
        end

        SellEntriesSequentially(entries, callback, sellResult, index + 1)
    end)
end

local function NotifyBankBatchResult(batchResult, options)
    options = options or {}
    if not batchResult then
        return
    end

    if batchResult.movedCount > 0 and options.successMessage then
        AI.Notify(string.format(options.successMessage, batchResult.movedCount))
    end

    if batchResult.deferredCount > 0 and options.deferredMessage then
        AI.Notify(string.format(options.deferredMessage, batchResult.deferredCount, options.minimumFreeSlots or 0))
    end

    if batchResult.failedCount > 0 and options.failureMessage then
        local message = string.format(options.failureMessage, batchResult.failedCount)
        local reasonSummary = BuildFailureReasonSummary(batchResult)
        if reasonSummary then
            message = string.format("%s (%s)", message, reasonSummary)
        end
        AI.Notify(message)
    end
end

local function BuildSellConfirmationMessage(items, totalValue, skippedUnsellable, skippedProtected)
    local lines = {}
    local displayCount = math.min(#items, 10)

    for i = 1, displayCount do
        local item = items[i]
        lines[#lines + 1] = string.format("* %s", item.name)
    end

    if #items > displayCount then
        lines[#lines + 1] = string.format("... and %d more item(s)", #items - displayCount)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("Total value: %sg", ZO_CommaDelimitNumber(totalValue))

    if skippedUnsellable > 0 then
        lines[#lines + 1] = string.format("Skipped unsellable item(s): %d", skippedUnsellable)
    end

    if (skippedProtected or 0) > 0 then
        lines[#lines + 1] = string.format("Skipped protected rare/legendary item(s): %d", skippedProtected)
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Sell these trash items?"

    return table.concat(lines, "\n")
end

function AI.InitializeCore()
    if ZO_Dialogs_RegisterCustomDialog then
        ZO_Dialogs_RegisterCustomDialog(SELL_CONFIRM_DIALOG, {
            canQueue = false,
            mustChoose = true,
            title = {
                text = "AutoInventory",
            },
            mainText = {
                text = function(dialog)
                    return dialog.data and dialog.data.message or ""
                end,
            },
            buttons = {
                [1] = {
                    text = "Sell All",
                    callback = function(dialog)
                        AI._sellConfirmationPending = false
                        if dialog.data and dialog.data.items then
                            AI.ConfirmSellTrash(
                                dialog.data.items,
                                dialog.data.skippedUnsellable or 0,
                                dialog.data.skippedProtected or 0,
                                dialog.data.onComplete
                            )
                        end
                    end,
                },
                [2] = {
                    text = "Cancel",
                    callback = function(dialog)
                        AI._sellConfirmationPending = false
                        AI._storeSellHandledThisSession = true
                        if dialog and dialog.data and dialog.data.onComplete then
                            dialog.data.onComplete({
                                cancelled = true,
                                soldStackCount = 0,
                                totalValue = 0,
                                failedCount = 0,
                                skippedUnsellable = dialog.data.skippedUnsellable or 0,
                                skippedProtected = dialog.data.skippedProtected or 0,
                            })
                        end
                        AI.Notify("AutoInventory: Sell cancelled")
                    end,
                },
            },
        })
    end
end

function AI.CloseSellConfirmation()
    AI._sellConfirmationPending = false
    if ZO_Dialogs_ReleaseAllDialogsOfName then
        ZO_Dialogs_ReleaseAllDialogsOfName(SELL_CONFIRM_DIALOG)
    elseif ZO_Dialogs_ReleaseDialog then
        ZO_Dialogs_ReleaseDialog(SELL_CONFIRM_DIALOG)
    end
end

function AI.GetBagItemsByCategory(bagId, targetCategory)
    local items = {}
    local slotIndex = ZO_GetNextBagSlotIndex(bagId, nil)

    while slotIndex do
        if AI.BagSlotHasItem(bagId, slotIndex) then
            local itemId = GetItemId(bagId, slotIndex)
            local category = AI.GetItemCategory(bagId, slotIndex, itemId)

            if category == targetCategory then
                local itemLink = GetItemLink(bagId, slotIndex)
                items[#items + 1] = {
                    bagId = bagId,
                    slotIndex = slotIndex,
                    itemId = itemId,
                    name = zo_strformat("<<t:1>>", GetItemLinkName(itemLink)),
                    itemLink = itemLink,
                }
            end
        end

        slotIndex = ZO_GetNextBagSlotIndex(bagId, slotIndex)
    end

    return items
end

function AI.GetBankItemsByCategory(targetCategories)
    local items = {}
    local categorySet = {}

    for _, category in ipairs(targetCategories) do
        categorySet[category] = true
    end

    for _, bagId in ipairs({ BAG_BANK, BAG_SUBSCRIBER_BANK }) do
        local slotIndex = ZO_GetNextBagSlotIndex(bagId, nil)

        while slotIndex do
            if AI.BagSlotHasItem(bagId, slotIndex) then
                local itemId = GetItemId(bagId, slotIndex)
                local category = AI.GetItemCategory(bagId, slotIndex, itemId)

                if categorySet[category] then
                    local itemLink = GetItemLink(bagId, slotIndex)
                    items[#items + 1] = {
                        bagId = bagId,
                        slotIndex = slotIndex,
                        itemId = itemId,
                        itemLink = itemLink,
                        name = zo_strformat("<<t:1>>", GetItemLinkName(itemLink)),
                        category = category,
                    }
                end
            end

            slotIndex = ZO_GetNextBagSlotIndex(bagId, slotIndex)
        end
    end

    return items
end

function AI.MoveItem(sourceBag, sourceSlot, targetBag, callback)
    if sourceBag == BAG_BACKPACK and targetBag == BAG_BACKPACK then
        if callback then
            callback(false, "same_bag")
        end
        return false
    end

    if sourceBag == BAG_BANK or sourceBag == BAG_SUBSCRIBER_BANK then
        if targetBag == BAG_BACKPACK then
            return MoveBagItem(sourceBag, sourceSlot, targetBag, callback)
        end
    elseif sourceBag == BAG_BACKPACK then
        return AI.DepositItemToBank(sourceSlot, callback)
    end

    if callback then
        callback(false, "unsupported_move")
    end
    return false
end

function AI.DepositItemToBank(slotIndex, callback)
    if not IsBankOpen() or not AI.BagSlotHasItem(BAG_BACKPACK, slotIndex) then
        if callback then
            callback(false, "bank_closed_or_missing_item")
        end
        return false
    end

    if AI.IsBankDepositBlocked and AI.IsBankDepositBlocked(BAG_BACKPACK, slotIndex) then
        if callback then
            callback(false, "blocked_item")
        end
        return false
    end

    if AI.CanDepositItemToBank and not AI.CanDepositItemToBank(BAG_BACKPACK, slotIndex) then
        if callback then
            callback(false, "bank_full")
        end
        return false
    end

    local destBag = FindBankDepositDestination(BAG_BACKPACK, slotIndex)
    if destBag ~= nil then
        return MoveBagItem(BAG_BACKPACK, slotIndex, destBag, callback)
    end

    if callback then
        callback(false, "bank_full")
    end
    return false
end

function AI.SellItem(bagId, slotIndex, callback)
    if not (AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive()) then
        if callback then
            callback(false, "merchant_not_open")
        end
        return false
    end

    if not AI.BagSlotHasItem(bagId, slotIndex) then
        if callback then
            callback(false, "missing_source_item")
        end
        return false
    end

    local quantity = GetSlotStackSize(bagId, slotIndex)
    if not quantity or quantity <= 0 then
        if callback then
            callback(false, "empty_stack")
        end
        return false
    end

    local sellPrice = GetItemSellValueWithBonuses(bagId, slotIndex)
    if sellPrice and sellPrice > 0 then
        local originalItemId = GetItemId(bagId, slotIndex)
        local originalStackCount = quantity
        SellInventoryItem(bagId, slotIndex, quantity)
        if callback then
            FinishSellRequest(bagId, slotIndex, originalItemId, originalStackCount, callback)
        end
        return true
    end

    if callback then
        callback(false, "unsellable_item")
    end
    return false
end

function AI.CanSellTrashItem(bagId, slotIndex)
    return GetTrashSellSkipReason(bagId, slotIndex) == nil
end

function AI.GetSlotDisplayQuality(bagId, slotIndex)
    if not AI.BagSlotHasItem(bagId, slotIndex) then
        return nil
    end

    local itemLink = GetItemLink(bagId, slotIndex)
    if GetItemLinkDisplayQuality then
        return GetItemLinkDisplayQuality(itemLink)
    end

    return GetItemLinkQuality(itemLink)
end

function AI.IsProtectedTrashItem(bagId, slotIndex)
    if bagId ~= BAG_BACKPACK or not AI.BagSlotHasItem(bagId, slotIndex) then
        return true
    end

    if IsItemPlayerLocked and IsItemPlayerLocked(bagId, slotIndex) then
        return true
    end

    local quality = AI.GetSlotDisplayQuality(bagId, slotIndex)
    local epicThreshold = ITEM_DISPLAY_QUALITY_EPIC or ITEM_QUALITY_EPIC or 4
    local legendaryThreshold = ITEM_DISPLAY_QUALITY_LEGENDARY or ITEM_QUALITY_LEGENDARY or 5
    local settings = AI.sv and AI.sv.settings or {}

    if quality ~= nil and quality >= legendaryThreshold then
        return not settings.allowLegendaryTrash
    end

    if quality ~= nil and quality >= epicThreshold then
        return not settings.allowEpicTrash
    end

    return false
end

function AI.CanAutoTrashItem(bagId, slotIndex)
    return bagId == BAG_BACKPACK
        and AI.BagSlotHasItem(bagId, slotIndex)
        and not AI.IsProtectedTrashItem(bagId, slotIndex)
end

local function FinishDestroyRequest(bagId, slotIndex, originalItemId, callback)
    RunDelayedOnce("FinishDestroyRequest", 250, function()
        local destroyed = not AI.BagSlotHasItem(bagId, slotIndex) or GetItemId(bagId, slotIndex) ~= originalItemId
        if callback then
            callback(destroyed)
        end
    end)
end

function AI.DestroyInventoryItem(bagId, slotIndex, callback)
    if not AI.CanAutoTrashItem(bagId, slotIndex) then
        if callback then
            callback(false)
        end
        return false
    end

    local originalItemId = GetItemId(bagId, slotIndex)
    DestroyItem(bagId, slotIndex)

    RunDelayedOnce("DestroyConfirm", 50, function()
        if CallSecureProtected then
            CallSecureProtected("RespondToDestroyRequest", true)
        end
        FinishDestroyRequest(bagId, slotIndex, originalItemId, callback)
    end)

    return true
end

function AI.DestroyItemsSequentially(items, callback, index, destroyedCount, skippedCount)
    index = index or 1
    destroyedCount = destroyedCount or 0
    skippedCount = skippedCount or 0

    if index > #items then
        if callback then
            callback(destroyedCount, skippedCount)
        end
        return
    end

    local item = items[index]
    if not item or not AI.CanAutoTrashItem(item.bagId, item.slotIndex) then
        return AI.DestroyItemsSequentially(items, callback, index + 1, destroyedCount, skippedCount + 1)
    end

    AI.DestroyInventoryItem(item.bagId, item.slotIndex, function(success)
        AI.DestroyItemsSequentially(
            items,
            callback,
            index + 1,
            destroyedCount + (success and 1 or 0),
            skippedCount + (success and 0 or 1)
        )
    end)
end

function AI.ProcessBankTransactions(options)
    options = options or {}

    local bagFreeSlots = GetNumBagFreeSlots(BAG_BACKPACK)
    local settings = AI.sv.settings
    local minimumFreeSlots = options.forceWithdrawAll and 0 or math.max(0, tonumber(settings.bagSpaceBuffer) or 0)

    local retrieveItems = {}
    local deferredRetrieveCount = 0
    for _, itemData in ipairs(AI.GetBankItemsByCategory({ AI.categories.RETRIEVE })) do
        local canMove, _, consumesNewSlot = AI.CanMoveItemToBag(itemData.bagId, itemData.slotIndex, BAG_BACKPACK)
        if not canMove or (consumesNewSlot and bagFreeSlots <= minimumFreeSlots) then
            deferredRetrieveCount = deferredRetrieveCount + 1
        else
            if consumesNewSlot then
                bagFreeSlots = bagFreeSlots - 1
            end
            retrieveItems[#retrieveItems + 1] = itemData
        end
    end

    local auctionItems = {}
    local deferredAuctionCount = 0
    for _, itemData in ipairs(AI.GetBankItemsByCategory({ AI.categories.AUCTION })) do
        local canMove, _, consumesNewSlot = AI.CanMoveItemToBag(itemData.bagId, itemData.slotIndex, BAG_BACKPACK)
        if not canMove or (consumesNewSlot and bagFreeSlots <= minimumFreeSlots) then
            deferredAuctionCount = deferredAuctionCount + 1
        else
            if consumesNewSlot then
                bagFreeSlots = bagFreeSlots - 1
            end
            auctionItems[#auctionItems + 1] = itemData
        end
    end

    local itemsToDeposit = {}
    local deferredDepositCount = 0
    local blockedDepositCount = 0
    local projectedBankFreeSlots = GetNumBagFreeSlots(BAG_BANK)
    local projectedSubscriberBankFreeSlots = IsESOPlusSubscriber() and GetNumBagFreeSlots(BAG_SUBSCRIBER_BANK) or 0
    for _, itemData in ipairs(AI.GetBagItemsByCategory(BAG_BACKPACK, AI.categories.BANK)) do
        if AI.IsBankDepositBlocked and AI.IsBankDepositBlocked(itemData.bagId, itemData.slotIndex) then
            blockedDepositCount = blockedDepositCount + 1
        else
            local canDeposit, destBag, _, consumesNewSlot = AI.CanDepositItemToBank(itemData.bagId, itemData.slotIndex)
            if not canDeposit then
                deferredDepositCount = deferredDepositCount + 1
            elseif consumesNewSlot and destBag == BAG_BANK and projectedBankFreeSlots <= 0 then
                deferredDepositCount = deferredDepositCount + 1
            elseif consumesNewSlot and destBag == BAG_SUBSCRIBER_BANK and projectedSubscriberBankFreeSlots <= 0 then
                deferredDepositCount = deferredDepositCount + 1
            else
                if consumesNewSlot then
                    if destBag == BAG_BANK then
                        projectedBankFreeSlots = projectedBankFreeSlots - 1
                    elseif destBag == BAG_SUBSCRIBER_BANK then
                        projectedSubscriberBankFreeSlots = projectedSubscriberBankFreeSlots - 1
                    end
                end
                itemsToDeposit[#itemsToDeposit + 1] = itemData
            end
        end
    end

    MoveEntriesSequentially(retrieveItems, function(itemData, stepDone)
        AI.MoveItem(itemData.bagId, itemData.slotIndex, BAG_BACKPACK, stepDone)
    end, function(retrieveResult)
        NotifyBankBatchResult(retrieveResult, {
            successMessage = "AutoInventory: Retrieved %d item(s) from bank",
            deferredMessage = "AutoInventory: Left %d pull-from-bank item(s) in the bank to keep %d backpack slot(s) free",
            failureMessage = "AutoInventory: Failed to pull %d item(s) from bank",
            minimumFreeSlots = minimumFreeSlots,
        })

        MoveEntriesSequentially(auctionItems, function(itemData, stepDone)
            AI.MoveItem(itemData.bagId, itemData.slotIndex, BAG_BACKPACK, stepDone)
        end, function(auctionResult)
            NotifyBankBatchResult(auctionResult, {
                successMessage = "AutoInventory: Prepared %d trader item(s) from bank. Visit a guild trader to list them.",
                deferredMessage = "AutoInventory: Left %d trader-prep item(s) in the bank to keep %d backpack slot(s) free",
                failureMessage = "AutoInventory: Failed to prepare %d trader item(s) from bank",
                minimumFreeSlots = minimumFreeSlots,
            })

            MoveEntriesSequentially(itemsToDeposit, function(itemData, stepDone)
                AI.DepositItemToBank(itemData.slotIndex, stepDone)
            end, function(depositResult)
                NotifyBankBatchResult(depositResult, {
                    successMessage = "AutoInventory: Deposited %d item(s) into bank",
                    deferredMessage = "AutoInventory: Left %d bank item(s) in your backpack because the bank is full",
                    failureMessage = "AutoInventory: Failed to deposit %d item(s) into bank",
                })

                if blockedDepositCount > 0 then
                    AI.Notify(string.format("AutoInventory: Skipped %d bank item(s) that cannot be stored in the bank", blockedDepositCount))
                end

                if options.callback then
                    options.callback({
                        retrieve = retrieveResult,
                        auction = auctionResult,
                        deposit = depositResult,
                    })
                end
            end, CreateBatchResult("deposit", #itemsToDeposit, deferredDepositCount))
        end, CreateBatchResult("auction", #auctionItems, deferredAuctionCount))
    end, CreateBatchResult("retrieve", #retrieveItems, deferredRetrieveCount))
end

function AI.GetSellableTrashItems()
    local itemsToSell = {}
    local skippedUnsellable = 0
    local skippedProtected = 0
    local totalValue = 0

    for _, itemData in ipairs(AI.GetBagItemsByCategory(BAG_BACKPACK, AI.categories.TRASH)) do
        local skipReason = GetTrashSellSkipReason(itemData.bagId, itemData.slotIndex)
        if skipReason == nil then
            local sellPrice = GetItemSellValueWithBonuses(itemData.bagId, itemData.slotIndex)
            local stackCount = GetSlotStackSize(itemData.bagId, itemData.slotIndex)
            itemData.sellPrice = sellPrice or 0
            itemData.stackCount = stackCount or 1
            itemData.totalValue = itemData.sellPrice * itemData.stackCount
            itemsToSell[#itemsToSell + 1] = itemData
            totalValue = totalValue + itemData.totalValue
        elseif skipReason == "protected" then
            skippedProtected = skippedProtected + 1
        else
            skippedUnsellable = skippedUnsellable + 1
        end
    end

    return itemsToSell, totalValue, skippedUnsellable, skippedProtected
end

function AI.ShowSellConfirmation(itemsToSell, totalValue, skippedUnsellable, skippedProtected, onComplete)
    if not (AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive()) then
        return false
    end

    if not ZO_Dialogs_ShowDialog then
        return AI.ConfirmSellTrash(itemsToSell, skippedUnsellable, skippedProtected, onComplete)
    end

    if ZO_Dialogs_IsShowingDialog and ZO_Dialogs_IsShowingDialog(SELL_CONFIRM_DIALOG) then
        return true
    end

    if AI.CloseSellConfirmation then
        AI.CloseSellConfirmation()
    end

    AI._sellConfirmationPending = true

    ZO_Dialogs_ShowDialog(SELL_CONFIRM_DIALOG, {
        items = itemsToSell,
        skippedUnsellable = skippedUnsellable or 0,
        skippedProtected = skippedProtected or 0,
        onComplete = onComplete,
        message = BuildSellConfirmationMessage(itemsToSell, totalValue, skippedUnsellable or 0, skippedProtected or 0),
    })

    return true
end

function AI.ConfirmSellTrash(itemsToSell, skippedUnsellable, skippedProtected, onComplete)
    local cappedEntries = {}
    for index, itemData in ipairs(itemsToSell) do
        if index > VENDOR_TRANSACTION_LIMIT then
            break
        end
        cappedEntries[#cappedEntries + 1] = itemData
    end

    local cappedOffCount = math.max(0, #itemsToSell - #cappedEntries)
    SellEntriesSequentially(cappedEntries, function(sellResult)
        AI._sellConfirmationPending = false
        local hadSuccessfulSales = (sellResult.soldStackCount or 0) > 0
        local hadRetryableFailure = not hadSuccessfulSales and (sellResult.failedCount or 0) > 0
        local retryCount = AI._storeSellFailureRetryCount or 0

        if hadRetryableFailure and retryCount < 1 and AI.sv.settings.autoSell and AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive() then
            AI._storeSellHandledThisSession = false
            AI._storeSellFailureRetryCount = retryCount + 1
        else
            AI._storeSellHandledThisSession = true
            if hadSuccessfulSales then
                AI._storeSellFailureRetryCount = 0
            end
        end

        if sellResult.soldStackCount > 0 then
            AI.Notify(string.format("AutoInventory: Sold %d trash item(s) for %sg", sellResult.soldStackCount, ZO_CommaDelimitNumber(sellResult.totalValue)))
        else
            AI.Notify("AutoInventory: No trash items were sold")
        end

        local totalSkipped = (skippedUnsellable or 0) + cappedOffCount
        if totalSkipped > 0 then
            AI.Notify(string.format("AutoInventory: Skipped %d trash item(s)", totalSkipped), nil, { chat = false })
        end

        if (skippedProtected or 0) > 0 then
            NotifyProtectedTrashSkipMessage(skippedProtected)
        end

        if sellResult.failedCount > 0 then
            local reasonSummary = BuildFailureReasonSummary(sellResult)
            local message = string.format("AutoInventory: Failed to sell %d trash item(s)", sellResult.failedCount)
            if reasonSummary then
                message = string.format("%s (%s)", message, reasonSummary)
            end
            AI.Notify(message)
        end

        if cappedOffCount > 0 then
            AI.Notify(string.format("AutoInventory: Vendor transaction cap reached, %d trash item(s) left unsold", cappedOffCount))
        end

        if hadRetryableFailure and retryCount < 1 and AI.StartStoreSellWatcher then
            AI.Notify("AutoInventory: Retrying failed trash sale once")
            AI.StartStoreSellWatcher()
        end

        if onComplete then
            sellResult.skippedUnsellable = skippedUnsellable or 0
            sellResult.skippedProtected = skippedProtected or 0
            sellResult.cappedOffCount = cappedOffCount
            onComplete(sellResult)
        end
    end, CreateSellResult(#cappedEntries, skippedUnsellable or 0))

    return true
end

function AI.ProcessAutoSell(skipConfirmation)
    if not (AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive()) then
        return false
    end

    local itemsToSell, totalValue, skippedUnsellable, skippedProtected = AI.GetSellableTrashItems()
    if #itemsToSell == 0 then
        if skippedUnsellable > 0 then
            AI.Notify(string.format("AutoInventory: Skipped %d unsellable trash item(s)", skippedUnsellable), nil, { chat = false })
        end
        if skippedProtected > 0 then
            NotifyProtectedTrashSkipMessage(skippedProtected)
        end
        if skippedUnsellable > 0 or skippedProtected > 0 then
            AI._storeSellHandledThisSession = true
        end
        return (skippedUnsellable > 0 or skippedProtected > 0) and "handled" or false
    end

    local needsConfirmation = AI.sv.settings.confirmBeforeSelling
    local threshold = tonumber(AI.sv.settings.sellConfirmationThreshold) or 0
    if threshold > 0 then
        for _, item in ipairs(itemsToSell) do
            if (item.totalValue or 0) >= threshold then
                needsConfirmation = true
                break
            end
        end
    end

    if needsConfirmation and not skipConfirmation then
        if AI.ShowSellConfirmation(itemsToSell, totalValue, skippedUnsellable, skippedProtected) then
            return "dialog"
        end
        return false
    end

    AI.ConfirmSellTrash(itemsToSell, skippedUnsellable, skippedProtected)
    return "started"
end

function AI.ProcessSpecificCategoryAction(entries, category, callback)
    entries = entries or {}

    if category == AI.categories.BANK then
        local depositEntries = {}
        local deferredCount = 0
        local blockedCount = 0
        local projectedBankFreeSlots = GetNumBagFreeSlots(BAG_BANK)
        local projectedSubscriberBankFreeSlots = IsESOPlusSubscriber() and GetNumBagFreeSlots(BAG_SUBSCRIBER_BANK) or 0

        for _, itemData in ipairs(entries) do
            if itemData.bagId == BAG_BACKPACK then
                if AI.IsBankDepositBlocked and AI.IsBankDepositBlocked(itemData.bagId, itemData.slotIndex) then
                    blockedCount = blockedCount + 1
                else
                    local canDeposit, destBag, _, consumesNewSlot = AI.CanDepositItemToBank(itemData.bagId, itemData.slotIndex)
                    if not canDeposit then
                        deferredCount = deferredCount + 1
                    elseif consumesNewSlot and destBag == BAG_BANK and projectedBankFreeSlots <= 0 then
                        deferredCount = deferredCount + 1
                    elseif consumesNewSlot and destBag == BAG_SUBSCRIBER_BANK and projectedSubscriberBankFreeSlots <= 0 then
                        deferredCount = deferredCount + 1
                    else
                        if consumesNewSlot then
                            if destBag == BAG_BANK then
                                projectedBankFreeSlots = projectedBankFreeSlots - 1
                            elseif destBag == BAG_SUBSCRIBER_BANK then
                                projectedSubscriberBankFreeSlots = projectedSubscriberBankFreeSlots - 1
                            end
                        end
                        depositEntries[#depositEntries + 1] = itemData
                    end
                end
            end
        end

        MoveEntriesSequentially(depositEntries, function(itemData, stepDone)
            AI.DepositItemToBank(itemData.slotIndex, stepDone)
        end, function(result)
            result.blockedCount = blockedCount
            if callback then
                callback(result)
            end
        end, CreateBatchResult("deposit", #depositEntries, deferredCount))
        return true
    end

    if category == AI.categories.RETRIEVE or category == AI.categories.AUCTION then
        local transferEntries = {}
        local deferredCount = 0

        for _, itemData in ipairs(entries) do
            if IsBankBag(itemData.bagId) then
                local canMove = AI.CanMoveItemToBag(itemData.bagId, itemData.slotIndex, BAG_BACKPACK)
                if canMove then
                    transferEntries[#transferEntries + 1] = itemData
                else
                    deferredCount = deferredCount + 1
                end
            end
        end

        MoveEntriesSequentially(transferEntries, function(itemData, stepDone)
            AI.MoveItem(itemData.bagId, itemData.slotIndex, BAG_BACKPACK, stepDone)
        end, function(result)
            if callback then
                callback(result)
            end
        end, CreateBatchResult(category == AI.categories.AUCTION and "auction" or "retrieve", #transferEntries, deferredCount))
        return true
    end

    if category == AI.categories.TRASH then
        local sellEntries = {}
        local skippedUnsellable = 0
        local skippedProtected = 0
        local totalValue = 0

        for _, itemData in ipairs(entries) do
            local skipReason = GetTrashSellSkipReason(itemData.bagId, itemData.slotIndex)
            if skipReason == nil then
                itemData.sellPrice = GetItemSellValueWithBonuses(itemData.bagId, itemData.slotIndex) or 0
                itemData.stackCount = GetSlotStackSize(itemData.bagId, itemData.slotIndex) or 1
                itemData.totalValue = itemData.sellPrice * itemData.stackCount
                sellEntries[#sellEntries + 1] = itemData
                totalValue = totalValue + itemData.totalValue
            elseif skipReason == "protected" then
                skippedProtected = skippedProtected + 1
            else
                skippedUnsellable = skippedUnsellable + 1
            end
        end

        local cappedEntries = {}
        for index, itemData in ipairs(sellEntries) do
            if index > VENDOR_TRANSACTION_LIMIT then
                break
            end
            cappedEntries[#cappedEntries + 1] = itemData
        end

        local cappedOffCount = math.max(0, #sellEntries - #cappedEntries)

        local needsConfirmation = AI.sv.settings.confirmBeforeSelling
        local threshold = tonumber(AI.sv.settings.sellConfirmationThreshold) or 0
        if threshold > 0 then
            for _, itemData in ipairs(cappedEntries) do
                if (itemData.totalValue or 0) >= threshold then
                    needsConfirmation = true
                    break
                end
            end
        end

        if needsConfirmation then
            if AI.ShowSellConfirmation(cappedEntries, totalValue, skippedUnsellable, skippedProtected, callback) then
                return true
            end
        end

        SellEntriesSequentially(cappedEntries, function(result)
            result.skippedUnsellable = skippedUnsellable
            result.skippedProtected = skippedProtected
            result.cappedOffCount = cappedOffCount
            if callback then
                callback(result)
            end
        end, CreateSellResult(#cappedEntries, skippedUnsellable))
        return true
    end

    return false
end

function AI.ProcessAutoDestroy()
    -- Trash is merchant-only now. Keep this as a no-op so older call sites
    -- cannot destroy inventory items outside a vendor.
    return
end

function AI.SortBag(bagId)
    if not AI.sv.settings.autoSort then
        return
    end

    local items = {}
    local slotIndex = ZO_GetNextBagSlotIndex(bagId, nil)

    while slotIndex do
        if AI.BagSlotHasItem(bagId, slotIndex) then
            local itemLink = GetItemLink(bagId, slotIndex)
            items[#items + 1] = {
                slotIndex = slotIndex,
                quality = GetItemLinkQuality(itemLink),
                itemType = GetItemLinkItemType(itemLink),
                level = GetItemLinkRequiredLevel(itemLink) + GetItemLinkRequiredChampionPoints(itemLink),
                name = zo_strformat("<<t:1>>", GetItemLinkName(itemLink)),
                itemLink = itemLink,
            }
        end

        slotIndex = ZO_GetNextBagSlotIndex(bagId, slotIndex)
    end

    local sortOrder = AI.sv.settings.sortOrder
    table.sort(items, function(a, b)
        for _, sortKey in ipairs(sortOrder) do
            if sortKey == "quality" and a.quality ~= b.quality then
                return a.quality > b.quality
            elseif sortKey == "type" and a.itemType ~= b.itemType then
                return a.itemType < b.itemType
            elseif sortKey == "level" and a.level ~= b.level then
                return a.level > b.level
            elseif sortKey == "name" and a.name ~= b.name then
                return a.name < b.name
            end
        end

        return a.slotIndex < b.slotIndex
    end)

    return items
end
