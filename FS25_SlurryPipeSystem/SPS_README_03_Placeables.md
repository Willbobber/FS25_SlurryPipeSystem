# Slurry Pipe System (SPS) — Adding SPS to Placeables (Stores, Pits & Source Tanks)

This guide is for placeable / map modders who want their own slurry store, open pit, manure
lagoon, or liquid-fertiliser source tank to work with SPS — so SPS tankers and sprayers can
load from and discharge into them.

**You never edit the SPS mod.** Everything is done inside *your own* placeable's XML and i3d.
Editing files inside the SPS mod folder will break multiplayer and is not supported.

Two placeable kinds, two blocks:
- **Slurry store / pit / lagoon** → `<slurryPipeSystem>`.
- **Liquid-fertiliser / herbicide source tank** (for sprayers) → `<sprayerPipeSystem>`.

> Drawing **water** from map lakes/ponds is a separate, map-i3d system — see the dedicated
> map-side water guide, not this document.

All element/attribute names below are exactly what the SPS parser reads.

---

## 1. How to register your placeable — embedded block

```xml
<placeable ...>
    ...
    <slurryPipeSystem>
        ... SPS config ...
    </slurryPipeSystem>
</placeable>
```

SPS uses `placeable.slurryPipeSystem` / `placeable.sprayerPipeSystem` directly. On load:

```
[SPS fillPlane debug] <yourPlaceable>.xml ...
... registerPlaceable - registered <yourPlaceable>.xml
```

**Storage requirement.** A slurry store only becomes a source if it has `spec_silo`,
`spec_husbandry`, or `spec_siloExtension`. (A `spec_husbandry` / `spec_productionPoint` with
no fill plane still works as a *coupling-only* source — pipe access, no arm surface
detection.)

---

## 2. Node resolution — which nodes need a nodeTree

Two resolution paths:

**A) Against your placeable's own i3d** (mapping name or index path) — no nodeTree needed:
- `fillPlane#node`
- `hideNodes` / `hideCollisions` entries
- `pipeAnimNode#node`
- a coupling's legacy `#node` (+ `#offsetX/Y/Z`)

