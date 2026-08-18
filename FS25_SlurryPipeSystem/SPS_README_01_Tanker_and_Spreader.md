# Slurry Pipe System (SPS) — Adding a Slurry Tanker or Spreader (Dribble Bar)

This guide is for vehicle modders who want their own tanker, nurse tank, pump station
or dribble bar to work with FS25_SlurryPipeSystem.

> 🎥 **Video walkthrough — setting up a vacuum tanker:**
> https://www.youtube.com/watch?v=1JKplzkCDS4

**You never edit the SPS mod.** Everything is done inside *your own* vehicle's XML and i3d.
Editing files inside the SPS mod folder will break multiplayer and is not supported — do
not do it. SPS reads your vehicle and configures itself automatically.

All element/attribute names below are exactly what the SPS parser reads. Since 1.0.1.4 a
`pipeCoupling`, `blockageNode` or `outsideControl` whose mount node cannot be found prints
an `[SPS] WARNING` naming the entry in the log — check there first when something does not
appear. Node names are also matched whitespace-tolerantly: an invisible trailing space in
an i3d node name (GIANTS Editor saves these happily) is rescued with a warning telling you
which node to fix. Misspelt element or attribute names are still silently ignored.

---

## 1. How to register your vehicle — embedded block

Put a `<slurryPipeSystem>` block directly inside your vehicle's own XML, as a child of
the root `<vehicle>` element:

```xml
<vehicle ...>
    ...
    <slurryPipeSystem>
        ... SPS config ...
    </slurryPipeSystem>
</vehicle>
```

When SPS sees `vehicle.slurryPipeSystem` in your XML it treats the vehicle as
self-contained and uses it directly. Nothing is copied, nothing in the SPS folder changes,
and your vehicle stays a normal standalone mod. This is the only method you need.

**Custom vehicle types work too (1.0.1.4+).** Your vehicle does not have to be typed
`manureBarrel` directly — a custom type declared in your own modDesc is fully supported as
long as it descends from one of the vanilla tanker types (`manureBarrel`, `manureTrailer`,
`selfPropelledManureBarrel`), at any parent depth:

```xml
<vehicleTypes>
    <type name="myTanker" parent="manureBarrel" className="Vehicle"
          filename="$dataS/scripts/vehicles/Vehicle.lua">
        <specialization name="waterTrailer"/>
    </type>
</vehicleTypes>
```

**Optional root attribute — `vehicleRole`:** `<slurryPipeSystem vehicleRole="slurry">`
forces SPS to treat the vehicle as a slurry machine, `vehicleRole="fertiliser"` forces the
fertiliser-sprayer exemption (no pressure model / slurry HUD). Only needed for edge cases
where vanilla's sprayer classification gets the machine wrong — e.g. a self-propelled unit
whose Sprayer spec points at a diesel tank. Omit it everywhere else; SPS decides from its
own registration.

---

## 2. Where the SPS nodes come from

Every `...NodeName` attribute below is resolved by name. SPS looks in two places, in order:

1. Nodes injected from an SPS **nodeTree** i3d (see below).
2. Failing that, a recursive search of your vehicle's own node tree (`rootNode`).

So you have a choice:

- **Author the nodes directly in your own i3d** (arm tip, coupler mount, blockage nodes,
  control nodes, etc.) and just reference them by name. No nodeTree needed. Simplest for a
  vehicle you build yourself.
- **Use a nodeTree i3d** to inject SPS nodes when you would rather keep them in a separate
  i3d file you ship alongside your vehicle.

### nodeTree (optional)

```xml
<nodeTree filename="path/to/nodes.i3d"/>
```

Path is relative to your vehicle's config folder. The injection rule the parser uses: the
nodeTree's first child is the SPS root; under it are *group* transforms; under each group
are *container* transforms. **Each container's name must match a node name that already
exists in your live vehicle.** Every child of that container is unlinked from the nodeTree
and re-linked under the matching live node. If a container's name has no match in the
vehicle, its children are skipped.

---

## 3. The drive model — `<pump>` (set this first)

