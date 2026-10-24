# FS25_SlurryPipeSystem

**Realistic physical slurry pipe system for Farming Simulator 2025.**

Replaces vanilla "drive into a trigger and fill" mechanics with a tactile system where you
physically connect tanker fill arms or pipes, run a PTO-driven pump, build pressure, control
flow direction, and watch slurry move through real plumbing — with a slurry that actually
thickens, crusts and blocks if you neglect it.

Current version: **1.0.1.8** — full list of changes in `RELEASE_NOTES_V1.0.1.8.md` inside the mod.

---

## What's new in 1.0.1.8

- **Physical pipes** — real pipes you buy, carry, plug in and join by hand, as an alternative
  to the original laid pipes. One shop page for every pipe: choose **slurry, water or milk**,
  **4 m or 6 m**, and the **ends** (female/male, female/female, male/male), plus a colour.
  The game asks the host once which pipe system a save uses; it can be changed later in the
  settings.
- **Free a stuck pipe** — pick up a pipe that is caught in a wheel or fender and press
  **Free stuck pipe** (Left Alt + F, rebindable): it passes through vehicles while held; let
  go and it collides again.
- **Pipe holders on tankers** — stow pipes on the tanker's side with right mouse.
- **SPS Docking Station** — a portable boot port, carried and stowed on tankers like a pipe.
- **SPS Tower Mixer** — a tractor-driven lagoon mixer on a folding tower with its own pump:
  mix the store, then pump the mixed slurry straight into a tanker.
- **Pump flow meter** — the PTO pump and the tower mixer show rate, total pumped and, when
  nothing moves, why (valve closed, source empty, destination full, too thick). The tanker
  HUD shows the same reason while a pump feeds it.
- **Water and milk by pipe** — fittings with their own valves for animal drinking water in
  and milk out, gravity flow, tanker to tanker; the **Cow Barn Medium (SPS)** placeable.
- **Fertiliser / herbicide silo** — four tanks, one connection, walk-in tank switch.
- **Dirt and wear** — pipes, the docking station, the PTO pump and the tower mixer get dirty
  and worn with use; the pressure washer cleans them.
- **Draw your own water courses** in the building screen.
- **Multiplayer** — many sync fixes; only an admin can change the SPS gameplay settings;
  other farms cannot work your valves, pumps or separator.
- **Shop** — the pipe, docking station, PTO pump and tower mixer sit under **Slurry Tools**
  and in the **SPS Slurry Kit** pack.

---

## What it does

**Two pipe systems (chosen per save)**
- **Physical pipes** — bought pipe items with real ends: carry them in your hands, plug an
  end into a coupler or join it to another pipe, stow them on a tanker's pipe holder.
- **Original system** — **pipe chains** laid by walking from one coupler toward another,
  and **direct pipes** — a single connecting pipe between two nearby couplers.

**Plumbing & transfer**
- **Fill arms** swung out of the tanker by joystick into open slurry pits or rubber boot
  ports on buildings, other vehicles and the docking station.
- **PTO Slurry Pump** — a pump on the tractor's three-point linkage that moves slurry
  between two pipes, with a flow meter.
- **Animated couplers and valves** — clamp handles close on connect, valve wheels and ball
  valves turn on open.
- **Lid-linked deployable couplers** — a store coupler can drive the placeable's own vanilla
  animated lid: deploy opens it, connect requires it fully open, and the lid locks while a
  pipe is live.
- **Pipes rest on real surfaces** — pipes settle onto concrete pads, building floors, bridge
  decks and roads, not just the terrain.
- **Coloured pipes** — pick from a palette, stored per save.
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
  engaged; walk-up hold-to-repair. A snapped bolt stays snapped through a save.

**Slurry that behaves like slurry**
- **Thickness / dry matter** — slurry thickens as dry matter concentrates; thickness affects
  flow and spread.
- **Crust & blockages** — an unmixed store crusts over on a fixed physical timescale (720
  game hours, roughly 30 in-game days, whatever your season length); crusted, lumpy slurry
  blocks spreader outlets and the macerator. Mixing clears the risk in about 2 game hours;
  **adding water** dilutes thick slurry.
- **Agitation** — the SPS Tower Mixer, fixed PTO agitators on stores, and any registered
  vehicle with an agitator tip node.
- **Slurry separation** — the Börger screw-press separator placeable strips dry matter out
  of piped slurry: solids drop onto its manure bunker, the thinner liquid fraction returns
  through the pipe. Walk-up start/stop and a five-step screw tightness control.
- **Water intake** — fill arms and pipes can draw water straight from map lakes and ponds
  wherever the map provides SPS water, or from water courses you draw yourself.
- **Front-mount fill arms** — a capacity-0 pass-through pump unit on the tractor's front
  linkage, hose-linked to a rear receiver tanker on **any** tractor. Filling cascades:
  coupler-connected targets first, overflow to the rear tanker, switching automatically as
  levels change — full mirror when unloading.
