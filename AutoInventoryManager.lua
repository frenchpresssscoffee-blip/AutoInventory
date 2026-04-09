AutoInventory = AutoInventory or {}
local AI = AutoInventory

AI.Manager = AI.Manager or {}
local Manager = AI.Manager

-- Constants
local WINDOW_NAME = "AutoInventoryManagerWindow"
local LIST_NAME = WINDOW_NAME .. "List"
local ROW_HEIGHT = 34
local MIN_WIDTH = 680
local MIN_HEIGHT = 430

local PALETTE = {
    overlay = {0.01, 0.01, 0.02, 0.48},
    windowBg = {0.028, 0.028, 0.032, 1},
    windowEdge = {0.10, 0.10, 0.12, 1},
    frameInner = {0.045, 0.045, 0.05, 1},
    frameSoft = {0.080, 0.074, 0.066, 0.95},
    frameLine = {0.18, 0.18, 0.20, 0.95},
    headerBg = {0.048, 0.042, 0.035, 0.985},
    headerEdge = {0.19, 0.17, 0.14, 0.92},
    amber = {0.56, 0.47, 0.31, 1},
    amberSoft = {0.20, 0.17, 0.11, 0.84},
    text = {0.93, 0.91, 0.85, 1},
    textMuted = {0.76, 0.74, 0.69, 1},
    textDim = {0.55, 0.54, 0.51, 1},
    searchBg = {0.060, 0.056, 0.050, 0.99},
    searchInset = {0.082, 0.082, 0.088, 1},
    listBg = {0.018, 0.018, 0.022, 0.98},
    listHeader = {0.11, 0.11, 0.12, 0.99},
    listHeaderLine = {0.24, 0.20, 0.11, 0.48},
    rowEven = {0.078, 0.078, 0.082, 0.72},
    rowOdd = {0.055, 0.055, 0.062, 0.68},
    rowHover = {0.12, 0.105, 0.075, 0.84},
    rowSelected = {0.17, 0.14, 0.085, 0.96},
    rowSelectedEdge = {0.50, 0.42, 0.22, 0.80},
    footerBg = {0.050, 0.050, 0.056, 0.98},
}

-- Local state
Manager.items = {}
Manager.filteredItems = {}
Manager.selectedItems = {}
Manager.filterCategory = "all"
Manager.searchText = ""

local function ApplyBackdropColors(control, center, edge, edgeSize)
    control:SetCenterColor(unpack(center))
    control:SetEdgeColor(unpack(edge))
    control:SetEdgeTexture("", edgeSize or 1, edgeSize or 1, edgeSize or 1, edgeSize or 1)
end

local function SetLabelColor(label, color)
    label:SetColor(color[1], color[2], color[3], color[4] or 1)
end

local function CreateBackdrop(name, parent, center, edge, edgeSize)
    local backdrop = WINDOW_MANAGER:CreateControl(name, parent, CT_BACKDROP)
    ApplyBackdropColors(backdrop, center, edge, edgeSize)
    return backdrop
end

local function NormalizeSearchText(text)
    text = text or ""
    text = text:gsub("|c%x%x%x%x%x%x", "")
    text = text:gsub("|r", "")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", "")
    text = text:gsub("%s+$", "")
    return zo_strlower(text)
end

local function GetCategoryColorArray(category, alpha)
    local colorDef = AI.GetCategoryColor and AI.GetCategoryColor(category)
    if colorDef and colorDef.UnpackRGB then
        local r, g, b = colorDef:UnpackRGB()
        return { r, g, b, alpha or 1 }
    end

    return { PALETTE.textMuted[1], PALETTE.textMuted[2], PALETTE.textMuted[3], alpha or 1 }
end

local function ScaleCategoryColor(category, scale, alpha)
    local color = GetCategoryColorArray(category, alpha or 1)
    return {
        color[1] * scale,
        color[2] * scale,
        color[3] * scale,
        alpha or color[4] or 1,
    }
end

local function ScaleColorArray(color, scale, alpha)
    return {
        (color[1] or 0) * scale,
        (color[2] or 0) * scale,
        (color[3] or 0) * scale,
        alpha or color[4] or 1,
    }
end

local function IsBankBag(bagId)
    return bagId == BAG_BANK or bagId == BAG_SUBSCRIBER_BANK
end

local function IsStoreOpen()
    return AI.IsStoreWindowOpen and AI.IsStoreWindowOpen()
end

local function IsSellWindowOpen()
    return AI.IsMerchantInteractionActive and AI.IsMerchantInteractionActive()
end

local function GetSelectionKey(bagId, slotIndex, itemId)
    local storageKey = AI.GetItemStorageKey and AI.GetItemStorageKey(bagId, slotIndex, itemId)
    if storageKey then
        return "stored:" .. storageKey
    end

    local itemLink = ""
    if AI.BagSlotHasItem and AI.BagSlotHasItem(bagId, slotIndex) then
        itemLink = GetItemLink(bagId, slotIndex) or ""
    end

    return string.format(
        "slot:%s:%s:%s:%s",
        tostring(bagId or 0),
        tostring(slotIndex or 0),
        tostring(itemId or 0),
        tostring(itemLink)
    )
end

local function ScheduleManagerUpdate(updateKey, delayMs, callback)
    if AI.ScheduleSingleUpdate then
        AI.ScheduleSingleUpdate("AutoInventoryManagerUpdate:" .. tostring(updateKey), delayMs, callback)
    else
        zo_callLater(callback, delayMs)
    end
end

local function ShouldHideManagedItemForFilter(item, filterCategory)
    if filterCategory == "all" or not item then
        return false
    end

    local bagId = item.bagId
    local slotIndex = item.slotIndex
    local category = item.category

    if category == AI.categories.BANK then
        if IsBankBag(bagId) then
            return true
        end

        return bagId == BAG_BACKPACK
            and IsBankOpen()
            and AI.CanDepositItemToBank
            and not AI.CanDepositItemToBank(bagId, slotIndex)
    end

    if category == AI.categories.RETRIEVE and bagId == BAG_BACKPACK then
        return true
    end

    return false
end

local function NotifySpecificCategoryActionResult(category, result)
    if not result then
        return
    end

    if category == AI.categories.BANK then
        if result.movedCount and result.movedCount > 0 then
            AI.Notify(string.format("AutoInventory: Deposited %d selected item(s) into bank", result.movedCount))
        end
        if result.blockedCount and result.blockedCount > 0 then
            AI.Notify(string.format("AutoInventory: Skipped %d selected item(s) that cannot be stored in the bank", result.blockedCount))
        end
        if result.deferredCount and result.deferredCount > 0 then
            AI.Notify(string.format("AutoInventory: Left %d selected item(s) in backpack because the bank has no room", result.deferredCount))
        end
        if result.failedCount and result.failedCount > 0 then
            AI.Notify(string.format("AutoInventory: Failed to deposit %d selected item(s)", result.failedCount))
        end
        return
    end

    if category == AI.categories.RETRIEVE then
        if result.movedCount and result.movedCount > 0 then
            AI.Notify(string.format("AutoInventory: Pulled %d selected item(s) from bank", result.movedCount))
        end
        if result.deferredCount and result.deferredCount > 0 then
            AI.Notify(string.format("AutoInventory: Could not pull %d selected item(s) because your backpack has no room", result.deferredCount))
        end
        if result.failedCount and result.failedCount > 0 then
            AI.Notify(string.format("AutoInventory: Failed to pull %d selected item(s) from bank", result.failedCount))
        end
        return
    end

    if category == AI.categories.AUCTION then
        if result.movedCount and result.movedCount > 0 then
            AI.Notify(string.format("AutoInventory: Prepared %d selected trader item(s) from bank", result.movedCount))
        end
        if result.deferredCount and result.deferredCount > 0 then
            AI.Notify(string.format("AutoInventory: Could not prepare %d selected trader item(s) because your backpack has no room", result.deferredCount))
        end
        if result.failedCount and result.failedCount > 0 then
            AI.Notify(string.format("AutoInventory: Failed to prepare %d selected trader item(s)", result.failedCount))
        end
        return
    end

    if category == AI.categories.TRASH then
        if result.soldStackCount and result.soldStackCount > 0 then
            AI.Notify(string.format("AutoInventory: Sold %d selected trash item(s) for %sg", result.soldStackCount, ZO_CommaDelimitNumber(result.totalValue or 0)))
        end
        local skippedCount = (result.skippedUnsellable or 0) + (result.cappedOffCount or 0)
        if skippedCount > 0 then
            AI.Notify(string.format("AutoInventory: Skipped %d selected trash item(s)", skippedCount), nil, { chat = false })
        end
        if result.skippedProtected and result.skippedProtected > 0 then
            if result.skippedProtected == 1 then
                AI.Notify("AutoInventory: Skipped rare item protected", nil, { chat = false })
            else
                AI.Notify(string.format("AutoInventory: Skipped %d protected selected rare/legendary trash item(s)", result.skippedProtected), nil, { chat = false })
            end
        end
        if result.failedCount and result.failedCount > 0 then
            AI.Notify(string.format("AutoInventory: Failed to sell %d selected trash item(s)", result.failedCount))
        end
    end
