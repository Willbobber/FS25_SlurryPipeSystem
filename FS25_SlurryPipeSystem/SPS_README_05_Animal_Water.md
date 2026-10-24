# SPS README 05 — Farm liquid lanes: animal drinking water in, milk out

Slurry Pipe System 1.0.1.8. How to give a barn pipe connections for the animals'
**drinking water** (water goes in) and for **milk** (milk comes out), and how to give a
water or milk carrier the one connector that serves both.

This is a **third, separate pipe system** next to the slurry lane (`<slurryPipeSystem>`) and
the sprayer lane (`<sprayerPipeSystem>`). It borrows the sprayer lane's hose and connector
meshes and its walk-up interaction, and nothing else:

- A **barn** gets one coupler **per lane**, each in its own block. The block is the flag:
  `<animalWaterSystem>` only ever passes WATER, `<milkPipeSystem>` only ever passes milk.
  The slurry coupler stays in `<slurryPipeSystem>` on its own pipe and keeps accepting
  slurry, digestate and water exactly as before.
- A **vehicle** gets **one** connector, `<liquidPipeSystem>`. It connects to whichever
  coupler it is parked at, and the far coupler decides what flows and which way.
- The same connector also works at **sprayer sources** — sprayer silos, IBC tanks and phyto
  buying stations — for fertiliser, herbicide and any script-mod sprayer liquid (Soil &
  Fertilizer). There the trailer behaves **exactly like a sprayer**: load and unload,
  per-tank compartments, ANY tanks, buying-station pricing, the same prompts.
- The liquid in the tank decides which couplers the connector can see: **milk** only milk
  couplers, **water** only water couplers, **fert / herb** only sprayer sources, an empty
  tank sees all of them. So milk can only leave to a milk connection, water can only go in
  through a water connection, and fert can never reach a milk stand or a trough.
- Real sprayers are untouched: they never get a liquid connector and never see barn
  couplers.
- Hoses are **saved**: after a reload the connection and its valve state come back, as
  slurry hoses always have.

All element and attribute names below are exactly what the parser reads.

---

## 1. Which barns qualify

**Water lane.** The barn must hold its drinking water as a **real pool**:
`<water automaticWaterSupply="false">` and `WATER` in its husbandry `<storage>`. On a barn
with automatic water supply vanilla never reads a water level, so SPS logs one warning and
skips that lane. Base game: the four **small** barns (cow 6,000 l, pig 3,000 l, sheep
1,500 l, horse 1,250 l). Every other base cow/pig barn is automatic.

**Sprayer sources.** Anything the sprayer lane already registers (README 03 §9, §9B, §9C
and IBC tanks). Nothing to configure on the source side.

**Milk lane.** The husbandry storage must hold `MILK` and/or `BUFFALOMILK`. Base game: the
small cow barn and the Rudolf Hormann cow barns (60,000 l per milk type). The lane takes
whichever milk type the barn actually holds; a buffalo barn gives BUFFALOMILK.

A barn that fails a lane's check keeps its other lanes:

```
[SPS LL] WARNING: <barn>.xml has <animalWaterSystem> but water supply is AUTOMATIC (no drinking-water pool) — WATER coupler skipped
```

## 2. Barn side — placeable XML

Embedded, as children of the root `<placeable>` element. Use one block, or both:

```xml
<placeable ...>
    ...
    <animalWaterSystem>
        <nodeTree filename="SPS_nodeTree_water.i3d"/>      <!-- optional -->
        <waterPipeCouplings>
            <waterPipeCoupling id="1" mountNodeName="SPS_waterPipeCoupler01"
                               maxPipeLength="7.5" connectorAnimation="3" valveAnimation="1"/>
        </waterPipeCouplings>
    </animalWaterSystem>

    <milkPipeSystem>
        <nodeTree filename="SPS_nodeTree_milk.i3d"/>       <!-- optional -->
        <milkPipeCouplings>
            <milkPipeCoupling id="1" mountNodeName="SPS_milkPipeCoupler01"
                              maxPipeLength="7.5" connectorAnimation="3" valveAnimation="1"/>
        </milkPipeCouplings>
    </milkPipeSystem>
</placeable>
```

