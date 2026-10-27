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