end

local function CountSelectedItems()
    local count = 0
    for _ in pairs(Manager.selectedItems or {}) do
        count = count + 1
    end
    return count
end

local function DescribeItem(item)
    if not item then
        return "nil-item"
    end

    return string.format(
        "%s [key=%s bag=%s slot=%s itemId=%s cat=%s]",
        tostring(item.name or "?"),
        tostring(item.selectionKey or "?"),
        tostring(item.bagId or "?"),
        tostring(item.slotIndex or "?"),
        tostring(item.itemId or "?"),
        tostring(item.category or "?")
    )
end

local function LogSelectedEntries(prefix, items)
    if not (AI.DebugManagerLog and AI.IsManagerDebugEnabled and AI.IsManagerDebugEnabled()) then
        return
    end

    AI.DebugManagerLog(string.format("%s count=%d selectedMap=%d filter=%s search=%s", prefix, #items, CountSelectedItems(), tostring(Manager.filterCategory), tostring(Manager.searchText)))
    for index, item in ipairs(items) do
        AI.DebugManagerLog(string.format("%s[%d] %s", prefix, index, DescribeItem(item)))
    end
end

local function LogCategoryCounts(prefix)
    if not (AI.DebugManagerLog and AI.IsManagerDebugEnabled and AI.IsManagerDebugEnabled()) then
        return
    end

    local totalCounts = {
        all = 0,
        unassigned = 0,
        keep = 0,
        bank = 0,
        retrieve = 0,
        auction = 0,
        trash = 0,
    }
    local filteredCounts = {
        all = 0,
        unassigned = 0,
        keep = 0,
        bank = 0,
        retrieve = 0,
        auction = 0,
        trash = 0,
    }

    for _, item in ipairs(Manager.items or {}) do
        totalCounts.all = totalCounts.all + 1
        totalCounts[item.category or "unassigned"] = (totalCounts[item.category or "unassigned"] or 0) + 1
    end

    for _, item in ipairs(Manager.filteredItems or {}) do
        filteredCounts.all = filteredCounts.all + 1
        filteredCounts[item.category or "unassigned"] = (filteredCounts[item.category or "unassigned"] or 0) + 1
    end

    AI.DebugManagerLog(string.format(
        "%s totals all=%d unassigned=%d keep=%d bank=%d retrieve=%d auction=%d trash=%d | filtered all=%d unassigned=%d keep=%d bank=%d retrieve=%d auction=%d trash=%d | filter=%s search=%s",
        prefix,
        totalCounts.all,
        totalCounts.unassigned or 0,
        totalCounts.keep or 0,
        totalCounts.bank or 0,
        totalCounts.retrieve or 0,
        totalCounts.auction or 0,
        totalCounts.trash or 0,
        filteredCounts.all,
        filteredCounts.unassigned or 0,
        filteredCounts.keep or 0,
        filteredCounts.bank or 0,
        filteredCounts.retrieve or 0,
        filteredCounts.auction or 0,
        filteredCounts.trash or 0,
        tostring(Manager.filterCategory),
        tostring(Manager.searchText)
    ))
end

function Manager.Initialize()
    Manager.CreateWindow()
    Manager.CreateControls()
    Manager.InitializeScrollList()
    Manager.SetupDragHandler()

    if AI.sv.managerPos then
        Manager.window:ClearAnchors()
        Manager.window:SetAnchor(TOPLEFT, GuiRoot, TOPLEFT, AI.sv.managerPos.x, AI.sv.managerPos.y)
    end

    Manager.Hide()
end

function Manager.ClearSelection()
    Manager.selectedItems = {}
    Manager.selectAllChecked = false

    if Manager.selectAll then
        Manager.UpdateCheckboxTexture(Manager.selectAll, false)
    end

    for _, item in ipairs(Manager.items or {}) do
        item.selected = false
    end
end

function Manager.SelectOnly(selectionKey)
    Manager.selectedItems = {}

    for _, item in ipairs(Manager.items or {}) do
        local isSelected = item.selectionKey == selectionKey
        item.selected = isSelected
        if isSelected then
            Manager.selectedItems[selectionKey] = true
        end
    end

    Manager.selectAllChecked = false
    if Manager.selectAll then
        Manager.UpdateCheckboxTexture(Manager.selectAll, false)
    end

    AI.DebugManagerLog(string.format("SelectOnly key=%s selectedMap=%d", tostring(selectionKey), CountSelectedItems()))
end

function Manager.ToggleSelection(selectionKey)
    local currentSelected = Manager.selectedItems[selectionKey] and true or false
    local nextSelected = not currentSelected
    Manager.SetItemSelected(selectionKey, nextSelected)

    Manager.selectAllChecked = false
    if Manager.selectAll then
        Manager.UpdateCheckboxTexture(Manager.selectAll, false)
    end

    AI.DebugManagerLog(string.format("ToggleSelection key=%s selected=%s selectedMap=%d", tostring(selectionKey), tostring(nextSelected), CountSelectedItems()))
    return nextSelected
end

function Manager.PruneSelection()
    local validSelections = {}

    for _, item in ipairs(Manager.items or {}) do
        if Manager.selectedItems[item.selectionKey] then
            validSelections[item.selectionKey] = true
        end
    end

    Manager.selectedItems = validSelections
end

function Manager.OnInventoryChanged()
    if not Manager.window or Manager.window:IsHidden() then
        return
    end

    if Manager._refreshQueued then
        return
    end

    Manager._refreshQueued = true
    ScheduleManagerUpdate("InventoryRefresh", 100, function()
        Manager._refreshQueued = false
        if Manager.window and not Manager.window:IsHidden() then
            Manager.RefreshData()
        end
    end)
end

function Manager.CreateWindow()
    local overlay = CreateBackdrop(WINDOW_NAME .. "Overlay", GuiRoot, PALETTE.overlay, {0, 0, 0, 0}, 1)
    overlay:SetAnchorFill(GuiRoot)
    overlay:SetDrawLayer(DL_BACKGROUND)
    overlay:SetDrawTier(DT_HIGH)
    overlay:SetDrawLevel(1)
    overlay:SetHidden(true)
    overlay:SetMouseEnabled(false)

    local window = WINDOW_MANAGER:CreateTopLevelWindow(WINDOW_NAME)
    window:SetAnchor(CENTER, GuiRoot, CENTER, 0, 0)
    window:SetDrawLayer(DL_OVERLAY)
    window:SetDrawTier(DT_HIGH)
    window:SetDrawLevel(2)
    window:SetDimensions(760, 500)
    window:SetMovable(true)
    window:SetMouseEnabled(true)
    window:SetClampedToScreen(true)
    window:SetHidden(true)
    window:SetResizeHandleSize(10)
    -- Set min/max dimensions using ESO's SetDimensionConstraints (minW, minH, maxW, maxH)
    -- Max values 0 means no maximum constraint
    if window.SetDimensionConstraints then
        window:SetDimensionConstraints(MIN_WIDTH, MIN_HEIGHT, 0, 0)
    end

    local matte = CreateBackdrop(WINDOW_NAME .. "Matte", window, {0.02, 0.02, 0.025, 1}, {0, 0, 0, 0}, 1)
    matte:SetAnchorFill(window)

    local bg = CreateBackdrop(WINDOW_NAME .. "Bg", window, PALETTE.windowBg, PALETTE.windowEdge, 1)
    bg:SetAnchorFill(window)

    local innerFrame = CreateBackdrop(WINDOW_NAME .. "InnerFrame", window, PALETTE.frameInner, PALETTE.frameLine, 1)
    innerFrame:SetAnchor(TOPLEFT, window, TOPLEFT, 2, 2)
    innerFrame:SetAnchor(BOTTOMRIGHT, window, BOTTOMRIGHT, -2, -2)

    local titleBg = CreateBackdrop(WINDOW_NAME .. "TitleBg", window, PALETTE.headerBg, PALETTE.headerEdge, 1)
    titleBg:SetAnchor(TOPLEFT, window, TOPLEFT, 2, 2)
    titleBg:SetAnchor(TOPRIGHT, window, TOPRIGHT, -2, 2)
    titleBg:SetHeight(42)

    local titleTexture = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "TitleTexture", titleBg, CT_TEXTURE)
    titleTexture:SetAnchorFill(titleBg)
    titleTexture:SetTexture("/esoui/art/characterwindow/characterwindow_bottombarbg.dds")
    titleTexture:SetAlpha(0.18)

    local titleAccent = CreateBackdrop(WINDOW_NAME .. "TitleAccent", titleBg, PALETTE.amber, {0, 0, 0, 0}, 1)
    titleAccent:SetAnchor(TOPLEFT, titleBg, TOPLEFT, 0, 0)
    titleAccent:SetAnchor(TOPRIGHT, titleBg, TOPRIGHT, 0, 0)
    titleAccent:SetHeight(2)

    local titleShadow = CreateBackdrop(WINDOW_NAME .. "TitleShadow", titleBg, {0, 0, 0, 0.20}, {0, 0, 0, 0}, 1)
    titleShadow:SetAnchor(BOTTOMLEFT, titleBg, BOTTOMLEFT, 0, 0)
    titleShadow:SetAnchor(BOTTOMRIGHT, titleBg, BOTTOMRIGHT, 0, 0)
    titleShadow:SetHeight(8)

    local icon = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Icon", window, CT_TEXTURE)
    icon:SetDimensions(26, 26)
    icon:SetAnchor(TOPLEFT, window, TOPLEFT, 14, 12)
    icon:SetTexture("/esoui/art/inventory/inventory_tabicon_items_up.dds")
    icon:SetColor(PALETTE.amber[1], PALETTE.amber[2], PALETTE.amber[3], 1)

    local title = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Title", window, CT_LABEL)
    title:SetFont("ZoFontWinH2")
    SetLabelColor(title, PALETTE.text)
    title:SetText("AutoInventory Manager")
    title:SetAnchor(LEFT, icon, RIGHT, 10, 0)

    -- Close button
    local closeButton = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Close", window, CT_BUTTON)
    closeButton:SetDimensions(24, 24)
    closeButton:SetAnchor(TOPRIGHT, window, TOPRIGHT, -8, 8)
    closeButton:SetNormalTexture("/esoui/art/buttons/closebutton_up.dds")
    closeButton:SetPressedTexture("/esoui/art/buttons/closebutton_down.dds")
    closeButton:SetMouseOverTexture("/esoui/art/buttons/closebutton_over.dds")
    closeButton:SetHandler("OnClicked", function() Manager.Hide() end)

    -- Minimize button
    local minButton = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Minimize", window, CT_BUTTON)
    minButton:SetDimensions(24, 24)
    minButton:SetAnchor(TOPRIGHT, closeButton, TOPLEFT, -4, 0)
    minButton:SetNormalTexture("/esoui/art/buttons/minimize_up.dds")
    minButton:SetPressedTexture("/esoui/art/buttons/minimize_down.dds")
    minButton:SetMouseOverTexture("/esoui/art/buttons/minimize_over.dds")
    minButton:SetHandler("OnClicked", function() Manager.Minimize() end)

    Manager.window = window
    Manager.overlay = overlay
    Manager.titleBg = titleBg
end

function Manager.CreateControls()
    local window = Manager.window

    local searchEdit = CreateBackdrop(WINDOW_NAME .. "SearchEdit", window, PALETTE.searchBg, PALETTE.frameLine, 1)
    searchEdit:SetAnchor(TOPLEFT, Manager.titleBg, BOTTOMLEFT, 10, 8)
    searchEdit:SetAnchor(TOPRIGHT, Manager.titleBg, BOTTOMRIGHT, -10, 8)
    searchEdit:SetHeight(24)
    searchEdit:SetMouseEnabled(true)

    local searchInset = CreateBackdrop(WINDOW_NAME .. "SearchInset", searchEdit, PALETTE.searchInset, {0, 0, 0, 0}, 1)
    searchInset:SetAnchor(TOPLEFT, searchEdit, TOPLEFT, 1, 1)
    searchInset:SetAnchor(BOTTOMRIGHT, searchEdit, BOTTOMRIGHT, -1, -1)
    searchInset:SetMouseEnabled(false)

    local searchInput = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "SearchInput", searchEdit, CT_EDITBOX)
    searchInput:SetAnchor(TOPLEFT, searchEdit, TOPLEFT, 8, 1)
    searchInput:SetAnchor(BOTTOMRIGHT, searchEdit, BOTTOMRIGHT, -8, -1)
    searchInput:SetFont("ZoFontGameSmall")
    searchInput:SetEditEnabled(true)
    searchInput:SetMouseEnabled(true)
    searchInput:SetTextType(TEXT_TYPE_ALL)
    searchInput:SetMaxInputChars(60)
    searchInput:SetHandler("OnMouseDown", function(editControl)
        editControl:TakeFocus()
    end)
    searchInput:SetHandler("OnMouseUp", function(editControl)
        editControl:TakeFocus()
    end)
    searchInput:SetHandler("OnEscape", function(editControl)
        editControl:LoseFocus()
    end)
    searchEdit:SetHandler("OnMouseDown", function()
        searchInput:TakeFocus()
    end)
    searchEdit:SetHandler("OnMouseUp", function()
        searchInput:TakeFocus()
    end)

    local searchHint = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "SearchHint", searchEdit, CT_LABEL)
    searchHint:SetFont("ZoFontGameSmall")
    SetLabelColor(searchHint, PALETTE.textDim)
    searchHint:SetText("Search")
    searchHint:SetAnchor(LEFT, searchEdit, LEFT, 9, 0)
    searchHint:SetMouseEnabled(false)

    local searchFocused = false

    local function UpdateSearchHint()
        local text = searchInput:GetText() or ""
        searchHint:SetHidden(text ~= "" or searchFocused)
    end

    searchInput:SetHandler("OnTextChanged", function(editControl)
        Manager.searchText = NormalizeSearchText(editControl:GetText())
        UpdateSearchHint()
        Manager.RefreshList()
    end)
    searchInput:SetHandler("OnFocusGained", function()
        searchFocused = true
        ApplyBackdropColors(searchEdit, {0.10, 0.09, 0.075, 1}, PALETTE.amberSoft, 1)
        UpdateSearchHint()
    end)
    searchInput:SetHandler("OnFocusLost", function()
        searchFocused = false
        ApplyBackdropColors(searchEdit, PALETTE.searchBg, PALETTE.frameLine, 1)
        UpdateSearchHint()
    end)
    UpdateSearchHint()

    Manager.searchInput = searchInput

    local filterFrame = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "FilterFrame", window, CT_CONTROL)
    filterFrame:SetAnchor(TOPLEFT, searchEdit, BOTTOMLEFT, -10, 8)
    filterFrame:SetAnchor(TOPRIGHT, searchEdit, BOTTOMRIGHT, 10, 8)
    filterFrame:SetHeight(30)

    local filterBg = CreateBackdrop(WINDOW_NAME .. "FilterBg", filterFrame, {0.035, 0.035, 0.04, 0.94}, {0.10, 0.10, 0.11, 0.80}, 1)
    filterBg:SetAnchorFill(filterFrame)

    local filters = {
        { key = "all", label = "All", color = PALETTE.amber },
        { key = AI.categories.KEEP, label = "Keep", color = GetCategoryColorArray(AI.categories.KEEP) },
        { key = AI.categories.BANK, label = "Bank", color = GetCategoryColorArray(AI.categories.BANK) },
        { key = AI.categories.RETRIEVE, label = AI.GetCategoryTabLabel and AI.GetCategoryTabLabel(AI.categories.RETRIEVE) or "Pull", color = GetCategoryColorArray(AI.categories.RETRIEVE) },
        { key = AI.categories.AUCTION, label = AI.GetCategoryTabLabel and AI.GetCategoryTabLabel(AI.categories.AUCTION) or "Trader", color = GetCategoryColorArray(AI.categories.AUCTION) },
        { key = AI.categories.TRASH, label = "Trash", color = GetCategoryColorArray(AI.categories.TRASH) },
    }

    local lastButton = nil
    for i, filter in ipairs(filters) do
        local button = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Filter" .. filter.key, filterFrame, CT_BUTTON)
        button:SetDimensions(i == 1 and 72 or 80, 26)
        if i == 1 then
            button:SetAnchor(LEFT, filterFrame, LEFT, 6, 0)
        else
            button:SetAnchor(LEFT, lastButton, RIGHT, 6, 0)
        end

        local btnBg = CreateBackdrop(WINDOW_NAME .. "Filter" .. filter.key .. "Bg", button, {0.075, 0.075, 0.082, 0.98}, {0.16, 0.16, 0.18, 0.95}, 1)
        btnBg:SetAnchorFill(button)

        local btnShade = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Filter" .. filter.key .. "Shade", button, CT_TEXTURE)
        btnShade:SetAnchorFill(button)
        btnShade:SetTexture("/esoui/art/characterwindow/characterwindow_bottombarbg.dds")
        btnShade:SetAlpha(0.12)

        local accent = CreateBackdrop(WINDOW_NAME .. "Filter" .. filter.key .. "Accent", button, filter.color, {0, 0, 0, 0}, 1)
        accent:SetAnchor(TOPLEFT, button, TOPLEFT, 0, 0)
        accent:SetAnchor(TOPRIGHT, button, TOPRIGHT, 0, 0)
        accent:SetHeight(2)

        local sideAccent = CreateBackdrop(WINDOW_NAME .. "Filter" .. filter.key .. "SideAccent", button, filter.color, {0, 0, 0, 0}, 1)
        sideAccent:SetAnchor(TOPLEFT, button, TOPLEFT, 0, 0)
        sideAccent:SetAnchor(BOTTOMLEFT, button, BOTTOMLEFT, 0, 0)
        sideAccent:SetWidth(2)

        local btnLabel = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Filter" .. filter.key .. "Label", button, CT_LABEL)
        btnLabel:SetFont("ZoFontGameSmall")
        SetLabelColor(btnLabel, ScaleColorArray(filter.color, 0.88, 1))
        btnLabel:SetText(filter.label)
        btnLabel:SetAnchor(CENTER, button, CENTER, 0, 0)

        button:SetHandler("OnClicked", function()
            if filter.key ~= "all" and Manager.HasVisibleSelection() then
                Manager.SetSelectedItemsCategory(filter.key)
                return
            end

            Manager.filterCategory = filter.key
            Manager.UpdateFilterButtons()
            Manager.RefreshList()
        end)

        button:SetHandler("OnMouseEnter", function()
            Manager["filterBtn_" .. filter.key].hovered = true
            Manager.UpdateFilterButtons()
        end)
        button:SetHandler("OnMouseExit", function()
            Manager["filterBtn_" .. filter.key].hovered = false
            Manager.UpdateFilterButtons()
        end)

        Manager["filterBtn_" .. filter.key] = {
            button = button,
            bg = btnBg,
            accent = accent,
            sideAccent = sideAccent,
            label = btnLabel,
            color = filter.color,
            hovered = false,
        }
        lastButton = button
    end

    local clearButton = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "ClearCategory", filterFrame, CT_BUTTON)
    clearButton:SetDimensions(82, 24)
    clearButton:SetAnchor(RIGHT, filterFrame, RIGHT, -6, 0)

    local clearButtonBg = CreateBackdrop(WINDOW_NAME .. "ClearCategoryBg", clearButton, {0.070, 0.070, 0.076, 0.98}, {0.16, 0.16, 0.18, 0.95}, 1)
    clearButtonBg:SetAnchorFill(clearButton)

    local clearButtonAccent = CreateBackdrop(WINDOW_NAME .. "ClearCategoryAccent", clearButton, {0.58, 0.56, 0.50, 0.38}, {0, 0, 0, 0}, 1)
    clearButtonAccent:SetAnchor(TOPLEFT, clearButton, TOPLEFT, 0, 0)
    clearButtonAccent:SetAnchor(TOPRIGHT, clearButton, TOPRIGHT, 0, 0)
    clearButtonAccent:SetHeight(2)

    local clearButtonLabel = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "ClearCategoryLabel", clearButton, CT_LABEL)
    clearButtonLabel:SetFont("ZoFontGameSmall")
    SetLabelColor(clearButtonLabel, {0.82, 0.80, 0.76, 1})
    clearButtonLabel:SetText("Remove")
    clearButtonLabel:SetAnchor(CENTER, clearButton, CENTER, 0, 0)
    clearButtonLabel:SetMouseEnabled(false)

    clearButton:SetHandler("OnClicked", function()
        if Manager.HasVisibleSelection() then
            Manager.ClearSelectedItemCategories()
        end
    end)
    clearButton:SetHandler("OnMouseEnter", function()
        ApplyBackdropColors(clearButtonBg, {0.090, 0.090, 0.098, 0.98}, {0.24, 0.24, 0.26, 1}, 1)
        clearButtonAccent:SetCenterColor(0.74, 0.71, 0.62, 0.55)
    end)
    clearButton:SetHandler("OnMouseExit", function()
        ApplyBackdropColors(clearButtonBg, {0.070, 0.070, 0.076, 0.98}, {0.16, 0.16, 0.18, 0.95}, 1)
        clearButtonAccent:SetCenterColor(0.58, 0.56, 0.50, 0.38)
    end)

    Manager.UpdateFilterButtons()

    local listContainer = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "ListContainer", window, CT_CONTROL)
    listContainer:SetAnchor(TOPLEFT, filterFrame, BOTTOMLEFT, 0, 10)
    listContainer:SetAnchor(BOTTOMRIGHT, window, BOTTOMRIGHT, -12, -76)

    local listBg = CreateBackdrop(WINDOW_NAME .. "ListBg", listContainer, PALETTE.listBg, {0.16, 0.16, 0.18, 0.85}, 1)
    listBg:SetAnchorFill(listContainer)

    Manager.listContainer = listContainer

    local headerHeight = 26
    local headers = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "Headers", listContainer, CT_CONTROL)
    headers:SetAnchor(TOPLEFT, listContainer, TOPLEFT, 0, 0)
    headers:SetAnchor(TOPRIGHT, listContainer, TOPRIGHT, 0, 0)
    headers:SetHeight(26)

    local headerBg = CreateBackdrop(WINDOW_NAME .. "HeaderBg", headers, PALETTE.listHeader, {0.16, 0.16, 0.18, 0.95}, 1)
    headerBg:SetAnchorFill(headers)

    local headerAccent = CreateBackdrop(WINDOW_NAME .. "HeaderAccent", headers, PALETTE.listHeaderLine, {0, 0, 0, 0}, 1)
    headerAccent:SetAnchor(BOTTOMLEFT, headers, BOTTOMLEFT, 0, 0)
    headerAccent:SetAnchor(BOTTOMRIGHT, headers, BOTTOMRIGHT, 0, 0)
    headerAccent:SetHeight(1)

    local xOffset = 5

    local selHeader = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "HeaderSel", headers, CT_LABEL)
    selHeader:SetFont("ZoFontGameSmall")
    SetLabelColor(selHeader, PALETTE.textDim)
    selHeader:SetText("")
    selHeader:SetAnchor(LEFT, headers, LEFT, xOffset + 8, 0)
    selHeader:SetDimensions(30, headerHeight)
    xOffset = xOffset + 35

    local iconHeader = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "HeaderIcon", headers, CT_LABEL)
    iconHeader:SetFont("ZoFontGameSmall")
    SetLabelColor(iconHeader, PALETTE.textDim)
    iconHeader:SetText("")
    iconHeader:SetAnchor(LEFT, headers, LEFT, xOffset, 0)
    iconHeader:SetDimensions(40, headerHeight)
    xOffset = xOffset + 45

    local nameHeader = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "HeaderName", headers, CT_LABEL)
    nameHeader:SetFont("ZoFontGameSmall")
    SetLabelColor(nameHeader, PALETTE.textMuted)
    nameHeader:SetText("Item Name")
    nameHeader:SetAnchor(LEFT, headers, LEFT, xOffset, 0)
    nameHeader:SetAnchor(RIGHT, headers, RIGHT, -190, 0)

    local valueHeader = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "HeaderValue", headers, CT_LABEL)
    valueHeader:SetFont("ZoFontGameSmall")
    SetLabelColor(valueHeader, PALETTE.textMuted)
    valueHeader:SetText("Value")
    valueHeader:SetAnchor(RIGHT, headers, RIGHT, -108, 0)
    valueHeader:SetDimensions(86, headerHeight)
    valueHeader:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)

    local catHeader = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "HeaderCat", headers, CT_LABEL)
    catHeader:SetFont("ZoFontGameSmall")
    SetLabelColor(catHeader, PALETTE.textMuted)
    catHeader:SetText("Category")
    catHeader:SetAnchor(RIGHT, headers, RIGHT, -10, 0)
    catHeader:SetDimensions(78, headerHeight)
    catHeader:SetHorizontalAlignment(TEXT_ALIGN_CENTER)

    local emptyState = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "EmptyState", listContainer, CT_LABEL)
    emptyState:SetFont("ZoFontGame")
    SetLabelColor(emptyState, PALETTE.textDim)
    emptyState:SetText("No items match the current filter.")
    emptyState:SetAnchor(CENTER, listContainer, CENTER, 0, 18)
    emptyState:SetHidden(true)

    Manager.headers = headers
    Manager.headerHeight = headerHeight

    -- Bottom action bar
    local actionBar = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "ActionBar", window, CT_CONTROL)
    actionBar:SetAnchor(BOTTOMLEFT, window, BOTTOMLEFT, 12, -44)
    actionBar:SetAnchor(BOTTOMRIGHT, window, BOTTOMRIGHT, -12, -44)
    actionBar:SetHeight(34)

    local actionBg = CreateBackdrop(WINDOW_NAME .. "ActionBg", actionBar, PALETTE.footerBg, {0.14, 0.14, 0.16, 0.85}, 1)
    actionBg:SetAnchorFill(actionBar)

    local actionHint = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "ActionHint", actionBar, CT_LABEL)
    actionHint:SetFont("ZoFontGameSmall")
    SetLabelColor(actionHint, PALETTE.textMuted)
    actionHint:SetText("Click a row to select one item. Use Shift/Ctrl-click or checkboxes for multi-select, then click a tab above.")
    actionHint:SetAnchor(LEFT, actionBar, LEFT, 12, 0)

    -- Select all checkbox
    local selectAllLabel = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "SelectAllLabel", actionBar, CT_LABEL)
    selectAllLabel:SetFont("ZoFontGameSmall")
    SetLabelColor(selectAllLabel, PALETTE.text)
    selectAllLabel:SetText("Select All")
    selectAllLabel:SetAnchor(RIGHT, actionBar, RIGHT, -12, 0)
    selectAllLabel:SetMouseEnabled(true)

    local selectAll = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "SelectAll", actionBar, CT_BUTTON)
    selectAll:SetDimensions(20, 20)
    selectAll:SetAnchor(RIGHT, selectAllLabel, LEFT, -6, 0)
    selectAll:SetNormalTexture("/esoui/art/buttons/checkbox_empty.dds")
    selectAll:SetHandler("OnClicked", function(control)
        Manager.selectAllChecked = not (Manager.selectAllChecked or false)
        Manager.UpdateCheckboxTexture(control, Manager.selectAllChecked)
        Manager.SelectAll(Manager.selectAllChecked)
    end)

    selectAllLabel:SetHandler("OnMouseUp", function(_, button)
        if button == MOUSE_BUTTON_INDEX_LEFT then
            Manager.selectAllChecked = not (Manager.selectAllChecked or false)
            Manager.UpdateCheckboxTexture(selectAll, Manager.selectAllChecked)
            Manager.SelectAll(Manager.selectAllChecked)
        end
    end)

    actionHint:SetAnchor(RIGHT, selectAll, LEFT, -16, 0)

    -- Status bar
    local statusBar = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "StatusBar", window, CT_CONTROL)
    statusBar:SetAnchor(BOTTOMLEFT, window, BOTTOMLEFT, 12, -18)
    statusBar:SetAnchor(BOTTOMRIGHT, window, BOTTOMRIGHT, -12, -18)
    statusBar:SetHeight(24)

    local statusBg = CreateBackdrop(WINDOW_NAME .. "StatusBg", statusBar, {0.045, 0.045, 0.05, 0.96}, {0, 0, 0, 0}, 1)
    statusBg:SetAnchorFill(statusBar)

    local statusAccent = CreateBackdrop(WINDOW_NAME .. "StatusAccent", statusBar, {0.38, 0.25, 0.09, 0.55}, {0, 0, 0, 0}, 1)
    statusAccent:SetAnchor(TOPLEFT, statusBar, TOPLEFT, 0, 0)
    statusAccent:SetAnchor(TOPRIGHT, statusBar, TOPRIGHT, 0, 0)
    statusAccent:SetHeight(1)

    local statusLabel = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "StatusLabel", statusBar, CT_LABEL)
    statusLabel:SetFont("ZoFontGameSmall")
    SetLabelColor(statusLabel, PALETTE.textMuted)
    statusLabel:SetText("0 selected | 0 shown")
    statusLabel:SetAnchor(LEFT, statusBar, LEFT, 0, 0)

    local valueLabel = WINDOW_MANAGER:CreateControl(WINDOW_NAME .. "ValueLabel", statusBar, CT_LABEL)
    valueLabel:SetFont("ZoFontGameSmall")
    SetLabelColor(valueLabel, PALETTE.amber)
    valueLabel:SetText("Selected Value: 0g")
    valueLabel:SetAnchor(RIGHT, statusBar, RIGHT, 0, 0)

    actionBar:ClearAnchors()
    actionBar:SetAnchor(BOTTOMLEFT, statusBar, TOPLEFT, 0, -8)
    actionBar:SetAnchor(BOTTOMRIGHT, statusBar, TOPRIGHT, 0, -8)

    -- Keep the scrollable area above the footer controls.
    listContainer:ClearAnchors()
    listContainer:SetAnchor(TOPLEFT, filterFrame, BOTTOMLEFT, 0, 8)
    listContainer:SetAnchor(BOTTOMRIGHT, actionBar, TOPRIGHT, 0, -10)

    Manager.statusLabel = statusLabel
    Manager.valueLabel = valueLabel
    Manager.emptyState = emptyState
    Manager.selectAll = selectAll
