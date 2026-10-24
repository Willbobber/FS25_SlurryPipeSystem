# Slurry Pipe System (SPS) — Adding Water Sources to a Map

This guide is for **map makers** who want SPS tankers to draw water from a map's lakes,
ponds, rivers or canals using their fill arm (water intake).

**You do this entirely in your own map's i3d** by adding a node tree called
`SPS_waterNodes`. You do not edit the SPS mod. SPS scans the map for this tree on load and
builds the water sources automatically.

---

## 0. Players: draw your own water course (no editor needed)

If a map has no `SPS_waterNodes`, you can mark the water yourself in the game:

1. Open the building screen, pick **Landscaping > SPS Water > Draw water course**.
2. **Click on the water first** - that sets the water level of the course.
3. Click markers round the shore, on the bank or on the water. Right click removes the last
   marker, Esc cancels the whole ring.
4. Click the **first marker** again to close the ring, name it (or keep "Water course N") and
   confirm. The fill arm and the physical pipes can draw water from it at once.
5. **Remove water course** in the same tab shows your courses as rings; click one to remove it.

Courses are saved **per map** in your profile folder
(`modSettings/FS25_SlurryPipeSystem/waterCourses/<mapId>.xml`), not in the savegame, so a new
career on the same map already has them. Map-maker water areas from `SPS_waterNodes` are
never shown or removable here; both kinds work side by side.

**Multiplayer:** the host (or the dedicated server) keeps the courses and the file. Everyone
who joins gets them on arrival, and any player with the farm's landscaping permission can draw
or remove a course for the whole server. Your own file on your PC is not touched while you are
joined - it is for the games you host yourself.

Console: `spsWaterCourses` lists the courses, `spsWaterCourseRemove <id>` removes one.

---

## 1. How water intake works

A tanker with an **open-pit fill arm** (see the tanker guide), when it is not connected to any
other source, checks whether its arm's centre node is over a water plane:

- **Fill (Load):** the centre node must be **below** the water surface (submerged).
- **Discharge:** the centre node must be **above** the water surface.

If so, SPS creates an **infinite** water source (never depletes) of fill type `WATER`, and the
arm loads/empties water. There is no per-tanker or per-placeable water config — the map
provides the water planes, the tanker uses its normal fill arm.

So your job as a mapper is just to mark where the water is and how high its surface sits.

---

## 2. The node tree — `SPS_waterNodes`

Add this transform group **anywhere in your map's i3d scenegraph** — under a `water`
group, a `misc` group, wherever suits your map's organisation. SPS deep-searches the
map's node tree at load, so the only requirement is the exact name `SPS_waterNodes`.

Alternatively, if you prefer to keep the nodes out of your map i3d entirely, export
them as a standalone file named exactly `SPS_waterNodes.i3d` and place it in the
**root of your map mod folder**. SPS looks for this file automatically — no manifest,
no SPS edit, nothing to register.

```
yourMap (map i3d)
└── water (or any group, any depth)
    └── SPS_waterNodes                  <- exact name, anywhere in the map tree
    ├── lakeNorth                       <- one node per water body (the "plane")
    │   ├── lakeNorth_01                <- a "quad group" (name ends with _<digits>)
    │   │   ├── node1                   <- corner 1
    │   │   ├── node2                   <- corner 2
    │   │   ├── node3                   <- corner 3
    │   │   └── node4                   <- corner 4
    │   ├── lakeNorth_02                <- another quad covering more of the lake
    │   │   ├── node1 ... node4
    │   └── ...
    ├── pondEast
    │   └── pondEast_01 ( node1..node4 )
    ├── lakeSouth
    │   └── shoreline                   <- a CLOSED SPLINE traced round the water (any name)
    └── canal
        └── canal_01 ( node1..node4 )
```

There are two ways to mark the footprint of a water body, and you can mix them under one
plane node:

- **Spline loop (quickest):** draw one closed spline round the shoreline. Best for lakes,
  ponds and irregular shapes.
- **Quad groups:** four corner nodes per patch. Best for a straight canal or a quick
  rectangle, and the original method — existing maps keep working unchanged.

### The rules, exactly as SPS reads them

**Plane node (water body):**
- Each direct child of `SPS_waterNodes` is one water body.
- **Its world Y is the water surface height.** Position the node at the water level. (Only Y
  matters for the surface; X/Z of this node are not used for the footprint.)
- The name is free (used only for logging).

**Spline loops:**
- Under a plane node, **any spline shape** is treated as a footprint. The name is free; SPS
  recognises it by type, not by name.
