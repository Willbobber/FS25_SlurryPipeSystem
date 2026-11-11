# SPS README 06 — Physical pipes

Slurry Pipe System 1.0.1.8. Physical pipes are real pipes you buy in the shop, carry with
your hands, lay on the ground, join end to end and plug into couplers. They are the
alternative to the **original system**, where a pipe is laid or drawn between two couplers
with R. This file covers playing with them (§1–§7) and what a modder adds so a vehicle or
building works with them (§8).

---

## 1. Choosing the pipe system

Every savegame uses **one** system, never both.

- **New game:** a few seconds after the map appears SPS asks once: **Physical pipes (new)**
  or **Original system**. An existing save that never saw the question gets it the same way;
  it stays on the original system until you choose.
- **Later:** SPS settings, gameplay section, **Physical Pipes** Yes / No (the server admin in
  multiplayer).
- **Original → physical:** a warning lists the laid pipes and connections; confirm and every
  original pipe and connection is removed.
- **Physical → original:** a warning lists the physical pipes and docking stations; confirm
  and they are all removed from the map (not refunded).

In physical mode the original R prompts for laying and connecting pipes are gone, and the
pipes and the docking station appear in the shop. In original mode they are hidden.

## 2. The pipes

Shop, Slurry Tanks category (and the **SPS Pipes** tile under Packs, with the docking station):
one item, **SPS Pipe**, one pipe per purchase, no leasing. Choose on its shop page:

| Option | Choices | Price |
|--------|---------|-------|
| Pipe | Slurry pipe 140 mm, Water hose 80 mm, Milk hose 80 mm | 250 |
| Length | 4 m, 6 m | 6 m: +100 |
| Ends (slurry pipe) | female / male, female / female, male / male | - (water and milk have a water fitting both ends) |
| Colour | slurry pipes only | - |

The choice is fixed after purchase; sell the pipe to change it. A bought pipe shows its own name and
icon (for example "SPS Water Hose 80 mm (6 m)").

A pipe is a chain of jointed bodies: it bends, drapes over the ground and swings when
carried. The metal ends stay straight. Slurry pipes take the colour chosen in the shop.
The water and milk hoses are the same hose in two colours; the fitting it is plugged into
decides what flows.

Pipes get dirty and worn with use: slowly while plugged in or joined into a run, much
faster while liquid passes (the valve at the coupling open), and by the normal vehicle
rules while carried or riding a moving tanker. Rain and the pressure washer clean them.
Wear is cosmetic: no damage, no repair bill. Modders can set the rates per pipe XML with
the game's own `<washable dirtDuration="" workMultiplier=""/>` and `<wearable wearDuration=""/>`.

Two settings (SPS settings, General settings tab; the admin sets them in multiplayer):
- **Pipe dirt** on / off and **Pipe dirt speed** (0.25x to 3x): how fast pipes get dirty. Off keeps them clean.
- **Pipe leakage** (default off): with it on, a pipe plugged into a machine whose far end lies open on the ground
  (within 1.5 m, not in water, not held) counts as an open end: the valve prompt appears at the machine, the liquid runs
  out, and a puddle grows under the end (it merges with nearby ones and dries after a while) with a leak stream at the end.
  Lift the end and it stops. Puddles are not saved. Store and 80 mm fittings can leak the same way.

## 3. Controls (the game's own hands)

| You | Mouse | Result |
|-----|-------|--------|
| Empty hands, aiming at a pipe | **Left** | Pick it up (pipes can be grabbed from 4 m) |
| Holding a pipe, an end near a free coupler or a free mating pipe end | **Right** | **Connect pipe end** |
| Empty hands, at a plugged or joined end | **Right** | **Unplug pipe end and carry it** |
| Empty hands, aiming at a plugged pipe | **Left** | **Unplug pipe**: the nearest plugged end comes out and the pipe falls |
| Holding a pipe near a tanker's pipe rack | **Right** | **Stow pipe** (§6) |
| Holding a pipe that is stuck in a vehicle (wheel, fender) | **Left Alt + F** | **Free stuck pipe**: while held it passes through vehicles; let go and it collides again |