**B) By name from an injected nodeTree only** (not searched in the placeable's own tree):
- a coupling's `mountNodeName`
- `fillPlane#centreNodeName` / `edgeNodeName` / `corner1NodeName` / `corner2NodeName`
- coupling `effects` effect-node names

### nodeTree (optional)

```xml
<nodeTree filename="path/to/nodeTree.i3d"/>
```

First child is the SPS root; under it are *group* transforms; under each group are *container*
transforms whose names must match a node in your placeable's first component
(`components[1]`). Each container's children are re-linked under that live node.

---

## 3. The fill plane — `<fillPlane>` (slurry stores)

Lets a tanker's fill arm detect the slurry surface, submerge into it, and follow it up/down.

```xml
<fillPlane node="0>5|2"
           minY="0.0"
           maxY="1.8"
           fillType="LIQUIDMANURE"
           shape="round"
           centreNodeName="pitCentre"
           edgeNodeName="pitEdge"/>
```

| Attribute        | Default        | Meaning |
|------------------|----------------|---------|
| `node`           | —              | The fill-plane node (your own i3d, by mapping name or index path). Moved in Y to represent the surface. |
| `minY`           | 0              | Local Y of the surface when **empty**. |
| `maxY`           | 1              | Local Y of the surface when **full**. |
| `fillType`       | `LIQUIDMANURE` | Content type. Falls back to LIQUIDMANURE if unknown. |
| `shape`          | —              | Optional XZ detection bounds: `round` or `rectangle`. |
| `centreNodeName` | —              | Centre of the detection area (nodeTree). |
| `edgeNodeName`   | —              | `round`: rim node; radius = XZ distance centre→edge. |
| `corner1NodeName`| —              | `rectangle`: one corner. |
| `corner2NodeName`| —              | `rectangle`: opposite corner. |

Surface Y = `minY + (fillLevel / capacity) * (maxY - minY)`. The shape nodes define only the
XZ footprint the arm must be over (their Y is ignored). Omit `shape` and the store still works
for piped access; the shape is what enables arm-into-pit surface detection.

> **`<fillPlane>` and `<slurryStores>` are alternatives, never companions.** Declaring both
> logs a warning and `<slurryStores>` wins — the singular block, including its crust nodes,
> is ignored. `<fillPlane>` is also **not supported on a production point**: nothing in
> vanilla drives a production point's plane node, so it would sit frozen at its authored
> height. Production points must use `<slurryStores>` (§3A), which drives the plane itself.

---

## 3A. Multi-store placeables — `<slurryStores>`

For a placeable with **more than one lagoon**, or for any **production point** (biogas
plant, etc.) where vanilla does not drive the plane. SPS drives each declared plane itself,
every tick, on both server and client.

```xml
<slurryStores>
    <slurryStore id="1" node="slurryStore01" fillPlaneNode="slurryPit_fillPlane"
                 minY="0.0" maxY="1.8" fillType="LIQUIDMANURE"
                 poolFillTypes="LIQUIDMANURE DIGESTATE"
                 shape="rectangle" centreNodeName="slurryPlaneCentre01"
                 corner1NodeName="pitCorner1" corner2NodeName="pitCorner2"
                 agitator="true" hideWhenEmpty="true">
        <crust planeNode="crust_fillPlane" foliageNode="crustFoliage" maxRise="0.16"/>
    </slurryStore>
    <slurryStore id="2" node="slurryStore02" ... />
</slurryStores>
```

| Attribute         | Default        | Meaning |
|-------------------|----------------|---------|
| `id`              | position index | Store id, used for saving and multiplayer sync. Keep stable once a save exists. |
| `node`            | —              | Root node of this store's subtree. **Required** — the store is skipped if not found. All the store's other nodes are resolved inside this subtree, so duplicating a lagoon only means renaming this root. |
| `fillPlaneNode`   | —              | The surface plane node. Driven in Y by SPS. |
| `minY` / `maxY`   | 0 / 1          | Local Y of the surface when empty / full. |
| `fillType`        | `LIQUIDMANURE` | This store's content type. |
| `poolFillTypes`   | `fillType`     | Space-separated set of fill types treated as **one body of liquid** sharing this plane and crust (e.g. `LIQUIDMANURE DIGESTATE` on a BGA). Unknown names are warned about and ignored. |
| `shape`           | —              | `round` or `rectangle` — XZ detection footprint, same meaning as `<fillPlane>`. |
| `centreNodeName`  | —              | Centre of the detection area. |
| `edgeNodeName`    | —              | `round`: rim node. |
| `corner1NodeName` / `corner2NodeName` | — | `rectangle`: opposite corners. |
| `agitator`        | `false`        | Whether this store participates in the thickness / crust model. |
| `hideWhenEmpty`   | `true`         | Hide the plane at zero fill level. |

Store 1 becomes the placeable's **primary** source, so every existing coupler binding, save
path and HUD readout keeps working unchanged; the remaining stores ride alongside it.

Each store keeps its **own** dry matter, crust and thickness, saved independently and synced
independently in multiplayer. A fixed agitator stirs the store named by its `storeId` (§6A).
Detection bounds nodes should live **inside** the store's own subtree so a lagoon can be
copy-pasted wholesale.

### Per-store crust

`<crust>` inside a `<slurryStore>` takes `planeNode`, `foliageNode` and `maxRise` with the
same meanings as the placeable-level block in §6. Plants, density and edge margin are read
from the placeable-level `<crust>` block and shared across stores.

---

## 4. Pipe couplings — `<pipeCouplings>` (store inlet/outlet)

A fixed connection point a tanker's strap pipe connects to. Walk-up connect and lay-chain are
added automatically on the placeable side.

```xml
<pipeCouplings>
    <pipeCoupling id="1"
                  mountNodeName="storeInlet01"
                  valveType="MANUAL"
                  flowDirection="BOTH"
                  connector="female"/>
</pipeCouplings>
```

| Attribute              | Default  | Meaning |
|------------------------|----------|---------|
| `id`                   | index+1  | Identifier. |
| `mountNodeName`        | —        | Coupler mount node (nodeTree). Required unless using legacy `#node`. |
| `node` (legacy)        | —        | Alternative: a node from your own i3d. |
| `offsetX/Y/Z` (legacy) | 0        | Optional local offset on the legacy `#node` mount. |
| `valveType`            | `MANUAL` | `MANUAL`, `HYDRAULIC`, or `NONE`. `NONE` = free-flowing port: no valve prompts anywhere on the run, the walk-up prompt is connect/disconnect only. |
| `flowDirection`        | `BOTH`   | `BOTH`, `FILL`, or `DISCHARGE` (separators additionally use `IN`/`OUT` — see §10). |
| `fillType`             | —        | Optional per-coupler fill type restriction: only this fill type passes through this coupler, in either direction (e.g. separate `LIQUIDMANURE` and `DIGESTATE` couplers on one shared BGA storage). Unset = no restriction — the transfer picks whichever supported type is actually present, unchanged legacy behaviour. |
| `connector`            | `female` | `male` / `female` — matched against the tanker end (tankers default `male`). |
| `connectorAnimation`   | —        | Optional coupler animation id (see §7). |
| `valveAnimation`       | —        | Optional valve animation id (see §7). |
| `deployable`           | false    | If true the coupler starts hidden + non-colliding until deployed. |
| `undeployedVisibleNode`| —        | Space-separated node names shown while undeployed (e.g. a cap). |
| `deployAnimatedObjectSaveId` | —  | Link the coupler to one of the placeable's own vanilla animated objects (a lid) — see below. |
| `headHeightNodeName`   | —        | Opt-in gravity head gate — see below. |

### Required mount node structure

Same as on vehicles — the connection arc is resolved **by child position**:

```
storeInlet01                   <- the mountNodeName
├── arcs                       <- MUST be child index 0 (any name) = arc apex
│   ├── arcA                   <- child 0 of arcs
│   └── arcB                   <- child 1 of arcs
├── inNode                     <- direct child, named EXACTLY "inNode"
└── outNode                    <- direct child, named EXACTLY "outNode"
```

- First child of the mount node = arc apex; its first two children = the arc points.
- The player must stand **inside this arc triangle** for the coupler to be selectable, and a
  tanker coupler connects only when the two triangles overlap within **5.9 m**.
- If no arc geometry is resolvable, the placeable coupler falls back to a **1.8 m** proximity
  radius (slurry only — this fallback does not exist for sprayers).
- `inNode` / `outNode` are direct children matched by exact name; they are the flow points.

### Connect / valve interaction (slurry)

At the coupler, the player presses ACTIVATE_OBJECT (R):
- **Short press** — connect (when a tanker coupler overlaps) or disconnect (when connected).
- **Hold ~0.8 s** — open the valve, then hold again to close it.
- If the coupling is `HYDRAULIC` or driven from a rear control, the walk-up prompt only
  disconnects (no valve via this prompt).
- `valveType="NONE"` couplers show no valve prompts at all — connect and disconnect only,
  and the far end of a connected run is treated as free-flowing.

### Lid-linked deployable couplers — `deployAnimatedObjectSaveId`

If your placeable already has a vanilla `<animatedObjects>` lid (e.g. a slurry tank cover),
a coupling can drive it as part of the deploy sequence — no restructuring of your animation:

```xml
<pipeCoupling id="1" mountNodeName="tankInlet01"
              deployable="true"
              deployAnimatedObjectSaveId="slurryLid"/>
```

- The attribute names the `saveId` of an AnimatedObject in the **same placeable's** own
  `<animatedObjects>` section. SPS drives it via the vanilla `setDirection` API, so its
  state syncs in multiplayer through the game's own AnimatedObject events.
- **Deploy** opens the lid; **undeploy** closes it. Connecting (or laying a chain) to the
  coupler is only available once the lid is **fully open**.
- While any linked coupler is deployed or connected, the lid's own walk-up trigger is
  locked, so a player cannot shut the lid on a live pipe.
- **Shared lids:** if one lid covers several couplers, use **one** AnimatedObject and have
  every coupling reference the **same** `deployAnimatedObjectSaveId` — do not create one
  animated object per coupler for the same lid nodes.
- An unknown saveId logs a warning and disables the link for that coupler; couplings
  without the attribute are completely unaffected.

### Gravity head equalisation — `headHeightNodeName`

By default a store coupling is ignored by gravity equalisation, exactly as before. Declaring
`headHeightNodeName` (a nodeTree node placed at the **highest point of the pipe run** from
that coupler — e.g. the crest the hose climbs over the tank wall) opts it in: while a
vehicle is connected, levels equalise by gravity between store and vehicle, but only while
the driving surface sits **above** every declared head node and the receiving surface. The
same attribute exists on vehicle couplings (see the tanker guide §7).

### Optional inlet effects

```xml
<pipeCoupling id="1" mountNodeName="storeInlet01">
    <effects inletDistance="1.5">
        <effectNode effectNode="inletEffectTG"/>   <!-- index 0: pipe effect root (nodeTree) -->
        <effectNode effectNode="smokeNode"/>       <!-- index 1: smoke node name beneath it -->
    </effects>
</pipeCoupling>
```

`effectNode(0)` is the pipe-effect transform group; `effectNode(1)` names the smoke node
beneath it. The smoke entry is **optional** — with only `effectNode(0)` declared the pipe
liquid effect still runs, just without the smoke layer. The pipe mesh must be the **first child** of the effect transform group (it is
resolved by child position, not by name). `inletDistance` (default 1.5) sets the effect
length.

### Effect timing and shaping

Each `<effectNode>` accepts its own timing attributes. All are optional; omitted or negative
values fall back to the defaults below, which match the values hardcoded before 1.0.0.10.3.
Times are in **seconds**.

```xml
<effects inletDistance="1.5">
    <effectNode effectNode="inletEffectTG" maxBending="0.8" extraDistance="0.1"
                fadeInTime="1.0" fadeOutTime="1.0" planeFadeTime="1.0"
                startDelay="0.0" stopDelay="0.0"/>
    <effectNode effectNode="smokeNode" fadeInTime="1.0" fadeOutTime="1.0"
                planeFadeTime="1.0" startDelay="0.1" stopDelay="0.1"
                alignToWorldY="true"/>
</effects>
```

| Attribute       | Stream (index 0) | Smoke (index 1) | Meaning |
|-----------------|------------------|-----------------|---------|
| `maxBending`    | 0.8              | —               | How far the slurry stream may bend. |
| `extraDistance` | 0.1              | —               | Extra length past the resolved endpoint, in metres. |
| `fadeInTime`    | 1.0              | 1.0             | Seconds to fade the effect in. |
| `fadeOutTime`   | 1.0              | 1.0             | Seconds to fade the effect out. |
| `planeFadeTime` | 1.0              | 1.0             | Seconds to fade the effect plane. |
| `startDelay`    | 0.0              | 0.1             | Seconds between flow starting and the effect appearing. |
| `stopDelay`     | 0.0              | 0.1             | Seconds between flow stopping and the effect ending. |
| `alignToWorldY` | —                | `true`          | Keep the smoke node upright in world space. |

The same attributes are read on fill arm effect blocks.

---

## 5. Hiding base-game parts — `<hideNodes>` / `<hideCollisions>`

Both resolve against your placeable's own i3d.

```xml
<hideNodes>
    <node name="vanillaFillPlane"/>
</hideNodes>
<hideCollisions>
    <node name="oldCollision"/>
    <node node="0>3|1|4"/>   <!-- or by index path -->
</hideCollisions>
```

`hideNodes` sets visibility off (restored on mod removal). `hideCollisions` removes the node
from physics, by `name` (deep search, all matches) or by `node` index/mapping path.

---

## 6. Agitation / thickening / crust — `agitator` + `<crust>`

```xml
<slurryPipeSystem agitator="true" crustGrow="1.0">
```

`agitator="true"` (default false) makes the store participate in the slurry thickness model —
its content thickens over time and can be agitated. Leave off for a simple always-liquid
source.

`crustGrow` (default `1.0`, clamped 0.1–10) scales how fast **this store** crusts over. The
baseline is 720 game hours from clean to fully crusted, absolute and independent of season
length. `0.5` = a covered or sheltered tank that takes twice as long; `2.0` = an exposed pit
that skins over in half the time.

### Crust visuals — `<crust>` (optional, embedded-supported)

An `agitator="true"` store can also show a rising crust with foliage growing on it as the
store settles:

```xml
<crust density="0.3" planeNode="crustPlane" foliageNode="crustFoliage"
       maxRise="0.1" edgeMargin="0.1">
    <plant i3d="foliage/weed01.i3d" stage="1" weight="2"/>
    <plant i3d="foliage/weed02.i3d" stage="2" weight="1"/>
</crust>
```

| Attribute       | Default | Meaning |
|-----------------|---------|---------|
| `density`       | 0.3     | Foliage placement density. |
| `planeNode`     | —       | Optional crust plane mesh (rises with the settle value above the slurry surface). |
| `foliageNode`   | —       | Optional dedicated foliage anchor plane (child of the crust mesh); when set, plants attach here only. |
| `maxRise`       | 0.1     | Metres the crust plane sits above the slurry surface at full crust. |
| `edgeMargin`    | 0       | Keep foliage this many metres inside the plane edge. |
| `plant#i3d`     | —       | Plant i3d, relative to your config folder. At least one plant is required or the block is ignored. |
| `plant#stage`   | 1       | Crust stage the plant appears at (higher = more neglected). |
| `plant#weight`  | 1       | Relative pick weight among plants of the same stage. |

Foliage appears in stages as crust builds (roughly 40 / 60 / 80% crust) and clears again as
the store is agitated.

---

## 6A. Fixed PTO agitator — `<fixedAgitator>`

A permanently installed lagoon mixer. The player drives a tractor up to it, connects a PTO
shaft, and it mixes the store it sits in — no tanker required. Optional; omit the block
entirely and nothing is registered.

```xml
<slurryPipeSystem>
    <fixedAgitator turnOffIfNotAllowed="true" maxConnectDistance="0.2" crustMix="1.0">
        <input inputNode="agitatorInput" detachNode="agitatorDetach"
               filename="shaft/ptoShaft.i3d" zOffset="0"
               distanceNode="ptoDistanceNode"/>
        <level node="agitatorLevelNode"/>
        <animationNodes>
            <animationNode node="paddle01" rotSpeed="180" rotAxis="2"
                           turnOnFadeTime="1" turnOffFadeTime="1"/>
        </animationNodes>
        <sounds>
            <turnedOn linkNode="agitatorSoundNode" template="pto01" volumeScale="1"/>
        </sounds>
    </fixedAgitator>
</slurryPipeSystem>
```

| Attribute                        | Default            | Meaning |
|----------------------------------|--------------------|---------|
| `turnOffIfNotAllowed`            | `true`             | Shut down automatically when the connection is no longer valid. |
| `maxConnectDistance`             | 0.2                | Metres within which the tractor's PTO must sit to connect. |
| `crustMix`                       | 1.0                | Mixing-speed multiplier, clamped 0.1–10. Same meaning as the vehicle agitator's — `2.0` clears a full crust in half the baseline 2 game hours. Lets a permanent lagoon mixer be rated separately from a PTO unit. |
| `storeId`                        | primary store      | Which `<slurryStore>` (§3A) this unit stirs, matching that store's `#id`. Omit on a single-store placeable. A referenced id that does not exist is warned about once in the log. |
| `input#inputNode`                | —                  | Node the PTO shaft attaches to. |
| `input#detachNode`               | —                  | Node used for the detach position. |
| `input#filename`                 | —                  | Shaft i3d, relative to your config folder. |
| `input#zOffset`                  | 0                  | Z offset applied to the spawned shaft. |
| `input#distanceNode`             | `ptoDistanceNode`  | Node the connect distance is measured from. |
| `level#node`                     | `agitatorLevelNode`| The slurry surface must be at or above this node's world Y for mixing to occur. Blades still spin below it — only the crust re-suspension is gated. |
| `animationNode#node`             | —                  | A rotating blade/paddle node. |
| `animationNode#rotSpeed`         | 0                  | Degrees per second. |
| `animationNode#rotAxis`          | 2                  | `1` = X, `2` = Y, `3` = Z. |
| `animationNode#turnOnFadeTime`   | 1                  | Seconds to spin up. |
| `animationNode#turnOffFadeTime`  | 1                  | Seconds to spin down. |
| `sounds.turnedOn#linkNode`       | —                  | Node the running sound is attached to. |
| `sounds.turnedOn#template`       | —                  | Base-game sound template name. |
| `sounds.turnedOn#volumeScale`    | 1                  | Volume multiplier. |

On a multi-store placeable (§3A) declare `storeId` so the unit stirs the right lagoon —
without it a fixed agitator always mixes the primary store no matter which lagoon its shaft
stands in. Several agitators working the same store stack additively.

---

## 7. Animations — connector / valve ids

`connectorAnimation` / `valveAnimation` are **integer ids**. Each animation's parts name
nodes that SPS searches for **under your coupling's mount node** and animates
(rotation/translation over a time span). connector plays forward on connect / reverse on
disconnect; valve plays on open / close.

Ids resolve from two places, config-local first:

**A) Your own definitions (recommended for custom parts).** Add a `<couplerAnimations>`
block inside your embedded `<slurryPipeSystem>` / `<sprayerPipeSystem>`:

