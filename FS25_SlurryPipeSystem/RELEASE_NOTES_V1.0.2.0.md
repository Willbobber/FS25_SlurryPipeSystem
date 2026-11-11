# FS25_SlurryPipeSystem — Release V1.0.2.0

Everything since V1.0.1.9. Pressure and vacuum on the pipes and tankers, pressure gauges, chemical
mixing with a full sprayer washout (and a washout station), water cages, new SPS vehicles (MKS 8 Dual
Tank, 550 Water/Chem Bowser, Supercis 800, Kotte FRC 65, Amazone UX5201 Super), pipe leakage and one
reach rule and coupler arc standard for every coupler.

Existing savegames load unchanged. New features that change play are switchable in the SPS settings.

## Added

### Pressure and vacuum
- **Vacuum tankers**: a vacuum tanker holds its vacuum, and the flow follows it. A tanker that draws air
  gets the air-suck rule. Opening the lid vents the tank.
- **High-volume pump (HVP) line suction** and **back pressure when spreading**: the spread rate ramps
  with the pump's pressure.
- **A free pipe end held in a pit's slurry** is a source: the pipe pulls from the pit.
- **Pressure gauges** on the Supercis 800 (display dials) and the pump / discharge gauges on the
  Kaweco Profi 2.
- A slurry pipe always comes off when pulled, valves stay as they were.

### Pipe leakage and dirt (settings)
- **Pipe leakage**: a pipe end lying open on the ground leaks, with a puddle that grows and dries,
  and a visible stream. Store and 80 mm fitting leaks too.
- **Pipe dirt** and **Pipe dirt speed** settings.
- A covered tanker can be filled and emptied through a coupling with the cover shut.
- Pipe **fill / flow / discharge sounds**.
- A base-game liquid manure buying station can also **buy** slurry from you (sell price scale).

### Chemical mixing and washout (Chem Mixing on)
- **Concentrates**: Soil & Fertilizer products sold as pallets become concentrate; a sprayer keeps a
  chemical + water mix, and the mix strength follows through every tank, pipe, discharge and onto the
  field (bands, scorch and residue damage with Soil & Fertilizer / Precision Farming).
- **Chem panel** with the mix, the rinse tank and the pipe target. Prices of concentrates are scaled.
- **Washout**: Left Ctrl + W washes out a dirty sprayer in stages (tank wash with sounds, boom spray with
  puddles and nozzle effects, final wash, empty). A different chemical needs a washout first. The
  number of rinses is a setting.
- **Washout station** (placeable, shop): paid clean water in, dirty water back down the pipe and gone,
  two handles on the station. The valve is **Automatic** or **By hand** (settings row).
- Wash out works on foot at the sprayer's control point.

### Vehicles
- **MKS 8 Dual Tank SPS**: a two-tank tanker. Ball valve, Y direction, Shift+Y tank choice, a tank panel,
  rear door, tube-stowed pipes that slide out, caps, and a **cage holder**.
- **550 Water/Chem Bowser**: its own three pipes (suction, wash, small hose), water-course intake,
  pull-cord generator, wash lance, chem bowl that dilutes chemicals in transfers. Works in both pipe modes.
- **Supercis 800 SPS**, **Kotte FRC 65 SPS** (pipe holders), **Amazone UX5201 Super SPS** (chem station:
  door, bowl, lever), **Kaweco Profi 2 SPS** (front fill pipe option).

### Water cages
- **Small** cage (80 mm water / milk pipes, either end) and **large** cage (male end of a slurry pipe)
  in the shop. A pipe end lying in a lake, river, pond or build-menu water course now **draws water only
  through a cage**; discharge and the gravity return need none. Without one the player sees "Fit a water
  cage on the pipe end first".
- A cage can be hung on a vehicle's cage holder node (MKS 8 rear, behind the door).

### Couplers, hoses and the shop
- **One reach rule** for every coupler: connect within the hose's reach and with the arcs overlapping,
  drop at reach + 0.5 m. 80 mm = 5.0 m.
- **One arc standard** (2.5 m deep, 3.0 m wide, level) for every shipped coupler, and the same
  standard applied at run time to the couplers of other mods.
- **Soil & Fertilizer IBCs** connect again: the coupler kit is added to any tank that lacks it.
- Pipes and cages in the Slurry Tools section of the shop.

### Settings menu
- All SPS rows are in one place (General settings): General, Slurry, Spreader HUD and Sprayers blocks;
  masters grey out their rows.

## Fixed
- **Washout boom spray did not show** when the tank was dirty with a Soil & Fertilizer chemical or one
  of its tank mixes: the nozzles now use the liquid fertiliser spray look for those.
- **Picking up a hung cage or a stowed tube pipe** at the MKS 8 rear node: what you look at is taken,
  not the tanker hull.
- **Hatch-store couplings** could never be deployed in pipe mode (earlier build).
- **Washout station handle** follows the valve with no pipe connected.
- Wash sounds and nozzle effects only run with water in the main tank.
- The SPS Profi 2 coupler is never gated; only the front fill receiver follows the Front fill pipe option.
- The 80 mm hose reach is the same for the connect prompt and the drop check.

## Known issues
- On the MKS 8, Unload at a washout station is refused.

## Notes
- A dedicated server admin sets "Physical pipes" in the SPS settings.
- Debug output is off; `spsDebug Info on` turns the routine pipe lines on.