| Attribute            | Default | Meaning |
|----------------------|---------|---------|
| `id`                 | index+1 | Identifier, unique across all of the placeable's liquid-lane couplers. |
| `mountNodeName`      | —       | The coupler mount node. **Required** — coupling skipped if not found. |
| `maxPipeLength`      | 7.5     | Max metres the hose may span; auto-disconnects beyond it. |
| `connectorAnimation` | —       | Optional coupler-clamp animation id (README 03 §7; the sprayer connector is id 3). |
| `valveAnimation`     | —       | Optional valve animation id, played open/closed with the B key (original system) or the fitting's R valve (physical pipes, §4A). |
| `headHeightNodeName` | —       | Optional, physical pipes: highest point the liquid must pass; gravity only flows when the driving surface is above it (§4A). |
| `tankTopNodeName` / `tankBottomNodeName` | — | Optional, physical pipes: top and bottom of this tank, so SPS knows the surface height for gravity (§4A). |

There is **no** `fillType`, `flowDirection` or `capacity`: the lane fixes the liquid and the
direction, and the capacity is the barn's own storage capacity for that liquid.

**Mount node structure** is the sprayer one (README 03 §4): first child = arc apex node named
`*Arcs` with two arc children, plus `inNode` and `outNode` somewhere below the mount. The
hose always ends at the barn coupler's `inNode`, whichever way the liquid flows. Put the
`sprayerConnector` mesh under the mount if you want the visible connector.

**Bundled** (non-embedded) configs are the normal SPS config: the lane blocks sit **inside**
the placeable's existing `fillPoints.xml`, as children of its `<slurryPipeSystem>` root, next to
`<pipeCouplings>`, and the lane couplers are authored in the **same** `nodeTree.i3d` as the
slurry coupler. No extra manifest entry is needed. Example: `configs/data/placeables/
rudolfHormann/cowBarnBig/fillPoints.xml` carries a ready `<milkPipeSystem>` block, commented
until its node exists. A barn with no slurry side would get its own `fillPoints.xml` with the same
`<slurryPipeSystem>` root holding only the lane blocks, listed under `<liquidPlaceableConfigs>`
in `configs/spsConfigManifest.xml`; SPS ships none at present.

## 3. Carrier side — vehicle XML

Any vehicle whose fill unit accepts water and/or milk: the Lizard MKS 8 / MKS 32 water
trailers take both. Embedded, as a child of the root `<vehicle>`:

```xml
<vehicle ...>
    ...
    <liquidPipeSystem>
        <nodeTree filename="SPS_nodeTree_liquid.i3d"/>   <!-- optional -->
        <flow litersPerSecond="200"/>
        <liquidPipeCouplings>
            <liquidPipeCoupling id="1" mountNodeName="SPS_liquidPipeCoupler01" fillUnitIndex="1"
                                maxPipeLength="7.5" connectorAnimation="3" valveAnimation="1"/>
        </liquidPipeCouplings>
        <liquidPumpControls>
            <liquidPumpControl id="1" nodeName="SPS_liquidControlNode" radius="1.5"/>
        </liquidPumpControls>
    </liquidPipeSystem>
</vehicle>
```

| Element / attribute                 | Default | Meaning |
|-------------------------------------|---------|---------|
| `flow#litersPerSecond`              | 200     | Transfer rate, both directions. |
| `liquidPipeCoupling#fillUnitIndex`  | 1       | The fill unit the liquid comes from / goes to. |
| `liquidPipeCoupling#lanes`          | all the fill unit accepts | Optional space-separated `WATER` / `MILK` / `SPRAYER` to narrow which couplers this connector may meet. |
| `liquidPipeCoupling#*`              |         | Otherwise the same as the barn side. The hose starts at this connector's `outNode`. |
| `liquidPumpControl#nodeName`        | —       | Walk-up node for the prompts. **Required** for the player to do anything. |
| `liquidPumpControl#radius`          | 1.5     | Activation radius (m). |

A vehicle may carry `<liquidPipeSystem>` **alongside** `<slurryPipeSystem>`; the blocks are
read independently and each needs its own mount node. A vehicle that has its own
`<sprayerPipeSystem>` is a sprayer: its liquid connector then serves water and milk only.

Bundled configs: a slurry tanker that also carries the connector puts `<liquidPipeSystem>`
**inside** its existing `<slurryPipeSystem>` root, nodes in the same `nodeTree.i3d`, no manifest
entry. Every shipped slurry tanker config carries one with `lanes="WATER"`, so a tanker that has
drawn water from a lake or a reservoir can deliver it to a barn's drinking-water coupler. A vehicle with no slurry side (the MKS trailers) gets its own `fillPoints.xml` with
`<liquidPipeSystem>` as the root, listed under `<liquidVehicleConfigs>`.