end

function Manager.InitializeScrollList()
    local listContainer = Manager.listContainer
    if not listContainer then return end

    local scrollList = WINDOW_MANAGER:CreateControlFromVirtual(LIST_NAME, listContainer, "ZO_ScrollList")
    scrollList:ClearAnchors()
    scrollList:SetAnchor(TOPLEFT, listContainer, TOPLEFT, 0, Manager.headerHeight)
    scrollList:SetAnchor(BOTTOMRIGHT, listContainer, BOTTOMRIGHT, 0, 0)

    -- Remove green border from scroll list background
    local scrollBg = scrollList:GetNamedChild("Bg")
    if scrollBg then
        scrollBg:SetEdgeColor(0, 0, 0, 0)
    end

    ZO_ScrollList_AddDataType(scrollList, 1, "ZO_SelectableLabel", ROW_HEIGHT,
        function(control, data)
            Manager.SetupRow(control, data)
        end,
        function(control)
            Manager.CleanupRow(control)
        end
    )

    local dataType = ZO_ScrollList_GetDataTypeTable(scrollList, 1)
    if dataType and dataType.pool and dataType.pool.m_Factory then
        local createRow = dataType.pool.m_Factory
        dataType.pool.m_Factory = function(pool)
            local control = createRow(pool)
            control:SetHeight(ROW_HEIGHT)
            if control.SetWrapMode then
                control:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)
            end
            return control
        end
    end

    Manager.scrollList = scrollList
