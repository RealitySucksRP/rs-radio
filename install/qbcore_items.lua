-- Merge these entries into qb-core/shared/items.lua when using qb-inventory.
-- Do not run this file as a FiveM resource.

-- Copy the entries inside this returned table into your inventory item table.
return {
radio = { name = 'radio', label = 'RS Radio', weight = 850, type = 'item', image = 'radio.png', unique = true, useable = true, shouldClose = true, description = 'A modern handheld radio for city communications.' },
radiocell = { name = 'radiocell', label = 'Radio Battery Cell', weight = 200, type = 'item', image = 'battery.png', unique = false, useable = true, shouldClose = true, description = 'A replacement power cell for a portable radio.' },
jammer = { name = 'jammer', label = 'Signal Jammer', weight = 2500, type = 'item', image = 'signal_jammer.png', unique = true, useable = true, shouldClose = true, description = 'A field unit capable of blocking radio frequencies.' },
}