```xml
<pump pumpType="vacuum" selfPowered="false" conduit="false"/>
```

`pumpType` is the single most important attribute. Four valid values:

| pumpType  | Behaviour |
|-----------|-----------|
| `vacuum`  | Stored-pressure model. Builds/holds/tapers a signed ±bar charge, shows the ±bar gauge. This is the full pressure tanker. |
| `HVP`     | High-volume pump. Pump-gated — PTO on = flow, PTO off = stop. Spread rate falls with slurry thickness. Shows an l/s gauge. |
| `conduit` | Pump station. Pump-gated, drives the conduit transfer HUD. |
| `openTop` | Passive vessel (e.g. a nurse tank / FRC). Never builds or holds pressure, no gauge. |

If you omit `pumpType` the vehicle defaults to `vacuum` **and logs a warning** naming your
config — so always set it explicitly. An unknown value also falls back to `vacuum` with a
warning.

Legacy fallbacks still work: `conduit="true"` maps to `pumpType="conduit"`, and
`<pressure openTop="true"/>` maps to `pumpType="openTop"`. Prefer the explicit `pumpType`.

- `selfPowered="true"` — vehicle has its own engine (loads the `<sounds><engineLoop>` sample).
- `conduit="true"` — legacy form of `pumpType="conduit"`.

Only `pumpType="vacuum"` vehicles use the pressure model. A fertiliser/herbicide sprayer is
also automatically excluded from the pressure model even if tagged vacuum.

---

## 4. Flow rate — `<flow>`

```xml
<flow fillLitersPerSecond="1500" emptyLitersPerSecond="2200"/>
```

Resolution order the parser uses for each rate:

1. `fillLitersPerSecond` / `emptyLitersPerSecond` (separate suck-in and push-out rates).
2. `litersPerSecond` (single value used for both, if the split ones are absent).
3. Vanilla in the *same* file — `fillTriggerVehicle#litersPerSecond` for fill,
   `dischargeable.dischargeNode(0)#emptySpeed` for empty.
4. Default: **1000 l/s**.

Single value form:

```xml
<flow litersPerSecond="1800"/>
```

---

## 5. Pressure model — `<pressure>` (vacuum tankers only)

Only read meaningfully when `pumpType="vacuum"`. All attributes are optional; defaults shown.

```xml
<pressure maxPressure="2.0"
          minThreshold="0.3"
          minBuildTime="10"
          maxBuildTime="30"
          fallTimeWorking="60"
          fallTimeEmpty="30"
          purgeTime="10"
          gravityFlowScalar="0.5"
          openTop="false"/>
```

| Attribute          | Default | Meaning |
|--------------------|---------|---------|
| `maxPressure`      | 2.0     | ±bar ceiling the tank charges to. |
| `minThreshold`     | 0.3     | Bar required before flow can start. |
| `minBuildTime`     | 10      | Seconds to reach max at a **full** tank. |
| `maxBuildTime`     | 30      | Seconds to reach max at an **empty** tank. |
| `fallTimeWorking`  | 60      | Seconds max→0 while fluid is transferring (slow). |
| `fallTimeEmpty`    | 30      | Seconds max→0 while venting with no transfer (fast). |
| `purgeTime`        | 10      | Seconds to vent max→0 on a direction flip. |
| `gravityFlowScalar`| 0.5     | Backflow/gravity rate as a fraction of base flow when pressure is spent. |
| `openTop`          | false   | Legacy. `true` = passive vessel; prefer `pumpType="openTop"`. |

---

## 6. Fill arms — `<fillArms>`

The boom/arm that loads from an open pit or another tanker's receiver.

```xml
<fillArms>
    <fillArm id="1"
             tipType="OPEN_PIT"
             fillUnitIndex="1"
             centreNodeName="armCentreNode"/>
</fillArms>
```