```xml
<couplerAnimations>
    <couplerAnimation id="1" name="myClamp">
        <part node="clampHandle01" startTime="0" endTime="1"
              startRot="0 0 0" endRot="0 0 -120"/>
        <part node="clampHandle02" startTime="0" endTime="1"
              startRot="0 0 0" endRot="0 0 120"
              startTrans="0 0 0" endTrans="0 0.02 0"/>
    </couplerAnimation>
</couplerAnimations>
```

| Attribute | Default | Meaning |
|---|---|---|
| `couplerAnimation#id`   | —   | Integer id referenced by `connectorAnimation` / `valveAnimation`. Required. |
| `couplerAnimation#name` | `anim_<id>` | Label used in the log. |
| `part#node`             | —   | Part node name, searched under the coupling's mount node. Required. |
| `part#startTime` / `#endTime` | 0 / 1 | Normalised time span this part animates over. |
| `part#startRot` / `#endRot`   | —   | `"x y z"` rotation in **degrees**. |
| `part#startTrans` / `#endTrans` | — | `"x y z"` translation. |

Local ids are checked **before** the shared library, so a local id overrides a shipped one
of the same number for that config only.

**B) The SPS shared library** (`configs/couplerAnimations.xml`). To use a shipped id, name
your clamp/valve sub-objects to match the part names that id expects (open the file
read-only to see them).

