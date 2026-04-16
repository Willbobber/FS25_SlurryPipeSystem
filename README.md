# FS25_SlurryPipeSystem

**Oscar Mods — Farming Simulator 2025**

Replaces the vanilla drive-in trigger slurry filling system with a realistic physical pipe and connection system. 
Tankers must physically position fill arms over slurry pits, connect pipes between vehicles and stores, or use a 
PTO-driven pump to move slurry between two points. 

No drive-in triggers. No automatic filling.

---

## Contents

- [How It Works](#how-it-works)
- [Controls](#controls)
- [Fill Arm — Loading from a Store](#fill-arm--loading-from-a-store)
- [Fill Arm — Tanker to Tanker](#fill-arm--tanker-to-tanker)
- [Pipe — Loading from a Store](#pipe--loading-from-a-store)
- [Pipe — Discharging (Pumped)](#pipe--discharging-pumped)
- [Pipe — Discharging (Gravity)](#pipe--discharging-gravity)
- [Nurse Tank (FRC65) — Fill Arm Loading](#nurse-tank-frc65--fill-arm-loading)
- [Nurse Tank (FRC65) — Pipe Connection](#nurse-tank-frc65--pipe-connection)
- [PTO Pump](#PTO pump)
- [Universal Rules](#universal-rules)
- [Setting Up a Vehicle Config](#setting-up-a-vehicle-config)
- [Setting Up a Placeable Config](#setting-up-a-placeable-config)
- [Save Data](#save-data)
- [Debug Mode](#debug-mode)

---

## How It Works

SPS is driven by a single global manager (`g_slurryPipeManager`) that registers vehicles and placeables, tracks connections, controls flow sessions, and syncs state across multiplayer via server-authoritative events.

There are no specialization files. The mod hooks directly into vanilla vehicle types using `SpecializationUtil.registerOverwrittenFunction` and overrides `Vehicle:onFinishedLoading`, `Vehicle:registerActionEvents`, `Placeable:finalizePlacement`, and `Placeable:delete`.

Each registered vehicle has a state table tracking pump running, valve open, flow direction, and spreader valve open. State changes are sent to all clients via custom events.

Vanilla drive-in trigger filling (`ManureBarrel:getAllowLoadTriggerActivation`) is blocked by SPS unless a valid physical connection is confirmed by the manager.

---

## Controls

All actions are registered as rebindable inputs in `modDesc.xml`.

| Action | Default | Description |
|---|---|---|
| `SPS_TOGGLE_PUMP` | Replaces PTO key | Pump on / off |
| `SPS_TOGGLE_FLOW` | Configurable | Open / close valve |
| `SPS_TOGGLE_DIRECTION` | Configurable | Switch fill / discharge direction |
| `SPS_TOGGLE_SPREADER` | Configurable | Open / close spreader valve (spreader vehicles only) |
| Activate (long press R) | R | Connect pipe / open valve at coupling / deploy coupling |

All SPS actions fire regardless of fold state or implement power state. Motor and PTO checks are performed manually inside the callbacks where relevant.

---

## Fill Arm — Loading from a Store

1. Drive tanker to the slurry store and position alongside.
2. Remain in the cab.
3. Use joystick axes to swing the fill arm out and lower the nozzle toward the pit.
4. The arm has two detection nodes — **upper** and **lower**.
   - Upper node must enter the store's fill volume detection zone (round or rectangle).
   - Lower node must be below the current slurry surface Y.
   - Both conditions must be true for flow to begin.
5. Press **Pump ON** — PTO engages, engine load increases.
6. Press **Flow OPEN** — slurry loads into the tanker.
7. If the surface drops below the lower node, flow stops automatically. Lower the arm further to resume.
8. When full: press **Flow CLOSE**, then **Pump OFF**.
9. Raise and stow the arm.

---

## Fill Arm — Tanker to Tanker

1. Position tanker A (with fill arm) alongside tanker B (with receiver cup).
2. Remain in cab of tanker A.
3. Swing the arm and lower the nozzle toward tanker B's receiver cup node.
4. Detection checks proximity AND alignment angle to the receiver cup.
5. Press **Pump ON** on tanker A.
6. Press **Direction** to set **DISCHARGE** (pump out of A into B).
7. Press **Flow OPEN** — slurry transfers from A to B.
8. If the arm moves out of alignment tolerance, flow stops automatically.
9. Press **Flow CLOSE**, then **Pump OFF**.
10. Raise and stow the arm.

---

## Strap Pipe — Loading from a Store

1. Park tanker within pipe length of the store inlet coupling. Maximum pipe length is defined per vehicle in its `fillPoints.xml`.
2. Press **Pump ON** in the cab — PTO engages.
3. Exit the cab and walk to the tanker pipe coupling point.
4. When within range a proximity activatable appears. Press **Activate** — the pipe visual appears and both ends snap into place automatically.
5. Flow begins automatically because the pump is already on.
6. Return to the cab.
7. Press **Flow CLOSE**, then **Pump OFF** to stop.
8. Exit the cab, walk to the pipe, press **Activate** to disconnect.

---

## Strap Pipe — Discharging (Pumped)

1. Park tanker within pipe length of the destination inlet.
2. Press **Pump ON** in the cab.
3. Press **Direction** to set **DISCHARGE**.
4. Exit the cab and walk to the tanker pipe coupling point.
5. Press **Activate** to connect — flow begins automatically.
6. Return to the cab.
7. Press **Flow CLOSE**, then **Pump OFF** to stop.
8. Exit cab, press **Activate** to disconnect.

---

## Strap Pipe — Discharging (Gravity)

Pump is **not required** for gravity discharge.

1. Position tanker above or alongside the destination.
2. Press **Direction** to set **DISCHARGE** (pump remains off).
3. Exit cab and walk to the tanker pipe coupling point.
4. Press **Activate** to connect.
5. Press **Flow OPEN** — gravity pulls slurry out. No engine load increase.
6. Press **Flow CLOSE** to stop.
7. Exit cab and disconnect.

---

## Nurse Tank (FRC65) — Fill Arm Loading

The FRC65 is a passive vessel with no pump of its own.

1. Position the working tanker so its fill arm can reach the open top of the FRC65.
2. Lower the arm — the arm lower node must be below the FRC65 slurry surface Y. Surface is detected from the FRC65 fill volume using `getFillPlaneHeightAtLocalPos`.
3. Press **Pump ON** on the working tanker.
4. Press **Direction** to **DISCHARGE**.
5. Press **Flow OPEN** — slurry pumps from tanker into FRC65.
6. FRC65 fill level and surface rise as it fills.
7. Press **Flow CLOSE**, then **Pump OFF** when done.

---

## Nurse Tank (FRC65) — Pipe Connection

1. Park working tanker alongside FRC65 within pipe length.
2. Press **Pump ON** in the cab.
3. Press **Direction** to **FILL** (pull from FRC65).
4. Exit cab and walk to the FRC65 pipe outlet coupling.
5. Press **Activate** to connect — flow begins from FRC65 into the tanker.
6. If either vehicle moves beyond max pipe length, the pipe disconnects automatically. Pump keeps running.
7. Press **Flow CLOSE**, then **Pump OFF** to stop.
8. Exit cab, press **Activate** to disconnect.

---

## Conduit Pump

The conduit pump (e.g. PTO Slurry Pump) is a pass-through implement — it has no fill unit of its own. Slurry moves directly between two connected couplings.

- Attach to a tractor via PTO.
- Connect a strap pipe to **coupling A** (one side) and another to **coupling B** (the other side).
- Both couplings must be connected for flow to occur.
- Press **Pump ON** in the tractor cab.
- Press **Direction** to set which way slurry flows (A→B or B→A).
- Press **Flow OPEN** — slurry transfers between the two connected sources.

A HUD panel appears in the cab showing **FROM** and **TO** vehicle or store names with current fill levels.

The conduit respects `flowDirection` restrictions on connected store couplings — a `DISCHARGE`-only store coupling will block reverse flow even if the direction is set incorrectly.

---

## Universal Rules

- **Pump OFF = no flow** (except gravity discharge which requires no pump).
- **No valid connection = no flow** regardless of pump state.
- **Connection lost mid-flow = flow stops immediately.** Pump keeps running.
- **Vanilla filling is blocked** by SPS unless a valid physical connection is confirmed.
- **Flow direction can only be changed when the valve is closed.**
- Pump state, valve state, direction, and connection state are all server-authoritative and synced to all clients.
- Each vehicle's maximum pipe length is defined individually in its `fillPoints.xml`.

---

## Setting Up a Vehicle Config

### Folder Structure

```
configs/
└── vehicleConfigs/
    └── <vehicleName>/
        ├── fillPoints.xml
        └── nodeTree.i3d
```

The folder name must exactly match the vehicle's i3d filename without extension. The manager scans this at load time.

**Exception:** Conduit pump vehicles (`conduit="true"`) have their coupling nodes authored directly in the vehicle i3d. No `nodeTree.i3d` is needed and the `<nodeTree>` element must be omitted.

---

### nodeTree.i3d Structure

All SPS nodes for a vehicle live in a separate `nodeTree.i3d` loaded at runtime via `loadI3DFile`. Do **not** use `cloneSharedI3DNode` — cloning breaks skin bindings.

```
nodeTree root (TransformGroup)
│
├── effectNode (TransformGroup)
│   └── effect (TransformGroup)             ← PipeEffect shape node
│       └── pipeEffectSmoke (TransformGroup) ← smoke/particle emitter
│
├── fillArms (TransformGroup)
│   ├── SPS_fillArmCentre01                 ← OPEN_PIT nozzle centre
│   ├── SPS_fillArmUpper01                  ← OPEN_PIT upper detection
│   ├── SPS_fillArmLower01                  ← OPEN_PIT lower detection
│   ├── SPS_fillArmTip01                    ← RUBBER_BOOT tip node
│   └── (repeat for additional arms)
│
├── pumpControls (TransformGroup)
│   └── tsa_vis (TransformGroup)            ← visual anchor for walkaround HUD
│
└── pipeCouplers (TransformGroup)
    ├── SPS_pipeCoupler01
    │   └── SPS_pipeCoupler01Arcs
    │       ├── SPS_pipeCoupler01Arc01      ← arc detection node left
    │       └── SPS_pipeCoupler01Arc02      ← arc detection node right
    └── SPS_pipeCoupler02
        └── SPS_pipeCoupler02Arcs
            ├── SPS_pipeCoupler02Arc01
            └── SPS_pipeCoupler02Arc02
```

#### Node Placement Rules

| Node | Placement |
|---|---|
| `SPS_pipeCouplerXX` | Centre of coupling mouth. Local Z-axis pointing outward away from barrel. |
| `SPS_pipeCouplerXXArc01/02` | 1.5m left and right in local X, 2.5m forward in local Z from coupler. |
| `SPS_fillArmCentre` | Nozzle tip centre — used for XZ surface sampling. |
| `SPS_fillArmUpper` | 0.3–0.5m above nozzle tip — must enter store fill volume. |
| `SPS_fillArmLower` | At or below nozzle tip — must be below slurry surface Y for flow. |
| `SPS_fillArmTip` | Exactly at nozzle tip — used for RUBBER_BOOT proximity and angle checks. |
| `effectNode / effect / pipeEffectSmoke` | At the point where slurry visually discharges. |

---

### fillPoints.xml Reference

```xml
<slurryPipeSystem>

    <!-- Path to nodeTree.i3d relative to this file. Omit for conduit vehicles. -->
    <nodeTree filename="nodeTree.i3d"/>

    <!-- Transfer rate in litres per second -->
    <flow litersPerSecond="1000"/>

    <!-- selfPowered: vehicle has its own pump, no tractor PTO required.
         conduit: pass-through pump, no fill unit, two couplings required. -->
    <pump selfPowered="false" conduit="false"/>

    <!-- Optional looping pump sound for selfPowered vehicles only -->
    <sounds>
        <engineLoop
            file="$data/sounds/somePumpSound.gls"
            linkNode="nodeInVehicleHierarchy"
            innerRadius="5"
            outerRadius="20"
        />
    </sounds>

    <!-- Fill arms. Leave self-closing if none. -->
    <fillArms>
        <fillArm
            id="1"
            cylinderedConfigIndex="1"
            tipType="OPEN_PIT"
            centreNodeName="SPS_fillArmCentre01"
            upperNodeName="SPS_fillArmUpper01"
            lowerNodeName="SPS_fillArmLower01"
            fillUnitIndex="1"
        >
            <!-- Effects block is optional. Omit to auto-detect from nodeTree. -->
            <effects>
                <effectNode
                    effectClass="PipeEffect"
                    effectNode="effect"
                    materialType="pipe"
                    maxBending="0.4"
                    extraDistance="0.3"
                    positionUpdateNodes="pipeEffectSmoke"
                />
                <effectNode
                    effectNode="pipeEffectSmoke"
                    materialType="unloadingSmoke"
                    delay="0.5"
                    alignToWorldY="true"
                />
            </effects>
        </fillArm>
    </fillArms>

    <!-- Pipe couplings. Leave self-closing if none. -->
    <pipeCouplings>
        <pipeCoupling
            id="1"
            cylinderedConfigIndex="1"
            mountNodeName="SPS_pipeCoupler01"
            valveType="MANUAL"
            maxPipeLength="6.0"
            fillUnitIndex="1"
            valveFromRearControl="false"
        />
        <pipeCoupling
            id="2"
            mountNodeName="SPS_pipeCoupler02"
            valveType="HYDRAULIC"
            maxPipeLength="6.0"
            fillUnitIndex="1"
        />
    </pipeCouplings>

    <!-- Rubber boot ports. Leave self-closing if none. -->
    <rubberBootPorts>
        <rubberBootPort
            id="1"
            lowerNodeName="SPS_rubberBootLower"
            upperNodeName="SPS_rubberBootUpper"
            valveType="NONE"
            fillUnitIndex="1"
        />
    </rubberBootPorts>

    <!-- Walkaround pump control activatable. Leave self-closing for cab-only vehicles. -->
    <pumpControls>
        <pumpControl
            id="1"
            nodeName="rearControlNode"
            radius="1.5"
        />
    </pumpControls>

</slurryPipeSystem>
```

#### Attribute Reference

**`<pump>`**
| Attribute | Values | Description |
|---|---|---|
| `selfPowered` | `true/false` | Vehicle has own pump, no tractor PTO needed. |
| `conduit` | `true/false` | Pass-through pump. No fill unit. Requires two couplings. |

**`<fillArm>`**
| Attribute | Description |
|---|---|
| `id` | Unique integer ID per arm. |
| `cylinderedConfigIndex` | Cylindered config slot (0-based). Omit if vehicle has one config. |
| `tipType` | `OPEN_PIT` / `RUBBER_BOOT` / `RUBBER_BOOT_PIT` |
| `centreNodeName` | XZ sampling node (OPEN_PIT). |
| `upperNodeName` | Must enter store fill volume (OPEN_PIT). |
| `lowerNodeName` | Must be below surface Y for flow (OPEN_PIT). |
| `tipNodeName` | Proximity/angle check node (RUBBER_BOOT). |
| `fillUnitIndex` | Vehicle fill unit index. Default: 1. |

**`<pipeCoupling>` (vehicle)**
| Attribute | Description |
|---|---|
| `id` | Unique integer ID. |
| `cylinderedConfigIndex` | Cylindered config slot. Omit if N/A. |
| `mountNodeName` | Coupling mount node in nodeTree. |
| `valveType` | `MANUAL` / `HYDRAULIC` / `NONE` |
| `maxPipeLength` | Max connection distance in metres. |
| `fillUnitIndex` | Vehicle fill unit. Default: 1. |
| `valveFromRearControl` | `true` = valve controlled from rear pumpControl activatable. |

**valveType values:**
- `MANUAL` — Player opens valve at the coupling using long press R.
- `HYDRAULIC` — Valve opened from cab via `SPS_TOGGLE_FLOW`. No manual valve prompt at coupling.
- `NONE` — No valve. Flow begins immediately when connected and pump is on.

**`cylinderedConfigIndex`** maps to the Cylindered specialization config slot (0-based). Elements without this attribute are always active regardless of configuration state.

---

## Setting Up a Placeable Config

### Folder Structure

```
configs/
└── placeableConfigs/
    └── <placeableName>/
        ├── fillPoints.xml
        └── nodeTree.i3d
```

The folder name must match the placeable's config filename without extension. Matching is by substring, so a folder named `cowShedUK` matches both `cowShedUK` and `cowShedUK_nonMilk`. Use a separate subfolder for variants that require different configs.

---

### nodeTree.i3d Structure

```
nodeTree root (TransformGroup)
└── <containerName> (TransformGroup)     ← must match a node in the placeable i3d
    ├── pipeCouplers (TransformGroup)
    │   ├── SPS_pipeCoupler01
    │   │   └── SPS_pipeCoupler01Arcs
    │   │       ├── SPS_pipeCoupler01Arc01
    │   │       └── SPS_pipeCoupler01Arc02
    │   └── (repeat for additional couplings)
    │
    ├── fillPlaneNodes (TransformGroup)
    │   ├── slurryPlaneCentre            ← centre of fill area (all shapes)
    │   ├── slurryPlaneEdge              ← edge point — round shape only
    │   ├── slurryPlaneCorner1           ← first corner — rectangle shape only
    │   └── slurryPlaneCorner2           ← opposite corner — rectangle shape only
    │
    └── effects (TransformGroup)
        └── effect (TransformGroup)      ← PipeEffect shape node
            └── pipeEffectSmoke          ← smoke/particle emitter
```

The `<containerName>` TransformGroup name must match an existing node in the placeable's own component hierarchy. The manager parents the nodeTree root into that node at runtime.

#### Node Placement Rules

| Node | Placement |
|---|---|
| `SPS_pipeCouplerXX` | Centre of coupling mouth on the building wall. Local Z pointing outward. |
| `SPS_pipeCouplerXXArc01/02` | 1.5m left and right in local X, 2.5m forward in local Z from coupler. |
| `slurryPlaneCentre` | Ground level centre of the slurry pit or tank opening. |
| `slurryPlaneEdge` | Edge of the circular pit at ground level — defines detection radius (round shape). |
| `slurryPlaneCorner1/2` | Two diagonally opposite corners of the rectangular pit (rectangle shape). |
| `effect / pipeEffectSmoke` | Physical inlet point where slurry enters the store. |

---

### fillPoints.xml Reference

```xml
<slurryPipeSystem>

    <nodeTree filename="nodeTree.i3d"/>

    <!-- Optional: rotate a node in the placeable i3d when a deployable coupling is deployed -->
    <pipeAnimNode node="gateNode" rx="0" ry="90" rz="0"/>

    <!-- Fill plane for arm detection and surface height -->
    <fillPlane
        node="fillPlaneShapeNode"
        minY="-2.5"
        maxY="0.0"
        fillType="LIQUIDMANURE"
        shape="round"
        centreNodeName="slurryPlaneCentre"
        edgeNodeName="slurryPlaneEdge"
    />

    <!-- For rectangular pits use shape="rectangle" with corners instead of edge:
    <fillPlane
        node="fillPlaneShapeNode"
        minY="-2.5"
        maxY="0.0"
        fillType="LIQUIDMANURE"
        shape="rectangle"
        centreNodeName="slurryPlaneCentre"
        corner1NodeName="slurryPlaneCorner1"
        corner2NodeName="slurryPlaneCorner2"
    />
    -->

    <!-- Store pipe couplings -->
    <pipeCouplings>
        <pipeCoupling
            id="1"
            mountNodeName="SPS_pipeCoupler01"
            flowDirection="DISCHARGE"
            valveType="NONE"
            deployable="false"
            maxPipeLength="6.0"
        >
            <!-- Optional visual inlet effect -->
            <effects inletDistance="1.5">
                <effectNode
                    effectClass="PipeEffect"
                    effectNode="effect"
                    materialType="pipe"
                    maxBending="0.4"
                    extraDistance="0.3"
                    positionUpdateNodes="pipeEffectSmoke"
                />
                <effectNode
                    effectNode="pipeEffectSmoke"
                    materialType="unloadingSmoke"
                    startDelay="0.5"
                    alignToWorldY="true"
                />
            </effects>
        </pipeCoupling>
    </pipeCouplings>

    <!-- Nodes to hide in the placeable i3d when SPS is active -->
    <hideNodes>
        <node name="vanillaDriveInTriggerMesh"/>
        <node name="vanillaFillTower"/>
    </hideNodes>

    <!-- Collision nodes to disable when SPS is active -->
    <hideCollisions>
        <node name="vanillaRampCollision"/>
    </hideCollisions>

</slurryPipeSystem>
```

#### Attribute Reference

**`<fillPlane>`**
| Attribute | Description |
|---|---|
| `node` | Engine-animated fill plane node in the placeable i3d. Engine moves its Y between minY and maxY as the store fills. |
| `minY` | Local Y of fill plane node when store is empty. |
| `maxY` | Local Y of fill plane node when store is full. |
| `fillType` | Fill type string (e.g. `LIQUIDMANURE`). |
| `shape` | `round` or `rectangle`. |
| `centreNodeName` | Centre of fill area in nodeTree. |
| `edgeNodeName` | Edge of circular area — round shape only. |
| `corner1NodeName` | First corner — rectangle shape only. |
| `corner2NodeName` | Opposite corner — rectangle shape only. |

**`<pipeCoupling>` (placeable)**
| Attribute | Description |
|---|---|
| `id` | Unique integer ID. |
| `mountNodeName` | Coupling mount node in nodeTree. |
| `flowDirection` | `DISCHARGE` / `FILL` / `BOTH` |
| `valveType` | `MANUAL` / `HYDRAULIC` / `NONE` |
| `deployable` | `true` = hidden by default, player deploys via long press R. |
| `maxPipeLength` | Max connection distance in metres. |

**flowDirection values:**
- `DISCHARGE` — Slurry can only be pumped INTO this store.
- `FILL` — Slurry can only be pulled OUT of this store.
- `BOTH` — No restriction on direction.

**`<pipeAnimNode>`** — Rotates a node in the placeable i3d when a deployable coupling is deployed. `rx/ry/rz` are Euler degrees. SPS does not touch the rotation when the coupling is undeployed — vanilla animation controls it in that state.

**`<hideNodes>`** — Nodes to hide in the placeable i3d when SPS is active. Use to suppress vanilla drive-in meshes or fill towers.

**`<hideCollisions>`** — Collision nodes to disable when SPS is active. Use to remove vanilla drive-in ramp collisions.

---

## Surface Y Detection

Surface height is determined each tick:

- **Placeable stores:** World Y is read directly from the engine-animated fill plane node via `getWorldTranslation`. The engine moves this node between `minY` (empty) and `maxY` (full) in local space.
- **Vehicle fill volumes (nurse tanks):** `getFillPlaneHeightAtLocalPos` is called on the fill volume each tick, sampling at the arm centre node XZ position.

Both paths feed the same unified surface detection function. When fill level reaches zero, surface Y equals `minY` — the arm lower node will always be above it and flow stops.

---

## Save Data

All connection state, pipe colour selections, and chain state are saved to:

```
savegame/FS25_SlurryPipeSystem.xml
```

This file is written automatically on every game save. Per-connection data saved includes coupling connections, deployed coupling states, chain pipe state, and selected pipe colour index.

---

## Debug Mode

Set `SlurryDebug.enabled = true` in `init.lua` to enable debug logging. This is hardcoded during development and should be set to `false` for release builds.

---

## Mod Structure

```
FS25_SlurryPipeSystem/
├── modDesc.xml
├── scripts/
│   ├── manager/
│   │   └── SlurryPipeManager.lua
│   ├── specializations/
│   │   ├── SlurryFillArm.lua
│   │   ├── SlurryPump.lua
│   │   ├── SlurryFlowValve.lua
│   │   ├── SlurryPipeCoupling.lua
│   │   ├── SlurryReceiver.lua
│   │   └── events/
│   │       ├── SlurryPumpStateEvent.lua
│   │       ├── SlurryFlowStateEvent.lua
│   │       ├── SlurryFlowDirectionEvent.lua
│   │       ├── SlurryPipeConnectEvent.lua
│   │       └── SlurryPipeDisconnectEvent.lua
│   ├── overrides/
│   │   └── ManureBarrelOverride.lua
│   └── util/
│       ├── SlurryNodeUtil.lua
│       └── SlurryDebug.lua
├── vehicleConfigs/
│   ├── kaweco_profi2/fillPoints.xml
│   ├── samsonAgro_pgII28Genesis/fillPoints.xml
│   └── kotte_frc65/fillPoints.xml
├── placeableConfigs/
│   └── baseTank/fillPoints.xml
├── i3d/
│   ├── nodes/spsPivot.i3d
│   └── pipes/strapPipe.i3d
└── l10n/
    └── l10n_en.xml
```

---

## Author

Oscar Mods
