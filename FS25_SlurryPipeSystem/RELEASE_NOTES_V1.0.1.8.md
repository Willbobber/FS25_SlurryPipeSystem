# FS25_SlurryPipeSystem — Release V1.0.1.8

Everything since V1.0.1.7. The big one: **physical pipes**, real pipes you buy,
carry, plug in and join by hand, as an alternative to the original laid pipes.
Also new: the **SPS Tower Mixer** (lagoon mixer with a pump), the **SPS Docking
Station**, pipe holders on tankers, valves on the water / milk fittings, and a
flow meter on the pumps.

New config keys are all optional. Existing vehicle / placeable configs and
savegames load unchanged; an existing save stays on the original pipe system
until you choose otherwise.

## Fixed

### Shop
- The pipe, docking station, PTO pump and tower mixer are now under **Slurry Tools**
  (were under Slurry Tankers), and all four are in the SPS Slurry Kit pack.
- The shop camera now frames the whole PTO pump and docking station, and the
  pipe is centred for both the 4 m and 6 m lengths.
- The tower mixer stands on its feet in the shop (they were in the floor).

### Farmtech SuperCis 800 pipe holder
- Its pipe holder (4 slots) was never built: the holder group pointed at a
  node the tanker does not have. Pipes now stow on its side.

### Multiplayer
- Only an admin can change the SPS gameplay settings (switching pipe mode
  removes every farm's pipes).
- Each lagoon of a multi-lagoon placeable now shows its own crust for joined
  players.
- Another farm can no longer work your valves, pumps, agitators, separator or
  shear bolt. Shared map stores still work for everyone.
- The shear bolt warning only shows to the farm that owns the machine.

### Shear bolt is saved
- A snapped (or worn) shear bolt stays that way after a save and reload.

### Rudolf Hormann Gea / Vector cow barns use their own pipe setup
- Both variants were reading the standard Big Cow Barn setup.

### Multiplayer: rear-control valve could not be closed by a joined player
- Reported on the Kotte TSA 30000: as a joined player (not the host) the
  hose connected and the pump ran, but "close valve" at the rear control did
  nothing and the hose refused to disconnect with "Close valve before
  disconnecting". The joined player's copy of the rear-control switch never
  learned the valve had opened, so every press re-sent "open". Host and
  single player were unaffected. Any tanker whose valve is worked from a
  rear/outside control node had this.

### Multiplayer: joining players received wrong pump / valve / direction state
- When a player joined a running game, the server's per-tanker state (pump
  running, valve open, flow direction, pressure, spreader valve, agitator,
  blockages, snapped shear bolt) was sent before the joiner's copies of the
  vehicles had finished loading, and was silently dropped. The joiner then
  saw every tanker as pump off / valve closed / fill direction until someone
  re-toggled it. That state is now held and applied once each vehicle has
  loaded on the joiner.

### Multiplayer: pipe / valve / pump events lost while a vehicle was still loading
- Any SPS event about a vehicle that another player was still loading (a
  freshly bought or reset tanker, or every tanker during a join) was dropped
  for that player. SPS now asks the engine to queue such events and deliver
  them once the vehicle is ready on that machine.

### Hoses and pipe chains no longer sink into concrete after a reload
- A hose or laid pipe that sat correctly on a concrete pad, building floor or
  bridge could come back after save and reload sunk into it. The floor under
  each pipe was probed while the world was still loading, before that
  surface's collision existed, and then kept. Pipes now keep re-checking the
  floor for a short while after they are rebuilt, and again whenever a
  placeable is placed, so they climb onto the surface as soon as it is there.
  The same fix covers a pad placed under an already-parked hose.

