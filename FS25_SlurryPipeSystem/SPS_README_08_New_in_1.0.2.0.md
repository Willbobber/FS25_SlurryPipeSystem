# SPS README 08 — New in 1.0.2.0

What 1.0.2.0 added that READMEs 01–07 do not cover. Water cages, the cage holder and the pipe dirt / leakage
settings are in README 06. Chem mixing, washout and the washout station are in README 02 and 03.

## 1. The MKS 8 Dual Tank — a two-tank tanker on the liquid lanes

`vehicles/mks8_dualTank/mks8DualTank.xml` is a complete example of a **vehicle with `<liquidPipeSystem>`**:
one fitting behind a rear door that routes to the tank you pick.

**Player controls (at the control node behind the door):**

| Key | What it does |
|---|---|
| N | Open / close the rear door (`loadAnimation`) |
| R at the fitting | Ball valve (library `valveAnimation="4"`, the same handle as the Kotte TSA) |
| B | Starts the engine (sound only, no visible engine), then runs the flow |
| Y | Direction: load / unload |
| Shift + Y | Tank: front / rear. The tank list panel shows both |

The books (chemical, water, strength) are kept per tank. The side **tubes** each hold one short pipe: only the
start end shows, grab it and walk back, and the pipe slides out of the tube. A fitted or a loose cap shows
depending on whether a pipe is in.

**XML (inside `<liquidPipeSystem>`):**
```xml
<liquidPipeCouplings>
    <liquidPipeCoupling id="1" mountNodeName="SPS_liquidPipeCoupler01" maxPipeLength="7.5" fillUnitIndex="1" valveAnimation="4">
        <tank id="1" fillUnitIndex="1" name="$l10n_front" tankTopNodeName="fullNode01" tankBottomNodeName="emptyNode01"/>
        <tank id="2" fillUnitIndex="2" name="$l10n_rear"  tankTopNodeName="fullNode02" tankBottomNodeName="emptyNode02"/>
    </liquidPipeCoupling>
</liquidPipeCouplings>
<loadAnimation name="rearDoor" doorCloseAuto="false" textOpen="..." textClose="..."/>
<liquidPumpControls><liquidPumpControl id="1" nodeName="SPS_liquidControlNode" radius="1.5"/></liquidPumpControls>
<generator pulls="2" pullSpeed="1.5" pullPause="0.4"> <sounds>...</sounds> </generator>
```
- `<tank>` children make one fitting route to several fill units (`fillUnitIndex`). `tankTopNodeName` /
  `tankBottomNodeName` are the full / empty marks used for the gravity level.
- `<extraFillTypes categories="SPRAYER" fillUnitIndex="1"/>` adds the sprayer liquids to a fill unit, so the tank can
  carry what a sprayer carries.
- `<generator>` is an engine with sound only: B pulls the cord `pulls` times, then the engine runs.
- The **tube pipe slots** are `<pipeHolders>` placements with `tube="true"`, and `stowedShow` / `stowedHide` for the cap
  nodes:
```xml
<pipeHolder id="1" nodeName="SPS_pipeHolder01" radius="1.2">
    <placement node="waterPipe" pipes="WATER MILK" tube="true" stowedShow="tubeCapLeftFitted" stowedHide="tubeCapLeftLoose"/>
</pipeHolder>
```
- `<cageHolder .../>` (README 06) goes in the same `<pipeHolders>`. `requiresAnimation="rearDoor"` means the cage can be
  hung and taken only while the door is open.

## 2. Couplers: one reach rule and one arc standard

- **Reach (original pipe mode):** two couplers connect while their mount nodes are within the hose's reach and their
  arcs overlap. 80 mm water / milk / sprayer hose 5.0 m, the 550 bowser's small hose 7.4 m, slurry couplers 5.9 m.
  A connected hose is dropped 0.5 m beyond that reach. Physical pipes keep their own rule.
- **Arc standard:** every SPS coupler arc is a level triangle 2.5 m deep and 3.0 m wide. SPS re-lays the arc of every
  coupling of every mod at run time (only your pointing direction is read) and logs `[SPS ARC] ... arc re-laid`.
  Mods need no change.

## 3. Soil & Fertilizer tanks

Any pallet tank derived from a listed Soil & Fertilizer tank gets the SPS coupler kit when it registers
(`[SPS IBC] coupler kit linked into ...`), so water pipes and the sprayer hose connect to them. No config is needed.

## 4. Settings summary

All SPS rows are under **General settings**, in four blocks: General, Slurry, Spreader HUD, Sprayers. A master row greys
out the rows that depend on it, and in multiplayer only the admin changes them. New rows in 1.0.2.0: Pipe dirt, Pipe dirt
speed, Pipe leakage, Chem Mixing and its rinse count, Washout station valve (Automatic / By hand), and the Profi 2
front fill pipe option.

## 5. Console

- `spsPipeDirt [0..1]` sets the dirt of every physical pipe (host); with no argument it reports.
- `spsChemPallets` lists the concentrate twins SPS made for pallets sold by other mods.
- `spsDebug` lists the debug channels; every channel is off in the release.
