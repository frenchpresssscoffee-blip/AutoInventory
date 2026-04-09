# AutoInventory

AutoInventory is an ESO addon for sorting items into simple categories and acting on them when it makes sense.

## What it does

- Shows a manager window where you can review items and assign categories.
- Adds right-click category options to inventory and bank items.
- Helps move items into and out of the bank.
- Keeps trader items easy to find.
- Sells trash items to NPC vendors.

## Categories

- `Keep`
  Leaves the item alone.

- `Bank`
  Marks the item to be stored in your bank.

- `Pull From Bank`
  Marks a banked item to be pulled back into your backpack later.

- `Trader Prep`
  Marks an item as something you want ready for guild trader listing later.

- `Trash`
  Marks an item for NPC vendor selling.

## Manager window

The manager window lets you:

- view all categorized items in one place
- search and filter by category
- select one or multiple items
- apply a category to the current selection
- clear a category from selected items

## How the flows work

### Bank

- Mark an item as `Bank` to store it away.
- Mark an item as `Pull From Bank` to bring it back later.

### Trader Prep

- Use `Trader Prep` as a list of items you want ready for guild trader selling.
- It helps keep those items visible and easy to prepare.
- It does not automatically post listings to a trader.

### Trash

- `Trash` is for NPC vendor selling.
- Outside a vendor, it stays as a category only.
- At an NPC vendor, trash items can be sold automatically.

## Slash commands

- `/ai help`
- `/ai sell`
- `/ai bank`
- `/ai clear`
- `/ai debug on`
- `/ai debug off`
- `/ai ops`
- `/ai ops clear`

## Files

- `AutoInventory.lua` - addon bootstrap and shared workflow coordination
- `AutoInventoryState.lua` - category state and persistence
- `AutoInventoryCore.lua` - bank, sell, and action processing
- `AutoInventoryManager.lua` - manager window UI and selection logic
- `AutoInventoryUI.lua` - right-click menu and slash commands
- `AutoInventorySettings.lua` - settings panel definitions

## Install

Copy the addon folder into:

`Documents/Elder Scrolls Online/live/AddOns/`

Then enable `AutoInventory` in the ESO addon menu.