- Draw it as a **closed** spline that follows the shoreline (Giants Editor: Create → Spline,
  place the control points round the water, then tick *Closed* in the spline attributes).
  An open spline still loads, with a warning in the log, and SPS joins its two ends with a
  straight line, so close it unless that straight edge happens to be what you want.
- SPS samples the spline at roughly one point per metre (8 to 512 points per loop) at map
  load and uses the samples as a polygon. Only the **XZ** of the spline is used; its Y is
  ignored, the surface height comes from the plane node.
- Keep the loop a little inside the visible shoreline, the same as corner nodes, and do not
  let it cross itself.
- One loop per water body is the usual case. Several loops under one plane node are allowed
  (a point counts if it is inside any of them), and loops can sit alongside quad groups.

**Quad groups:**
- Under a plane node, each group whose **name ends with an underscore followed by digits**
  (`_01`, `_02`, …) is treated as a quad. They are found by a recursive search, so they may be
  nested if you like, as long as the name pattern matches.
- A water body needs **at least one** quad or spline loop. Use several quads to cover an
  irregular shape (or one spline loop instead) — a point counts as "in water" if it is inside
  **any** quad or loop of that body.

**Corner nodes:**
- Each quad group must contain **exactly four** children named `node1`, `node2`, `node3`,
  `node4`. Place them at the four corners of that patch of water.
- Their **XZ world positions** define the quad polygon (a horizontal point-in-polygon test).
  Their Y is not used — the surface height comes from the plane node, not the corners.
- Order them around the perimeter (1→2→3→4) so the quad is a sensible non-crossing shape.

If a quad group is missing any of `node1`–`node4` it is skipped with a warning; if a body
ends up with no valid quads it is dropped.

---

## 3. What you will see in the log

On a correctly set-up map:

```
[SPS WPM] Found SPS_waterNodes in map scenegraph
[SPS WPM] Spline loop 'shoreline': 312.5 m sampled into 312 vertices
[SPS WPM] Loaded water plane 'lakeNorth' with 2 quad(s) and 1 spline loop(s) at Y=12.40
[SPS WPM] Loaded N water plane(s)
```

An open spline adds `WARNING: Spline '...' is not closed`; a spline under 3 m is skipped.

If the tree is absent:

```
[SPS WPM] No SPS_waterNodes in map scenegraph, checking for external i3d...
[SPS WPM] No water nodes found (map-embedded or external) - water system disabled
```

The `Y=` value is the surface height SPS read from each plane node — check it matches your
actual water level.

---

## 4. Tips

- Keep quads reasonably convex and don't overlap them more than necessary; many small quads
  are fine and let you trace a winding river or an irregular lake edge.
- The surface Y is a single value per water body, so split bodies that sit at different
  heights (e.g. a stepped canal) into separate plane nodes, each at its own level.
- Put the corner nodes a little inside the visible shoreline so a tanker arm has to be
  genuinely over the water, not on the bank.
- Nothing about fill type or capacity needs setting — water is always `WATER` and infinite.
- A **paid** pool (a `buyingStation` placeable with an SPS `<fillPlane>`, placeables guide §9B)
  wins over a free `SPS_waterNodes` footprint drawn over the same water, so do not trace a
  free loop round a reservoir you mean to charge for.

---

## 5. Note on the external/manifest method (not for map makers)

SPS can also load water nodes from an i3d bundled **inside the SPS mod**
(`water/{mapFolder}/SPS_waterNodes.i3d`, matched to your map by title in
`water/spsWaterManifest.xml`). That path requires editing the SPS mod and is intended only
for shipping pre-made water nodes for maps the author cannot modify. **As a map maker, use the
map-embedded `SPS_waterNodes` tree above** — it lives in your own map, needs no SPS changes,
and will not cause multiplayer issues.

---

## 6. Checklist

1. Add a transform group named exactly `SPS_waterNodes` anywhere in your map's i3d —
   OR ship a standalone `SPS_waterNodes.i3d` in the root of your map mod folder.
2. Add one child node per water body, positioned at the **water surface height** (its Y).
3. Under each, EITHER draw one closed spline round the shoreline, OR add one or more quad
   groups named `…_01`, `…_02`, … (or both).
4. For quads, give each exactly four corner nodes `node1`–`node4` at the patch corners (XZ).
   For splines, make sure *Closed* is ticked.
5. Load the map and confirm `[SPS WPM] Loaded N water plane(s)` with the right `Y=` values.
6. Test with an open-pit fill-arm tanker: lower the arm into the water and it should load
   `WATER`.