end

function Manager.UpdateCheckboxTexture(checkbox, selected)
    if selected then
        checkbox:SetNormalTexture("/esoui/art/buttons/checkbox_checked.dds")
    else
        checkbox:SetNormalTexture("/esoui/art/buttons/checkbox_empty.dds")
    end
end

function Manager.RefreshSelectionVisuals()
    if Manager.scrollList and ZO_ScrollList_RefreshVisible then
        ZO_ScrollList_RefreshVisible(Manager.scrollList)
    else
        Manager.RefreshList()
    end
end

function Manager.SetupRow(control, data)
    control.data = data
    if control.SetText then
        control:SetText("")
    end

    local rowBg = control:GetNamedChild("RowBg")
    if not rowBg then
        rowBg = CreateBackdrop("$(parent)RowBg", control, PALETTE.rowOdd, {0, 0, 0, 0}, 1)
        rowBg:SetAnchor(TOPLEFT, control, TOPLEFT, 2, 1)
        rowBg:SetAnchor(BOTTOMRIGHT, control, BOTTOMRIGHT, -2, -1)
    end
    rowBg:SetMouseEnabled(false)

    local rowAccent = control:GetNamedChild("RowAccent")
    if not rowAccent then
        rowAccent = CreateBackdrop("$(parent)RowAccent", control, PALETTE.amber, {0, 0, 0, 0}, 1)
        rowAccent:SetAnchor(TOPLEFT, control, TOPLEFT, 2, 1)
        rowAccent:SetAnchor(BOTTOMLEFT, control, BOTTOMLEFT, 2, -1)
        rowAccent:SetWidth(3)
    end
    rowAccent:SetMouseEnabled(false)

    local isEvenRow = ((data.itemId or 0) + (data.slotIndex or 0)) % 2 == 0
    local stripe = isEvenRow and PALETTE.rowEven or PALETTE.rowOdd

    local xOffset = 5

    local checkbox = control:GetNamedChild("Checkbox")
    if not checkbox then
        checkbox = WINDOW_MANAGER:CreateControl("$(parent)Checkbox", control, CT_BUTTON)
        checkbox:SetDimensions(20, 20)
        checkbox:SetAnchor(LEFT, control, LEFT, xOffset + 8, 0)
        checkbox:SetNormalTexture("/esoui/art/buttons/checkbox_empty.dds")
    end
    checkbox:SetHandler("OnClicked", function(ctrl)
        local parent = ctrl:GetParent()
        local rowData = parent and parent.data
        if not rowData then
            return
        end

        rowData.selected = not rowData.selected
        Manager._skipRowMouseUpKey = rowData.selectionKey
        Manager.SetItemSelected(rowData.selectionKey, rowData.selected)
        Manager.UpdateCheckboxTexture(ctrl, rowData.selected)
        Manager.RefreshSelectionVisuals()
        AI.DebugManagerLog(string.format("CheckboxToggle key=%s selected=%s item=%s selectedMap=%d", tostring(rowData.selectionKey), tostring(rowData.selected), DescribeItem(rowData), CountSelectedItems()))
    end)
    Manager.UpdateCheckboxTexture(checkbox, data.selected)
    xOffset = xOffset + 35

    local icon = control:GetNamedChild("Icon")
    if not icon then
        icon = WINDOW_MANAGER:CreateControl("$(parent)Icon", control, CT_TEXTURE)
        icon:SetDimensions(28, 28)
        icon:SetAnchor(LEFT, control, LEFT, xOffset, 0)
    end
    icon:SetMouseEnabled(false)
    icon:SetTexture(data.icon)

    local iconBorder = control:GetNamedChild("IconBorder")
    if not iconBorder then
        iconBorder = WINDOW_MANAGER:CreateControl("$(parent)IconBorder", control, CT_TEXTURE)
        iconBorder:SetDimensions(32, 32)
        iconBorder:SetAnchor(CENTER, icon, CENTER, 0, 0)
        iconBorder:SetTexture("/esoui/art/actionbar/abilityframe64_up.dds")
    end
    iconBorder:SetMouseEnabled(false)
    local qualityColor = GetItemQualityColor(data.quality)
    iconBorder:SetColor(qualityColor:UnpackRGB())
    xOffset = xOffset + 45

    local nameLabel = control:GetNamedChild("Name")
    if not nameLabel then
        nameLabel = WINDOW_MANAGER:CreateControl("$(parent)Name", control, CT_LABEL)
        nameLabel:SetFont("ZoFontGame")
        nameLabel:SetAnchor(LEFT, control, LEFT, xOffset, 0)
        nameLabel:SetAnchor(RIGHT, control, RIGHT, -190, 0)
        nameLabel:SetMaxLineCount(1)
        nameLabel:SetWrapMode(TEXT_WRAP_MODE_ELLIPSIS)
    end
    nameLabel:SetMouseEnabled(false)

    local displayName = data.name
    if data.stackCount > 1 then
        displayName = string.format("%s |cA7A7A3x%d|r", displayName, data.stackCount)
    end
    SetLabelColor(nameLabel, PALETTE.text)
    nameLabel:SetText(displayName)

    local valueLabel = control:GetNamedChild("Value")
    if not valueLabel then
        valueLabel = WINDOW_MANAGER:CreateControl("$(parent)Value", control, CT_LABEL)
        valueLabel:SetFont("ZoFontGameSmall")
        valueLabel:SetAnchor(TOPRIGHT, control, TOPRIGHT, -96, 6)
        valueLabel:SetDimensions(86, ROW_HEIGHT)
        valueLabel:SetHorizontalAlignment(TEXT_ALIGN_RIGHT)
    end
    valueLabel:SetMouseEnabled(false)
    local totalValue = data.sellPrice * data.stackCount
    valueLabel:SetText(string.format("%sg", ZO_CommaDelimitNumber(totalValue)))
    if totalValue > 0 then
        SetLabelColor(valueLabel, {0.90, 0.88, 0.78, 1})
    else
        SetLabelColor(valueLabel, PALETTE.textDim)
    end

    local catLabel = control:GetNamedChild("Category")
    if not catLabel then
        catLabel = WINDOW_MANAGER:CreateControl("$(parent)Category", control, CT_LABEL)
        catLabel:SetFont("ZoFontGameSmall")
        catLabel:SetAnchor(TOPRIGHT, control, TOPRIGHT, -2, 6)
        catLabel:SetDimensions(78, ROW_HEIGHT)
        catLabel:SetHorizontalAlignment(TEXT_ALIGN_CENTER)
    end
    catLabel:SetMouseEnabled(false)
    local catColor = GetCategoryColorArray(data.category) or PALETTE.textMuted
    SetLabelColor(catLabel, catColor)
    catLabel:SetText(AI.GetCategoryDisplayName(data.category))

    local function UpdateRowState(isHovering)
        if data.selected then
            ApplyBackdropColors(rowBg, isHovering and {0.22, 0.17, 0.09, 0.94} or PALETTE.rowSelected, isHovering and {0.68, 0.56, 0.28, 0.82} or PALETTE.rowSelectedEdge, 1)
            rowAccent:SetHidden(false)
        elseif isHovering then
            ApplyBackdropColors(rowBg, PALETTE.rowHover, {0.34, 0.27, 0.12, 0.28}, 1)
            rowAccent:SetHidden(true)
        else
            ApplyBackdropColors(rowBg, stripe, {0, 0, 0, 0}, 1)
            rowAccent:SetHidden(true)
        end
    end

    UpdateRowState(false)

    control:SetHandler("OnMouseEnter", function()
        UpdateRowState(true)
    end)
    control:SetHandler("OnMouseExit", function()
        UpdateRowState(false)
    end)
    control:SetHandler("OnMouseUp", function(ctrl, button)
        if button ~= MOUSE_BUTTON_INDEX_LEFT then
            return
        end

        local rowData = ctrl and ctrl.data
        if not rowData then
            return
        end

        if Manager._skipRowMouseUpKey == rowData.selectionKey then
            Manager._skipRowMouseUpKey = nil
            return
        end

        local wantsMultiSelect = (IsShiftKeyDown and IsShiftKeyDown()) or (IsControlKeyDown and IsControlKeyDown())
        if wantsMultiSelect then
            rowData.selected = Manager.ToggleSelection(rowData.selectionKey)
            AI.DebugManagerLog(string.format("RowMultiToggle key=%s item=%s", tostring(rowData.selectionKey), DescribeItem(rowData)))
        else
            Manager.SelectOnly(rowData.selectionKey)
            rowData.selected = true
            AI.DebugManagerLog(string.format("RowSingleSelect key=%s item=%s", tostring(rowData.selectionKey), DescribeItem(rowData)))
        end

        Manager.RefreshSelectionVisuals()
        Manager.UpdateStatusBar()
    end)