---

## 8. Optional pipe animation node — `<pipeAnimNode>`

```xml
<pipeAnimNode node="0>7|0" rx="0" ry="0" rz="0"/>
```

A node (your own i3d) rotated by the given degrees while the store is in use. All default 0.

---

## 9. Liquid-fertiliser / herbicide source tank — `<sprayerPipeSystem>`

For a placeable that feeds **sprayers**. Simpler — no fill plane, source comes from storage.

```xml
<placeable ...>
    ...
    <sprayerPipeSystem>
        <sprayerPipeCouplings>
            <sprayerPipeCoupling id="1" mountNodeName="tankOutlet01"
                                 flowDirection="BOTH" maxPipeLength="7.5"/>
        </sprayerPipeCouplings>
        <nodeTree filename="nodeTree.i3d"/>   <!-- optional -->
    </sprayerPipeSystem>
</placeable>
```

| Element / attribute                     | Default | Meaning |
|-----------------------------------------|---------|---------|
| `sprayerPipeCoupling#id`                 | index+1 | Identifier. |
| `sprayerPipeCoupling#mountNodeName`      | —       | Coupler mount node. **Required.** |
| `sprayerPipeCoupling#flowDirection`      | `BOTH`  | `BOTH` / `FILL` / `DISCHARGE`. |
| `sprayerPipeCoupling#maxPipeLength`      | 7.5     | Max pipe span (m). |
| `sprayerPipeCoupling#connectorAnimation` | —       | Optional coupler animation id. |
| `sprayerPipeCoupling#valveAnimation`     | —       | Optional valve animation id. |
| `sprayerPipeCoupling#fillType`           | —       | Optional fixed-type restriction: only this fill type passes through this coupler, in either direction. |
| `sprayerPipeCoupling#capacity`           | —       | Optional per-coupler capacity in litres, added to the store for this coupler's type (each coupler = one physical tank; same-type couplers sum). Requires `#fillType` or a dynamic declaration below. |
| `sprayerPipeCoupling#fillTypes`          | —       | Dynamic compartment: a space-separated fill type name list, or `ANY` — see below. Requires `#capacity`. |
| `sprayerPipeCoupling#fillTypeCategories` | —       | Dynamic compartment by category names (or `ANY`). Requires `#capacity`. |

