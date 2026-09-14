# Properties and color scales

Property maps add physicochemical context to a geometric pore or tunnel. They do not
convert a radius profile into a permeability calculation. Report the scale,
lining definition, smoothing, and analysis mode with any property-colored
figure.

## Available properties

<p align="center"><img src="images/render_hydrophobicity.png" alt="3D pore surface colored by residue hydrophobicity" width="720"></p>

| Interface label | Quantity and source | Important restriction |
|---|---|---|
| Kyte–Doolittle | Residue hydropathy | Residue-level average |
| Wimley–White (interface) | Interfacial hydrophobicity | Residue-level average; CHAP uses its own compatible variant |
| Kapcha–Rossky | Atomic hydrophobicity assignment | Tunnel mode uses atoms in the tunnel lining |
| Fauchère–Pliska | Residue lipophilicity | Distinct from MOLE logP |
| Formal charge | Assigned residue formal charge | Not a pH-dependent electrostatics calculation |
| Grantham polarity | Residue polarity | Sequential scale |
| MOLE hydropathy, hydrophobicity, polarity, charge | MOLE lining-property tables | Distinct from similarly named pore scales |
| MOLE logP, logD, logS | MOLE residue lookup values | Do not substitute one for another |
| MOLE mutability | MOLE residue mutability lookup | Higher values indicate the table's variable end |
| MOLE ionizable | Count/indicator from MOLE residue assignments | Not a protonation-state calculation |
| Electrostatic potential | Relative potential in kcal mol⁻¹ e⁻¹ | Requires appropriate charge data |
| Water G(z) | Water free energy derived from density | Requires Hydration Compute |
| Water density | Water depletion field | Requires Hydration Compute |

The Pore Profile **Fill** picker also offers `watermelon (radius)`: the fill
is the profile's own radius in the ten watermelon bands. The Mean Profile fill
has its own **Fill by** picker in the Mean Profile gear (watermelon or a
property), independent of the 3D surface's property picker under the plot,
which appears only while the mean surface is shown and colored by property.
Both tunnel fills use the bands whenever the tunnel's color mode is watermelon.

Tunnel mode offers Kyte–Doolittle, Wimley–White, Kapcha–Rossky,
Fauchère–Pliska, the MOLE properties in the table, and electrostatic potential.
In tunnel mode the potential is evaluated at the route's own points rather than
per lining residue, from the same formal charges pore mode uses, and is coloured
on the frame's own value spread. Hydration-derived properties are pore-only.

### Non-protein residues in the selection

The residue-level scales (Kyte–Doolittle, Wimley–White, Fauchère–Pliska,
Grantham polarity, and the MOLE tables) are amino-acid tables. A selected
residue that is not in them - a glycan, lipid, ligand, or cap - takes a
neutral placeholder value and is announced once per residue name in the
console; no published value exists for such residues on these scales, so
their colour is a placeholder, not a measurement.

Two schemes remain fully meaningful for heteroatoms: **Kapcha–Rossky** is
atom-level - with partial charges loaded (PSF/topology) it applies the
original |q| < 0.25 e rule to every atom directly, glycans included - and the
**water schemes** (G(z), density) are computed from the water itself. Prefer
those, or plain radius, when a glycan or lipid lines the region of interest.
**Formal charge** is also correct for neutral sugars (zero).

The full numerical ranges and primary references are listed in
[References](references.md). Nonstandard residues absent from the MOLE lookup
table receive a neutral fallback and generate a warning; assign their chemistry
outside the plugin or interpret the aggregate cautiously.

## How a slice receives a value

For residue properties, VMDPathFinder identifies lining residues within the selected
surface-distance shell, optionally applies the pore-facing filter, assigns each
residue its table value, and smooths the result along the route. Pore and tunnel
lining definitions differ, so aggregate values should not be compared across
modes as if they were generated from the same samples.

Two independent distance controls have the same default:

- **Pore lining threshold** (default 3 Å) classifies lining residues for the
  lining/facing displays and residue-property averaging.
- **Bottleneck shell** (default 3 Å) selects residues for the constriction
  report.

Changing one does not change the other.

## Where properties appear

The 3D surface, Pore Profile **Fill**, and Mean Profile synchronize a selected
property where that property is available. In Pore mode, **Over Time** has its
own selector and **Compute** step; in Tunnel mode it uses the selected route's
property.

After Hydration has been computed, Pore Profile Fill and Mean Profile offer
trajectory-average **Water G(z)** and **Water density**. The 3D surface instead
offers current-frame **Water density** when per-frame hydration data exist.

## Unrolled map layers

<p align="center"><img src="images/unrolled_map.png" alt="Unrolled 2D pore-wall map" width="720"></p>

**Unrolled** maps use wall distance, oxygen/nitrogen identity, residue number,
chain (or segment), and polarity. They also offer Kyte–Doolittle,
Wimley–White, Fauchère–Pliska, formal charge, Grantham polarity, MOLE logP,
logD, logS, mutability, and ionizable assignment. Polarity is its own wall
classification, not formal charge.

After a Connolly run, **Connolly reach** reports the maximum radial extent of
the Connolly surface in each axial and angular map cell. Large patches identify
lateral expansions that can be examined as individual openings with the
`pore_lobes` surface color. This differs from **Wall distance**, which reports
the nearest pore-wall atom along a ray from the axis.

## Reading colors

Read the legend, not color alone. Most scales have fixed limits; tunnel charge,
ionizable counts, and electrostatic potential use data-dependent ranges.
Zero-centred scales place zero in the middle; other scales run from low to high.
Water density is shown as depletion, `1 - ρ/ρ_bulk`: positive values are below
bulk density and negative values are above it.
