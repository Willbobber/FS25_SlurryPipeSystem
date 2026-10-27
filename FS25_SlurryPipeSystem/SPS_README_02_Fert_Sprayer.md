# Slurry Pipe System (SPS) — Adding a Fertiliser / Herbicide Sprayer

This guide is for vehicle modders who want their own sprayer (trailed or self-propelled)
to load liquid fertiliser / herbicide through the SPS pipe-and-coupler system, the way the
Kverneland iXtrack does.

**You never edit the SPS mod.** Everything is done inside *your own* vehicle's XML and i3d.
Editing files inside the SPS mod folder will break multiplayer and is not supported. SPS
reads your vehicle and configures itself automatically.

The sprayer system is **separate** from the slurry tanker system and uses its own
`<sprayerPipeSystem>` block. Do not mix the two blocks up — a sprayer uses
`<sprayerPipeSystem>`, a slurry tanker uses `<slurryPipeSystem>`. A vehicle *may* carry both
if it genuinely does both jobs, but most sprayers only need the sprayer block.

All element/attribute names below are exactly what the SPS parser reads. Misspell one and it
is silently ignored — that part of your vehicle just will not register.

---

## 1. How sprayers differ from slurry tankers

Read this first — the sprayer model is deliberately simpler than the slurry one:

- **No pressure model.** There is no `<pressure>`, no ±bar gauge, no vacuum/HVP/conduit
  pump types. Flow is a flat litres-per-second.
- **No hydraulic/manual valve type.** Sprayer couplings have no `valveType` attribute.
- **Pump and valve are one control.** Opening the valve turns the pump on; closing it turns
  the pump off. There is no separate "pump on" step.
- **One interaction point.** All connect / disconnect / valve / direction actions happen at
  a single walk-up **pump control node**. There are no per-coupler arc activatables, and the
  placeable/source side has no activatable of its own — everything is driven from the
  sprayer vehicle's pump control node.
- **Direction can only change while the valve is closed** (Load ↔ Unload).
- **Front tanks pair automatically.** A front tank on the same tractor as a rear sprayer
  forms a "FlowControl" combo — one connection fills/drains both tanks, and an automatic
  balancer keeps the rear topped up from the front while spraying. See §12. Nothing to
  declare — it just works when both are attached.

---

## 2. How to register your sprayer — embedded block

Put a `<sprayerPipeSystem>` block directly inside your vehicle's own XML, as a child of the
root `<vehicle>` element:

```xml
<vehicle ...>
    ...
    <sprayerPipeSystem>
        ... SPS sprayer config ...
    </sprayerPipeSystem>
</vehicle>
```

When SPS sees `vehicle.sprayerPipeSystem` in your XML it treats the vehicle as
self-contained and uses it directly. Nothing is copied, nothing in the SPS folder changes.
On a successful load you will see in the log:

```
[SPS SPR] registerSprayerVehicle: registered <yourVehicle>.xml
```

---

## 3. Where the SPS nodes come from

Every `...NodeName` / `nodeName` attribute below is resolved by name. SPS looks in two
places, in order:

1. Nodes injected from an SPS **nodeTree** i3d (see below).
2. Failing that, a recursive search of your vehicle's own node tree (`rootNode`).

So you can either author the SPS nodes directly in your own i3d and just reference them by
name (simplest for your own vehicle), or ship them in a separate nodeTree i3d and inject
them.

### nodeTree (optional)

```xml
<nodeTree filename="path/to/nodes.i3d"/>
```

Path is relative to your vehicle's config folder. Injection rule: the nodeTree's first child
is the SPS root; under it are *group* transforms; under each group are *container*
transforms. **Each container's name must match a node name that already exists in your live
vehicle.** Every child of that container is unlinked from the nodeTree and re-linked under
the matching live node.

---

## 4. Flow rate — `<flow>`

```xml
<flow litersPerSecond="200"/>
```

