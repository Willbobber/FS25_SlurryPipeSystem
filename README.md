# FS25_SlurryPipeSystem

**Realistic physical slurry pipe system for Farming Simulator 2025.**

Replaces vanilla "drive into a trigger and fill" mechanics with a tactile system where you
physically connect tanker fill arms or pipe chains, run a PTO-driven pump, build pressure,
control flow direction, and watch slurry move through real plumbing — with a slurry that
actually thickens, crusts and blocks if you neglect it.

---

## What it does

**Plumbing & transfer**
- **Fill arms** swung out of the tanker by joystick into open slurry pits or rubber boot
  ports on buildings and other vehicles.
- **Pipe chains** — multi-segment pipes laid by walking from one coupler toward another,
  locked into place when both ends overlap valid couplings.
- **Direct bez pipes** — a single connecting pipe between two nearby couplers, for quick pump
  transfers between a tanker and a building.
- **Conduit pump (PTO Slurry Pump)** — a passive pump trailer that lets two pipe chains
  transfer through it.
- **Animated couplers and valves** — clamp handles close on connect, valve wheels rotate on
  open.
- **Lid-linked deployable couplers** — a store coupler can drive the placeable's own vanilla
  animated lid: deploy opens it, connect requires it fully open, and the lid locks while a
  pipe is live.
- **Pipes rest on real surfaces** — laid pipes and connection pipes settle onto concrete
  pads, building floors, bridge decks and roads, not just the terrain.
- **Coloured pipes** — pick from a palette per pipe segment, stored per save.
- **Multi-fill-type support** — works with `LIQUIDMANURE` and `DIGESTATE`; transfers
  automatically pick whichever fill type is actually present, and mixed deposits merge into
  the type already held.
- **Gravity head equalisation** — opt-in per coupler: levels equalise between connected
  vessels by gravity, gated on the pipe's high point, so slurry only runs downhill when it
  genuinely can.

**Pumps & pressure**
- **Pump types** — `vacuum` (stored ±bar pressure model with a gauge), `HVP` high-volume
  pump, `conduit` pump station, and `openTop` passive vessels (e.g. nurse tanks).
- **Pressure model** — vacuum tankers build, hold, taper and purge a stored charge that
  drives fill and discharge; spread behaviour scales with pressure rather than a simple
  on/off.
- **PTO shear bolt (opt-in)** — wears and snaps under load while turning with the PTO
  engaged; walk-up hold-to-repair.

**Slurry that behaves like slurry**
- **Thickness / dry matter** — slurry thickens as dry matter concentrates; thickness affects
  flow and spread.
- **Crust & blockages** — an unmixed store crusts over on a fixed physical timescale (720
  game hours, roughly 30 in-game days, whatever your season length); crusted, lumpy slurry
  blocks spreader outlets and the macerator. Mixing clears the risk in about 2 game hours;
  **adding water** dilutes thick slurry.
- **Agitation** — a manager-driven agitator works on any registered vehicle with an agitator
  tip node, no specialization required.
- **Slurry separation** — the Börger screw-press separator placeable strips dry matter out
  of piped slurry: solids drop onto its manure bunker, the thinner liquid fraction returns
  through the pipe. Walk-up start/stop and a five-step screw tightness control; recirculate
  for progressively thinner slurry.
- **Water intake** — fill arms can draw water straight from map lakes and ponds wherever the
  map provides SPS water planes.
- **Front-mount fill arms** — a capacity-0 pass-through pump unit on the tractor's front
  linkage, hose-linked to a rear receiver tanker on **any** tractor via injected Giants
  connection hoses (the Xerion keeps its own factory hose circuit). Filling cascades:
  coupler-connected targets first, overflow to the rear tanker, switching automatically as
  levels change — full mirror when unloading.
- **Buying station support** — a compatible buying-station placeable (FS25_BuyableManureAndOther)
  acts as a paid, infinite pipe-only source, with a walk-up switch to choose which sold
  liquid the coupler dispenses (Shift + activate cycles in reverse). A **sprayer** variant
  sells liquid fertiliser / herbicide straight into the sprayer pipe system — a part-full
  sprayer auto-switches the station to its held liquid on connect and locks the switch
  while connected, and script mods can add whole liquid categories via
  `<extraFillTypeCategory>`.