end

function Manager.CleanupRow(control)
    control.data = nil
    control:SetHandler("OnMouseEnter", nil)
    control:SetHandler("OnMouseExit", nil)
    control:SetHandler("OnMouseUp", nil)
end

function Manager.SetupDragHandler()
    local window = Manager.window
    window:SetHandler("OnMoveStop", function()
        if not AI.sv.managerPos then AI.sv.managerPos = {} end
        AI.sv.managerPos.x = window:GetLeft()
        AI.sv.managerPos.y = window:GetTop()
    end)
end

function Manager.UpdateFilterButtons()
    for key, btnData in pairs(Manager) do
        if key:find("^filterBtn_") then
            local catKey = key:gsub("filterBtn_", "")
            local isSelected = Manager.filterCategory == catKey
            local color = btnData.color
            if isSelected then
                ApplyBackdropColors(btnData.bg, {0.105, 0.095, 0.082, 0.98}, {0.34, 0.30, 0.22, 1}, 1)
                btnData.accent:SetHidden(false)
                btnData.sideAccent:SetHidden(false)
                btnData.accent:SetCenterColor(color[1], color[2], color[3], 0.90)
                btnData.sideAccent:SetCenterColor(color[1], color[2], color[3], 0.70)
                SetLabelColor(btnData.label, color)
            elseif btnData.hovered then
                ApplyBackdropColors(btnData.bg, {0.085, 0.085, 0.092, 0.98}, {0.22, 0.22, 0.24, 1}, 1)
                btnData.accent:SetHidden(false)
                btnData.sideAccent:SetHidden(false)
                btnData.accent:SetCenterColor(color[1], color[2], color[3], 0.48)
                btnData.sideAccent:SetCenterColor(color[1], color[2], color[3], 0.38)
                SetLabelColor(btnData.label, {color[1], color[2], color[3], 1})
            else
                ApplyBackdropColors(btnData.bg, {0.075, 0.075, 0.082, 0.98}, {0.16, 0.16, 0.18, 0.95}, 1)
                btnData.accent:SetHidden(false)
                btnData.sideAccent:SetHidden(false)
                btnData.accent:SetCenterColor(color[1], color[2], color[3], 0.22)
                btnData.sideAccent:SetCenterColor(color[1], color[2], color[3], 0.22)
                SetLabelColor(btnData.label, {color[1] * 0.84, color[2] * 0.84, color[3] * 0.84, 1})
            end
        end
    end