| Attribute         | Default | Meaning |
|-------------------|---------|---------|
| `litersPerSecond` | 200     | Transfer rate in both directions. |

There is no separate fill/empty split on sprayers — one rate is used for Load and Unload.

---

## 5. Pipe couplings — `<sprayerPipeCouplings>`

> **Physical pipes (README 06):** the bought **water hose** plugs into these couplers too
> (sprayer, silo, IBC, buying station). The hose end lands on the coupling's `inNode` with
> +Z pointing into the coupler, so aim that node for a hose fitting as well as for the drawn
> hose. Everything below is unchanged for the original system.

The coupler the pipe connects to. At least one is required for anything to happen.

```xml
<sprayerPipeCouplings>
    <sprayerPipeCoupling id="1"
                         mountNodeName="couplerMount01"
                         flowDirection="BOTH"
                         maxPipeLength="7.5"
                         fillUnitIndex="1"
                         connectorAnimation="1"
                         valveAnimation="2"/>
</sprayerPipeCouplings>
```

| Attribute            | Default | Meaning |
|----------------------|---------|---------|
| `id`                 | index+1 | Identifier. |
| `mountNodeName`      | —       | The coupler mount node. **Required** — coupling skipped if not found. |
| `flowDirection`      | `BOTH`  | `BOTH`, `FILL`, or `DISCHARGE`. |
| `maxPipeLength`      | 7.5     | Max metres a pipe may span from this coupler. |
| `fillUnitIndex`      | 1       | Fill unit filled/emptied by this coupler. |
| `connectorAnimation` | —       | Optional coupler-clamp animation id (see §7). |
| `valveAnimation`     | —       | Optional valve animation id (see §7). |

**Required child nodes:** the mount node must contain two transforms named exactly `inNode`
and `outNode` somewhere in its hierarchy. SPS finds them automatically. The pipe visual is
drawn from this coupler's `outNode` to the partner coupler's `inNode`, so place/orient them
where the pipe should leave and enter.

**Pipe rest length:** the connection pipe is a fixed-length hose of `maxPipeLength` metres —
slack hangs as a downward bow that pulls out as the vehicles separate, and the pipe rests on
hard surfaces beneath it. The connection breaks past `maxPipeLength`.

**Optional `IBCspawnPoint` child:** SPS can spawn a matching IBC source tank for the sprayer
(hold **R** at the pump control while the sprayer holds a fill type and no partner coupler is
in range — the spawned IBC matches the sprayer's current liquid, including Soil & Fertilizer
types). By default the IBC is placed 4 m out facing the coupler; if the mount node contains a
child named exactly `IBCspawnPoint`, the IBC spawns at that node's position and heading
instead (height snapped to terrain). The prompt is suppressed while the sprayer is empty.

---

## 6. Pump control — `<sprayerPumpControls>`

The single walk-up node that exposes **all** sprayer prompts (connect, disconnect, valve
open/close, direction). Required for the player to operate the sprayer.

```xml
<sprayerPumpControls>
    <sprayerPumpControl id="1" nodeName="pumpControlNode" radius="1.5"/>
</sprayerPumpControls>
```

| Attribute  | Default | Meaning |
|------------|---------|---------|
| `id`       | index+1 | Identifier. |
| `nodeName` | —       | The control node. **Required** — control skipped if not found. |
| `radius`   | 1.5     | Activation radius in metres. |

Place this node where the operator would stand to work the coupler.

---

## 7. Animations — connector, valve, load

SPS plays three optional animation kinds during the connect/disconnect sequence. All are
optional; without them the system still works, just with no moving parts.

### connectorAnimation / valveAnimation (coupler part animations)

These are **integer ids** on a coupling. They are bound to named *part nodes* found **under
that coupling's mount node** and driven by the SPS coupler animator:

- On **connect**, the connector animation plays forward; the valve starts closed.
- On **valve open/close**, the valve animation plays.
- On **disconnect**, valve then connector animations play in reverse.