### Fill types and capacities are yours to declare

The SPS block fully controls what the store holds — you do not need the map or base
placeable XML to declare the liquids. A coupler with `#fillType` + `#capacity` adds that
type and capacity to the storage on registration.

### Dynamic lock-until-empty compartments

A coupler declared with `#fillTypes` / `#fillTypeCategories` (instead of a fixed
`#fillType`) is one physical tank compartment:

- It starts **unlocked** and accepts any liquid from its allowed list.
- The first fill type that flows through it **locks** the compartment to that type — its
  capacity counts toward that type, and only that type passes until it drains.
- When its level reaches **zero** it unlocks again and the type disappears from the tank.
- `fillTypes="ANY"` (or `fillTypeCategories="ANY"`) accepts whatever liquid the **connected
  sprayer** actually holds — including script-mod liquids (e.g. Soil & Fertilizer types)
  that never appear in the base sprayer category. ANY compartments still lock-until-empty
  the same way. `#capacity` is mandatory; ANY without it disables the compartment with a
  log line.
- Compartment state saves, syncs in multiplayer, and survives join-in-progress.

Remaining rules:
- **Mount node structure** is identical to §4: first child = arc apex (2 arc children), plus
  `inNode` + `outNode` direct children. Arcs are **mandatory** for sprayer couplers (no
  proximity fallback).