## 4. Operating sequence — the same at every connection

1. Park within `maxPipeLength` of the coupler you want so the two arcs cross, walk to the
   control node. The prompt names the lane: **Connect pipe (Water)**, **(Milk)** or
   **(Sprayer source)**. With several couplers in reach, the one nearest to you wins.
2. **R** — connect. Hose appears, connector animations play, valve stays closed.
3. **Y** — Load / Unload. At a sprayer source you choose, exactly as on a sprayer. At a
   barn the lane fixes it (water = Unload, milk = Load) and the row just shows it.
4. **B** — Start Flow / Stop Flow. Refused with a warning when nothing can move: tank empty
   or holding the wrong liquid, barn full or empty, tank full or unable to take that liquid.
5. Water is credited through the vanilla unloading-station path (trough plane rises, the
   animals drink it, farm access applies). Milk is drawn through the vanilla loading-station
   path, the same one the milk load trigger uses. At a sprayer source the sprayer code runs
   the transfer, with all its rules and pricing.
6. The transfer stops itself when the source runs out or the destination fills. **B** again
   stops it by hand.
7. **R** — disconnect. Driving beyond `maxPipeLength` disconnects automatically.

In multiplayer every connect, disconnect, valve and direction change is synced, and a
joining player receives the live hoses and their state. Hoses, valve state and direction
are saved with the game and come back after a reload.

## 4A. Physical pipes: fitting valves, gravity, tanker to tanker (1.0.1.8)

With **physical pipes** (README 06) the 80 mm hoses plug into the same couplers, and the
fittings behave like real ones:

1. Plug the hose into both fittings (mouse, README 06 §3). Nothing opens on its own.
2. **R** at each fitting — **Open valve** / **Close valve**. The fitting's handle
   (`valveAnimation`, or `connectorAnimation` on fittings that only have one) turns with it.
   On the carrier the R prompt is at its control node.
3. **B** at the carrier — pump. Refused with "Open the valves at both fittings first" until
   both valves are open; closing either valve stops it.
4. **Gravity:** with both valves open and the pump **off**, liquid flows by itself from the
   higher tank to the lower one, water from a carrier into the barn and milk from the barn
   into a carrier, slowing as the levels close in. It needs the driving surface above the
   receiving one and above both fittings' `headHeightNodeName` (when set). The surface height
   comes from `tankTopNodeName` / `tankBottomNodeName` (the level is placed between them); a
   carrier without them uses its fill volume; with neither, no gravity. B always pumps,
   whatever the heights.
5. **Tanker to tanker:** a hose between two carriers' connectors transfers water or milk
   between them. The carrier whose control node you use is the pump; **Y** sets Load (into
   this carrier) / Unload. Both must hold the same liquid, or the receiver must be empty.
6. A hose cannot be unplugged while the valve of the fitting it is in is open.

Valve states are saved with the game.

## 5. Log lines

```
[SPS LL] registerLiquidLaneVehicle: registered <vehicle>.xml (1 connector(s) [WATER MILK], 1 control(s))
[SPS LL] registerLiquidLanePlaceable: registered <barn>.xml (2 coupling(s): WATER MILK)
[SPS LL] flow stopped on <vehicle>.xml: warning_spsMilkBarnEmpty | warning_spsLiquidBarnFull | ...
[SPS LL] registerLiquidLaneVehicle: registered mks8.xml (1 connector(s) [WATER MILK SPRAYER], 1 control(s))
[SPS PHYS] fitting valve OPEN: coupling id=1 of <barn>.xml
[SPS PHYS] gravity flow START on <vehicle>.xml: WATER, tank y=.. barn y=.. head=.. rate x..
```

Debug channels: `spsDebug SPSM_LiquidLanes on`, `SPSLiquidLaneControl`, `SPSLiquidLaneEvent`.

## 6. Checklist

- Water lane: `automaticWaterSupply="false"` and WATER in the husbandry storage.
- Milk lane: MILK and/or BUFFALOMILK in the husbandry storage.
- One mount node per lane on the barn, one connector on the vehicle; each with `*Arcs`
  (two children), `inNode`, `outNode`; connector mesh optional.
- Vehicle: fill unit accepts the liquid; control node within reach of the connector.
- Same `mountNodeName` spelling in the XML and the i3d.