The part-node names each id expects are defined by the SPS coupler animator, not by your XML.
For example, in the log the iXtrack's `connectorAnimation="1"` expects part nodes named
`clampHandle01` / `clampHandle02` under the mount node:

```
[SPS] SPSCouplerAnimator.bind: part node 'clampHandle01' not found under mountNode for animation id=1
```

That warning means the animation id is valid but your mount node does not contain the part
nodes that id drives — name your clamp/valve sub-objects to match, or omit the animation
attribute if you do not want it.

You can also define your **own** animation ids without touching SPS: add a
`<couplerAnimations>` block inside your `<sprayerPipeSystem>` using the same format as the
SPS `configs/couplerAnimations.xml` (see the placeable guide §7 for the block format).
Config-local ids are checked before the shared library, so a local id overrides a shipped
one of the same number.

### loadAnimation (vehicle-level)

```xml
<loadAnimation name="toggleCover"/>
```

`name` is one of your vehicle's own declared animations (e.g. a cover/flap). It is shared
across all couplings, played forward as part of connecting and reversed on disconnect. Omit
the element if your sprayer has no such animation. (In the log, `loadAnimationName=nil`
simply means none was declared — that is fine.)

---

## 8. Engine sound — `<sounds>` (optional)

```xml
<sounds>
    <engineLoop ... linkNode="exhaustNode" />
</sounds>
```

`engineLoop` is a standard `loadSampleFromXML` sound, loaded on clients and played while the
valve is open (flowing) and stopped when closed. `linkNode` may reference a node that lives
in your nodeTree rather than your base i3d — SPS injects it into the vehicle's i3dMappings so
the sound can attach to it (see the log line `injected 'exhaustNode' into i3dMappings`).

---

## 9. Operating sequence (what the player does, and what fires)

This is the runtime flow confirmed in the log, so you can sanity-check your setup:

1. Park the sprayer within `maxPipeLength` of the source coupler and walk to the **pump
   control node**.
2. **Connect** — pipe visual is created (`outNode`→`inNode`), connector animations play
   forward, load animation plays, valves initialise **closed**.
   `[SPS SPR] applySprayerConnect: pipe created pipeId=…`
3. **Set direction** (Load = fill the sprayer / Unload = empty it). Only allowed while the
   valve is closed.
   `[SPS SPR] onSprayerToggleDirection: direction=0|1`
4. **Open valve** — this starts the pump and the flow in one action; engine sound starts.
   `[SPS SPR] onSprayerToggleValve: valveOpen=true pumpRunning=true`
   → `[SPS SPR] updateSprayers: flow session STARTED …`
5. **Close valve** to stop. Change direction again if needed.
6. **Disconnect** at the pump control node — pumps stop, valve + connector animations
   reverse, pipe disappears, load animation reverses.

`direction=0` is Load (`SPS_SPRAYER_DIRECTION_FILL`), `direction=1` is Unload
(`SPS_SPRAYER_DIRECTION_DISCHARGE`).

---

## 10. Minimal worked example

```xml
<vehicle ...>
    ...
    <sprayerPipeSystem>
        <flow litersPerSecond="200"/>

        <sprayerPipeCouplings>
            <sprayerPipeCoupling id="1"
                                 mountNodeName="couplerMount01"
                                 flowDirection="BOTH"
                                 maxPipeLength="7.5"
                                 fillUnitIndex="1"
                                 connectorAnimation="1"/>
        </sprayerPipeCouplings>

        <sprayerPumpControls>
            <sprayerPumpControl id="1" nodeName="pumpControlNode" radius="1.5"/>
        </sprayerPumpControls>

        <!-- optional -->
        <loadAnimation name="toggleCover"/>
        <sounds>
            <engineLoop ... linkNode="exhaustNode"/>
        </sounds>
    </sprayerPipeSystem>
</vehicle>
```