| Attribute             | Default     | Meaning |
|-----------------------|-------------|---------|
| `id`                  | index+1     | Identifier. |
| `tipType`             | `OPEN_PIT`  | `OPEN_PIT`, `RUBBER_BOOT`, or `RUBBER_BOOT_PIT`. |
| `fillUnitIndex`       | 1           | Which fill unit the arm loads. |
| `centreNodeName`      | —           | Required for `OPEN_PIT` (and used by `RUBBER_BOOT_PIT`). The submersion detection node. |
| `tipNodeName`         | —           | Required for `RUBBER_BOOT` (and used by `RUBBER_BOOT_PIT`). |
| `cylinderedConfigIndex` | —         | Optional config gate, see §13. |
| `configType`          | `cylindered`| Config type for the gate. |

tipType notes:
- `OPEN_PIT` — needs `centreNodeName`; if missing the arm is skipped with a log line.
- `RUBBER_BOOT` — needs `tipNodeName`; skipped if missing.
- `RUBBER_BOOT_PIT` — uses both; loads if at least one node resolves.

---

## 7. Pipe couplings — `<pipeCouplings>`

The strap-pipe coupling point on the tanker (walk-up connect).

```xml
<pipeCouplings>
    <pipeCoupling id="1"
                  mountNodeName="couplerMount01"
                  valveType="MANUAL"
                  flowDirection="BOTH"
                  maxPipeLength="6.0"
                  fillUnitIndex="1"
                  connector="male"/>
</pipeCouplings>
```

| Attribute              | Default  | Meaning |
|------------------------|----------|---------|
| `id`                   | index+1  | Identifier. |
| `mountNodeName`        | —        | The coupler mount node. Required — coupling skipped if not found. |
| `valveType`            | `MANUAL` | `MANUAL`, `HYDRAULIC`, or `NONE`. |
| `flowDirection`        | `BOTH`   | `BOTH`, `FILL`, or `DISCHARGE`. |
| `maxPipeLength`        | 6.0      | Max metres a connection may span from this coupler. |
| `fillUnitIndex`        | 1        | Fill unit fed/drained by this coupler. |
| `valveFromRearControl` | false    | If true the valve is driven from the rear/outside control node. |
| `connector`            | `male`   | `male` / `female` — matched against the partner end. |
| `connectorAnimation`   | —        | Coupler animation id. |
| `valveAnimation`       | —        | Valve animation id. |
| `headHeightNodeName`   | —        | Opt-in gravity head gate — see below. |
| `cylinderedConfigIndex`| —        | Optional config gate, see §13. |
| `configType`           | `cylindered` | Config type for the gate. |

The coupler mount node must contain two child nodes named exactly `inNode` and `outNode`;
SPS finds them automatically as the in/out flow points.

A coupling automatically gets a walk-up **connect** activatable and a **lay chain**
activatable.

Pipe visuals from a coupling rest on hard surfaces automatically — laid chains and
connection pipes settle onto concrete pads, floors, bridge decks and roads as well as the
terrain. No configuration is needed.

### Gravity head equalisation — `headHeightNodeName` (optional)

By default a coupling takes no part in gravity equalisation and behaves exactly as before.
Declaring `headHeightNodeName` opts the coupling in: name a node placed at the **highest
point of the pipe run** from that coupling (e.g. the top of the tank neck or the crest the
hose climbs over). While connected, levels then equalise by gravity between the two vessels —
but only while the driving surface is **above** every declared head node and the receiving
surface, so slurry cannot magically climb over a crest it could not really clear. Both
vehicle and store couplings support the attribute; a pair where neither end declares it is
ignored by equalisation entirely.

`connectorAnimation` / `valveAnimation` ids come from the SPS shared animation library — or
from a `<couplerAnimations>` block you define inside your own `<slurryPipeSystem>` (same
format as the shared file; local ids win). See the placeable guide §7 for the block format.

---

## 8. Spreader / dribble bar — `<blockageNodes>`

A dribble bar or band spreader is registered through its blockage (outlet) nodes. A vehicle
that has **only** blockage nodes (no arms, no couplings) is treated as a *spreader implement*
— it carries no pressure system of its own and is driven by the tanker it is attached to.