- **Storage requirement:** the placeable must expose storage via `spec_silo` (incl.
  `spec_silo.storages[1]`) or `spec_husbandry`. SPS reads the fill level from there.
- **No placeable-side prompt** — all sprayer connect/disconnect is driven from the sprayer
  vehicle's pump control node. The source tank just defines the coupling.
- If you author the coupler nodes directly in the placeable i3d (no nodeTree), embedded
  sprayer placeables find them by name in the placeable's component tree.
- **Info box per-tank rows:** stores with per-coupler capacities (`#fillType`+`#capacity`
  or the dynamic `#fillTypes`/`#fillTypeCategories` declarations) show one row per physical
  tank in the walk-up info display — `T-1`, `T-2`, … — with each tank's held liquid and
  litres. Empty tanks read "Empty". Nothing to configure; the rows come from the coupler
  declarations.

---

## 9B. Buying stations — `<buyingStation>` (paid, infinite pipe sources)

A placeable that already carries the vanilla **buying station** spec
(`PlaceableBuyingStation`) can act as a paid, infinite SPS pipe source. Two variants exist
and they are **mutually exclusive on one placeable** (declaring both logs a warning and the
sprayer block is ignored):

- **Slurry:** `<slurryPipeSystem><buyingStation .../></slurryPipeSystem>` — feeds the
  slurry pipe/coupler system, one switchable sold type on the coupler.