Node requirements for this example:
- `couplerMount01` exists, and contains child transforms named `inNode` and `outNode`.
- `pumpControlNode` exists where the operator stands.
- if `connectorAnimation="1"` is used, the clamp part nodes that id drives exist under
  `couplerMount01` (otherwise drop the attribute).

---

## 11. Checklist

1. Add the `<sprayerPipeSystem>` block to **your own** vehicle XML — never edit the SPS mod.
2. Set `<flow litersPerSecond>`.
3. Add at least one `<sprayerPipeCoupling>` with a `mountNodeName`, and give that mount node
   `inNode` + `outNode` children.
4. Add one `<sprayerPumpControl>` with a `nodeName` — this is the only operator interaction
   point.
5. Optionally add connector/valve/load animations and an engine sound.
6. Load the game and confirm `[SPS SPR] registerSprayerVehicle: registered …`. If a coupler
   or control is missing, the log names exactly which node was not found.

---

## 12. Front / rear tank combos ("FlowControl")

If your sprayer is used with a front tank — or your mod *is* a front tank — SPS links the
two automatically, modelled on the real Amazone FT-P + UF FlowControl system. There is no
per-pair configuration and no keybind.

### Pairing rules (all automatic, checked about once a second)

A combo forms when, on the **same root vehicle** (tractor):

- one implement is a **sprayer** (carries the vanilla sprayer specialization) — the *rear*, and
- another implement is a plain **fillable tank** with *no* sprayer specialization, positioned
  **forward of the tractor's origin** — the *front*, and
- the two share at least one supported fill type on the relevant fill units
  (the rear's sprayer fill unit vs. any of the front's fill units).

Only the vehicle the pipe physically connects to needs an SPS `<sprayerPipeSystem>` block —
the partner can be a completely vanilla implement. Front tanks that are registered in the
SPS **slurry** front-mount system are excluded, so the two systems never fight over one tank.
The combo dissolves the moment either implement is detached.

### What a combo changes

- **Fill both.** One pipe connection to *either* member fills **both** tanks, split
  proportional to free capacity — tanks with different starting levels reach full at the
  same moment.
- **Drain both.** Unloading through the pipe draws from **both**, split proportional to
  level; the session only reads "empty" when both are.
- **Automatic balancer.** While attached (no pump, no keybind — the real front tank has its
  own transfer pump): when the rear falls to **30%**, liquid is pulled front→rear at
  **200 l/min** until the rear recovers to **40%** or the front is empty. Net effect matches
  the real system — the rear is never emptied before the front; the front drains first
  (front axle load preserved), then the rear runs 30% → 0. The balancer pauses while a pipe
  transfer is active on either member, and stops with a one-shot warning if the rear cannot
  accept the front's fill type.

### Optional tuning — `<frontTankBalance>`

Inside `<sprayerPipeSystem>`; every attribute is optional and the values below are the
built-in defaults. When both members are SPS-registered, the **rear** sprayer's values win.

```xml
<frontTankBalance lowPct="30" highPct="40" transferLitersPerMinute="200"/>
```

| Attribute                 | Default | Meaning |
|---------------------------|---------|---------|
| `lowPct`                  | 30      | Rear level (%) at which the front→rear pull starts. |
| `highPct`                 | 40      | Rear level (%) at which the pull stops. |
| `transferLitersPerMinute` | 200     | Balancer transfer rate. |

### Multiplayer & troubleshooting

Everything runs server-side; fill levels reach clients through the normal vanilla sync, and
join-in-progress needs nothing special. For a live trace, enable the debug channel:

```
spsDebug SPSM_Sprayers.FrontTank on
```

`[SPS FT-BAL]` lines then report combo link/unlink, balance START/STOP with the reason
(`rear-restored`, `front-empty`, `type-mismatch`) and a once-per-second FLOW heartbeat.

Buying-station fills are combo-aware too: the purchase is split across both tanks
proportional to free capacity, same as a pipe fill, with each tank's litres charged to its
owning farm.