**Spreading**
- **Dribble bars & band spreaders** — per-outlet blockage modelling with a macerator that
  shields the outlets up to its capacity, per-vehicle tuning, and a spreader HUD.
- **Fertiliser / herbicide sprayers** — load liquid fertiliser or herbicide through the same
  coupler-and-pipe system via a dedicated sprayer integration, operated from a single
  walk-up pump control. No pressure model on sprayers — flow is a flat rate.
- **Front tank combos ("FlowControl")** — any front tank pairs automatically with any rear
  sprayer on the same tractor sharing a fill type. One pipe connection to either tank fills
  or drains **both**, and an automatic balancer (modelled on the real Amazone FT-P) holds the
  rear at 30% from the front tank while spraying, so the front empties first and front axle
  load is preserved. No config pairing, no keybind — attach and go.

---

## How to add support to your own content

**The supported way to add SPS to your own mod is the embedded path below.** You do **not**
edit the SPS mod. Adding files inside the SPS folder is an internal mechanism used only for
the fleet SPS ships itself; doing it to add your own content will cause multiplayer issues.

### Embedded — for modders (recommended, MP-safe, self-contained)

Add a single block to your **own** vehicle, placeable or map. No SPS-side files, no manifest
entry. Players with SPS installed get integration automatically; players without SPS see your
mod work normally. Self-contained, with no conflicts against other mods of the same vehicle.

| Your content | Block to add | Where |
|---|---|---|
| Slurry tankers, dribble bars, nurse tanks, pump trailers | `<slurryPipeSystem>` | inside `<vehicle>` |
| Fertiliser / herbicide sprayers | `<sprayerPipeSystem>` | inside `<vehicle>` |
| Slurry stores, pits, lagoons | `<slurryPipeSystem>` | inside `<placeable>` |
| Liquid-fertiliser source tanks | `<sprayerPipeSystem>` | inside `<placeable>` |
| Map water sources (lakes/ponds) | an `SPS_waterNodes` node tree | in the **map i3d**, under the terrain root |

See the setup guides listed in the documentation map below.

### Video guides

Watch the whole process end to end before (or instead of) reading:

- **Setting up a vacuum tanker** — fill arm, couplers, pressure model, nodeTree:
  https://www.youtube.com/watch?v=1JKplzkCDS4
- **Setting up a placeable store** — fill plane, couplers, surface detection:
  https://www.youtube.com/watch?v=C4EO5RhY6Fk

### Custom vehicle types

Your vehicle does **not** have to use a vanilla type name. A custom type declared in your
modDesc works as long as it descends from one of the vanilla tanker or sprayer types:

```xml
<vehicleTypes>
    <type name="myTanker" parent="manureBarrel" className="Vehicle"
          filename="$dataS/scripts/vehicles/Vehicle.lua">
        <specialization name="waterTrailer"/>
    </type>
</vehicleTypes>
```

SPS walks the parent chain, so any descendant of `manureBarrel`, `manureTrailer`,
`selfPropelledManureBarrel`, `sprayer` or `selfPropelledSprayer` — at any depth — receives
the full SPS behaviour. (Added in 1.0.1.4; earlier versions required the exact vanilla
type names.)

Even a type that descends from **none** of these still works (1.0.1.5+): a vehicle
carrying an embedded `<slurryPipeSystem>` block receives the tanker behaviour per-vehicle
when it registers, whatever its type — the block in your XML is the authority. Descending from
the matching vanilla family is still recommended (it is what the type means in vanilla,
and other slurry-aware mods may key on it too).

### Bundled / manifest (SPS-internal — not for third-party modders)

How SPS ships support for its own stock fleet: files inside the SPS folder plus a
`spsConfigManifest.xml` entry, matched by config path. This requires modifying the SPS mod
and is **not** a supported way to add your own content — use the embedded path instead.

---

## File layout