end

function Manager.RefreshData()
    Manager.items = {}

    -- Scan backpack
    local bagId = BAG_BACKPACK
    local slotIndex = ZO_GetNextBagSlotIndex(bagId, nil)
    while slotIndex do
        if AI.BagSlotHasItem(bagId, slotIndex) then
            local itemId = GetItemId(bagId, slotIndex)
            local itemLink = GetItemLink(bagId, slotIndex)
            local name = GetItemLinkName(itemLink)
            local icon = GetItemLinkIcon(itemLink)
            local quality = GetItemLinkQuality(itemLink)
            local stackCount = GetSlotStackSize(bagId, slotIndex)
            local sellPrice = GetItemSellValueWithBonuses(bagId, slotIndex)
            local category = AI.GetItemCategory(bagId, slotIndex, itemId)

            table.insert(Manager.items, {
                itemId = itemId,
                itemLink = itemLink,
                name = zo_strformat("<<t:1>>", name),
                searchName = NormalizeSearchText(zo_strformat("<<t:1>>", name)),
                icon = icon,
                quality = quality,
                stackCount = stackCount,
                sellPrice = sellPrice or 0,
                category = category,
                bagId = bagId,
                slotIndex = slotIndex,
                selectionKey = GetSelectionKey(bagId, slotIndex, itemId),
                selected = Manager.selectedItems[GetSelectionKey(bagId, slotIndex, itemId)] or false
            })
        end
        slotIndex = ZO_GetNextBagSlotIndex(bagId, slotIndex)
    end

    -- Scan bank if accessible
    if IsBankOpen() then
        for _, bankBagId in ipairs({BAG_BANK, BAG_SUBSCRIBER_BANK}) do
            local bankSlotIndex = ZO_GetNextBagSlotIndex(bankBagId, nil)
            while bankSlotIndex do
                if AI.BagSlotHasItem(bankBagId, bankSlotIndex) then
                    local itemId = GetItemId(bankBagId, bankSlotIndex)
                    local itemLink = GetItemLink(bankBagId, bankSlotIndex)
                    local name = GetItemLinkName(itemLink)
                    local icon = GetItemLinkIcon(itemLink)
                    local quality = GetItemLinkQuality(itemLink)
                    local stackCount = GetSlotStackSize(bankBagId, bankSlotIndex)
                    local sellPrice = GetItemSellValueWithBonuses(bankBagId, bankSlotIndex)
                    local category = AI.GetItemCategory(bankBagId, bankSlotIndex, itemId)

                    table.insert(Manager.items, {
                        itemId = itemId,
                        itemLink = itemLink,
                        name = zo_strformat("<<t:1>>", name) .. " |c666666[Bank]|r",
                        searchName = NormalizeSearchText(zo_strformat("<<t:1>>", name) .. " [Bank]"),
                        icon = icon,
                        quality = quality,
                        stackCount = stackCount,
                        sellPrice = sellPrice or 0,
                        category = category,
                        bagId = bankBagId,
                        slotIndex = bankSlotIndex,
                        selectionKey = GetSelectionKey(bankBagId, bankSlotIndex, itemId),
                        selected = Manager.selectedItems[GetSelectionKey(bankBagId, bankSlotIndex, itemId)] or false
                    })
                end
                bankSlotIndex = ZO_GetNextBagSlotIndex(bankBagId, bankSlotIndex)
            end
        end
    end

    -- Sort by quality (highest first) then name
    table.sort(Manager.items, function(a, b)
        if a.quality ~= b.quality then
            return a.quality > b.quality
        end
        return a.name < b.name
    end)

    Manager.PruneSelection()

    Manager.RefreshList()
