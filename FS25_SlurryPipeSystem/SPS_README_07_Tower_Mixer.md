# SPS README 07 — SPS Tower Mixer and pump mixers

Slurry Pipe System 1.0.1.8. The **SPS Tower Mixer** is a three-point-mounted lagoon mixer on
a tower, with an optional pump. §1–§5 are for players; §6 shows how any vehicle can be made
an SPS mixer or pump mixer.

---

## 1. Buying

Shop, Slurry Tanks category, from 18,500 (the power it needs is shown in the shop).

| Option | Choices |
|--------|---------|
| Design | **Basic mixer** (mixes only) or **Pump mixer** (+4,500: mixes and pumps) |
| Pipe extension | No / **Yes** (+250, pump mixer only): a swinging pipe on the boom with its own coupler |

## 2. Parts and controls

The mixer has two control groups (switch with the game's control-group key):

| Group | Part | Keys (game defaults, rebindable) |
|-------|------|------|
| 1 | Left leg | J / N |
| 1 | Right leg | K / M |
| 2 | Telescopic extension (tower height) | Shift + K / Shift + M |
| 2 | Tower rotation | Shift + Ctrl + K / Shift + Ctrl + M |
| 2 | Boom section 1 | K / M |
| 2 | Boom section 2 | J / N |
| 2 | Boom section 3 (blade end) | Shift + J / Shift + N |

- **Legs** work at any time, folded or not. Their feet level themselves on the ground; lower
  them to take the weight (they lift the tractor's rear when pushed down).
- **Platform:** walk up to the mixer and enter it to work it from the levers. The driver
  stands at the levers; each lever moves with its part. Cameras: inside and outside. It is
  not in the Tab rotation.
- **B** turns the mixer on: the blades spin.
- **X** folds / unfolds (the boom between transport and work).

## 3. Attaching and detaching

- **Detach:** the boom swings round, the ladders open, and the legs lower so the mixer
  stands on them; only then does it let go of the tractor. It runs at the fold's speed.
- **Attach:** the same in reverse. The legs lift first, then the boom folds for transport.
- A mixer bought from the shop stands on its legs in this parked pose. Its pose, folded or
  worked, is kept across save and reload.

## 4. Mixing

Lower the blade end into a lagoon or pit (below the surface) and turn the mixer on (B).
It mixes the crust and the settled layer like any SPS agitator, and only while the blades
turn. See the Slurry Guide for what mixing does.

## 5. Pumping (pump mixer)

The pump mixer pumps slurry **out** of the store its blades stand in, never into it.

1. Connect a pipe from the mixer's coupler to a tanker or another store. Without the
   extension the coupler is on the tower; with the extension it is the one on the pipe
   extension (the tower coupler is then out of use). The coupler is hydraulic and takes a
   **female** pipe end.
2. Turn the mixer on (B), blades in the slurry.
3. Open the mixer's valve: **Left Alt + B** (SPS pump mixer valve). Close it the same way.
4. A tanker's own valve must be open too; closing it stops the pump.

The pump panel shows **Blades: SPINNING** (green) while the blades turn, **Status:
PUMPING** or why it has stopped, the rate in l/s, the litres pumped, the slurry's thickness
and the flow speed it allows, and FROM / TO with their levels. The mixer's valve state is
saved with the game.

## 6. For modders: mixers and pump mixers

All inside the vehicle's `<slurryPipeSystem>` block (README 01 §1):

```xml
<slurryPipeSystem agitatorOnly="true">
    <agitator tipNode="SPS_agitatorTip" crustMix="1.0" requiresTurnedOn="true"/>
    <pumpMixer enabled="true"/>
    <flow litersPerSecond="800"/>
    <pipeCouplings>
        <pipeCoupling id="1" mountNodeName="SPS_pipeCoupler01" valveType="HYDRAULIC"
                      maxPipeLength="4.0" connector="female"
                      configType="design" cylinderedConfigIndex="1"
                      configType2="design2" configIndex2="0"/>
        <pipeCoupling id="2" mountNodeName="SPS_pipeCoupler02" valveType="HYDRAULIC"
                      maxPipeLength="4.0" connector="female"
                      configType="design2" cylinderedConfigIndex="1"/>
    </pipeCouplings>
</slurryPipeSystem>
```

| Key | Meaning |
|-----|---------|
| `agitator#requiresTurnedOn` | Default `false` (mixes whenever the PTO is connected). `true` = mixes only while the vehicle is turned on (TurnOnVehicle). Use it for a mixer that is not driven through a PTO shaft. |
| `pumpMixer#enabled` | Default `false`. `true` = the vehicle pumps from the store its agitator tip is submerged in into whatever its connected coupler leads to. Pull-out only; refuses a partner declared `flowDirection="FILL"` and the store it stands in. |
| `flow#litersPerSecond` | Pump rate. |
| `configType2` / `configIndex2` / `configMode2` | Optional second configuration gate on a coupling (README 01 §13). |

How a pump mixer runs:
- **Valve:** an `agitatorOnly` vehicle gets no SPS cab keys, so give its vehicle type the
  `FS25_SlurryPipeSystem.spsPumpMixerControl` specialization: it adds the **SPS pump mixer
  valve** action (Left Alt + B) on the vehicle itself. A `MANUAL` coupler's own valve (R at
  the coupler) also opens the pump.
- **Pumps while** the vehicle is turned on, the valve is open, the tip is below a store's
  surface, a coupler is connected and the receiving side's valve is open.
- **Thickness** slows and stops it like any SPS pump.
- **A parked pose** that differs from the folded transport pose: an attachable support
  animation (`<attachable><support animationName="..." delayedOnLoad="true"/>`) plus the
  `FS25_SlurryPipeSystem.spsParkPose` specialization, which keeps a saved pose across a
  reload (vanilla replays the support animation on load and would overwrite it).

The SPS Tower Mixer's own `vehicles/towerMixer/towerMixer.xml` is annotated throughout and
is the worked example: support legs with self-levelling feet (Cylindered `alignToWorldY`),
fold and park animations, levers as dashboards, a standing driver with hand IK targets.

Log lines with `spsDebug SPSM_Flow on`:

```
[SPS PUMPMIX] <vehicle>.xml: valve closed
[SPS PUMPMIX] <vehicle>.xml: blades off (turn the mixer on)
[SPS PUMPMIX] <vehicle>.xml: tip not submerged in a store
[SPS PUMPMIX] <vehicle>.xml: receiving coupler's valve is closed
```
