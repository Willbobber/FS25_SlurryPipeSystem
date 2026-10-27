# FS25_SlurryPipeSystem — Release V1.0.1.9

Everything since V1.0.1.8. Multiplayer fixes for the physical pipes, reported and retested by
server players; the invisible hoses of the original pipe system; the water hose now serving
fertiliser / herbicide in the physical pipe system; and a round of work on the Borger 125
separator (display, drop effect, weathering).

No config changes are needed. Existing savegames load unchanged.

## Added

### Physical pipes: fertiliser and herbicide through the water hose
- The 80 mm **water hose** now plugs into the fert / herb couplers of sprayers, fert / herb
  silos, IBCs and buying stations (physical pipe system). Plug one end into the sprayer and
  the other into the source - or into a second sprayer - and use the sprayer's own keys:
  **B** at the sprayer starts and stops the flow, **Y** sets Load / Unload. The hose cannot
  be unplugged while the flow is on. A sprayer whose cover is closed takes no hose: open it
  first (X).
- Hose rule: the water hose goes on water, milk and fert / herb fittings; the **milk hose**
  goes on milk fittings only, and a chain that holds a milk hose connects milk fittings only.
- The original pipe system is unchanged: its sprayer connect, drawn hose and keys all work as
  before.

### Borger 125 separator
- **Info box** (bottom right) now shows the separator's own rows: separated manure in kg / t,
  Source, Return, Status (running, or why not), Intake and Solids rates.
- **Control panel read-outs**: the six panel displays show live digits (litres and m³ in and
  out, screw and manure counters).
- **Drop effect**: the solids now visibly fall from the chute onto the heap, with dust.
- **Weathering**: the separator picks up dirt and wear in use like a vehicle, and the concrete
  bunker takes the game's own moss / dirt like a placeable. Repaint / clean as usual.
- Wrench icon on the control switch.

### Slurry stores
- **Crust dilutes on fill**: pumping fresh slurry into a store with a crust thins the crust in
  proportion, instead of leaving it as it was.

### Shop
- The **SPS Tower Mixer** now stands on the workshop floor in the shop (its feet were sunk in).

### Logging
- **Quiet log**: a normal game writes only the SPS start-up lines and genuine warnings /
  errors. The routine pipe lines (plugged, joined, restored, stowed, hose loaded) come back
  with the console command `spsDebug Info on`.

## Fixed

### Multiplayer: physical pipes (reported on dedicated servers)
- **Picking things up by hand as a joined player** could fail: the item fell straight out of
  the hands, later grabs did nothing, and the server log showed `getParent: Unknown entity
  id` errors. An SPS hook on the hand pick-up lost the game's "picked up OK" answer.
- **A physical pipe was always held by its female end** whichever end you grabbed, and the
  F/F and M/M pipes could not be picked up at all. The game's pick-up message only names the
  object, not the part of it you aimed at; SPS now sends that part ahead of it.
- **Dropped pipes hung in mid-air** on joined players' screens until picked up again. The
  game only keeps sending a vehicle's position while its first body is moving, and a pipe is
  13-19 bodies; the pipe now keeps reporting while any of its bodies moves.
- **Pipes plugged in, joined or stowed before you joined looked loose**: their state arrived
  while your game was still loading the vehicles they were attached to. The joining game now
  keeps retrying until those vehicles are ready.

### Physical pipes (single player too)
- **Tanker spins when a physical pipe is plugged in** (Kotte TSA rear coupler): the pipe ran
  through the tanker's own collision. A plugged pipe now ignores the vehicle it is plugged
  into - and only that vehicle; it still collides with the ground, buildings, the player,
  other vehicles and other pipes.
- **Grab cube on a plugged-in pipe end gave no prompt**: aiming the hand at the cube of a
  pipe end plugged into a tanker now gives the Unplug / Disconnect prompts (the tanker's
  hull was in the way of the aim).
- **Reload with pipes plugged in**: after loading a save, plugged pipes could come loose and
  a stretched original-system hose appeared in the coupler. The save no longer carries the
  old bond for a physical pipe, and a stale one found on load is broken.
- **Pipe vanished on a small camera turn** (render culling of the laid pipe): fixed.
- **One pipe into both couplers of the same machine** is refused (a loop is not a connection).

### Original pipe system
- **Invisible hoses**: in V1.0.1.8, with the original (non-physical) pipe system, the
  automatic hose between two couplers was never drawn - tanker to store, tanker to the start
  of a laid chain, sprayer and water / milk hoses. The connection worked and was reported,
  but nothing was visible.
- **Sprayer / water / milk hose dropped at once** when the two couplers were more than 4 m
  apart: the connect prompt now appears only within the hose's 4 m reach, so park closer and
  the hose stays.

### Borger 125 separator
- **"Source empty" with a full store**: the separator did not pass its farm to the store
  access check and was refused. Fixed.
- The separator's effect no longer crashes the game when the model lacks its effect nodes.

## Notes
- Dedicated servers never see the start-up pipe-mode question; an admin switches
  "Physical pipes" in the SPS settings instead.
- Configs revised in this release: Witcombe cow barn parlour (map and buildings pack) and the
  shared connector library.