- **Sprayer:** `<sprayerPipeSystem><buyingStation .../></sprayerPipeSystem>` — feeds
  sprayers through the sprayer pipe system. The sold set is **explicit-only** — nothing is
  auto-added from the station, and **WATER is always refused** from the sprayer cycle.

Both variants use the same attributes:

| Attribute / child                            | Default | Meaning |
|----------------------------------------------|---------|---------|
| `fillTypes`                                  | —       | Space-separated **ordered** switch cycle of vanilla-declared sold types (vanilla pricing), e.g. `"LIQUIDMANURE DIGESTATE"`. |
| `fillType` (legacy)                          | slurry: `LIQUIDMANURE` | Single sold type = one-entry cycle (the switch prompt never shows). |
| `default`                                    | first in cycle | Starting selection. |
| `<extraFillType name="…" priceScale="…"/>`   | scale 1.0 | An SPS-extra sold type the vanilla station does **not** declare (e.g. WATER on a slurry well — slurry side only). SPS performs the purchase itself with the same price maths; `priceScale="0"` = free. Appended to the switch cycle after `fillTypes`. |
| `<extraFillTypeCategory name="…" priceScale="…"/>` | scale 1.0 | **Sprayer side only:** appends a whole fillType *category* to the cycle — the script-mod hook (e.g. Soil & Fertilizer liquids). Unknown categories/types resolve to nothing and are skipped with a log line, so one config loads clean with or without the liquid mod installed. Types the vanilla station already declares keep vanilla pricing; an explicit `<extraFillType>` scale wins over its category's scale. |

### Player interaction

- The walk-up switch cycles the sold liquid; **Shift + activate cycles in reverse** (both
  variants). The selection is server-authoritative and synced.
- **Sprayer stations:** a part-full sprayer **auto-switches** the station to its held
  liquid on connect, and the switch prompt is **locked while a sprayer is connected**
  (server-validated).
- No Storage object exists on a buying station — every draw is a purchase at the moment it
  flows.

---

## 10. Slurry separator — `<separator>` (screw-press placeables)

A placeable of type `manureHeapSeparator` (a placeable type parenting the vanilla
`manureHeap` — declare it in your own modDesc `<placeableTypes>`) becomes an SPS screw-press
separator: it pulls slurry in through one coupler, drops the pressed solids onto its own
manure heap, and returns the thinner liquid fraction out through the other coupler.

```xml
<placeable ...>   <!-- type="manureHeapSeparator" -->
    ...
    <slurryPipeSystem>
        <separator ratedLitersPerHour="125000"
                   costPerHour="0"
                   solidsDryMatter="0.28"
                   captureEffMin="0.15"
                   captureEffMax="0.40"
                   tightMinThroughputMult="0.5"/>
        <pipeCouplings>
            <pipeCoupling id="1" mountNodeName="sepInlet"  valveType="NONE" flowDirection="IN"/>
            <pipeCoupling id="2" mountNodeName="sepOutlet" valveType="NONE" flowDirection="OUT"/>
        </pipeCouplings>
        <nodeTree filename="nodeTree.i3d"/>
    </slurryPipeSystem>
</placeable>
```

