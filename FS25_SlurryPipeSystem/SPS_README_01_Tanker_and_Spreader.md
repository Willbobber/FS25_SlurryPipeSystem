# Slurry Pipe System (SPS) — Adding a Slurry Tanker or Spreader (Dribble Bar)

This guide is for vehicle modders who want their own tanker, nurse tank, pump station
or dribble bar to work with FS25_SlurryPipeSystem.

**You never edit the SPS mod.** Everything is done inside *your own* vehicle's XML and i3d.
Editing files inside the SPS mod folder will break multiplayer and is not supported — do
not do it. SPS reads your vehicle and configures itself automatically.

All element/attribute names below are exactly what the SPS parser reads. If you misspell
one it is silently ignored and the matching part of your vehicle simply will not register.

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
`workAreaNode`.

Each outlet gets a walk-up, hold-to-clear blockage activatable that only appears while that
node is blocked and only clears once the bar is stopped.

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
    <agitator tipNode="agitatorTip"/>
</slurryPipeSystem>
```

- `agitator#tipNode` — optional node used as the agitator tip. Works on any vehicle type.
- `agitatorOnly="true"` (root attribute) — marks the vehicle as agitator-only.

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
