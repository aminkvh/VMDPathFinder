# Tunnel workflow

<p align="center"><img src="images/tunnel_3d_side.png" alt="Four tunnels found by the MOLE 2 engine, branching from a buried start point" width="480"></p>

Tunnel mode searches for routes from a buried site to the molecular surface.
Use it for internal cavities, enzyme access paths, and branched egress routes.
Use pore mode instead when one known channel axis is the object of study.

For a publication using Tunnel mode, cite MOLE 2. If route clustering is used,
also cite CAVER 3.0; both references are listed in
[References](references.md#tunnel-analysis).

## 1. Prepare and align

Load the structure or trajectory and choose the atoms that define the molecular
interior. Make periodic structures whole before analysis. For trajectory-wide
route tracking, **Align trajectory** is on by default. Keep it enabled and
choose a stable reference selection unless the trajectory is already aligned.
It fits the loaded frames before searching. Cross-frame clustering compares
route geometry; translation or rotation of an unaligned protein is otherwise
interpreted as route motion.

## 2. Define the origin

The start point should lie in the buried cavity of interest. Enter coordinates,
use a selection's centre of geometry (**COG**) or VMD's centre of rotation
(**COR**), or enable automatic origin detection. A poor origin can return no
routes or routes from the wrong cavity. The **⌖** button opens the on-screen
stick described under pore mode, step 3, to nudge the start point relative to
the current view.

The start point also accepts a **VMD selection** instead of coordinates - its
centre is re-evaluated in every frame, so a residue-defined origin (for example
`resname HEM`) follows the trajectory rather than staying where it was in frame
0. Several origins are given as a `;` list mixing both forms
(`73.8 26.5 26.6; resid 74 and chain A`); each is pinned separately and the
routes found from all of them are merged and de-duplicated, which is MOLE's
pinned multi-origin mode.

Custom exits restrict the search toward known surface regions, and take the same
three forms - coordinates, a selection, or a `;` list of them. A custom path is
defined by start and end points. **Use custom exits only** excludes other exit
candidates; use it only when the biological exit is independently known.

## 3. Set the search criteria

The six controls shown in the main panel are sufficient for most analyses:

| Control | Default | Meaning |
|---|---:|---|
| Probe | 3.0 Å | Probe used to define accessible void space |
| Interior | 1.25 Å | Minimum interior clearance |
| Origin radius | 5.0 Å | Region around the requested start used to seed origins |
| Minimum length | 0 Å | Reject routes shorter than this value |
| Bottleneck | 1.25 Å | Minimum accepted route radius |
| Cluster within frame | on | Merge geometrically similar routes in each frame |

The remaining search, exit, clustering, and rendering controls are available
from the **⚙** next to **MOLE parameters**. They are defined in the
[parameter reference](parameters.md#tunnel-search).
Change one class of parameters at a time and retain the settings with exported
results.

## 4. Run and inspect routes

<p align="center"><img src="images/tunnel_panel.png" alt="Tunnel panel: per-route bottleneck, length, hydrophobicity and charge, with the selected route profile" width="860"></p>

Select **Run Tunnel**. The route table reports:

| Column | Meaning |
|---|---|
| Show | Visibility |
| route/color | Tracked route identifier and display color |
| Rts | Number of route instances represented by the cluster |
| Bneck | Mean bottleneck radius |
| Len | Mean route length |
| Vol | Mean tube volume: a circular tube of the profile's own radius swept along the centreline, averaged over the frames the route appears in |
| Phob | MOLE length-weighted hydrophobicity mean |
| Chg | Mean net formal charge |
| Seen | Percentage of analysed frames containing the tracked route |

Sort by a column to inspect a different property; sorting does not alter route
identity. Expand a row for details. The row gear controls that route's
representation, color, material, and property. The global gear applies display
choices to routes without a per-route override.

Choose the **Surface mesher** in **File > Settings**. Property colouring uses
the same route surface as flat colouring. Lower the marching-cubes **grid**
for finer detail at greater cost.

Tunnel properties are Kyte–Doolittle, Wimley–White, Kapcha–Rossky,
Fauchère–Pliska, and the MOLE hydropathy, hydrophobicity, polarity, charge,
ionizable, logP, logD, logS, and mutability fields. See
[Properties](properties.md) for their definitions and citations.

First validate every candidate in 3D. A high-ranked route can still be an
irrelevant solvent-accessible groove, and a route that terminates incorrectly
usually indicates an origin, selection, exit, or interior-classification issue.

## 5. Cluster and track

**Cluster within frame** merges similar candidates produced in one structure.
The bottleneck-row clustering control sets its geometric cutoff.

Cross-frame clustering assigns a persistent route identity to matching routes
from aligned frames. It is controlled by maximum geometric deviation, maximum
ranks considered per frame, and the minimum **Seen** percentage (the **Seen ≥**
field on the Interior row of the panel). Restricting
ranks reduces cost but can hide a route that is poorly ranked in some frames.

Treat a low-Seen cluster cautiously in Mean Profile or trend plots: the average
may describe only a small subset of frames. Cross-frame identity is a geometric
classification, not proof that individual solvent molecules use the route.

## 6. Display lining residues

Select a route and open **Lining** to inspect protein residues and HET groups in
contact with it. **Show lining** creates a VMD representation; previous/next
controls step through routes. **Show all** displays the routes that remain after
the current filters. The 3D view draws only the listed routes: a route hidden below the floor is not drawn until you show it.

The lining window exports the selected route's lining data. The standard plot
tabs and CSV exports operate on the selected tracked route. The exported
`tunnel_N.csv` carries per-point `FreeRadius` and `BRadius` alongside the
radius, and the lining window reports the positive and negative residue counts
next to the net charge.

## 7. Available downstream analyses

Tunnel mode supports the radius/profile, Over Time, Mean Profile, Trends,
Histogram, property, lining, and Ion & Water views. Trends plots the selected
route's bottleneck radius, length or tube volume across the trajectory - pick
which with the **Metric** control beside the Export menu. Ion & Water measures the
selected route along itself, as distance along the route and distance from
it, so a bent tunnel plots as it is. Over Time, Mean Profile, Histogram and the
mean tube put each frame's route on one axis: distance along its own centreline
from the route's start point, the convention CAVER, MOLE and CHAP use. Mean
Profile, Histogram and the mean tube keep only the stretch that at least half
of the route-bearing frames reach (roughly the median route length); the title
counts the trimmed bins and the CSV exports still carry them, marked. This
floor is this plugin's own rule: CAVER paints uncovered stretches as unknown
and CHAP resamples every frame onto one grid. It does not provide
tunnel hydration, tunnel ellipse fitting, or pore-mode bulk-to-bulk permeation.
Water free-energy and density properties require a pore-mode hydration result.

## 8. Cavities

A **cavity** is an internal pocket; a tunnel is a route from a pocket to the
surface. MOLE identifies cavities from the structure before choosing origins.
Changing only the tunnel start point therefore need not change the cavity list.

**Cavities** lists what MOLE found in the displayed frame: type (*Cavity* when it
opens to the surface - a pocket - or *Void* when it is fully enclosed), this
frame's volume, the mean and spread over the frames the cavity was tracked
through, how often it was seen, its **max probe** (the largest sphere that fits
inside, not a ligand-fit test), depth, the **Boundary / Inner**
residue counts, and the **Start pt** the chosen rule below would search from.
Click a column header to sort. **Residues** opens the two residue sets - boundary
residues line the opening, inner residues are buried in it - with their MOLE
properties and a ready-made VMD selection string. **Lining** draws them on the
structure, boundary residues yellow and inner residues red, and follows the
frame you move to.

Every value that depends on the frame - volume, depth, the residue counts, the
rank and the start point - is re-read when you change frames, and the **Seen**
cell turns green when the pocket exists in the frame you are looking at and red
when it does not. The **⚙** at the end of each row sets that pocket's own
appearance: **Color by** takes either a flat colour or a property of its lining
residues, and the other two settings choose the material and whether it is drawn
as a surface or as the clearance spheres themselves.

The window initially shows pockets present in at least 25% of analysed frames.
Enable **Show all** to include less frequent pockets; the adjacent count shows
how many are listed. On a long trajectory that can be several hundred rows.

### Using a cavity to start a search

The hard part of a tunnel run is choosing the origin: a poor one returns no
routes, or routes from the wrong cavity. **Use as start** puts a cavity's start
point into the **Start point** field, so the next run searches from that pocket.

The natural loop is therefore: run once with **Auto-detect origins** (which needs
no start point and returns every cavity), inspect the list, pick the pocket you
care about, then re-run pinned to it.

Two rules are offered, and the status line always says which one was used:

| Rule | Point | Source |
|---|---|---|
| **deepest (MOLE)** | the cavity's deepest point by `DepthLength` | MOLE's own automatic origin, read from the engine rather than recomputed - the point it would have searched from itself |
| **largest sphere (CAVER)** | centre of the largest sphere that fits inside | the rule CAVER Analyst's *Create Starting Point* uses |

Under MD the more robust origin is often not a coordinate at all but a **VMD
selection** in the Start point field, which is re-evaluated every frame and so
follows the protein; the cavity's residue list is a good place to find one.

### Display

Ticking **Draw** meshes the cavity as a sphere-union surface on a **track of its
own**, separate from the routes, so route display settings and cavity ticks do
not disturb each other. **Solid** switches from transparent to opaque, and
**Spheres** draws the clearance spheres themselves instead of a surface over
them. **Show all** / **Hide all** apply to every cavity in the frame.

### What the numbers mean, and what they are not

*Id* is a **tracked** id: a pocket is intended to keep the same number, the same
colour and the same tick across frames, matched by centroid proximity.

Matching uses proximity to each track's running mean centre. Drifting pockets
can split into separate tracks; nearby pockets can exchange identities, and a
track can reconnect after an absence. Inspect mobile or crowded pockets before
reporting **Seen**, mean volume, or trends. **Rank here** is the volume rank in
the displayed frame, not the tracked identity; *absent* means no cavity was
assigned to that track in this frame.

Two caveats worth carrying into a figure caption:

- The drawn surface is a sphere-union approximation for visualization.
- **Volume** is MOLE's cavity volume: the sum of cavity tetrahedron volumes
  minus atomic van der Waals corner caps. It is not the enclosed volume of
  the displayed surface or the tube volume of a tunnel.

Cavities require the compiled engine; a run made with the pure-Tcl fallback has
none, and the window says so.