```xml
<blockageNodes>
    <blockageNode mountNodeName="outlet01" workAreaNode="band01"/>
    <blockageNode mountNodeName="outlet02" workAreaNode="band02"/>
    <blockageNode mountNodeName="distributorMacerator"/>
</blockageNodes>
```

| Attribute            | Default    | Meaning |
|----------------------|------------|---------|
| `mountNodeName`      | —          | The outlet node. Required — skipped if not found. |
| `blockageAnimation`  | —          | Optional animation played on block/clear. |
| `workAreaNode`       | —          | Optional band-parent node for that outlet's work-area section. |
| `workAreaConfigIndex`| —          | Optional config gate (§13), `configType` defaults to `workArea`. |
| `configType`         | `workArea` | Config type for the gate. |

A node whose name contains `Macerator` is treated as the central distributor: blocking it
stops the whole bar. The macerator has no work-area section, so do not give it a
`workAreaNode`. You may declare several macerator nodes (for separate animation points on a
wide bar) — they are treated as one logical macerator and block together.

Each outlet gets a walk-up, hold-to-clear blockage activatable that only appears while that
node is blocked and only clears once the bar is stopped.

### How a blockage is decided

Blockages are caused by **lumps**, i.e. the crust the tanker is carrying, inherited from the
store's crust level at fill time. Dry matter is only a mild amplifier — its real job is
slowing the pump, not clogging the bar. Mixing the store before you fill is what keeps the
bar clear.

The macerator is a lump smasher with a finite capacity, so the two rows have separate crust
thresholds:

- **Macerator** — exposed from `maceratorCrustMin` upward. It is the part taking the
  punishment while it is coping.
- **Outlets** — protected until `outletCrustMin`, the point at which lumps start getting
  past the macerator. A bar with **no macerator node** has no such protection and uses the
  lower `outletCrustMinRaw` instead.

A roll is taken every 6 seconds while the bar is actually spreading (discharge active, the
spreader valve open, and not AI-driven). The macerator and the outlets roll independently.
The outlet roll is taken **once for the bar**, and a random still-open outlet takes it — not
once per outlet, so a wide bar is not inherently more fragile than a narrow one.

### Tuning per vehicle — `<blockageNodes>` attributes

Every attribute below is optional and sits on the **container**, not on individual nodes.
Omit any and it inherits the global default, so an existing config needs no changes.

```xml
<blockageNodes baseChance="0.001" maceratorCrustMin="0.25" maceratorChance="0.027"
               outletCrustMin="0.60" outletCrustMinRaw="0.25"
               outletChance="0.030" dmBonus="0.25">
    ...
</blockageNodes>
```

| Attribute           | Default | Meaning |
|---------------------|---------|---------|
| `baseChance`        | 0.001   | Per-roll, per-**bar** chance of a foreign-object clog (wood, stone) even on perfectly clean slurry. Applies to both rows. |
| `maceratorCrustMin` | 0.25    | Carried crust below which the macerator copes and nothing lump-driven happens. |
| `maceratorChance`   | 0.027   | Per-roll chance added on top of `baseChance` at full crust, scaled by how far crust has climbed past `maceratorCrustMin`. |
| `outletCrustMin`    | 0.60    | The macerator's capacity ceiling. Below this the outlets stay clear. Used only when a macerator node exists. |
| `outletCrustMinRaw` | 0.25    | Outlet threshold when **no** macerator is fitted. |
| `outletChance`      | 0.030   | Per-roll chance added on top of `baseChance` at full crust, scaled past whichever outlet threshold applies. |
| `dmBonus`           | 0.25    | Extra multiplier at the dry-matter jam point, applied to both rows. `0` = dry matter has no effect on blockages. |

Chances are clamped 0–1 on read (`dmBonus` 0–10), so a typo cannot produce a bar that clogs
every roll.

Sized against a five-minute tankful (about 50 rolls), the defaults give roughly a 5% chance
of any stoppage on freshly agitated slurry and around 70% on a store left unmixed for a
month. A wide-bore splash plate with no macerator should be authored well above the
unprotected default — the shipped Farmtech Supercis 800 and Joskin Cobra configs use
`outletCrustMinRaw="0.85"`, `outletChance="0.010"`, `baseChance="0.0005"` as a reference.

