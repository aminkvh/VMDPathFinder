# Export and import

Each plot tab provides an **Export** menu for the displayed figure and the data
used to draw it. Export the CSV together with a publication figure so processing
and units remain inspectable.

Figures are written directly as EPS. JPEG export uses Ghostscript or
ImageMagick when available and otherwise falls back to EPS; check the status
message and resulting extension.

## Plot exports

| Tab | Principal CSV content |
|---|---|
| Pore Profile | channel coordinate, radius, and selected fill property where applicable |
| Over Time | frame-by-position radius or property matrix |
| Mean Profile | coordinate, mean radius, standard deviation, contributing-frame count, and the drawn fill property; the header names the radius source |
| Trends | frame and selected metric |
| Histogram (radius summary) | axial-bin coordinate and uncapped mean/minimum/maximum radius aggregate; the header names the radius source |
| Hydration | coordinate, relative density, free energy, waters per frame, and available standard deviations; the per-frame views export their coordinate × frame matrix instead |
| Ion & Water | plotted occupancy or passage data and species metadata |

Additional exports include summary metrics, bottleneck residues, unrolled
pore-wall layers, and tunnel lining data. Inspect the CSV header: it is the
authoritative statement of columns and units for that export.

## Run identity

Pore runs receive a timestamp and a short settings hash; the run's folder is
named after them and `run_<id>.txt` and the Log record them. The hash covers
the settings, not the coordinates; the manifest records the structure's atom
count and radius of gyration.

## Connolly openings

The **Ion & Water > Openings** summary can be exported as a figure. Its CSV
command still exports the occupancy grid, not the per-opening summary.

With **Color** set to `pore_lobes`, each region gear exports the pore or one
lateral opening. The header gear exports all regions. The all-frame table
includes occurrence, dot count, neck, extension, axial position, and azimuth.
Axial position and azimuth describe the tracked opening's average location;
they are repeated across its present frames, not measured separately in each row.
An opening absent from a frame has `present=0` and blank measurement cells.
A neck capped at **ENDRAD** corresponds to `open` in the table: the calculated
clearance reaches or exceeds that limit, so the value is a lower bound.

## Filenames

VMDPathFinder suggests a descriptive filename for each export. Confirm the destination
before saving.

## Time column

With a positive **Time/frame**, every CSV with a `frame` column (pore and
tunnel Trends, cavity tables, bottleneck residues, tunnel passability, and
Ion & Water Count and Passage) adds `time_<unit>` beside it. Time is the
loaded frame index multiplied by the saved-frame interval; microseconds use
`time_us`.

CSVs whose columns are frame numbers (pore and tunnel Over Time, the
hydration per-frame map) record the interval in a comment header. The
single-frame Pore Profile and tunnel profile CSVs state the frame's time in
their header.

## Hydration export

In the Density, Free energy, and Hydrophobicity views the Hydration export
writes the mean density/free-energy profile. In the two per-frame views it
writes the plotted matrix: one row per channel coordinate, one column per
frame, cells `rho/rho_bulk` or `-kT ln(rho/rho_bulk)`. `channel_coord` is
HOLE's `coord` in both files, the same frame as the Pore Profile CSV's
`z_coordinate`.

## Tunnel lining

In tunnel mode, **Lining → Export** writes lining data for the selected route.
Standard plot exports remain CSV.

## Saved runs and import

When **Save results** is enabled, each frame has a result directory and the run
root contains provenance/manifest data. Use **File → Load Saved Analysis…** to restore a saved
HOLE or tunnel calculation without executing the engine again. Imported data
can be plotted and exported, but analyses that need the original trajectory
coordinates, such as ion tracking, also require the matching molecule and frames
to be loaded in VMD.