### Spreader HUD now shows for injectors / dribble bars without an SPS config
- Reported with the Vredo ProfiXL injector (issue #37): a registered tanker
  towing a spreading tool that has no SPS config of its own showed no HUD at
  all. The panel now appears for the tanker (fill, crust, thickness, risk,
  pump) whenever a spreading tool is attached, with no outlet strip because
  that tool has no blockage nodes. Tools that do have an SPS config are
  unchanged and keep their strip.

### Agitator `tipNode` accepts i3dMapping ids and index paths
- Reported for mobile agitators (issue #33): `<agitator tipNode="..."/>` only
  matched a plain node name, and only inside the vehicle's first component.
  It now also accepts an i3dMapping id or an index path such as `0>0|4`,
  searches every component by name, and logs a warning when the node cannot
  be found instead of silently disabling the tip.

### Fixed lagoon agitators now load the tractor
- Reported for the mrh liquid manure tank's built-in mixer (issue #33): the
  tractor connected, the shaft turned, but the engine showed no load and the
  tractor symbol in the help panel stayed grey. A placeable is not a PTO
  implement to the game, so its draw was never counted. While the mixer runs,
  the tractor now takes real PTO load (default 60 kW at 540 rpm, per
  placeable via `neededPtoPower` / `ptoRpm` on `<fixedAgitator>`), the engine
  holds PTO speed, and the schema symbol turns green.

### Help-menu (F1) rows stopped updating after a dialog had been open
- After any in-game dialog while sitting in the cab (a teleport/dev tool, some
  mod menus), the SPS rows in the F1 help box froze: the pump, valve and
  direction keys still worked but the text kept saying "is OFF" until you got
  out and back in. SPS was registering its cab keys while the dialog was open,
  where the game itself registers nothing, so a second copy of each key landed
  in the menu's input context under the same id and took the text updates.
  SPS now stays quiet whenever the game does. The same thing could also make
  the cab keys disappear entirely after connecting a pipe with a menu open.

### Shear bolt setting no longer switches itself back on
- Reported as issue #39: the PTO shear bolt On/Off setting in the SPS settings
  page was applied in the running game and sent to other players, but never
  written to the savegame, so it came back **On** after every restart. It is now saved and
  restored with the other SPS gameplay settings. Saves from older versions
  load as On, the previous behaviour.

### Build-menu preview shows the SPS version of a building
- When placing a building that SPS modifies, the preview in the construction
  menu showed the base building: its own fill points still visible and no SPS
  couplers. The SPS parts only appeared once the building was placed. The
  preview now shows the SPS version, with the couplers in place and the
  replaced base parts hidden, so what you see is what you get.

### Hoses no longer bunch up at the ends
- The sprayer hose (and the slurry strap hose) placed its bones at equal
  steps of the curve parameter, not at equal distances along the curve, so
  the hose skin squashed up near the couplers and stretched in the middle,
  worst when a coupler faced away from the other end. Bones are now spread
  at equal distances along the hose.

### Cab controls silently lost to a key clash
- If another vehicle in the chain (a folding implement, a bale loader, a
  tractor with steps) uses the same key as an SPS control, the game drops
  one of them. Before, SPS stored the dead key and said nothing: the F1 row
  froze and the key did nothing. Now SPS logs **one** `[SPS] WARNING` naming
  the clashing action, so the fix (rebind one of them in Options > Controls,
  or re-select the tanker) is obvious. Note: the mod defaults are **X** =
  valve, **Y** = direction, **Z** = spreader valve, **B** = pump; an old
  profile may still carry the previous Z/X layout.

### Gravity levelling now works through a laid pipe chain
- Head-height equalisation (a part-full tanker connected to a store above or
  below it, valve open, pump off) only ran through a single strap pipe. With a
  chain of laid pipes to the store it never started, because the tanker's
  partner was the pipe end, not the store. Reported on The Mechet dairy barn;
  any store reached through a chain had it.

### Pumping into a biogas plant you do not own now pays you
- Reported by a player: slurry pumped into a map biogas plant he did not own
  disappeared and no money came in. Every pipe into a placeable store wrote
  straight into the store, with no ownership check. Pipes now follow the
  game's own rules, the same as a tipping trigger:
  - your own (or an accessible) store: stored, no money;
  - a map biogas plant you do not own: a **sale**, paid at the plant's price
    and shown in the finances, the level does not rise;
  - drawing out of a store you have no access to: refused, with the warning
    "No access to this store";
  - water into a store you do not own: refused, never sold.

### Front-mount cascade no longer draws free liquid from a buying station
- A front-mounted unit whose external source was a buying station (hose on a
  buying-station coupler, or now its arm in a paid pool) filled the rear
  tanker without charging. It is now charged exactly like a direct coupler
  fill.

## Performance

### Less work per frame, smaller download
- Store and agitator checks run five times a second instead of every frame,
  hoses far from the camera are not reshaped, and several oversized textures
  were halved (about 50 MB less in the mod).
- A much quieter log.txt: routine lines (holders and node trees registered,
  pipe picked up / dropped, hooks installed) moved behind the debug channel
  `Info` (`spsDebug Info on` in the console). Warnings and errors still show.

### Multiplayer / dedicated server lag
- Hose reshaping between two machines that are not moving no longer runs
  every frame on every machine (it was 14 to 30 physics raycasts plus terrain
  probes per hose per frame, on the server and on every client). The hose
  still follows a moving tanker exactly as before and still lies on terrain
  and concrete pads.
- The crust foliage on lagoons refreshed every tick while crust was growing;
  it now refreshes in small steps.
- An always-on internal arm-detection diagnostic that built strings for every
  arm-equipped vehicle every third tick on all machines has been removed, and
  several per-tick table allocations in the manager update are gone.

## Added

### Free a stuck pipe
- A pipe caught in a wheel or under a fender can be freed: pick it up, then
  press **Free stuck pipe** (Left Alt + F, rebindable). While you hold it the
  pipe passes through vehicles, so you can pull it out; let go and it collides
  with everything again.

### Pipe flow on the tanker HUD
- While a running pump fills or empties your tanker, the tanker HUD shows
  "Pipe flow" and, when nothing moves, why (valve closed, source empty,
  destination full, too thick). The pump's valve prompt shows the same reason.

### Physical pipes: buy them, carry them, plug them in
- A second pipe system, chosen per savegame. A new game asks once when it
  starts: **Physical pipes (new)** or **Original system**. You can change it
  later in the SPS settings ("Physical Pipes", admin only in multiplayer).
  The two systems never mix:
  - switching to physical warns you, then removes every original laid pipe
    and connection;
  - switching back to original warns you, then removes every physical pipe
    and every docking station (they are deleted, not refunded).
- In physical mode the pipes are shop items (Slurry Tanks category), bought one at
  a time, no leasing. Each is 13 jointed bodies, so it bends, drapes over the
  ground and can be carried:
  - **SPS Slurry Pipe 140 mm**, with an Ends option: female / male,
    female / female or male / male (250);
  - **SPS Slurry Pipe 140 mm (6 m)** (350);
  - **SPS Water Hose 80 mm** and **SPS Milk Hose 80 mm**, plus 6 m versions
    (250 / 350). Water and milk hoses are the same hose; the fitting decides
    the liquid.
  - Slurry pipes take the SPS pipe colour (shop colour row).
- Controls, with the game's own hands (pick-up reach for pipes is 4 m):
  - **left mouse** picks a pipe up, as any object;
  - holding a pipe with an end near a free coupler (or a free mating end of
    another pipe): **right mouse** = "Connect pipe end";
  - empty hands at a plugged end: **right mouse** = "Unplug pipe end and
    carry it"; **left mouse** on the pipe = "Unplug pipe", it falls.
- Ends must mate: a coupler that wants a male end only takes a male end, and
  pipes **join end to end** (male into female) to make any length. A chain of
  pipes with both outer ends on couplers is one connection: valves, pump and
  flow work exactly as with the original system.
- **Valves are separate in physical mode**: open the valve at each coupler
  or fitting (R) after plugging in, and a pipe cannot be unplugged while that
  valve is open ("Close the valve before unplugging the pipe").
- A pipe whose far end lies in a lake, river or drawn water course is a
  **water intake**: open the coupler valve and pump.
- Overstretch a pipe (drive off with it plugged in) and the end pulls out.
- Plugged and joined ends, valve states and stowed pipes are saved with the
  game and come back after a reload. Multiplayer synced, including players
  who join later.
- Full guide, including what a modder needs: new
  `SPS_README_06_Physical_Pipes.md`.

### SPS Docking Station (physical mode)
- A carriable inlet post (1,250, Slurry Tanks category, shop in physical mode only).
  Put it down at the end of a pipe from a store, plug the pipe into it, then
  drive a tanker with a rubber-boot fill arm up and lower the arm into its
  boot: the tanker fills from the store through the pipe, as at a store's own
  docking point. The rubber boot bends and squashes around the arm tip.
- Pick it up and set it down anywhere with the hands; it rides on a tanker's
  docking-station frame (see pipe holders below). In original mode docking
  stations are placed at the end of a laid pipe with R, as before.

### Pipe holders on tankers
- Tankers can carry physical pipes and a docking station. Holding a pipe near
  a tanker's rack shows "Stow pipe: holder N"; the pipe is laid in place along
  the rack. With several racks in reach, the mouse wheel (or ; and ') picks
  the rack. A rack holds one family, slurry pipes or water / milk hoses.
  Stowed pipes ride with the tanker and are saved. A docking-station frame
  works the same way for the station.
- Shipped on the Kaweco Profi 2. For your own tankers: `<pipeHolders>` and
  `<dockingStationHolders>` in the SPS config, with slot nodes captured in
  the GIANTS Editor using the included `placementPipes/SPS_PipePlacement.lua`
  script. Details in `SPS_README_01_Tanker_and_Spreader.md` §7A.

### Water and milk fittings: valves, gravity, tanker to tanker (physical mode)
- Every 80 mm fitting, on the barn and on the tanker, has its own ball valve:
  plug the hose in, then open each fitting with R. The pump stays at the
  tanker (B); it refuses to start until both valves are open, and closing a
  valve stops it.
- **Gravity**: with both valves open and the pump off, water runs from a tank
  standing higher into a lower barn supply (and milk the other way), slowing
  as the levels come together. Barns and tankers can mark their tank with
  `headHeightNodeName`, `tankTopNodeName` and `tankBottomNodeName` on the
  lane coupling; without them the fill volume is used.
- **Tanker to tanker**: two water or milk carriers joined by a hose transfer
  between each other. The tanker you stand at pumps; Y sets Load / Unload.
- Valve handles only move when you work the valve.

### Water flows back to the lake by gravity
- A tanker holding water, connected to a lake or water course through an open
  **manual** coupler valve with the pump off, drains back into it until the
  levels match. Water only; slurry never runs into open water. Both pipe
  systems.

### Valve states are saved
- A valve left open comes back open after a reload: the tanker's own valve,
  the pump's valve, physical-pipe coupler valves and the water / milk fitting
  valves. Before, every valve came back closed.

### New vehicle: SPS Tower Mixer
- A three-point-mounted lagoon mixer on a tower: hydraulic support legs with
  self-levelling feet, a telescopic extension, a rotating tower and a folding
  three-section boom with the mixer blades at its tip. Shop: slurry tanks,
  configurations **Basic** or **Pump mixer** (+4,500), and with the pump
  mixer an optional **pipe extension** (+250).
- Work it from the platform (walk up to it and enter) with the levers, or
  from the tractor. Legs: J / N (left), K / M (right), usable at
  any time, folded or not. The tower and boom are the second control group.
  The driver stands at the levers and the driver's hands follow the lever
  in use.
- Fold / unfold moves the boom between transport and work. Detaching sets it
  down: the boom swings round, the ladders open and the legs lower so the
  mixer stands on them before it lets go. Attaching reverses it. Its pose is
  kept across save and reload.
- **Mixing**: lower the blades into a lagoon or pit and turn the mixer on;
  it mixes the crust and the settled layer like any SPS agitator (only while
  the blades turn).
- **Pump mixer**: pumps slurry OUT of the store it stands in, through its
  hydraulic coupler (or the extension's coupler), into a tanker or another
  store. Valve = its own key, **Left Alt + B** (X is the fold key on the
  mixer); the pump runs while the
  blades turn and the valve is open, and stops when the receiving tanker's
  valve is closed.
- For modders: `<pumpMixer enabled="true"/>` and the agitator's new
  `requiresTurnedOn` are in the vehicle's `<slurryPipeSystem>` block; a
  pipe coupling can be gated by a second configuration with
  `configType2` / `configIndex2`. Player and modder guide: new
  `SPS_README_07_Tower_Mixer.md`.

### Pump flow meter (PTO pump and pump mixer)
- The pump panel now shows **Status: PUMPING** (green), or "stopped" and why
  (valve closed, pump off / blades off, no pipe, receiving valve closed,
  source empty, destination full, too thick, ...), the **rate** in l/s and
  the **litres pumped**, the **thickness** of what is pumped and the flow
  speed it allows, plus FROM / TO with levels. The pump mixer also shows
  **Blades: SPINNING** in green while they turn. Works the same for every
  player in multiplayer.

### New hose look (original system)
- Every connection in the original system (couplers, laid chains, sprayer
  hoses, water / milk lanes) is now drawn with the new hose meshes: proper
  metal fittings at each end, collisions, and fixed colours for water (blue)
  and milk (white); slurry hoses keep the SPS pipe colour.

### Ramp on or off, per store, in the build menu
- The slurry stores that SPS gives a ramp (Liquid Manure Tank,
  Liquid Manure Tank Extension (Small), Witcombe Cow Barn Parlour) now show
  a **Ramp: Yes / No** option when you place them, so one store can have the
  ramp and the next not. Stores already placed keep their ramp. Modders can
  offer the same for any node their SPS nodeTree adds with
  `<rampOption node="..."/>` (`SPS_README_03_Placeables.md` §4B).

### Original-system parts hide in physical pipe mode
- A config can name parts of a vehicle or building that only belong to the
  original pipe system, `<physicalModeHide><node name="..."/></physicalModeHide>`;
  they are hidden while physical pipes are in use and come back in the
  original system, switching live. `collision="true"` on a node switches its
  collision off with it. First use: the Joskin Cobra's side pipe,
  whose rack takes the store-bought pipes in physical mode.
  `SPS_README_01_Tanker_and_Spreader.md` §7B. Pipe racks, docking-station
  frames and these hidden parts can follow a tanker's shop options with the
  usual `configType` / `cylinderedConfigIndex` gate, so a rack on an optional
  hose carrier only exists when the carrier was bought (README 01 §13).

### Own shop icons
- Every SPS shop item now has its own icon: the pipes, the docking station,
  the PTO pump, the tower mixer, the sprayer silo, the Borger separator and
  the Cow Barn Medium (SPS).

### `spsMpState` console command
- Writes every registered vehicle's and placeable's coupling state (connected,
  partner, valve, arc geometry, whether you stand inside the arc and which
  coupler overlaps it) plus the pending multiplayer queues to `log.txt`. For
  multiplayer bug reports: run it on the machine showing the wrong prompt and
  send the log.

### Map water from a closed spline
- Map makers can now mark a lake, pond or river for the fill arm by drawing
  **one closed spline** round the shoreline under the water body's node in
  `SPS_waterNodes`, instead of placing four corner nodes per patch. SPS
  samples the spline at about one point per metre. The four-node quads still
  work and the two can be mixed under one body. Details in
  `SPS_README_04_Map_Water.md`.

### Fill-arm access to a buying station's pool
- A water reservoir or other `buyingStation` with a visible pool can now be
  drawn from with an open-pit fill arm, not only through its coupler. The
  station author adds a `<fillPlane>` with shape bounds to the SPS block; the
  player is charged at the station's price exactly as through the coupler.
  Details in `SPS_README_03_Placeables.md` §9B.

### Virtual slurry surfaces for barns and sheds
- A placeable whose vanilla config declares no slurry fill plane (a barn with
  a static decorative pit) can now carry an SPS-driven virtual surface via
  `<slurryStores>`, so gravity levelling through its coupler works. SPS moves
  a store's plane itself whenever vanilla declares none for that fill type.
  Details in `SPS_README_03_Placeables.md` §3A "Who moves the plane".

### One connection, several tanks: `<tank>` children and a walk-in tank switch
- A sprayer-source silo can now put several physical tanks behind **one**
  coupler. Each `<tank>` under the coupling has its own capacity and type
  rule, exactly like a Witcombe-style per-coupler tank, and shows as its own
  `T-n` row in the info box. The player connects once, walks into the
  station's switch trigger and cycles the tank the coupler feeds (activate
  key, Shift for backwards). A marker icon shows where the switch is.
  Switching is refused while the connected sprayer's valve is open. The
  selection is saved and synced to joining players. Existing single-tank
  couplers are unchanged. Details in `SPS_README_03_Placeables.md` §9C.

### New placeable: Cow Barn Medium (SPS), slurry, milk and water by pipe
- The medium Rudolf Hoermann cow barn, shipped by SPS under Animal Pens with
  all three connections: slurry out, milk out, drinking water in. Its water
  is a real 35,000 l supply, not the automatic supply of the base barn, so
  the cows must be watered, by SPS pipe from a water carrier or by a water
  trailer at the unload trigger. Its XML is annotated throughout to show
  what each SPS part does and how to add the same to your own barn.

### New placeable: fertiliser / herbicide silo, four tanks, one connection
- Shipped under Containers: four flat-bottom tanks, one SPS coupler, four
  "any liquid" tanks of 43,375 l each, the walk-in tank switch, plus the
  normal vanilla load and unload triggers.

### Animal drinking water in, milk out, by pipe — farm liquid lanes
- A water or milk carrier (the Lizard MKS 8 / MKS 32, or a tanker that also
  carries water or milk) gets **one** pipe connector, `<liquidPipeSystem>`. A
  barn gets a **water** coupler (`<animalWaterSystem>`, water goes in to the
  animals' drinking supply) and/or a **milk** coupler (`<milkPipeSystem>`,
  milk comes out), each on its own block, next to its slurry coupler on the
  slurry pipe. The connector serves whichever barn coupler it is parked at;
  the barn coupler decides the liquid and the direction. A tank holding milk
  only sees milk couplers, a tank holding water only water couplers. Uses
  the sprayer hose and connector, but sprayers can never connect to any of
  it, and water through a slurry coupler still dilutes the pit as before.
  The same connector also works at sprayer silos, IBC tanks and phyto
  buying stations for fertiliser, herbicide and script-mod sprayer liquids,
  where the trailer behaves exactly like a sprayer. A tank holding fert only
  sees sprayer sources, so fert can never reach a trough or a milk stand.
  Every shipped slurry tanker also gets a water-only connector, so a tanker
  that has drawn water from a lake or a reservoir can fill a barn's trough.
  Works on barns that hold real water (automatic supply off) and/or milk.
  The same prompts everywhere: R connects (the prompt names the lane),
  Y sets Load / Unload, B starts and stops the flow.
  Multiplayer synced. Config guide: new `SPS_README_05_Animal_Water.md`.
  Shipped configs: the Lizard MKS 8 / MKS 32 connector, milk couplers on the
  Rudolf Hormann cow barns, the UK cow shed and the Witcombe parlour, and a
  water connector on every shipped slurry tanker.

### Sprayer and liquid-lane hoses survive a reload
- Sprayer pipe connections, and the new water / milk connections, are now
  saved with the game and come back after a reload with their valve state and
  direction, as slurry hoses always have. Before, every sprayer came back
  disconnected.

### Store thickness ignores milk, straw and drinking water
- The slurry thickness model on barns and biogas plants summed every liquid in
  the building's storage, so milk, straw, silage and the animals' drinking
  water counted as pit volume. Only the slurry pool counts now. Existing
  saves adjust once on load with no visible change on plain lagoons.

### The Mechet drop-in kit — `Mechet/` folder
- Ready-made SPS files for the three **The Mechet** mods (map, Farm Pack,
  Production & Industry Pack): couplers and surfaces for the biogas plant,
  dealer slurry station, water reservoir and water tower, the beef and dairy
  sheds, the phyto dealer and the phyto silo (two tanks, walk-in switch), plus
  fill-arm water nodes for the lakes. The game ignores the folder; you copy
  the files into your own Mechet mods. Instructions and the Mechet versions
  they were made for are in `Mechet/README_Mechet_SPS_Kit.md`.

### Debug channels survive a reload
- `spsDebug <channel> on` is now remembered in
  `modSettings/FS25_SlurryPipeSystem/spsDebugChannels.xml` in your profile
  folder, so a trace can cover the game load itself. `spsDebug all off`
  clears it. For bug reports only; a fresh install has nothing enabled.

### Draw your own water courses in the building screen
- Any map, no editor needed: Building screen > Landscaping > **SPS Water** >
  **Draw water course**. Click the water first (that sets the water level),
  then click markers round the shore, on the bank or on the water, and click
  the first marker to close the ring. Right click removes the last marker,
  Esc cancels. Name it or keep "Water course N". The fill arm and the
  physical pipes can draw water from it straight away, like a map-maker's
  water area.
- **Remove water course** in the same tab shows your courses as rings; click
  one to remove it.
- Courses are saved per map in your profile folder
  (`modSettings/FS25_SlurryPipeSystem/waterCourses/`), not in the savegame,
  so a new career on the same map already has them. Map-maker water areas
  from `SPS_waterNodes` are untouched and cannot be removed here.
- Multiplayer: the host (or the dedicated server) keeps the courses and
  their file. Everyone who joins sees them straight away, and any player
  with the landscaping permission can draw or remove one for the whole
  server. Your own file on your PC is not touched while you are joined.

### One shop page for every physical pipe
- The six pipe items are now one: **SPS Pipe**. On its shop page choose the
  pipe (slurry 140 mm, water or milk 80 mm), the length (4 m or 6 m, +100 for
  6 m) and, for slurry, the ends (female/male, female/female, male/male).
- The pipe and the docking station also sit together on the **SPS Pipes**
  tile under the shop's Packs tab.

### Physical pipes get dirty and worn with use
- The bought pipes build up dirt and wear over time, like any vehicle. A pipe
  plugged in or joined into a run gets dirty slowly; with liquid passing (the
  valve at its coupling open) it gets dirty much faster and the metal ends wear.
  Carried or riding a moving tanker's rack, the normal vehicle rules apply.
- Rain and the pressure washer clean them; the game's dirt setting applies.
  Wear is cosmetic only: pipes take no damage and have no repair bill.
- The docking station works the same way: a little dirt while a fill arm is
  docked or a pipe is plugged in, much more while liquid passes through it.
  It washes with the pressure washer; no damage.
- The PTO slurry pump and the tower mixer now get dirty and worn while they
  run, even standing in one place (before, like any vehicle, they only did
  while driving). Normal damage and repair as before.

## Changed

### Pipe and arm effects only play while unloading
- The liquid stream on the fill arm and the inlet effect on a store coupler
  now play only while liquid is actually being **unloaded**, pumped or by
  gravity, and stop as soon as the tanker is empty. Nothing plays while
  loading from a pit, pool, store or buying station. Before, the arm showed a
  "suction" stream while filling and the store inlet could show slurry
  pouring in while the tanker was drawing out.

### Fixed agitator connect distance
- The distance within which a tractor's PTO connects to a fixed lagoon
  agitator is now 0.3 m (was 0.2 m), per placeable via `maxConnectDistance`.
