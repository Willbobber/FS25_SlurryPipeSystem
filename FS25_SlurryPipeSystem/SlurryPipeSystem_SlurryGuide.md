# Slurry Pipe System — Managing Your Slurry

A practical guide to keeping a healthy slurry operation. This covers what makes slurry easy or hard to pump and spread, and what you need to do to keep things flowing and avoid blockages.

If you just want the short version, skip to **The Routine** at the bottom.

---

## Two things decide how good your slurry is

Your slurry is judged on two separate qualities. They are not the same thing, and they are fixed in different ways.

**Thickness (how concentrated it is).**
This is how much solid matter is packed into the slurry. Thin, watery slurry pumps and spreads fast. Thick slurry moves slowly, and if it gets thick enough it stops flowing altogether — the pump simply can't shift it. Thickness is a property of the slurry itself.

**Crust (how settled and lumpy it is).**
When a store sits without being mixed, the solids slowly settle out and a crust forms on top. Crust is what causes **blockages** when you spread. It builds up gradually the longer a store is left alone, and you'll see it appear on the surface of the store over time. Unlike thickness, crust isn't really about concentration — it's about neglect.

A store can be thin but crusted (left sitting too long), or freshly mixed but genuinely too thick (too little water in it). They're different problems with different fixes.

---

## What each one does to you

**Thick slurry** slows down every part of the operation — filling the tanker, pumping it back out, and spreading it. The thicker it is, the slower it goes. Past a certain point it won't flow at all, and you'll be sat there with a full tank that won't empty.

**Crusted slurry** is the blockage risk. When you load from a crusted store, your tanker carries that crust with it into the field. While you're spreading, crusted slurry can clog your outlets or your macerator and stop the spread. Clean, well-mixed slurry almost never blocks — there's only ever a tiny random chance from the odd bit of debris. Crusted slurry blocks often.

Thickness also makes blockages a bit worse on top of crust, so thick **and** crusted is the worst combination you can load.

---

## How to fix each problem

### Stirring (mixing) — fixes crust

Run a PTO agitator with its tip submerged in the store and it will mix the slurry, breaking down the crust and re-suspending the settled solids back into the body of the slurry. This is the single most important maintenance job. A well-mixed store carries almost no blockage risk.

Mixing takes time — you can't fix a badly neglected store in a few seconds. Leave the agitator running and it works through the crust steadily.

**Important limit:** mixing only fixes settling and crust. It **cannot** thin out slurry that is genuinely too concentrated. If your slurry is too thick on its own — too little water in it — no amount of stirring will help. For that, you need water.

**Mix before you pump.** Pumping from a *settled* store draws the liquid preferentially and concentrates what's left behind — the longer a store has sat, the thicker the remainder gets as you empty it. A freshly filled or **fully mixed** store pumps out honestly: dry matter leaves in proportion, and the store drains completely to zero. So a stir before a big pump-out isn't just about crust — it's the difference between emptying the store and slowly cooking down a thick heel you'll need water to shift later. The on-screen warnings name the actual fix for each state: still thickening, thickening (add water), needs mixing, or too thick.

### Water — fixes thickness

Adding water dilutes the slurry and brings the concentration down, making it pump and spread freely again. Once slurry is well mixed, water — or the separator described below — is the fix for slurry that's still too thick.

You don't store water separately in a slurry store — any water you pipe or fill-arm in is blended straight into the slurry as it enters. SPS tankers can also draw water from lakes and ponds with a fill arm if you need a source out in the field.

So the rule of thumb:
- **Lumpy / crusted / won't spread cleanly →** mix it.
- **Still too thick after mixing / won't pump →** add water.

### Separating — strips the solids out entirely

If you'd rather remove the solids than dilute them, pipe your slurry through a **screw-press
separator** (the Börger bunker separator in the store, under the SPS brand). It pulls slurry
in through one coupler, presses the dry matter out as stackable solid manure that drops onto
its bunker heap, and returns the thinner liquid fraction out through the other coupler.

- **Walk up to the control panel** to start and stop it, and to cycle the **screw tightness**
  (0–100% in five steps). Tighter captures more dry matter per pass but slows the
  throughput; looser runs faster and captures less.
- **One pass makes it thinner, not thin.** A screw press only captures a fraction of the
  dry matter each time through. Pipe the liquid fraction back round for another pass —
  recirculating through the separator gets the slurry progressively thinner, no water needed.
