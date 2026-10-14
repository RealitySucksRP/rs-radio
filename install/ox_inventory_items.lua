-- Merge these entries into ox_inventory/data/items.lua.
-- Do not run this file as a FiveM resource.

-- Copy the entries inside this returned table into your inventory item table.
return {
['radio'] = {
    label = 'RS Radio',
    weight = 850,
    stack = false,
    close = true,
    consume = 0,
    description = 'A modern handheld radio for city communications.',
    image = 'radio.png',
    client = { export = 'rs-radio.useRadio' }
},

['radiocell'] = {
    label = 'Radio Battery Cell',
    weight = 200,
    stack = true,
    close = true,
    consume = 0,
    description = 'A replacement power cell for a portable radio.',
    image = 'battery.png',
    client = { export = 'rs-radio.RechargeRadio' }
},

['jammer'] = {
    label = 'Signal Jammer',
    weight = 2500,
    stack = false,
    close = true,
    consume = 0,
    description = 'A field unit capable of blocking radio frequencies.',
    image = 'signal_jammer.png',
    client = { export = 'rs-radio.placeJammer' }
},
}