### Optional spreader animation

For a spreading component driven by SPS discharge state (not by vanilla turnOn):

```xml
<spreaderAnimation name="spreadFans" stopDelay="2.0"/>
```

`stopDelay` is in seconds (converted to ms internally; default 2.0).

---

## 9. Rubber boot ports — `<rubberBootPorts>`

A two-node port (upper/lower) used for boot-tip submersion fills.

```xml
<rubberBootPorts>
    <rubberBootPort id="1"
                    lowerNodeName="bootLower01"
                    upperNodeName="bootUpper01"
                    valveType="NONE"
                    fillUnitIndex="1"/>
</rubberBootPorts>
```

Both `lowerNodeName` and `upperNodeName` must resolve or the port is skipped. `valveType`
defaults to `NONE`.

---

## 10. Outside controls — `<outsideControls>`

A single walk-up node that exposes PTO and/or direction controls outside the cab.

```xml
<outsideControls>
    <outsideControl id="1"
                    mountNodeName="rearControlNode"
                    radius="1.5"
                    pto="true"
                    direction="true"/>
</outsideControls>
```

| Attribute       | Default | Meaning |
|-----------------|---------|---------|
| `mountNodeName` | —       | Control node. Required — skipped if not found. |
| `radius`        | 1.5     | Activation radius in metres. |
| `pto`           | false   | Expose the PTO (pump on/off) prompt here. PTO prompt is gated by tractor capability. |
| `direction`     | false   | Relocate the cab fill/empty (direction) control to this node. |

## 11. Pump controls — `<pumpControls>` (TSA-style all-in-one rear node)

```xml
<pumpControls>
    <pumpControl id="1" nodeName="pumpControlNode" radius="1.5"/>
</pumpControls>
```

`nodeName` required; `radius` defaults to 1.5.

---

## 12. Agitator, sounds, shear bolt

### Agitator

```xml
<slurryPipeSystem agitatorOnly="false">
    ...
    <agitator tipNode="agitatorTip" crustMix="1.0"/>
</slurryPipeSystem>
```

- `agitator#tipNode` — optional node used as the agitator tip. Works on any vehicle type.
- `agitator#crustMix` — optional mixing-speed multiplier, default `1.0`, clamped 0.1–10.
  `1.0` clears a full crust in the baseline 2 game hours of continuous stirring; `2.0`
  does it in one. Lets a big PTO mixer be rated above a small one.
- `agitatorOnly="true"` (root attribute) — marks the vehicle as agitator-only.

Mixing runs on absolute game time via the shared monotonic clock, so it means the same
thing on every save regardless of season length, and it is timescale-correct through
sleeping and fast-forward. Multiple agitators working the same store stack additively.

### Sounds (client side)

```xml
<sounds fullThreshold="0.99">
    <engineLoop ... />        <!-- only loaded if selfPowered="true" -->
    <vacPumpFilling ... />    <!-- vacuum pumpType only -->
    <vacPumpFull ... />       <!-- vacuum pumpType only -->
</sounds>
```

`engineLoop` is a standard `loadSampleFromXML` sound, loaded only for `selfPowered` vehicles.
`vacPumpFilling` / `vacPumpFull` are vacuum-only and reference base-game sound templates by
name (no file is copied). `fullThreshold` (default 0.99) is the fill fraction at which the
sound switches to the "full" sample.

### Shear bolt

```xml
<shearBolt bolt="true"/>
```

Per-vehicle opt-in. Only vehicles with `bolt="true"` get a PTO shear bolt (wear, snap,
freeze and the walk-up repair activatable). Default is false — no bolt, no wear, no
activatable. The repair activatable hosts on your outside-control node, falling back to a
pump-control node.

---

## 12A. Front mounts & receiver tankers — `<frontMount>` / `<tractorMountFillArms>`