```
FS25_SlurryPipeSystem/
├── modDesc.xml
├── SPS_README_01_Tanker_and_Spreader.md        ← tanker / dribble-bar setup (embedded)
├── SPS_README_02_Fert_Sprayer.md               ← sprayer setup (embedded)
├── SPS_README_03_Placeables.md                 ← store / pit / source-tank setup (embedded)
├── SPS_README_04_Map_Water.md                  ← map water sources (embedded, map i3d)
├── SlurryPipeSystem_SlurryGuide.md             ← player guide: thickness, crust, mixing, blockages
├── RELEASE_NOTES_V1.0.1.5.md                   ← changes in this release
├── RELEASE_NOTES_V1.0.1.4.md                   ← previous release
│
├── configs/
│   ├── spsConfigManifest.xml                   ← bundled (SPS-internal) fleet list
│   ├── couplerAnimations.xml                   ← coupler animation library (shared)
│   ├── spsColors.xml                           ← pipe colour palette
│   ├── data/                                   ← stock fleet bundled configs
│   │   ├── vehicles/<vendor>/<model>/{fillPoints.xml, nodeTree.i3d}
│   │   └── placeables/<vendor>/<model>/{fillPoints.xml, nodeTree.i3d}
│   └── mods/                                   ← third-party fleet bundled configs (internal)
│       └── <FS25_ModFolderName>/...
│
├── water/                                      ← optional external water nodes (SPS-internal)
│   ├── spsWaterManifest.xml
│   └── <mapFolder>/SPS_waterNodes.i3d
│
├── i3d/                                        ← SPS visual assets
│   ├── pipes/slurryPipe.i3d                    ← slurry pipe mesh and rig
│   ├── pipes/sprayerPipe.i3d                   ← sprayer pipe mesh
│   ├── nodes/spsPivot.i3d                      ← chain pivot helper
│   └── dockingStation/dockingStation.i3d       ← docking station building
│
└── scripts/                                    ← Lua source
    ├── init.lua                                ← entry point (loaded last)
    ├── debug/
    │   └── SPSDebugConfig.lua / SlurryDebug.lua ← channel-gated debug registry + markers
    ├── manager/
    │   ├── SlurryPipeManager.lua               ← singleton manager (core)
    │   └── SPSM_Chains / SPSM_Couplers / SPSM_Flow / SPSM_Pressure /
    │       SPSM_Consistency / SPSM_Stores / SPSM_Spreader / SPSM_Sprayers /
    │       SPSM_FrontMount / SPSM_IBC .lua
    │                                           ← domain modules of the manager
    ├── events/
    │   └── SPSEvents.lua                       ← network events
    ├── chains/
    │   └── SPSPipeChain.lua / SPSChainActivatable.lua
    ├── couplers/
    │   ├── SPSPipeVisual.lua / SPSPipeActivatable.lua / SPSCouplerAnimator.lua
    │   └── SPSPumpControlActivatable.lua / SPSOutsideControlActivatable.lua
    ├── blockage/
    │   └── SPSBlockageActivatable.lua / SPSBlockageEvent.lua
    ├── shearBolt/
    │   └── SPSShearBolt.lua / SPSShearBoltActivatable.lua / SPSShearBoltEvent.lua
    ├── agitators/
    │   ├── SlurryAgitatorEvent.lua
    │   └── SPSFixedAgitator / SPSFixedAgitatorShaft / SPSFixedAgitatorActivatable /
    │       SPSFixedAgitatorEvent .lua          ← fixed PTO agitator placeable system
    ├── separator/
    │   └── SPSSeparator.lua / SPSSeparatorActivatable.lua / SPSSeparatorEvent.lua
    ├── buyStation/
    │   └── SPSBuyStationActivatable.lua / SPSBuyStationEvent.lua
    ├── hud/
    │   └── SPSSpreaderHUD.lua                  ← (+ SPSConduitHUDExtension.lua, source()'d)
    ├── herbFertSprayer/                        ← fertiliser / herbicide sprayer support
    │   ├── SPSSprayerPumpControl.lua / SPSSprayerEvents.lua
    │   └── SPSSprayerPipeVisual.lua / SPSSprayerPipeActivatable.lua
    ├── water/
    │   └── SPSWaterPlaneManager.lua            ← map water detection
    ├── util/
    │   └── SlurryNodeUtil.lua / SlurryTractorCapability.lua / SPSCrustVegetation.lua
    ├── settings/
    │   └── SPSSettingsMenuExtension.lua        ← in-game settings page (source()'d late)
    └── overrides/
        ├── ManureBarrelOverride.lua / PlaceableOverride.lua
        └── SPSSlurryTankExtensions.lua / SPSChainBondPersistence.lua
```

