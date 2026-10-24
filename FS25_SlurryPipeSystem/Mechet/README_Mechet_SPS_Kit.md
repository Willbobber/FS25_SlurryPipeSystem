# Slurry Pipe System — The Mechet drop-in kit

Ready-made SPS files for the three **The Mechet** mods. The game does NOT load anything in this
folder; it is here for you to copy into your own copies of the Mechet mods. The three folders are
named exactly like the mods, and every file sits at the path it has inside that mod, so you can
copy a whole folder over the matching mod and let it overwrite.

Made against: `FS25_The_Mechet` 1.0.0.2, `FS25_The_Mechet_Farm_Pack` 1.0.0.2,
`FS25_The_Mechet_Production_And_Industry_Pack` 1.0.0.1. If the map author releases a newer
version, compare before overwriting — these XMLs are complete files, not patches.

## How to install

1. **Back up** the three Mechet zips in your `mods` folder.
2. Unpack each Mechet zip into a folder of the **same name** (e.g. `mods/FS25_The_Mechet/`), then
   delete or move the zip so the game sees only the folder. FS25 loads a folder mod exactly like a
   zip. (If you prefer to keep zips, add the files into the zip at the same paths instead.)
3. Copy the contents of `Mechet/FS25_The_Mechet/` into `mods/FS25_The_Mechet/`, and the same for
   the other two folders. Say **yes to overwrite** when asked.
4. Start the game with SPS enabled. Without SPS the placeables still work exactly as before —
   the SPS block in each XML is ignored by the base game.

Existing savegames are fine: nothing changes the storage, triggers or store items of the
placeables; only SPS couplers, surfaces and water nodes are added.

## What each file adds

### FS25_The_Mechet (the map)
| File | Adds |
|------|------|
| `SPS_waterNodes.i3d` + `.shapes` | Fill-arm water from the lakes and the reservoir pool (closed-spline footprints). |
| `maps/placeables/bga/BGA.xml` + `nodeTree.i3d` + `.shapes` | Biogas plant: LIQUIDMANURE coupler (manual valve) at the slurry intake, DIGESTATE coupler at the digestate outlet, SPS-driven digestate lagoon surface. |
| `maps/placeables/cooperatives/reservoir_01.xml` + `nodeTree.i3d` | Coop water reservoir: WATER buying-station coupler plus fill-arm access to the pool (paid at the station price). |
| `maps/placeables/negociant/buyingStationLiquidManure.xml` + `nodeTree.i3d` | Dealer slurry station: paid LIQUIDMANURE coupler and fill-arm access to the pit. |
| `maps/placeables/waterTower/water_Tower.xml` + `nodeTree.i3d` + `.shapes` | Water tower: WATER buying-station coupler with a manual valve. |

### FS25_The_Mechet_Farm_Pack
| File | Adds |
|------|------|
| `Stabulation_Engraissement.xml` + `SPS_nodeTree_Stabulation_Engraissement.i3d` + `.shapes` | Beef fattening shed: slurry coupler with a virtual pit surface, so gravity levelling works through the coupler. |
| `Stabulation_Laitiere.xml`, `Stabulation_Laitiere_Map.xml` + `SPS_nodeTree_Stabulation_Laitiere.i3d` + `.shapes` | Dairy shed (buyable and map-placed versions): the same coupler + virtual surface. Both XMLs share one nodeTree. |

### FS25_The_Mechet_Production_And_Industry_Pack
| File | Adds |
|------|------|
| `Station_Phyto_BuyingStation.xml` + `SPS_nodeTree_Station_Phyto_BuyingStation.i3d` + `.shapes` | Phyto dealer (both map-placed stations): sprayer coupler, fertiliser/herbicide walk-up type switch. |
| `Station_Phyto_Silo.xml` + `SPS_nodeTree_Station_Phyto_Silo.i3d` + `.shapes` | Buyable phyto silo: one sprayer coupler feeding two 86,600 l "any liquid" tanks with the walk-in tank switch (R / Shift+R). The marker icon comes from the SPS mod itself. |

## Notes
- Copy the `.i3d.shapes` files together with their `.i3d`; an i3d without its shapes file will not load.
- The calf shed, sheepfold, pastures, greenhouses and the solid-manure stations have nothing to
  add — they hold no liquid SPS can pump.
- Questions and problems: the SPS GitHub issues page. Say which Mechet version you are on.