- **Buying station support** — a compatible buying-station placeable (FS25_BuyableManureAndOther)
  acts as a paid, infinite pipe-only source, with a walk-up switch to choose which sold
  liquid the coupler dispenses. A **sprayer** variant sells liquid fertiliser / herbicide
  straight into the sprayer pipe system.

**Spreading**
- **Dribble bars & band spreaders** — per-outlet blockage modelling with a macerator that
  shields the outlets up to its capacity, per-vehicle tuning, and a spreader HUD.
- **Fertiliser / herbicide sprayers** — load liquid fertiliser or herbicide through the same
  coupler-and-pipe system, operated from a single walk-up pump control. No pressure model on
  sprayers — flow is a flat rate.
- **Front tank combos ("FlowControl")** — any front tank pairs automatically with any rear
  sprayer on the same tractor sharing a fill type. One pipe connection to either tank fills
  or drains **both**, and an automatic balancer holds the rear at 30% from the front tank
  while spraying, so the front empties first. No config pairing, no keybind.

---

## Documentation map

The guides ship inside the mod folder:

If you want to... | Read this
---|---
Set up or use a slurry tanker or dribble bar | **SPS_README_01_Tanker_and_Spreader.md**
Set up or use a fertiliser / herbicide sprayer | **SPS_README_02_Fert_Sprayer.md**
Set up a store, pit, barn or liquid source tank | **SPS_README_03_Placeables.md**
Add water sources to a map / draw water courses | **SPS_README_04_Map_Water.md**
Animal drinking water in and milk out by pipe | **SPS_README_05_Animal_Water.md**
Use physical pipes, pipe holders and the docking station | **SPS_README_06_Physical_Pipes.md**
Use the SPS Tower Mixer | **SPS_README_07_Tower_Mixer.md**
Understand thickness, crust and mixing | **SlurryPipeSystem_SlurryGuide.md**

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

See the guides in the documentation map above.

### Bundled / manifest (SPS-internal — not for third-party modders)

How SPS ships support for its own stock fleet: files inside the SPS folder plus a
`spsConfigManifest.xml` entry, matched by config path. This requires modifying the SPS mod
and is **not** a supported way to add your own content — use the embedded path instead.

---

## File layout

```
FS25_SlurryPipeSystem/
├── modDesc.xml
├── RELEASE_NOTES_V1.0.1.8.md                  ← everything since 1.0.1.7
├── SPS_README_01 … 07_*.md                    ← player / modder guides (see documentation map)
├── SlurryPipeSystem_SlurryGuide.md            ← thickness, crust and mixing explained
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
├── vehicles/
│   ├── hoses/spsPipe.xml                       ← the physical pipe (one shop item, all types)
│   ├── dockingStation/                         ← SPS Docking Station
│   ├── PTOSlurryPump/                          ← PTO Slurry Pump
│   └── towerMixer/                             ← SPS Tower Mixer
│
├── placeables/                                 ← Cow Barn Medium (SPS), fert/herbicide silo,
│                                                  Börger separator, water-course brushes
├── i3d/                                        ← shared visual assets (connectors, IBCs, mixers…)
├── placementPipes/                             ← pipe visuals for the build-menu preview
├── effects/                                    ← pipe / arm effects
├── water/                                      ← optional external water nodes (SPS-internal)
├── Mechet/                                     ← drop-in kit for The Mechet map
├── icons/  l10n/                               ← HUD icons, six languages
│
└── scripts/                                    ← Lua source
    ├── init.lua                                ← entry point
    ├── debug/                                  ← channel-gated debug registry (`spsDebug`)
    ├── manager/                                ← singleton manager + domain modules
    ├── specializations/                        ← pipe item, docking station, pump mixer, park pose…
    ├── hoses/                                  ← hose visuals, carrying pipes in the hands
    ├── events/                                 ← network events
    ├── chains/  couplers/  liquidLanes/        ← original pipes, couplers, water / milk lanes
    ├── herbFertSprayer/  separator/  agitators/
    ├── blockage/  shearBolt/  buyStation/
    ├── hud/  settings/  water/  util/  overrides/
```

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
See the placeables guide for the block format.

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

### A quiet log

SPS writes only warnings, errors and a couple of status lines to `log.txt`. Routine detail
(registrations, pipe grab / drop, hooks) is behind the `Info` debug channel: type
`spsDebug Info on` in the console when you need it.

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
- **Real autosave** — SPS save data is preserved across autosaves.
- **Multiplayer** — server-authoritative state; connections, valves, pressure, pump, pipes
  and shear-bolt state all sync via dedicated events. Unzipped mod folders do not run in
  multiplayer — use the release zip.

---

## Credits

**Oscar Mods** — design, code, art.

Contributions, bug reports, and modder-side embedded integrations welcome.