---

## Documentation map

If you want to... | Read / watch this
---|---
Add SPS to a slurry tanker or dribble bar | **SPS_README_01_Tanker_and_Spreader.md** · [video: vac tanker setup](https://www.youtube.com/watch?v=1JKplzkCDS4)
Add SPS to a fertiliser / herbicide sprayer | **SPS_README_02_Fert_Sprayer.md**
Add SPS to a store, pit or liquid source tank | **SPS_README_03_Placeables.md** · [video: placeable setup](https://www.youtube.com/watch?v=C4EO5RhY6Fk)
Add water sources to a map | **SPS_README_04_Map_Water.md**
Understand thickness, crust, mixing and blockages in play | **SlurryPipeSystem_SlurryGuide.md**

---

## Key concepts

### Embedded blocks are detected first

`<slurryPipeSystem>` / `<sprayerPipeSystem>` inside a vehicle or placeable XML are detected
before any manifest lookup. The manifest is only consulted when no embedded block is present.
A third-party retexture of a vehicle can ship its own embedded block and get SPS integration
without affecting other instances of the same base vehicle, and without touching SPS.

### Coupler animations come from the shared library — or your own

Coupler clamp and valve animations are defined in the SPS-bundled
`configs/couplerAnimations.xml`. A coupling references an animation by integer `id`
(`connectorAnimation` / `valveAnimation`), and SPS resolves that animation's named part nodes
**under the coupling's mount node** and drives them. To use a shipped animation you name your
clamp/valve sub-objects to match the part names that id expects (the file lists them).

You can also define your **own** animations without touching SPS: put a
`<couplerAnimations>` block inside your embedded `<slurryPipeSystem>` /
`<sprayerPipeSystem>`, using the same format as the shipped file. Config-local ids are
checked before the shared library, so a local id overrides a shipped one of the same number.
See the placeable guide §7 for the block format.

### Path-based manifest matching (internal)

For the bundled fleet, each manifest entry has a `path` that must match the **tail** of the
runtime `configFileName` Giants reports (stock = `data/vehicles/...`, mods =
`mods/<FS25_ModFolderName>/...`). Case-insensitive but otherwise exact — no fuzzy matching.
The bundled `fillPoints.xml` location is auto-derived from the path (drop the filename,
prepend `configs/`, append `fillPoints.xml`), overridable with a `configFolder` attribute.

### Multi-fill-type pipes

Coupling-to-coupling transfers and discharge effects use whatever fill type is present in the
source. A nurse tanker carrying digestate piped to a digestate-accepting store works exactly
like the liquidmanure equivalent.

---

## Compatibility

- **Manual Attach** — load-order-safe; SPS detects FS25_manualAttach and routes pipe-related
  connection-hose checks through its API when present.
- **Soil & Fertilizer (TheCodingDad, FS25_SoilFertilizer)** — all twelve S&F custom liquid
  IBC tanks are recognised: SPS spawns the matching branded IBC for a connected sprayer's
  fill type, with correct labelling and pipe connections. No S&F files are touched.
- **Buyable Manure And Other (BartsoNv3, FS25_BuyableManureAndOther)** — the liquid manure
  buying station registers as a paid, infinite SPS pipe source, with a walk-up switch
  between its sold liquids. Purchases charge through the station's own pricing.
- **Base-game silo extensions** — the vanilla Liquid Manure Tank Extensions (small and
  large) link to their base tank normally; SPS's anti-pooling filter recognises them as
  capacity extensions. Standalone tanks still keep separate fill levels.
- **Missions & contracts** — mission/contract vehicles are never captured by SPS, so
  leased contract sprayers and tankers fill through vanilla triggers and contracts
  complete normally, on dedicated servers included.
- **Real autosave** — SPS save data is preserved across autosaves.
- **Multiplayer** — server-authoritative state; valve toggles, connections, pressure, pump
  and shear-bolt state all sync via dedicated events.

---

## Credits

**Oscar Mods** — design, code, art.

Contributions, bug reports, and modder-side embedded integrations welcome.