A **front mount** is a capacity-0 pass-through pump unit carried on the tractor's front
linkage (e.g. the Claas Saddle Trac pack front fill-arm unit): it has a fill arm and pipe
couplings but no storage of its own. A **receiver** is a rear tanker that opts in to being
hose-fed by a front mount. SPS links the two through a Giants connection hose and pumps
through the front unit into/out of the receiver.

### How the pairing works

SPS injects a plain-type connection hose (default `TOOL_CONNECTOR_TOP_RIGHT`) into each
vehicle's own hose system at registration time, replicated field-for-field from vanilla, so
the vehicles connect exactly like factory hoses on **any tractor**. On the Xerion, which
carries its own specType'd hose circuit for these vehicles, the injected plain hose is
suppressed automatically — no duplicate hoses. The receiver is resolved from vanilla
connection-hose state, identically on every peer, so multiplayer needs no extra sync.

Standard receiver mount node name across all tankers: **`slurryPipe`**.

### Runtime behaviour — the pass-through cascade

Every tick the front mount resolves its tank-side outlets in strict priority:

1. its own **connected pipe couplings** with the manual valve open (far side may be a
   vehicle, a laid/bez pipe run, or a placeable store), then
2. the **hose-bridged receiver** tanker.

Filling sends liquid to the first target with free capacity; unloading draws from the first
with content. So a coupler-connected tanker fills first, overflow goes to the rear
receiver, and the flow switches back automatically as levels change — with the full mirror
when unloading. Water sources are valid infinite fill sources and refused as unload
destinations. Thickness/crust blends apply to receiver transfers as on any tanker.
Front-mount units never show the spreader valve keybind.

### Front mount config (on the front unit)

```xml
<frontMount enabled="true" hoseTypes="slurryConnector">
    <hose node="frontHoseNode" type="TOOL_CONNECTOR_TOP_RIGHT" length="2" diameter="0.18"/>
</frontMount>
```

| Attribute (`<frontMount>`) | Default | Meaning |
|----------------------------|---------|---------|
| `enabled`                  | false   | Turns the front-mount system on for this vehicle. |
| `hoseSpecTypes`            | —       | Space-separated specType'd hose type names (Xerion-style pairings kept in the vehicle's own XML). |
| `hoseTypes`                | —       | Space-separated plain hose type names for normal-tractor pairings. At least one of the two attributes is required or the front mount is disabled with a warning. |

### Receiver config (on the rear tanker)

```xml
<tractorMountFillArms accepted="true">
    <hose node="slurryPipe" cylinderedConfigIndex="0,1"/>
    <staticPipe node="samsonFillPipe_PT" cylinderedConfigIndex="0"/>
    <staticPipe node="samsonFillPipe_Sap2" cylinderedConfigIndex="1"/>
</tractorMountFillArms>
```

`accepted="true"` opts the tanker in. Multiple `<hose>` entries may be declared; the
**first** whose config gate matches (or that has no gate) is injected — one config file can
serve config-dependent mount points. `<staticPipe>` entries are static pipe meshes whose
visibility is set once at registration from their config gate (no gate = always shown).

### `<hose>` attributes (both blocks — mirror vanilla `<connectionHoses><hose>`)

| Attribute                 | Default                   | Meaning |
|---------------------------|---------------------------|---------|
| `node`                    | —                         | Hose mount node **name** (SPS nodeTree first, then the vehicle's own i3d). Required — hose skipped with a warning if not found. |
| `type`                    | `TOOL_CONNECTOR_TOP_RIGHT`| Vanilla hose type. |
| `length`                  | 2                         | Hose length in metres. |
| `diameter`                | 0.18                      | Hose diameter. |
| `isTwoPointHose`          | true                      | Vanilla two-point hose flag. |
| `inputAttacherJointIndex` | 1                         | Attacher joint the hose belongs to (`inputAttacherJointIndices` accepted for a single value). |
| `straighteningFactor`     | 1                         | Multiplies the hose type's start-straightening — higher keeps the pipe straight along the mount node's −Z for longer before it sags. |
| `cylinderedConfigIndex`   | —                         | Receiver `<hose>`/`<staticPipe>` only: comma-separated 0-based config indices this entry applies to (`configType` overrides the default `cylindered`), same convention as §13. |

### Optional `<objectChange>` child of `<hose>`

A static mesh switched with the hose's connection state (driven on connect/disconnect
transitions):