| Attribute                  | Default | Meaning |
|----------------------------|---------|---------|
| `ratedLitersPerHour`       | 30000   | Intake rate at fully loose screw (l/h). |
| `costPerHour`              | 0       | Money charged per hour of active separating. |
| `solidsDryMatter`          | 0.28    | Dry-matter fraction of the pressed solids. |
| `captureEffMin` / `Max`    | 0.15 / 0.40 | Fraction of incoming DM captured at 0% / 100% screw tightness. |
| `tightMinThroughputMult`   | 0.5     | Throughput multiplier at full tightness (1.0 when loose). |
| `inCouplingId` / `outCouplingId` | — | Explicitly pick the suction/return couplers by id; when absent the couplings' own `flowDirection="IN"` / `"OUT"` resolve them. |
| `panelNodeName`            | `SPS_separatorPanel` | Walk-up control node (falls back to the IN coupling's mount). |
| `interactRadius`           | 4.0     | Control activation radius (m). |
| `dropNodeName`             | `SPS_dropNode` | Node the solids drop-effect plays from. |
| `minSourceDM`              | 0.005   | Below this source dry-matter fraction the separator halts (auto-resumes). |
| `maxDropBacklog`           | 500     | Litres of undropped solids before the bunker counts as full (auto-resumes when cleared). |

Every value has a working default, so a bare `manureHeapSeparator` placeable with two IN/OUT
couplings works with no `<separator>` block at all. Further optional attributes tune the
drop visual (particle node/type, chunk texture and density, shader scales) — the shipped
Börger config is the reference for those.

Walk-up controls at the panel node: start/stop, and cycle screw tightness 0–100% in five
steps (tighter = more DM captured per pass, slower throughput). State is server-
authoritative, MP-synced, saved, and join-in-progress safe. The placeable's manure heap
fills with the pressed solids like any vanilla heap.

---

## 11. Minimal worked example — slurry pit + coupling

```xml
<placeable ...>
    ...
    <slurryPipeSystem agitator="true">
        <nodeTree filename="nodeTree.i3d"/>
        <fillPlane node="0>5|2" minY="0.0" maxY="1.6" fillType="LIQUIDMANURE"
                   shape="rectangle"
                   centreNodeName="pitCentre"
                   corner1NodeName="pitCorner1"
                   corner2NodeName="pitCorner2"/>
        <pipeCouplings>
            <pipeCoupling id="1" mountNodeName="pitInlet01"
                          valveType="MANUAL" flowDirection="BOTH" connector="female"/>
        </pipeCouplings>
        <hideNodes>
            <node name="vanillaFillPlane"/>
        </hideNodes>
    </slurryPipeSystem>
</placeable>
```

Node requirements: `0>5|2` is the fill-plane mesh in your i3d; `pitCentre/pitCorner1/
pitCorner2` and `pitInlet01` live in the nodeTree, with `pitInlet01` built per §4 (arc apex
first child + arc points, plus `inNode`/`outNode`).

---

## 12. Checklist

1. Add the block to **your own** placeable XML — never edit the SPS mod.
2. Slurry store: ensure it is real storage (`spec_silo` / `spec_husbandry` /
   `spec_siloExtension`).
3. `<fillPlane>` with `node`, `minY`, `maxY`, `fillType`, and a `shape` for arm detection.
   For more than one lagoon, or for any production point, use `<slurryStores>` (§3A)
   **instead** — never both.
4. `<pipeCouplings>` — each mount node needs the arc-apex first child (2 arc points) and
   `inNode` + `outNode` direct children.
5. Hide replaced vanilla parts with `<hideNodes>` / `<hideCollisions>`.
6. Liquid-fert tank: `<sprayerPipeSystem>` with a coupling (same mount structure) + real
   storage; declare types/capacities on the couplers, or use dynamic `fillTypes="ANY"`
   compartments.
7. Optional: link a coupler to your own animated lid with `deployAnimatedObjectSaveId`
   (one shared AnimatedObject per lid), and opt into gravity equalisation with
   `headHeightNodeName`.
8. Optional: a permanently installed lagoon mixer via `<fixedAgitator>` (§6A).
9. Load and confirm `registerPlaceable - registered …`; missing nodes are named in the log.