Where nothing SPS applies, left and right mouse do what they always do (pick up, throw).

## 4. Making a connection

- **Ends must mate.** A coupler takes one kind of end (male or female); slurry pipes join
  male into female. Use the Ends option to buy the pipe you need: for example store (takes
  a male end) ← female/male pipe → tanker (takes a female end).
- **Joining:** carry a pipe's end to the free end of another pipe and right click. Joined
  pipes behave as one. Join as many as you need.
- **Connected:** when both outer ends of a pipe, or of a chain of joined pipes, sit on
  couplers, the two couplers are connected. Pump, direction, flow, thickness, gravity
  levelling and every other SPS rule work exactly as with an original pipe.
- **Valves are separate** in physical mode. Walk to each coupler and open its valve (R);
  a hydraulic coupler's valve is the vehicle's own valve key. A pipe cannot be unplugged
  while the valve of the coupler it sits on is open: "Close the valve before unplugging the pipe".
- **Water intake:** a pipe with one end on a tanker coupler and the other end lying in a
  lake, river or drawn water course takes water: open the coupler valve and pump (fill
  direction).
- **Overstretch:** drive off with a pipe still plugged in and its end pulls out.

## 5. Water and milk hoses

The 80 mm hoses plug into the barn's and the carrier's water / milk fittings (README 05).
Which hose goes where: the **water hose** plugs into water fittings, milk fittings and the
fert / herb couplers of sprayers, fert / herb silos, IBCs and buying stations; the **milk
hose** plugs into milk fittings only, and a chain that holds a milk hose connects milk
fittings only.

**Fert / herb.** Plug a water hose into a sprayer's coupler (open its cover first if it has
one, X) and the other end into a fert / herb silo, an IBC or a buying station - or into a
second sprayer. The sprayer's own keys then work as in the original system: **B** at the
sprayer starts and stops the flow, **Y** sets Load / Unload. The hose cannot be unplugged
while the flow is on. A sprayer with a physical hose on its coupler no longer offers the
original walk-up connect; without a hose it still does.
Every fitting has its own ball valve: plug in, then open each fitting with R. The pump at
the carrier (B) will not start until both valves are open, and closing a valve stops it.
With both valves open and the pump off, liquid also flows by **gravity** from the higher
tank to the lower one. Two water or milk carriers joined by a hose transfer between each
other: the carrier you stand at pumps, Y sets Load / Unload. Details: README 05 §4A.

## 6. Pipe racks and the docking station on a tanker

- A tanker with pipe racks (shipped: Kaweco Profi 2) carries pipes. Hold a pipe near the
  rack: **Stow pipe: holder N (… free)**, right click, and the pipe is laid in its slot.
  Several racks in reach: mouse wheel or `;` / `'` choose the rack. A rack holds one family
  at a time, slurry pipes or water / milk hoses. Grab a stowed pipe to take it off.
- **SPS Docking Station** (shop, 1,250, physical mode only): a portable inlet post. Plug a
  pipe from a store into it, then lower a tanker's rubber-boot fill arm into its boot and
  the tanker fills from the store through the pipe. Carry it with the hands; it also rides
  a tanker's docking-station frame like a stowed pipe.

## 7. Saving and multiplayer

Plugged ends, joints, valve states, stowed pipes and stations on frames are saved and come
back after a reload. Everything is synced in multiplayer, including to players who join a
running game.

## 8. For modders: making a coupler work with physical pipes

Nothing new is needed for a coupler to accept physical pipes. Every SPS slurry coupler
(`<pipeCouplings><pipeCoupling>`, README 01 §7 and README 03 §4), every water / milk
fitting (README 05) and every sprayer coupler (`<sprayerPipeCouplings>`, README 02 §5 -
the water hose plugs in; its `inNode` is where the hose end lands) takes them. Three things
matter:

- **`connector`** on a slurry coupler is the pipe **end** it takes: `male` (default) = a male
  pipe end plugs in, `female` = a female pipe end. Store couplers usually take the male end,
  tankers the female end, so the female/male pipe runs store → tanker.
- **`valveType`**: `MANUAL` = the coupler has its own valve (R at the coupler in physical
  mode); `HYDRAULIC` = the valve is the vehicle's cab valve; `NONE` = no valve, never blocks.
- **The mount node** needs `inNode` (its +Z points into the coupler); the pipe end is placed
  on it. The arc group is not used by physical pipes but keep it for the original system.

Pipe racks: `<pipeHolders>` and `<dockingStationHolders>`, README 01 §7A. Water / milk
gravity nodes: README 05 §4A.

Log lines (`spsDebug SPSM_PhysPipes on` for more):

```
[SPS PHYS] end 1 (female) plugged into coupling id=1 of <vehicle>.xml
[SPS PHYS] chain complete: coupling id=1 <-> id=1 connected (valve / pump / flow as the original system)
[SPS PHYS] unplug of end 1 refused: the coupler's valve is still open
```

## Trailer-specific pipes: the 550 Water/Chem Bowser (2026-11-09, untested)

A vehicle fitting (`<liquidPipeCoupling>`) can take only its own pipes. Attributes, all optional:

- `acceptPipes="WT_SUCTION WT_SMALL"` hose keys allowed on the fitting; nothing else plugs in there.
- `acceptEnd="start"` only the pipe's start end (gender `bowser`) plugs in; `end` = the far (water) end.
- `waterSource="WT_SUCTION"` that pipe's free far end lying in a water course is an intake: B at the control node pumps water into the tank.
- `washOutlet="WT_WASH"` that pipe's free far end pours the tank out where it lies (stream + puddle); `washLitersPerSecond` (default 40).
- `connectorAnimationName="..."` a vehicle animation held open while a pipe is on the fitting (caps, handles).

`<generator pullAnimation pulls pullSpeed pullPause revsAnimation>` with `<sounds><pull/><start/><engineLoop/></sounds>` is the
small pump engine: B pulls the cord `pulls` times, then the engine runs and liquid moves. `<physicalModeHide>` and `<pipeHolders>`
work inside `<liquidPipeSystem>` exactly as inside `<slurryPipeSystem>`.

The pipes themselves are `vehicles/hoses/spsBowserPipe.xml` (shop: "550 Bowser Pipes", one Pipe row, physical mode only), built by
`tools/build_pipes_bowser.py` from William's Blender export. Hose keys `WT_SUCTION`, `WT_WASH`, `WT_SMALL`; start gender `bowser`.

**Original mode (2026-11-10, untested).** The same three pipes are drawn by the live hose system from a second template file,
`i3d/pipes/bowserHoses.i3d` (built by `tools/build_hoses_bowser.py` from the same export), listed in `i3d/pipes/hoses.xml` with
`i3d="bowserHoses.i3d"`. A fitting's `waterSource` / `washOutlet` key names the hose drawn for it, so any bowser tagged like the
550 gets its own pipes. The prompts show at the pump control node AND anywhere inside a fitting's arc, as at a tanker's coupler:

- **R** at the inlet: a partner fitting in reach (a barn lane, an IBC, a sprayer vehicle's water fitting) = the small hose and the
  normal connect; nothing in reach = **Take suction pipe**: the end into your hands. Walk it out (up to the pipe's own length,
  7.75 m) and **right mouse** or R (**Release suction pipe**) lays the end where it is, on the ground or the river bed. B then
  pumps water in. R at the bowser (**Remove suction pipe**) puts it back on the rack; H with the end in hand puts it back too.
- **H** (`SPS_BOWSER_HOSE`): the wash hose into your hands - only with the engine running (B first; otherwise "Start the engine
  (B) before taking the wash hose"). Its end follows you up to the hose's length. **Right mouse** (the hands' secondary action,
  the same button as in pipe mode) starts and stops the pour: a chem tank's fill point within 1.5 m of the end takes the liquid at
  the bowser's strength, anywhere else it lands on the ground. H puts it back from anywhere; H also puts a carried suction end back.
- A tanker's water fitting arc over the bowser's inlet arc: R = Connect (Bowser to tanker / Tanker to bowser), B pumps,
  Y = load / unload. The connection swings both fittings' handles over (the bowser's inlet valve too); they come back on
  the disconnect.