end

function Manager.RefreshList()
    Manager.filteredItems = {}

    for _, item in ipairs(Manager.items) do
        item.selected = Manager.selectedItems[item.selectionKey] or false
        local include = true

        if Manager.filterCategory ~= "all" and item.category ~= Manager.filterCategory then
            include = false
        end

        if include and ShouldHideManagedItemForFilter(item, Manager.filterCategory) then
            include = false
        end

        if Manager.searchText ~= "" and not (item.searchName or NormalizeSearchText(item.name)):find(Manager.searchText, 1, true) then
            include = false
        end

        if include then
            table.insert(Manager.filteredItems, item)
        end
    end

    if not Manager.scrollList then
        Manager.UpdateStatusBar()
        return
    end

    ZO_ScrollList_Clear(Manager.scrollList)
    local scrollData = ZO_ScrollList_GetDataList(Manager.scrollList)
    for _, item in ipairs(Manager.filteredItems) do
        table.insert(scrollData, ZO_ScrollList_CreateDataEntry(1, item))
    end
    ZO_ScrollList_Commit(Manager.scrollList)

    if Manager.emptyState then
        Manager.emptyState:SetHidden(#Manager.filteredItems > 0)
    end

    LogCategoryCounts("RefreshList")

    Manager.UpdateStatusBar()
end

function Manager.SetItemSelected(selectionKey, selected)
    Manager.selectedItems[selectionKey] = selected or nil

    for _, item in ipairs(Manager.items) do
        if item.selectionKey == selectionKey then
            item.selected = selected
            break
        end
    end

    Manager.UpdateStatusBar()
end

function Manager.GetSelectedEntries()
    local selectedEntries = {}

    for _, item in ipairs(Manager.filteredItems) do
        item.selected = Manager.selectedItems[item.selectionKey] or false
        if item.selected then
            table.insert(selectedEntries, item)
        end
    end

    table.sort(selectedEntries, function(left, right)
        if left.bagId ~= right.bagId then
            return left.bagId < right.bagId
        end
        return (left.slotIndex or 0) > (right.slotIndex or 0)
    end)

    LogSelectedEntries("GetSelectedEntries", selectedEntries)

    return selectedEntries
end

function Manager.HasVisibleSelection()
    return #Manager.GetSelectedEntries() > 0
end

function Manager.SelectAll(select)
    for _, item in ipairs(Manager.filteredItems) do
        item.selected = select
        Manager.selectedItems[item.selectionKey] = select or nil
    end
    Manager.RefreshSelectionVisuals()
    Manager.UpdateStatusBar()
end

function Manager.ClearSelectedItemCategories()
    Manager.SetSelectedItemsCategory(nil)
end

function Manager.SetSelectedItemsCategory(category)
    local previousFilter = Manager.filterCategory
    local selectedEntries = Manager.GetSelectedEntries()
    local count = 0
    local actionTriggered = false
    local skippedUntracked = 0
    local sessionOnlyCount = 0

    LogSelectedEntries("ApplyCategory:" .. tostring(category), selectedEntries)
    LogCategoryCounts("ApplyCategoryBefore:" .. tostring(category))

    for _, item in ipairs(selectedEntries) do
        local categorySaved, saveMode = AI.SetItemCategory(item.bagId, item.slotIndex, category, item.itemId, { applyEffects = false })
        if categorySaved then
            item.category = category
            count = count + 1
            if saveMode == "session" then
                sessionOnlyCount = sessionOnlyCount + 1
            end
        else
            skippedUntracked = skippedUntracked + 1
            item.selected = false
            Manager.selectedItems[item.selectionKey] = nil
        end
    end

    if count > 0
        and AI.ProcessSpecificCategoryAction
        and (
            ((category == AI.categories.BANK or category == AI.categories.RETRIEVE or category == AI.categories.AUCTION) and IsBankOpen())
            or (category == AI.categories.TRASH and IsSellWindowOpen())
        ) then
        actionTriggered = AI.ProcessSpecificCategoryAction(selectedEntries, category, function(result)
            NotifySpecificCategoryActionResult(category, result)
            if Manager.window and not Manager.window:IsHidden() then
                Manager.RefreshData()
            end
        end)
    end

    if count > 0 or skippedUntracked > 0 then
        if category == nil then
            AI.Notify(string.format("AutoInventory: Removed category from %d item(s)", count))
        elseif category == AI.categories.BANK then
            if IsBankOpen() then
                if actionTriggered then
                    AI.Notify(string.format("AutoInventory: Marked %d selected item(s) for bank", count))
                else
                    AI.Notify(string.format("AutoInventory: Marked %d item(s) for bank", count))
                end
            else
                AI.Notify(string.format("AutoInventory: Marked %d item(s) for bank", count))
            end
        elseif category == AI.categories.RETRIEVE then
            if IsBankOpen() then
                if actionTriggered then
                    AI.Notify(string.format("AutoInventory: Marked %d selected item(s) to pull from bank", count))
                else
                    AI.Notify(string.format("AutoInventory: Marked %d item(s) to pull from bank", count))
                end
            else
                AI.Notify(string.format("AutoInventory: Marked %d item(s) to pull from bank", count))
            end
        elseif category == AI.categories.AUCTION then
            if IsBankOpen() then
                if actionTriggered then
                    AI.Notify(string.format("AutoInventory: Marked %d selected item(s) for trader prep", count))
                else
                    AI.Notify(string.format("AutoInventory: Marked %d item(s) for trader prep. Banked trader items will be pulled when you open the bank.", count))
                end
            elseif AI.IsTradingHouseInteractionActive and AI.IsTradingHouseInteractionActive() then
                AI.Notify(string.format("AutoInventory: Marked %d item(s) for trader prep. Listing at the guild trader is manual.", count))
            else
                AI.Notify(string.format("AutoInventory: Marked %d item(s) for trader prep. Banked trader items will be pulled when you open the bank.", count))
            end
        elseif category == AI.categories.TRASH then
            if IsSellWindowOpen() then
                AI.Notify(string.format("AutoInventory: Marked %d selected item(s) as trash", count))
            else
                AI.Notify(string.format("AutoInventory: Marked %d item(s) as trash", count))
            end
        else
            AI.Notify(string.format("AutoInventory: Set %d item(s) to %s", count, AI.GetCategoryDisplayName(category)))
        end

        if skippedUntracked > 0 then
            AI.Notify(string.format("AutoInventory: Skipped %d item(s) without a stable storage key", skippedUntracked))
        end

        if sessionOnlyCount > 0 then
            AI.Notify(string.format("AutoInventory: %d item(s) were tagged for this session only because ESO did not expose a stable item ID", sessionOnlyCount))
        end

        Manager.ClearSelection()
        Manager.filterCategory = previousFilter
        Manager.UpdateFilterButtons()
        AI.DebugManagerLog(string.format("PreserveFilter after apply previous=%s current=%s target=%s", tostring(previousFilter), tostring(Manager.filterCategory), tostring(category)))

        if actionTriggered then
            ScheduleManagerUpdate("SpecificActionRefresh", 700, function()
                if Manager.window and not Manager.window:IsHidden() then
                    Manager.RefreshData()
                end
            end)
        else
            Manager.RefreshList()
        end

        LogCategoryCounts("ApplyCategoryAfter:" .. tostring(category))
    end
end

function Manager.UpdateStatusBar()
    local selectedCount = 0
    local totalValue = 0

    for _, item in ipairs(Manager.filteredItems) do
        item.selected = Manager.selectedItems[item.selectionKey] or false
        if item.selected then
            selectedCount = selectedCount + 1
            totalValue = totalValue + (item.sellPrice * item.stackCount)
        end
    end

    Manager.statusLabel:SetText(string.format("%d selected | %d shown", selectedCount, #Manager.filteredItems))
    Manager.valueLabel:SetText("Selected Value: " .. ZO_CommaDelimitNumber(totalValue) .. "g")
end

function Manager.SetFilter(filterKey)
    local nextFilter = filterKey or "all"
    if Manager.filterCategory ~= nextFilter then
        Manager.ClearSelection()
    end
    Manager.filterCategory = nextFilter
    Manager.UpdateFilterButtons()
    if Manager.window and not Manager.window:IsHidden() then
        Manager.RefreshList()
    end
end

function Manager.Show(filterKey)
    if Manager.overlay then
        Manager.overlay:SetHidden(false)
    end
    Manager.window:SetHidden(false)
    Manager.ClearSelection()
    Manager.searchText = ""
    Manager.searchInput:SetText("")
    Manager.SetFilter(filterKey or "all")
    Manager.RefreshData()
    SCENE_MANAGER:SetInUIMode(true)
end

function Manager.Hide()
    Manager.ClearSelection()
    if Manager.overlay then
        Manager.overlay:SetHidden(true)
    end
    Manager.window:SetHidden(true)
    SCENE_MANAGER:SetInUIMode(false)
end

function Manager.Toggle()
    if Manager.window:IsHidden() then
        Manager.Show()
    else
        Manager.Hide()
    end
end

function Manager.Minimize()
    Manager.Hide()
end

function Manager.ShowAuctionItems()
    if not Manager.window or Manager.window:IsHidden() then
        Manager.Show(AI.categories.AUCTION)
    else
        Manager.ClearSelection()
        Manager.searchText = ""
        if Manager.searchInput then
            Manager.searchInput:SetText("")
        end
        Manager.SetFilter(AI.categories.AUCTION)
        Manager.RefreshData()
    end
end

function AI.InitializeManager()
    Manager.Initialize()
end