- The pressed solids are normal manure — load the heap and spread it like any muck.
- The separator **halts itself** when the incoming slurry has nothing left worth pressing,
  or when the bunker heap backs up — clear the heap and it resumes.
- Running it can cost money per hour, depending on the machine.

So you now have two ways to deal with thick slurry: **water** blends it thinner in the
store, the **separator** physically removes the solids and hands you manure as a bonus.

---

## Loading: you inherit the store's condition

When you fill your tanker, it takes on the condition of the store you loaded from. Load from a freshly mixed store and your tanker carries clean slurry into the field — minimal blockages. Load from a crusted, neglected store and you're carrying that crust with you, and you'll be hopping out to clear blockages all afternoon.

**This is why you mix before you load, not after.** The state of the store at the moment you fill is what you take with you.

---

## When a blockage happens

If you do clog up mid-field, the spread stops. Get out on foot, walk up to the blocked spreader, and use the activate prompt to clear it. Then you're spreading again. If you keep blocking, the slurry you loaded was crusted — go back and mix the store properly before your next load.

---

## Reading the HUD

The spreader readout shows your fill level along with the slurry's condition — thickness, crust, blockage risk and pump state. If the risk reading is high before you head out, that's your cue to mix the store first. You can resize, reposition or turn off parts of this readout in the mod settings.

The **pump panel** (PTO pump and the tower mixer's pump) shows **Status: PUMPING** in green, or
"stopped" and the reason (valve closed, pump or blades off, no pipe, receiving valve closed,
source empty, destination full, too thick), the rate in l/s, the litres pumped, the thickness of
what you are pumping and the flow speed it allows, and where it comes from and goes to. The
tower mixer adds **Blades: SPINNING** while its blades turn.

When an outlet or the macerator is blocked, the readout adds a red **"Blocked — Clear at the outlet"** row. That is not a random red HUD: get out, pump off, valve closed, and clear it at the outlet on foot. Refilling never clears it.

---

## Controls

Default keys in the cab (all rebindable in Options > Controls):

| Key | Does |
|-----|------|
| **B** | Pump / PTO on-off |
| **X** | Open / close the flow valve |
| **Y** | Switch fill / discharge direction (only while the valve is closed) |
| **Z** | Spreader valve open / close |
| **T** / **B** | Fixed lagoon agitator (tractor backed up to it): connect-disconnect / PTO on-off |
| **X** | Sprayer: open / close the cover while no pipe is connected |
| Hold **R** | Replace a snapped shear bolt (on foot, at the pump) |
| **Left Alt + B** | Tower mixer (pump mixer): open / close its pump valve |
| **R** | Physical pipes: open / close the valve at a coupler or water / milk fitting (on foot) |
| Left / right mouse | Physical pipes: pick up, connect, unplug (see `SPS_README_06_Physical_Pipes.md`) |
| Mouse wheel or **;** / **'** | Physical pipes: choose the pipe rack when stowing |
| Middle mouse | Move or resize the spreader HUD |

The pump, valve and direction rows appear in the F1 help box for the tanker the tractor has selected (G). If another implement in the chain uses the same key, the game keeps only one of them; SPS then writes one `[SPS] WARNING` line in `log.txt` naming the clashing action. Rebind one of them, or re-select the tanker. If you played SPS before mid-2026 your profile may still hold the old layout (valve on Z), which is fine, just different from the list above.

---

## Reporting a problem

Send `log.txt` from your profile folder. For a multiplayer problem, first open the console (`~`) on the machine showing the wrong prompt and run `spsMpState`, which writes the full coupling state to the log. `spsDebug` lists trace channels the author may ask you to switch on; they are remembered until you run `spsDebug all off`.

---

## Turning the system off

If you'd rather not deal with any of this, the whole realism system — thickness, crust, blockages, and pipe-length flow loss — can be switched off in the mod's settings menu. There are also individual toggles if you want, say, blockages off but thickness still on.

---

## The Routine (the short version)

1. **Mix your store regularly**, and always give it a stir before loading. This is what keeps blockages away.
2. **Don't let a store sit unmixed for seasons** — crust builds up across the year and you'll pay for it in slow flow and constant blockages.
3. **Load from a freshly mixed store** so your tanker carries clean slurry.
4. **If it's still too thick to pump after mixing, add water** — or run it through a
   separator to strip the solids out instead.
5. **Check the HUD risk reading** before you set off; mix again if it's high.
6. **Blocked in the field?** Hop out, clear it at the spreader, and mix the store better next time.

Mix well, water when needed, load clean — and the slurry flows.