- Carried and laid pipes have no collision and droop to the ground between the fitting and the hands.
- **Reach (every original-mode hose, 2026-11-10):** two couplers connect while their mount nodes are within the hose's
  reach (80 mm water / milk / sprayer hose 5.0 m = the two 2.5 m arcs nose to nose; the bowser's small hose 7.4 m;
  slurry couplers 5.9 m) and their arcs overlap. A connected hose is dropped only 0.5 m beyond that reach, so a pair
  connected at the edge stays connected until a vehicle actually drives off.
- **Arcs (2026-11-10):** every SPS fitting's arc is the same 2.5 m deep x 3.0 m wide level triangle in front of the fitting
  (`tools/sps_arcscan.py` audits them, `tools/sps_arcrelay.py --apply` re-lays any that drift). Two arcs nose to nose
  overlap up to 5 m, which is the 80 mm hose reach. Physical pipes never use the arcs.
  **Modders:** SPS re-lays every arc to this standard at run time, on every machine, from the arc you placed - only its
  pointing direction is read, projected flat in your vehicle's or building's own space. So an Arcs group under a fitting
  that points up or down, or one made with the old 3.5 m / 2 m template, works exactly like a standard one; one
  `[SPS ARC] ... arc re-laid` log line tells you it was corrected. Arc01 / Arc02 keep their sides.
- Nothing is saved: the pipes vanish on reload.

## Water cages and the cage holder (1.0.2.0, physical pipes)

A pipe end lying in open water (lake, river, pond or a build-menu water course) draws only through a **water cage**.
Discharge into water and the gravity return need no cage; open air gives nothing and no message. Buy the cages in the
shop (**Water Cage**, one item with a Small / Large selector; Slurry Tools section):
- **Small** cage: fits either end of an 80 mm water or milk pipe. **Large** cage: the male end of a slurry pipe (it refuses
  a female end).
- Pick the cage up by hand and join it to the free pipe end like another pipe. Lay the cage in the water: its water-level
  mark must be under the surface. Without a cage the player sees "Fit a water cage on the pipe end first" and no litres move.
  The bowser's own suction pipe needs no cage. A cage never plugs into a coupling.
- Original pipe mode (strap pipes) is unchanged: it does not use cages.

**Cage holder (modders).** A vehicle can carry one parked cage on a node, taken from the pipe-holder system:
```xml
<pipeHolders>
    <cageHolder id="3" nodeName="SPS_cageHolder01" radius="1.5" cages="CAGE_SMALL"
                requiresAnimation="rearDoor" requiredAnimationTime="0.95"/>
</pipeHolders>
```
- `nodeName` is a transform in the vehicle (mapped in `i3dMappings`); the cage hangs on its frame (+Z along the cage, +Y up).
- `cages` is `CAGE_SMALL`, `CAGE_LARGE` or both, space separated. `radius` is the reach for hanging it.
- `requiresAnimation` (optional): the cage can be hung and taken only while that vehicle animation is at or beyond
  `requiredAnimationTime` (default 0.95), for example a door. A wrong name does not lock the holder.
- `offset="x y z"` (optional, node-local metres) moves the hung cage.
- Hang a cage with the hands' stow action while holding it near the holder; look at it and grab it to take it off. A cage
  hung on a holder cannot take a pipe. Hung cages are saved.