```xml
<hose node="slurryPipe">
    <objectChange node="couplerCap" visibilityActive="false" visibilityInactive="true"
                  initialState="inactive"/>
</hose>
```

| Attribute            | Default | Meaning |
|----------------------|---------|---------|
| `node`               | —       | Node name to switch. |
| `visibilityActive`   | true    | Visibility while the hose is connected. |
| `visibilityInactive` | false   | Visibility while disconnected. |
| `initialState`       | —       | `inactive` additionally applies the inactive visibility once at injection — for SPS-owned meshes that load visible in the nodeTree. Omit for meshes whose load-time state is owned by the vehicle's own vanilla objectChanges. |

---

## 13. Config gating (multi-config vehicles)

Fill arms, couplings and blockage nodes can be restricted to a specific vehicle
configuration so the right parts load for the right design/work-area selection.

- Arms / couplings use `cylinderedConfigIndex` with `configType` (default `cylindered`).
- Blockage nodes use `workAreaConfigIndex` with `configType` (default `workArea`).

The index is the **0-based active config index**, and may be a comma-separated list for a
part that should load on several configs:

```xml
<fillArm id="1" cylinderedConfigIndex="0,2" centreNodeName="arm" tipType="OPEN_PIT"/>
<blockageNode mountNodeName="outlet" workAreaConfigIndex="1"/>
```

When the vehicle's active config index does not match, that element is skipped. If SPS
cannot resolve the active config index at all, the element loads (and duplicate couplings on
the same mount node are dropped automatically).

---

## 14. Minimal worked example — a pressure vacuum tanker

```xml
<vehicle ...>
    ...
    <slurryPipeSystem>
        <pump pumpType="vacuum" selfPowered="false"/>
        <flow fillLitersPerSecond="1500" emptyLitersPerSecond="2200"/>
        <pressure maxPressure="2.0" minThreshold="0.3"
                  minBuildTime="10" maxBuildTime="30"
                  fallTimeWorking="60" fallTimeEmpty="30" purgeTime="10"/>

        <fillArms>
            <fillArm id="1" tipType="OPEN_PIT" fillUnitIndex="1" centreNodeName="armCentre"/>
        </fillArms>

        <pipeCouplings>
            <pipeCoupling id="1" mountNodeName="couplerMount01"
                          valveType="MANUAL" flowDirection="BOTH"
                          maxPipeLength="8.0" fillUnitIndex="1" connector="male"/>
        </pipeCouplings>

        <outsideControls>
            <outsideControl id="1" mountNodeName="rearControl" radius="1.5"
                            pto="true" direction="true"/>
        </outsideControls>

        <sounds fullThreshold="0.99">
            <vacPumpFilling template="..." />
            <vacPumpFull    template="..." />
        </sounds>
    </slurryPipeSystem>
</vehicle>
```

A dribble-bar implement is just the `<blockageNodes>` (plus optional `<spreaderAnimation>`)
with no arms or couplings, and typically `pumpType` omitted because its controlling tanker
drives it.

---

## 15. Checklist

1. Add the `<slurryPipeSystem>` block to **your own** vehicle XML — never edit the SPS mod.
2. Decide `pumpType` (vacuum / HVP / conduit / openTop) and set it explicitly.
3. Author (or inject via nodeTree) every node you reference, with matching names.
4. Set `<flow>` rates.
5. For a vacuum tanker, tune `<pressure>`.
6. Add `<fillArms>` and/or `<pipeCouplings>` for loading/discharge.
7. Add `<blockageNodes>` (+ optional `<spreaderAnimation>`) for a spreader/dribble bar.
8. Add `<outsideControls>` / `<pumpControls>` for walk-up operation.
9. Verify in the log: an embedded config logs registration; missing nodes log a skip line
   naming the part.
