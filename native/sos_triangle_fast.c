/* ==========================================================================
 *  NOTICE OF MODIFICATION (Apache License, Version 2.0, Section 4(b))
 *
 *  This file is a modified version of `sos_triangle.c` from the HOLE2 suite
 *  (https://github.com/osmart/hole2), which is licensed under the Apache
 *  License, Version 2.0. This file has been changed from the original.
 *
 *      Modified by: Amin Akbari Ahangar
 *      Date:        2026
 *      Changes:     performance optimisations + a raised capacity limit;
 *                   see CHANGES.md in this directory for the full list and
 *                   rationale. A copy of the Apache 2.0 License is in
 *                   ./LICENSE and attribution is in ./NOTICE.
 *
 *  The original copyright and attribution notices are retained below and in
 *  the program banner (per Apache 2.0 Section 4(c)).
 * ========================================================================== */

/* ========================================================================== */
/*  sos_triangle_fast.c  --  drop-in faster build of HOLE's sos_triangle       */
/*                                                                             */
/*  This is a MODIFIED COPY of the upstream sos_triangle.c (osmart/hole2).     */
/*  The original file is NOT touched. CLI, stdin/stdout format and numerical   */
/*  output are unchanged, so it is a drop-in replacement: compile it and point */
/*  the plugin's "sos_triangle" path (Settings dialog) at the resulting binary.*/
/*                                                                             */
/*  Speed changes (algorithmic only; identical output, checked against the stock binary):    */
/*    1. cull_coords(): O(N^2) duplicate-point scan -> spatial hash grid        */
/*       (cell = the 1e-3 dedup tolerance; a 3x3x3 neighbour scan keeps it      */
/*       exact). [minor in practice]                                           */
/*    2. check_point(): per-point O(tri_count) rescan -> O(1) "point_used[]"    */
/*       flag set in gen_triangle(). [minor in practice]                       */
/*    3. neighbour() (the dominant cost): hoist edge-invariant terms out of the */
/*       per-dot loop and drop pow(v,2)->v*v.                                   */
/*    4. destroy(): O(edges) list scan -> O(1) average via an edge hash keyed   */
/*       on the endpoint pair (creation-order chains preserve the first match). */
/*    5. neighbour() spatial grid: only dots within 3*|base| of vertex a can    */
/*       ever be chosen, so query a uniform grid instead of scanning all dots.  */
/*       Ties broken by smallest index to match the original exactly.          */
/*    5b. neighbour() grid CELL SIZE: size cells to the true 2-D surface dot    */
/*       spacing (~5x the median nearest-neighbour distance), not the bbox      */
/*       estimate cbrt(volume/N) which overestimates it ~5x for a surface and   */
/*       made the query walk thousands of out-of-radius dots (>99% rejected).   */
/*       ~2x on the triangulation phase; still identical (cell size is a   */
/*       pure acceleration parameter and a mis-estimate falls back to a scan).  */
/*    Net: ~13x at the plugin's default dot density, much more on large surfaces */
/*    (35x vs upstream at dot density 25 / ~42k triangles, and growing).        */
/*  Capacity change (separate from speed, easy to tune):                       */
/*    6. MAX_COORD raised so larger pores / higher dot densities triangulate   */
/*       instead of aborting with "Maximum number of polygons exceeded".       */
/*                                                                             */
/*  Everything else is verbatim from upstream. See README.md in this folder.   */
/* ========================================================================== */

/* now called sos_triangle ! */
/* surface: This  program is part of the HOLE suit of programs */
/* Copyright Guy M.P. Coates 1998-1999  */

/* Version 1.1 */
/* OSS 11.2000 introduce vmd option RENAME surface to sos_triangle */
/* OSS 11.2000 reorder_triangle function introduced to sort */
/*             out smoothed surface */
/* OSS 11.2000 introduce colour -1 dots for the ends - process these */
/*             in triangulation but cull these triangles before output */



/* This program generates a solid triangular mesh surface of a hole surface
in  various formats.
It uses a Step-by-step method of delaunay triangulation to calculate
the polygons:

Program reads a .sos file in ascii format from stdin  and writes
the surface file to  stdout */


#include <stdio.h>
#include <math.h>
#include <pthread.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include "xalloc.h"
#include "hole_io.h"
#ifdef VMDPATHFINDER_MULTICALL
int nm_search_main(int argc, char **argv);
int mesh_csg_main(int argc, char **argv);
int conn_lobes_main(int argc, char **argv);
#endif

/* Checked realloc. The growth sites below all used "p = realloc(p, n)", which
   on failure loses the original pointer AND leaves p NULL for the very next
   write - turning an allocation failure under memory pressure into a null
   dereference. Matches the OOM-and-exit idiom already used elsewhere in this
   file; exiting means the lost pointer is not a leak that matters. */
static void *xrealloc(void *p, size_t n, const char *what)
{
    void *q = realloc(p, n);
    if (!q && n) {
        fprintf(stderr, "\nOOM growing %s to %lu bytes\n", what, (unsigned long)n);
        free(p);
        exit(1);
    }
    return q;
}
#include <time.h>
#ifdef _OPENMP
#include <omp.h>
#endif

/***************************************************************/
/*   Change the value of MAX_COORD in the following line to    */
/*   increase the number of polygons that can be accomodated.  */
/*   Raised from the upstream 30000: with the O(N^2) passes     */
/*   below now linear, a larger ceiling is cheap and lets big   */
/*   pores / high dot densities triangulate instead of aborting.*/
/*   (Static arrays scale with this: ~ MAX_COORD * 240 bytes.)  */
/***************************************************************/

#define MAX_COORD 200000


/***************************************************************/
/*    Voodoo Angle: This angle defines the cutoff for the      */
/*    surface search: decrease this angle if the alogrithm     */
/*    forms closed surfaces where it shouldn't:                */
/***************************************************************/

#define VOODOO_ANGLE 102.0


/***************************************************************/
/*   You should not need to alter anything below this line!    */
/***************************************************************/

#define LINE_LEN 256  /* maximum line length */



/* Function declarations */

/* This structure is used for the tree of active edges */

  struct base_line {
    int a,b,c,z;   /* hold  coordinates of triangle and opposing vertex */ 
    
    /* flags to see if triangulation should continue from the edges */

    int base1_active,base2_active;
    
    /* pointers to daughter nodes */
    struct  base_line *base1;
    struct  base_line *base2;
  };

/* A linked list of edges: used to check if triangulation 
connects with previously triangulated area: contains pointers
to cross reference edges to entries in the tree */

struct edge_list {
    int x1,x2,*own_base,order;
    struct edge_list *next;
    struct edge_list *hnext;  /* speedup 4: next node in its edge-hash bucket */
  };


void vrml_out();
void molscript_out();
void read_cord(); /* reads in the dots coordinates */
void polygonize(); /* generates the polygons */
int calc_tri(struct base_line *node);  /* calcs the triangles */

/* --- calc_tri stack safety -------------------------------------------------
   calc_tri() is an advancing-front triangulator that RECURSES once per triangle
   it lays down (see the two self-calls at the end of it), so its recursion depth
   grows with the size of the surface, not with anything bounded. Measured on a
   real cloud: depth ~1.4x the dot count - 17978 dots -> 24671 frames,
   83638 dots -> 118407 frames. On the default 8 MB stack that runs out somewhere
   around 112000 dots and the process dies of SIGSEGV: no error message, no
   output file, and nothing the caller can distinguish from any other crash.
   (The plugin's dot budget keeps normal runs well below this, but a budget is a
   policy and this is a crash - it should not be the only thing standing between
   a big surface and a segfault.)

   Two independent guards, neither of which changes a single emitted triangle:
     1. the recursion runs on a dedicated thread with a large stack, so the depth
        it can reach is bounded by memory rather than by the 8 MB default;
     2. a depth counter that stops cleanly - the same "polygon cap" style exit
        gen_triangle() already uses - if even that is exhausted. A clean exit is
        recoverable: the caller sees an empty surface and retries at a lower dot
        density, where a SIGSEGV just looks like a broken program.
   -------------------------------------------------------------------------- */
#define CT_MAX_DEPTH   4000000L      /* ~30x the deepest measured legitimate run */
#define CT_STACK_BYTES (768UL*1024UL*1024UL)
extern long ct_depth;
void calc_tri_root(struct base_line *node);

int check_point(int current_point); /* checks a point to see if it exists */
/* finds nearest neighbour */
int neighbour (struct base_line *node,double angle,double *min_dist);

/* writes triangle & calculates colour */
int gen_triangle (struct base_line *node);
/* adds list of edge to tree and linked list of edges */
int add_edge(int x1, int x2,int *own_base,int order);
/* Searches and removes edges from list and tree is the edges 
connect with other triangles */
void destroy (int edge1,int edge2, int *active);
/* writes out the bulk of VRML file */
void vrml_end();
/* converts quanta colours into RGB colour space */
void colour_conv(int col_index,double *red_ptr, double *green_ptr, double *blue_ptr);
/* procedure to cull zero area triangle */
void cull_triangles();
/* compares two vectors to see if they are the same */
int vec_compare (int vec_a,int vec_b);
/* cull duplicate coordinates */
void cull_coords();
/* find the normal xyz to triangle abc */
int tri_normal (int a,int b,int c,double *x_ptr,double *y_ptr,double *z_ptr);
/* Function to output in prepi free file format */
void prepi_out();
/* calculate the normals at all the vertices */
int vertex_normals();
/* check for back faced polygons */
int back_check(int a);

void povray_out();
void help();

/* OSS 11-2000 vmd output option*/
void vmd_out();
void vmd_points_out();
/* OSS 11-2000 reorder_triangle needed to sort out smoothed surfaces*/
void reorder_triangle();

/* Global Variables */

double dots[MAX_COORD][7]; /* hold the xcoor:ycoor:zcoor:colour:nx:ny:nz records of the points */
int tri[MAX_COORD][5]; /* list of polygons: dot1:dot2:dot3:colour:flipped */
int culled_tri[MAX_COORD][6];
double in_dots[MAX_COORD][7]; /* inital dots read in from HOLE: contains redundant coords*/
double triangle_normals[MAX_COORD][3]; /* holds normals to the triangles */


int in_dots_total=0;
int max_dots=0;  /* the total number of points */
int tri_count=0; /* counter for polygons */
int culled_tri_count=0;
struct base_line *root;  /* first base line */
struct edge_list *start; /* start and end of linked list of edges */
struct edge_list *end;

int smooth=0; /* flag for smoothed surfaces */
int dump=0; /* falg for dumping colour records */
int start_point=0; /* contains the starting point */
int flipped=0;
int format=4; /* OSS vmd now the default */
double axis[3];
float max_vertex_length=5.0; /* maximum length for a triangle vertex */

/* --- hydrophobicity recolouring (VMDPathFinder extension) --------------------- */
/* When --hydro-atoms is given, each emitted triangle is coloured by the      */
/* hydrophobicity of the nearest HOLE channel sphere instead of by the        */
/* surface's own colour index. This reproduces the plugin's Tcl               */
/* colorize_hydrophobic exactly, but in compiled code inside the already-     */
/* parallel per-frame surface build. With no --hydro-atoms flag the program   */
/* is byte-for-byte the unmodified fast sos_triangle.                          */
int    hydro_mode = 0;            /* 1 = recolour by nearest-sphere hydropathy */
int    hydro_kd   = 1;            /* 1 = Kyte-Doolittle, 0 = Wimley-White       */
/* Lining-shell thickness (A): atoms within (sphere_radius + this) of a sphere    */
/* centre are averaged into that sphere's hydropathy. Mirrors state(hydro_shell)  */
/* in the plugin; default 3.0 matches the Tcl default so both paths agree.        */
double hydro_shell_cut = 3.0;
/* --points: emit the surface as unique vertices ("draw point") instead of      */
/* triangles. Replaces the plugin's Tcl dots_from_trinorm dedup pass with the    */
/* same output, straight from the already-deduplicated dot list.                 */
int    points_mode = 0;
int    pt_emitted[MAX_COORD];    /* per-dot "already written as a point" flag    */
/* --recolor BASE.vmd_plot: re-colour an already-triangulated surface by nearest- */
/* sphere hydropathy WITHOUT re-triangulating. Reads the base mesh's triangles    */
/* and re-emits them with freshly computed colours, so a scheme/colour change is  */
/* a cheap recolour instead of a full sph_process+sos_triangle rebuild.           */
int    recolor_mode = 0;
char   recolor_path[2048] = "";
char   hydro_atoms_path[2048] = "";
char   hydro_sph_path[2048]   = "";
/* --hydro-values FILE: per-sphere PRE-COMPUTED property values, one per line,   */
/* parallel to the .sph file's sphere order. When given, the binary does NOT     */
/* average atoms - it loads these values straight into sph_h[] and colours every */
/* vertex by its nearest sphere. This keeps the binary fully property-agnostic   */
/* (it never sees residues, atom names or scale names): the plugin computes the  */
/* value for ANY scheme + lining/facing/side-chain mode in Tcl and hands over a  */
/* plain scalar per sphere. --hydro-signed picks the colour ramp (diverging vs   */
/* sequential) to match ::VMDPathFinder::norm_to_vmd_color. Values are expected already */
/* normalized: [-1,1] for signed scales, [0,1] for unsigned ones.                */
char   hydro_values_path[2048] = "";
int    hydro_values_mode = 0;     /* 1 = colour from --hydro-values, not atoms   */
int    hydro_signed = 1;          /* 1 = diverging ramp, 0 = sequential ramp     */
/* --hydro-range LO HI: the property scale's REAL extremes. When given, the      */
/* values in --hydro-values / --hydro3d-values sidecars are RAW (real units,     */
/* e.g. Kyte-Doolittle -4.5..+4.5) and the binary normalises them to a colour    */
/* band internally (see normalize_raw, replicating ::VMDPathFinder::property_norm).    */
/* When absent (older plugin), the sidecar values are assumed already-normalized */
/* to [-1,1]/[0,1] - back-compatible. This is what lets the plugin store/show    */
/* RAW property numbers everywhere (panels/axes) while the surface still colours */
/* identically: normalization is now purely a private detail of the colour step. */
double hydro_lo = 0.0, hydro_hi = 0.0;
int    hydro_have_range = 0;
int    write_props_mode = 0;      /* --write-props: write per-sphere h[], skip triangulation */
int    hydro_residue_mode = 0;    /* --hydro-residue: dedup by resid (6th sidecar col)       */
int   *atom_resid = NULL;         /* integer residue ID per atom (hydro_residue_mode only)   */
int    max_resid_val = -1;        /* max resid seen; stamp array sized max_resid_val+1        */
/* channel spheres (centre + radius) and their averaged hydropathy */
double *sph_x=NULL,*sph_y=NULL,*sph_z=NULL,*sph_r=NULL,*sph_h=NULL;
int    *sph_flood=NULL;           /* 1 = Connolly flood-fill/escaped marker, see hydro_read_spheres */
int     n_sph=0;
int    *thin=NULL;                /* indices of the spheres kept after thinning */
int     n_thin=0;
/* channel-local protein atoms: position + KD and WW hydropathy (precomputed   */
/* by the plugin so the scale tables stay single-sourced in Tcl).              */
double *atom_x=NULL,*atom_y=NULL,*atom_z=NULL,*atom_hkd=NULL,*atom_hww=NULL;
int     n_atom=0;

/* --hydro3d-values FILE: TRUE per-triangle colouring by real 3D distance to    */
/* the (few dozen) qualifying pore-lining residues, instead of --hydro-values'  */
/* nearest-CENTERLINE-SPHERE lookup (which only varies along the channel axis  */
/* and paints every triangle at a given height identically, regardless of      */
/* angular position). True 3D distance lets the colour vary around the pore.   */
/* File format: one line per qualifying residue, "x y z value"                 */
/* (already Tcl-normalized, same convention as --hydro-values). Purely         */
/* additive: does not touch hydro_mode/hydro_values_mode/sph_h[]/the native    */
/* colour index at all, so all three colouring mechanisms coexist and this     */
/* binary is byte-for-byte unchanged when --hydro3d-values is not given.       */
char   hydro3d_path[2048] = "";
int    hydro3d_mode = 0;         /* 1 = colour via hydro_at_point_3d(), not hydro_at_point() */
/* --value-radius --bands E0,..,En --band-names N0,..,N(n-1): colour each
   triangle by the radius of the centreline sphere whose surface is nearest its
   centroid, in n absolute radius bands (the plugin's watermelon scale). */
#define SOS_MAXBANDS 32
int    hydro_bands_mode = 0;
static double band_edge[SOS_MAXBANDS + 1]; static char *band_name[SOS_MAXBANDS];
static int n_bands = 0, n_band_edges = 0;
static int *cl_idx = NULL, n_cl = 0;   /* centreline spheres (not flood/escaped, r > 0) */
double hydro3d_bandwidth = 3.0;  /* Gaussian-kernel bandwidth (A), --hydro3d-bandwidth  */
double *res3d_x=NULL,*res3d_y=NULL,*res3d_z=NULL,*res3d_h=NULL;
int     n_res3d=0;
int    hydro3d_precomputed = 0;  /* 1 = --hydro3d-values-in: colour from an already-averaged per-triangle values file, not a live hydro_at_point_3d() evaluation */
double *precomputed_vals = NULL;
int     n_precomputed = 0;
int     precomputed_cap = 0;
int     precomputed_idx = 0;

/* C-SIDE PORE LINING. Instead of the pre-filtered {x y z value} contributor     */
/* rows hydro3d_read_residues() takes (which required a per-frame pure-Tcl lining */
/* test on the main thread), hydro3d_lining!=0 makes the binary take ALL channel- */
/* local atoms ("x y z value resid is_ca" rows) and do the pore-lining/facing     */
/* test HERE, inside the parallel batch. This moves                              */
/* the hot loop off the Tcl main thread and fans it out across workers. The      */
/* qualifying contributors are then fed to the exact same hydro_at_point_3d()    */
/* Nadaraya-Watson smoother, so surface colours + panel per-sphere averages are  */
/* computed by one code path (no cross-view leakage). lining: 1 = residue mode   */
/* (contributor = qualifying residue COG, value = residue property), 2 = atom    */
/* mode (KR - contributor = each qualifying atom, value = its own +/-1).         */
int    hydro3d_lining = 0;
int    hydro3d_facing = 0;        /* residue mode: keep only pore-FACING residues */
double hydro3d_thresh = 3.0;      /* pore-lining distance threshold (A)           */
double *at3_x=NULL,*at3_y=NULL,*at3_z=NULL,*at3_v=NULL;   /* per-atom input       */
int    *at3_resid=NULL,*at3_isca=NULL;
int    asym_rays = 36;    /* --asym-rays: N ray directions for the asymmetry probe */
int     n_at3=0;
int     res3d_cap=0;             /* capacity of res3d_* (push_res3d grows it)    */

/* --hydro3d-props FILE: the single authoritative per-position value shared by the
   OTHER views (Pore Profile Fill, Over Time heatmap, Mean Profile), so they use
   the SAME true-3D Nadaraya-Watson values painted on the surface rather than a
   separate local-shell average. Reads the SAME dot cloud used for triangulation
   (skips the actual
   triangulation - polygonize/build_neighbour_grid are not needed here), scores
   every dot with hydro_at_point_3d() (the exact same function --hydro3d-values
   uses for surface colouring), bins each dot to its nearest INPUT sphere, and
   writes the per-sphere MEAN of its dots' values, one per line, in .sph file
   order (n_sph lines) - mirrors --write-props' output convention exactly so
   downstream Tcl code can reuse it unchanged. Requires --hydro3d-values (the
   residue list) and --hydro-sph to already be set. */
char   hydro3d_props_path[2048] = "";
int    hydro3d_props_mode = 0;

/* --- speedup 2: O(1) check_point ---------------------------------------- */
/* Set to 1 the first time a dot index is used as a triangle vertex (in       */
/* gen_triangle). check_point() then just reads this instead of rescanning    */
/* every triangle. File-scope ints are zero-initialised, so all start unused. */
int point_used[MAX_COORD];

/* --- speedup 1: spatial hash for cull_coords ---------------------------- */
/* A chained hash of accepted dots, bucketed by integer cell (coord/CELL).    */
/* CELL equals the dedup tolerance so any pair within tolerance lands in the   */
/* same or an adjacent cell; cull_coords scans the 3x3x3 neighbourhood and     */
/* still confirms with vec_compare(), so the result is identical to the        */
/* original exhaustive scan -- only far fewer comparisons.                     */
#define CELL_TOL    1.0e-3
#define HASH_BUCKETS (1 << 19)        /* >= 2*MAX_COORD, power of two */
int  hb_head[HASH_BUCKETS];           /* bucket -> first node index, or -1 */
int  hn_next[MAX_COORD];              /* node -> next node in bucket */
int  hn_cx[MAX_COORD], hn_cy[MAX_COORD], hn_cz[MAX_COORD]; /* node cell */
int  hn_dot[MAX_COORD];               /* node -> dots[] index */
int  hn_count=0;                      /* nodes inserted */

static unsigned hash_cell(int cx,int cy,int cz)
{
  unsigned h = (unsigned)cx*73856093u ^ (unsigned)cy*19349663u ^ (unsigned)cz*83492791u;
  return h & (HASH_BUCKETS - 1);
}

/* A dot's integer cell index, safe against a non-finite coordinate.
 *
 * `(int)floor(v/cell)` is UNDEFINED when v is NaN, or when the quotient falls
 * outside int range. In practice it yields INT_MIN, and the +-1 neighbourhood
 * walks that consume these indices (build_grid_at's callers, cull_coords) then
 * compute INT_MIN-1 -- signed overflow, which is itself undefined. UBSan
 * reports exactly that on a .sos carrying NaN dots:
 *     sos_triangle_fast.c: runtime error: signed integer overflow:
 *     -2147483648 + -1 cannot be represented in type 'int'
 *
 * This hazard belongs to the spatial hash added in THIS file, not to HOLE:
 * upstream sos_triangle.c has no cell index at all (its cull is an O(N^2)
 * vec_compare scan, and its neighbour search is a full scan), so there is no
 * upstream behaviour to stay byte-identical to here -- only UB to remove.
 *
 * Clamping rather than rejecting keeps a non-finite dot in the same place
 * upstream would: carried through the pipeline rather than silently dropped.
 * CELL_LIMIT leaves headroom for the +-1 walk, and sits ~1e9 cells from the
 * origin -- 1e6 A at CELL_TOL 1e-3, and larger still for the coarser
 * neighbour grid -- so every coordinate a real .sos can hold is far inside it
 * and the kept-dot set is bit-for-bit unchanged.
 */
#define CELL_LIMIT 1000000000          /* << INT_MAX, with room for +-1 */
static int cell_index(double v, double cell)
{
  double c = floor(v / cell);
  /* Written as a negated `>` so NaN - for which every comparison is false -
     falls into this branch instead of reaching the (int) cast. */
  if (!(c > -(double)CELL_LIMIT)) return -CELL_LIMIT;
  if (c >  (double)CELL_LIMIT)    return  CELL_LIMIT;
  return (int)c;
}

/* --- speedup 4: edge hash for destroy() -------------------------------- */
/* destroy() scans the append-only edge list for the (unordered) pair it is    */
/* given -- O(edges) per call, O(edges^2) overall. Index every edge by its     */
/* endpoint pair so destroy() only inspects edges that share that pair. Edges   */
/* are appended to their bucket in creation order, so a head->tail scan returns */
/* the same first match the original list scan did -> identical behaviour.      */
#define EDGE_HASH (1 << 18)
struct edge_list *eh_head[EDGE_HASH];   /* zero-initialised (NULL) */
struct edge_list *eh_tail[EDGE_HASH];

static unsigned hash_edge(int a,int b)
{
  int lo = (a<b)?a:b;
  int hi = (a<b)?b:a;
  return ((unsigned)lo*73856093u ^ (unsigned)hi*19349663u) & (EDGE_HASH - 1);
}

static void edge_hash_insert(struct edge_list *n)
{
  unsigned b = hash_edge(n->x1, n->x2);
  n->hnext = NULL;
  if (eh_tail[b]) { eh_tail[b]->hnext = n; eh_tail[b] = n; }
  else            { eh_head[b] = eh_tail[b] = n; }
}

/* --- speedup 5: spatial grid for neighbour() --------------------------- */
/* neighbour() never selects a dot whose distance from vertex a exceeds        */
/* 3*|base| (the check_dist test), so it only needs to look at dots near a.     */
/* Bucket all dots into a uniform grid (built once after cull_coords) and visit */
/* only the cells covering that radius. To keep the result identical even  */
/* though dots are now visited out of index order, the selection below picks    */
/* the smallest-angle dot and breaks ties by smallest index (exactly what the   */
/* original strict-"<" scan in index order produces). This finally does what    */
/* the upstream "Box type data structure would be better" comment suggested.    */
double NCELL = 0.0;                /* grid cell size (avg dot spacing) */
int ng_head[HASH_BUCKETS];         /* cell bucket -> first dot index, or -1 */
int ng_dotnext[MAX_COORD];         /* dot -> next dot in same bucket */
int ng_cx[MAX_COORD], ng_cy[MAX_COORD], ng_cz[MAX_COORD]; /* dot's cell */

/* Fill the grid buckets at a given cell size. Pulled out of build_neighbour_grid
   so the cell size can be refined and the grid rebuilt cheaply. */
void build_grid_at(double cell)
{
  int i, b;
  NCELL = cell;
  for (b=0;b<HASH_BUCKETS;b++) ng_head[b] = -1;
  for (i=0;i<max_dots;i++) {
    ng_cx[i]=cell_index(dots[i][0],NCELL);
    ng_cy[i]=cell_index(dots[i][1],NCELL);
    ng_cz[i]=cell_index(dots[i][2],NCELL);
    b=hash_cell(ng_cx[i],ng_cy[i],ng_cz[i]);
    ng_dotnext[i]=ng_head[b];
    ng_head[b]=i;
  }
}

static int ncell_nn_cmp(const void *p,const void *q)
{ double a=*(const double*)p, b=*(const double*)q; return a<b?-1:(a>b?1:0); }

/* Speedup 5b: size the grid cell to the SURFACE dot spacing, not the bounding-box
   estimate. cbrt(bbox_volume/N) assumes the dots fill a 3-D volume, but they lie
   on a 2-D surface inside that box, so it overestimates the spacing several-fold
   (e.g. NCELL=5.1 A when the dots are ~1 A apart). The 3*|base| neighbour query
   then spans far fewer cells than it should and each cell holds dozens of dots,
   so nb_consider() is called on thousands of out-of-radius dots (measured: >99%
   of candidates rejected by the distance test). Refining NCELL to ~5x the median
   nearest-neighbour distance (validated near-optimal across surfaces) shrinks the
   neighbour search ~2x on the triangulation phase. This is a pure acceleration:
   nb_consider() applies the identical 3*|base| test regardless of cell size, and
   the fallback below caps a mis-estimate at the original full scan, so the output
   is byte-for-byte unchanged. */
static void ncell_to_surface_spacing()
{
  /* 1000 samples is plenty for a stable median and keeps this O(1)-ish so small
     surfaces (where triangulation is already cheap) pay no measurable overhead. */
  int s, m=0, want = max_dots<1000 ? max_dots : 1000;
  int step = max_dots/(want?want:1);
  double *nn;
  if (step<1) step=1;
  nn = malloc(sizeof(double)*(want+1));
  if (!nn) return;
  for (s=0; s<max_dots && m<want; s+=step) {
    double best=1e30; int dx,dy,dz, cx=ng_cx[s],cy=ng_cy[s],cz=ng_cz[s];
    for (dx=-1;dx<=1;dx++) for (dy=-1;dy<=1;dy++) for (dz=-1;dz<=1;dz++) {
      int qx=cx+dx,qy=cy+dy,qz=cz+dz, n=ng_head[hash_cell(qx,qy,qz)];
      while (n!=-1) {
        if (n!=s && ng_cx[n]==qx && ng_cy[n]==qy && ng_cz[n]==qz) {
          double a=dots[n][0]-dots[s][0], b=dots[n][1]-dots[s][1], c=dots[n][2]-dots[s][2];
          double d=a*a+b*b+c*c; if (d<best) best=d;
        }
        n=ng_dotnext[n];
      }
    }
    if (best<1e29) nn[m++]=sqrt(best);
  }
  if (m>0) {
    double med;
    qsort(nn,m,sizeof(double),ncell_nn_cmp);
    med = nn[m/2];
    if (med > 1.0e-4) build_grid_at(5.0*med);
  }
  free(nn);
}

void build_neighbour_grid()
{
  int i;
  double minx,miny,minz,maxx,maxy,maxz,vol;
  if (max_dots <= 0) return;
  minx=maxx=dots[0][0]; miny=maxy=dots[0][1]; minz=maxz=dots[0][2];
  for (i=1;i<max_dots;i++) {
    if (dots[i][0]<minx) minx=dots[i][0]; if (dots[i][0]>maxx) maxx=dots[i][0];
    if (dots[i][1]<miny) miny=dots[i][1]; if (dots[i][1]>maxy) maxy=dots[i][1];
    if (dots[i][2]<minz) minz=dots[i][2]; if (dots[i][2]>maxz) maxz=dots[i][2];
  }
  /* coarse cell from the bbox estimate, then refine to the true surface spacing */
  vol = (maxx-minx)*(maxy-miny)*(maxz-minz);
  if (vol > 0.0) NCELL = cbrt(vol/(double)max_dots);
  if (!(NCELL > 1.0e-4)) NCELL = 1.0;   /* guards degenerate/flat inputs */
  build_grid_at(NCELL);
  ncell_to_surface_spacing();
}

/* Evaluate one candidate dot exactly as the original neighbour() inner body
   did, updating the running best (min_ang,c). The selection picks the smallest
   angle and breaks ties by smallest dot index -- identical to the original
   strict-"<" scan done in index order, but valid for any visit order so the
   grid can hand dots over in cell order. The "*c <= max_dots" guard reproduces
   the original behaviour that the initial min_ang of 1.0 is never matched by an
   equal angle (only beaten by a strictly smaller one). */
static void nb_consider(struct base_line *node, const double *pointm,
                        const double *veczm, double magzm, double base_dist,
                        double angle_limit, int loop, double *min_ang, int *c)
{
  double da0,da1,da2;
  double vm0,vm1,vm2,magmc,dotp,angle2;
  double va0,va1,va2,vb0,vb1,vb2,maga,magb,angle;

  if ((loop==node->a) || (loop==node->b) || (loop==node->z)) return;

  da0=dots[loop][0]-dots[node->a][0];
  da1=dots[loop][1]-dots[node->a][1];
  da2=dots[loop][2]-dots[node->a][2];
  if (da0*da0+da1*da1+da2*da2 > 9*base_dist) return;   /* check_dist bound */

  vm0=dots[loop][0]-pointm[0];
  vm1=dots[loop][1]-pointm[1];
  vm2=dots[loop][2]-pointm[2];
  magmc=sqrt(vm0*vm0+vm1*vm1+vm2*vm2);
  dotp=(vm0*veczm[0])+(vm1*veczm[1])+(vm2*veczm[2]);
  angle2=((dotp/(magmc*magzm)));

  if (angle2 > angle_limit)
    {
      va0=dots[loop][0]-dots[node->a][0];
      va1=dots[loop][1]-dots[node->a][1];
      va2=dots[loop][2]-dots[node->a][2];
      vb0=dots[loop][0]-dots[node->b][0];
      vb1=dots[loop][1]-dots[node->b][1];
      vb2=dots[loop][2]-dots[node->b][2];
      maga=sqrt(va0*va0+va1*va1+va2*va2);
      magb=sqrt(vb0*vb0+vb1*vb1+vb2*vb2);
      dotp=(va0*vb0)+(va1*vb1)+(va2*vb2);
      angle=(dotp/(maga*magb));

      if (angle < *min_ang || (*c <= max_dots && angle == *min_ang && loop < *c))
	{
	  *min_ang=angle;
	  *c=loop;
	}
    }
}

/* Map an averaged hydropathy value to a VMD colour name. This MUST stay in    */
/* step with ::VMDPathFinder::hydro_to_vmd_color in vmdpathfinder.tcl (golden-tested by     */
/* verify.sh). Positive = hydrophobic (red), negative = hydrophilic (blue).     */
static const char *hydro_color_name(double h)
{
  if (hydro_kd) {                 /* Kyte-Doolittle: -4.5 .. +4.5 */
    if (h < -3.0) return "blue";
    if (h < -1.5) return "iceblue";
    if (h < -0.5) return "cyan";
    if (h <  0.5) return "white";
    if (h <  1.5) return "yellow";
    if (h <  3.0) return "orange";
    return "red";
  } else {                        /* Wimley-White (negated): -2.02 .. +1.85 */
    if (h < -1.5) return "blue";
    if (h < -0.7) return "iceblue";
    if (h < -0.2) return "cyan";
    if (h <  0.2) return "white";
    if (h <  0.7) return "yellow";
    if (h <  1.2) return "orange";
    return "red";
  }
}

/* Map a PRE-NORMALIZED property value (t) to a VMD colour name. This MUST stay  */
/* in step with ::VMDPathFinder::norm_to_vmd_color in vmdpathfinder.tcl. Used by the         */
/* --hydro-values path, where the plugin has already mapped any scale to a       */
/* normalized position: signed scales give t in [-1,1] (diverging blue->white->  */
/* red); unsigned scales give t in [0,1] (sequential white->red).                */
static const char *norm_color_name(double t)
{
  if (hydro_signed) {
    if (t < -0.66) return "blue";
    if (t < -0.33) return "iceblue";
    if (t < -0.11) return "cyan";
    if (t <  0.11) return "white";
    if (t <  0.33) return "yellow";
    if (t <  0.66) return "orange";
    return "red";
  }
  if (t < 0.25) return "white";
  if (t < 0.50) return "yellow";
  if (t < 0.75) return "orange";
  return "red";
}

/* Map a RAW property value to a normalized position, replicating              */
/* ::VMDPathFinder::property_norm exactly. Signed scales: v<0 -> v/|lo|, v>=0 -> v/hi  */
/* (so the neutral value 0 always lands at the centre even when |lo| != hi),    */
/* clamped to [-1,1]. Unsigned scales: (v-lo)/(hi-lo), clamped to [0,1]. Used   */
/* only when --hydro-range gave us the scale's real extremes; keeps the surface */
/* colours identical to a pre-normalized path while the values that        */
/* flow through the plugin stay in real units.                                  */
static double normalize_raw(double v)
{
  double t;
  if (hydro_signed) {
    if (v < 0.0) t = (hydro_lo < 0.0) ? v / (-hydro_lo) : 0.0;
    else         t = (hydro_hi > 0.0) ? v / hydro_hi   : 0.0;
    if (t < -1.0) t = -1.0;
    if (t >  1.0) t =  1.0;
  } else {
    double span = hydro_hi - hydro_lo;
    t = (span != 0.0) ? (v - hydro_lo) / span : 0.5;
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
  }
  return t;
}

/* Colour for a surface point: the --hydro-values and --hydro3d-values paths    */
/* supply RAW values when --hydro-range is given (normalise here), else already-*/
/* normalized values (legacy); the legacy atom-averaging path uses the kd/ww ramp.*/
static const char *surface_color_name(double v)
{
  if (hydro_bands_mode) {
    int b;
    for (b = 0; b < n_bands; b++) if (v < band_edge[b + 1]) return band_name[b];
    return band_name[n_bands - 1];
  }
  if (hydro_values_mode || hydro3d_mode) {
    return norm_color_name(hydro_have_range ? normalize_raw(v) : v);
  }
  return hydro_color_name(v);
}

/* Read channel spheres from the HOLE .sph PDB (ATOM/HETATM records). Every
   ATOM/HETATM line is kept, in file order - callers that need the RAW,
   unfiltered order (hydro_load()'s --hydro-values path, index-parallel to a
   separate values file) depend on that; do not filter here. sph_flood[i]
   marks (without removing) HOLE's own non-centerline conventions - residue
   sequence -999 (Connolly flood-fill dot, sph_process.f) or -888 (escaped
   search sphere, same convention _capsule_rings/Tcl's _sph_line_is_flood_fill
   use), or a beta of ~999.99 (an axial step that escaped to bulk solvent,
   coarea.f's REQUIV=1E06 case clamped to the .sph beta field) - so
   hydro_splice_spheres can drop them, mirroring the Tcl filter exactly. */
static void hydro_read_spheres(void)
{
  hio_reader rd; hio_rec a;
  int cap = 0;
  if (!hio_open(&rd, hydro_sph_path)) { fprintf(stderr, "\nhydro: cannot open sph file '%s'", hydro_sph_path); return; }
  while (hio_next(&rd, &a)) {
    if (n_sph == cap) {
      cap = cap ? cap * 2 : 1024;
      sph_x = xrealloc(sph_x, cap*sizeof(double), "sph_x"); sph_y = xrealloc(sph_y, cap*sizeof(double), "sph_y");
      sph_z = xrealloc(sph_z, cap*sizeof(double), "sph_z"); sph_r = xrealloc(sph_r, cap*sizeof(double), "sph_r");
      sph_h = xrealloc(sph_h, cap*sizeof(double), "sph_h"); sph_flood = xrealloc(sph_flood, cap*sizeof(int), "sph_flood");
    }
    sph_x[n_sph] = a.x; sph_y[n_sph] = a.y; sph_z[n_sph] = a.z;
    sph_r[n_sph] = a.beta;
    sph_h[n_sph] = 0.0;
    sph_flood[n_sph] = (a.resseq == -999 || a.resseq == -888 || sph_r[n_sph] > 900.0) ? 1 : 0;
    n_sph++;
  }
  hio_close(&rd);
}

/* Splice HOLE's two-arm .sph centerline into one continuous path, mirroring Tcl's
   _asym_gather (vmdpathfinder.tcl) EXACTLY: HOLE grows the pore path in TWO directions
   from CPOINT, so the raw .sph sphere order is typically two arm segments
   concatenated back-to-back (real inter-sample steps stay under a few A; the arm
   seam reaches tens to ~100 A). Reverse the first arm and concatenate the second,
   over the FILTERED (r>0.005 AND !sph_flood) sphere list only - same filter Tcl's
   parse_sph_centerline/_sph_line_is_flood_fill apply. r>0.005 alone is NOT enough
   on a CONNOLLY .sph: its flood-fill dots (sph_flood, residue seq -999) carry a
   real positive radius, so they passed the old r-only filter and got spliced in as
   if they were centerline points - verified on a real Connolly fixture (1BL8): 18473
   spliced points instead of the correct 169, silently corrupting every ellipse/ESP
   fast-path result on a Connolly run (Task #30).
   Scoped: called explicitly at the asymmetry/ellipse call sites only, NEVER inside
   hydro_read_spheres() itself - hydro_load()'s hydro-values coloring path reads a
   separate values file that is index-parallel to the RAW .sph order, so splicing
   there would desync that unrelated, working pipeline. sph_h/sph_flood are left
   untouched (stale size vs the new n_sph is harmless: these consumers never read
   them post-splice, and reset_hydro_state() frees the pointers unconditionally
   regardless of size). */
static void hydro_splice_spheres(void)
{
  int *keep, nk = 0, i, seam = -1;
  double *nx, *ny, *nz, *nr;
  if (n_sph <= 0) return;
  keep = (int*) malloc(n_sph * sizeof(int));
  if (!keep) return;
  for (i = 0; i < n_sph; i++) if (sph_r[i] > 0.005 && !sph_flood[i]) keep[nk++] = i;
  if (nk > 3) {
    for (i = 0; i < nk-1; i++) {
      int a = keep[i], b = keep[i+1];
      double dx = sph_x[b]-sph_x[a], dy = sph_y[b]-sph_y[a], dz = sph_z[b]-sph_z[a];
      if (sqrt(dx*dx+dy*dy+dz*dz) > 10.0) { seam = i; break; }
    }
  }
  nx = (double*) malloc((nk>0?nk:1)*sizeof(double)); ny = (double*) malloc((nk>0?nk:1)*sizeof(double));
  nz = (double*) malloc((nk>0?nk:1)*sizeof(double)); nr = (double*) malloc((nk>0?nk:1)*sizeof(double));
  if (!nx || !ny || !nz || !nr) { free(keep); free(nx); free(ny); free(nz); free(nr); return; }
  if (seam < 0) {
    for (i = 0; i < nk; i++) { int s = keep[i]; nx[i]=sph_x[s]; ny[i]=sph_y[s]; nz[i]=sph_z[s]; nr[i]=sph_r[s]; }
  } else {
    int w = 0, j;
    for (j = seam; j >= 0; j--)     { int s = keep[j]; nx[w]=sph_x[s]; ny[w]=sph_y[s]; nz[w]=sph_z[s]; nr[w]=sph_r[s]; w++; }
    for (j = seam+1; j < nk; j++)   { int s = keep[j]; nx[w]=sph_x[s]; ny[w]=sph_y[s]; nz[w]=sph_z[s]; nr[w]=sph_r[s]; w++; }
  }
  free(sph_x); free(sph_y); free(sph_z); free(sph_r);
  sph_x = nx; sph_y = ny; sph_z = nz; sph_r = nr;
  n_sph = nk;
  free(keep);
}

/* --esp: average in-vacuo electrostatic potential (HOLE helefi model) along the
   centerline. sph_x/y/z are the spliced r>0.005 centerline (hydro_read_spheres +
   hydro_splice_spheres already ran, so n_sph and the ORDER match Tcl's _asym_gather
   centres exactly -> identical summation). CHARGEFILE has "x y z q" per formal
   point charge; Tcl assigns those charges (Asp/Glu/Arg/Lys, His excluded) and this
   only does the O(n_sph * n_charge) distance sum - a pure speedup for
   electrostatic_potential_for_frame, whose Tcl loop is the reference/fallback
   (same K = 331.850, same 0.01 A floor). Writes one number (mean kcal/mol/e). */
static int esp_compute(const char *chargefile, const char *outfile, int per_point)
{
  FILE *f = fopen(chargefile, "r");
  double *qx=NULL,*qy=NULL,*qz=NULL,*qc=NULL, total=0.0, K=331.850;
  int nq=0, cap=0, i, s;
  char line[512];
  FILE *o;
  if (!f) { fprintf(stderr, "\n--esp: cannot open charge file %s\n", chargefile); return 1; }
  while (fgets(line, sizeof(line), f)) {
    double x,y,z,q;
    if (sscanf(line, "%lf %lf %lf %lf", &x,&y,&z,&q) != 4) continue;
    if (nq == cap) { cap = cap ? cap*2 : 256;
      qx = xrealloc(qx, cap*sizeof(double), "qx"); qy = xrealloc(qy, cap*sizeof(double), "qy");
      qz = xrealloc(qz, cap*sizeof(double), "qz"); qc = xrealloc(qc, cap*sizeof(double), "qc"); }
    qx[nq]=x; qy[nq]=y; qz[nq]=z; qc[nq]=q; nq++;
  }
  fclose(f);
  o = fopen(outfile, "w");
  if (!o) { free(qx);free(qy);free(qz);free(qc);
            fprintf(stderr, "\n--esp: cannot open output %s\n", outfile); return 1; }
  /* per_point=1 (--esp-points): one potential per .sph point, in FILE order (no
     splice/filter), for the surface-colouring sidecar. per_point=0 (--esp): the
     MEAN over the spliced r>0.005 centreline (the caller ran hydro_splice_spheres),
     for the readout/Trends. */
  for (s = 0; s < n_sph; s++) {
    double pot = 0.0;
    for (i = 0; i < nq; i++) {
      double dx = sph_x[s]-qx[i], dy = sph_y[s]-qy[i], dz = sph_z[s]-qz[i];
      double d = sqrt(dx*dx + dy*dy + dz*dz);
      if (d < 0.01) d = 0.01;
      pot += K*qc[i]/d;
    }
    if (per_point) fprintf(o, "%.6f\n", pot); else total += pot;
  }
  if (!per_point && n_sph > 0) fprintf(o, "%.10g\n", total / n_sph);
  fclose(o);
  free(qx); free(qy); free(qz); free(qc);
  return 0;
}

/* --hydro-values: load one pre-computed property value per sphere (parallel to  */
/* the .sph order) straight into sph_h[], skipping all atom averaging. Returns 1 */
/* on success. If the file has fewer values than spheres the rest stay 0; extra  */
/* values are ignored. Whitespace/blank tolerant (one number per line).          */
static int hydro_read_values(void)
{
  FILE *f = fopen(hydro_values_path, "r");
  char line[256];
  int i = 0;
  if (!f) { fprintf(stderr, "\nhydro: cannot open values file '%s'", hydro_values_path); return 0; }
  while (i < n_sph && fgets(line, sizeof(line), f)) {
    char *p = line, *e;
    double v = strtod(p, &e);
    if (e == p) continue;          /* blank / non-numeric line */
    sph_h[i++] = v;
  }
  fclose(f);
  return (i > 0);
}

/* --hydro3d-values: load "x y z value" rows, one per qualifying pore-lining     */
/* residue (a few dozen typically, not thousands), for the true-3D per-triangle */
/* colour lookup (hydro_at_point_3d). Values are already Tcl-normalized, same    */
/* convention as --hydro-values. Growable array, mirrors hydro_read_atoms.       */
static int hydro3d_read_residues(void)
{
  FILE *f = fopen(hydro3d_path, "r");
  char line[256];
  int cap = 0;
  if (!f) { fprintf(stderr, "\nhydro3d: cannot open values file '%s'", hydro3d_path); return 0; }
  while (fgets(line, sizeof(line), f)) {
    char *p = line, *e;
    double x,y,z,h;
    x = strtod(p, &e); if (e == p) continue; p = e;
    y = strtod(p, &e); if (e == p) continue; p = e;
    z = strtod(p, &e); if (e == p) continue; p = e;
    h = strtod(p, &e); if (e == p) continue; p = e;
    if (n_res3d == cap) {
      cap = cap ? cap * 2 : 64;
      res3d_x = xrealloc(res3d_x, cap*sizeof(double), "res3d_x"); res3d_y = xrealloc(res3d_y, cap*sizeof(double), "res3d_y");
      res3d_z = xrealloc(res3d_z, cap*sizeof(double), "res3d_z"); res3d_h = xrealloc(res3d_h, cap*sizeof(double), "res3d_h");
    }
    res3d_x[n_res3d]=x; res3d_y[n_res3d]=y; res3d_z[n_res3d]=z; res3d_h[n_res3d]=h;
    n_res3d++;
  }
  fclose(f);
  return (n_res3d > 0);
}

/* Read the all-atoms sidecar for C-side lining: "x y z value resid is_ca" rows  */
/* (one per channel-local atom the plugin selected). Growable; strtod hot loop.  */
static int hydro3d_read_atoms_lining(void)
{
  FILE *f = fopen(hydro3d_path, "r");
  char line[512];
  int cap = 0;
  if (!f) { fprintf(stderr, "\nhydro3d: cannot open atoms file '%s'", hydro3d_path); return 0; }
  while (fgets(line, sizeof(line), f)) {
    char *p = line, *e;
    double x,y,z,v,rid,ca;
    x   = strtod(p, &e); if (e == p) continue; p = e;
    y   = strtod(p, &e); if (e == p) continue; p = e;
    z   = strtod(p, &e); if (e == p) continue; p = e;
    v   = strtod(p, &e); if (e == p) continue; p = e;
    rid = strtod(p, &e); if (e == p) continue; p = e;
    ca  = strtod(p, &e); if (e == p) continue; p = e;
    if (n_at3 == cap) {
      cap = cap ? cap * 2 : 8192;
      at3_x = xrealloc(at3_x, cap*sizeof(double), "at3_x"); at3_y = xrealloc(at3_y, cap*sizeof(double), "at3_y");
      at3_z = xrealloc(at3_z, cap*sizeof(double), "at3_z"); at3_v = xrealloc(at3_v, cap*sizeof(double), "at3_v");
      at3_resid = xrealloc(at3_resid, cap*sizeof(int), "at3_resid"); at3_isca = xrealloc(at3_isca, cap*sizeof(int), "at3_isca");
    }
    at3_x[n_at3]=x; at3_y[n_at3]=y; at3_z[n_at3]=z; at3_v[n_at3]=v;
    at3_resid[n_at3]=(int)(rid+0.5); at3_isca[n_at3]=(int)(ca+0.5);
    n_at3++;
  }
  fclose(f);
  return (n_at3 > 0);
}

/* True nearest sphere (3D) to a point: squared distance to its centre + its     */
/* radius, for the lining test |sqrt(d2) - r| <= thresh. Linear scan over n_sph  */
/* (a few hundred) - O(n_atoms * n_sph) per frame is ~10M ops, negligible in C.  */
static void hydro3d_nearest_sphere(double px, double py, double pz,
                                   double *d2out, double *rout)
{
  int s; double best = 1e30, br = 0.0;
  for (s = 0; s < n_sph; s++) {
    double dx = px-sph_x[s], dy = py-sph_y[s], dz = pz-sph_z[s];
    double d2 = dx*dx + dy*dy + dz*dz;
    if (d2 < best) { best = d2; br = sph_r[s]; }
  }
  *d2out = best; *rout = br;
}

/* Fixed slicing axis for the ellipse probe (the HOLE cvect / pore vector). {0,0,0} = derive it
   from the near-pore atom cloud PCA (fallback). Set from the CLI (--asym-ellipse OUT tx ty tz). */
static double asym_axis[3] = {0.0, 0.0, 0.0};

/* Threads for the ellipse-probe slice loop (compute_ellipse). Default 1 so BATCH workers (N
   parallel processes) never oversubscribe; the single-frame caller passes --asym-threads nproc.
   asym_threads_explicit distinguishes "--asym-threads N was given" from "still at the
   built-in default": --asym-ellipse/--asym-ellipse-geo (always ONE process per call) fall
   back to omp_get_max_threads() when nothing was given, so a caller that forgets the flag -
   or an older Tcl side that never learned about it - still gets full parallelism instead of
   silently running serial (measured 3.9s -> 0.4s on a 508-slice/27k-atom channel, 16 cores).
   --batch-asym-ellipse (many worker PROCESSES already share the cores) does NOT get this
   auto-detect: it always keeps whatever asym_threads is when its branch runs (1, since the
   caller never passes --asym-threads to a batch invocation), so N workers can never
   oversubscribe to N*nproc threads. */
static int asym_threads = 1;
static int asym_threads_explicit = 0;
static void asym_threads_auto_single_frame(void)
{
  if (asym_threads_explicit) return;
#ifdef _OPENMP
  { int n = omp_get_max_threads(); if (n > 1) asym_threads = n; }
#endif
}

/* PROFILING ONLY (SOS_ELLIPSE_TIMING=1 env var) - measures where compute_ellipse's time
   goes: neighbour gather vs the PoreAnalyser Nelder-Mead fit itself. Off by default, writes
   to stderr only, never touches stdout/output files or any computed number. Summed across
   OMP threads, so with --asym-threads 1 the two numbers are true wall-clock phase times;
   with N>1 they are thread-seconds (sum, not wall), still useful for the compute/gather RATIO. */
static int g_ellipse_timing = 0;
static double g_time_gather = 0.0, g_time_fit = 0.0;
static double now_sec(void)
{
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* Threads for the --recolor triangle-colour loop + the hydro3d atom-lining loop
   (recolor_vmd_plot / hydro3d_build_contributors). Default 1 so the BATCH recolour
   modes (--batch-hydro3d-*, already N parallel worker processes) never oversubscribe;
   the single-frame plugin recolour opts up to nproc via --recolor-threads N. */
static int recolor_threads = 1;

/* ---- PoreAnalyser ellipse fit (Seiferth & Biggin 2024) - a LITERAL port of their own    */
/* code, not an equivalent-but-different solver. Per cross-section the minor semi-axis is  */
/* pinned to the HOLE radius b and {major a, orientation theta, centre cx,cy} are optimised */
/* to maximise a subject to no atom-vdW overlap. Three pieces are ported, all pure C:        */
/*  (1) pa_de/pa_on/pa_ev: their exact point-to-ellipse overlap test (Chatfield closest-     */
/*      point iteration + the vdW-sphere penalty), matching their own code (0.0 max diff).      */
/*  (2) sci_nm: scipy's REAL _minimize_neldermead (adaptive Gao-Han coefficients, bounds by   */
/*      clipping, xatol/fatol 1e-4, maxiter 800) - not a theta-grid or Hooke-Jeeves stand-in; */
/*      PoreAnalyser calls this exact scipy routine, so this ports it exactly.               */
/*  (3) pa_fit: their own two-pass insert_ellipse driver (pass 1 rad_fac 0.9, HOLE- and COG-  */
/*      seeded simplices, centre bounds +/-0.1b; pass 2 rad_fac 0.99, bounds +/-0.5*pass1-a;  */
/*      revert pass 2 if the centre moved more than max(b,7) or a grew >1.5x; <30 neighbours  */
/*      collapses to a circle).                                                              */
/* CAVEAT:        */
/* PoreAnalyser's OWN code does not reproduce its own published figures run to run - Nelder-  */
/* Mead is a local, non-convex optimiser, so its result depends on the exact scipy/numpy      */
/* version. This port targets THEIR CODE, not a single frozen "correct" number: on identical  */
/* atom sets it reproduces their current output closely (most slices within a few percent;    */
/* a minority diverge more where the optimiser lands in a different local optimum - the same  */
/* sensitivity their own code has, not a defect unique to this port).                         */
static void pa_de(double A, double B, double px0, double py0, double *ox, double *oy)
{
  double px = fabs(px0), py = fabs(py0), t = 3.141592653589793/4.0, x = 0, y = 0; int k;
  for (k = 0; k < 3; k++) {
    double c = cos(t), s = sin(t);
    double ex = (A*A-B*B)*c*c*c/A, ey = (B*B-A*A)*s*s*s/B;
    double rx, ry, qx, qy, r, q;
    x = A*c; y = B*s;
    rx = x-ex; ry = y-ey; qx = px-ex; qy = py-ey; r = hypot(ry,rx); q = hypot(qy,qx);
    t += r*asin((rx*qy-ry*qx)/(r*q)) / sqrt(A*A+B*B-x*x-y*y);
    if (t > 1.5707963267948966) t = 1.5707963267948966; if (t < 0) t = 0;
  }
  *ox = (px0 < 0 ? -x : x); *oy = (py0 < 0 ? -y : y);
}
/* pa_on/pa_ev take the ellipse rotation as PRECOMPUTED c_nth=cos(-th), s_nth=sin(-th),
   c_th=cos(th), s_th=sin(th), and the rotated centre rc1=cx*c_nth-cy*s_nth,
   rc2=cx*s_nth+cy*c_nth, rather than th/cx/cy themselves. Both call sites (sci_pen, pa_fit's
   probe-shrink loop) invoke this pair once per atom with theta AND the centre CONSTANT
   across the whole atom loop (theta/cx/cy are 3 of the 4 Nelder-Mead simplex coordinates,
   fixed for a given penalty evaluation; theta=0,cx=px,cy=py - all literal/loop-invariant -
   in the shrink loop) - so the transcendentals this used to spend PER ATOM recomputing
   cos/sin(-th) and the rotated centre (twice: once inside pa_on, again inside pa_ev) were
   recomputing the SAME values up to na times. Each caller now computes c_nth/s_nth/c_th/
   s_th/rc1/rc2 ONCE via the exact same expressions before its atom loop; since these are
   pure deterministic functions of bit-identical inputs, reusing one evaluation in place of
   many is bit-for-bit identical to the original per-atom calls - not an approximation, a
   de-duplication. cx/cy are still passed through for pa_ev's own ptx/pty (the UNrotated
   atom-to-centre vector, needed before its own rotation into prx/pry). */
static int pa_on(double a, double b, double c_nth, double s_nth, double rc1, double rc2, double x, double y)
{
  double x1 = x*c_nth-y*s_nth, y1 = x*s_nth+y*c_nth;
  return (x1-rc1)*(x1-rc1)/(a*a) + (y1-rc2)*(y1-rc2)/(b*b) <= 1.0;
}
static double pa_ev(double a, double b, double c_nth, double s_nth, double c_th, double s_th,
                    double rc1, double rc2, double cx, double cy, double sx, double sy, double sr)
{
  double ptx, pty, prx, pry, c1, c2, crx, cry;
  if (pa_on(a,b,c_nth,s_nth,rc1,rc2,sx,sy)) return -sr;
  ptx = sx-cx; pty = sy-cy;
  prx = ptx*c_nth-pty*s_nth; pry = ptx*s_nth+pty*c_nth;
  pa_de(a,b,prx,pry,&c1,&c2);
  crx = c1*c_th-c2*s_th+cx; cry = c1*s_th+c2*c_th+cy;
  return hypot(crx-sx,cry-sy)-sr;
}
/* PoreAnalyser fit on the projected in-plane atoms; returns a (minor b pinned, reported via ob),   */
/* via sci_nm below (scipy Nelder-Mead) with the rad_fac probe-shrink loop first.                   */
static void sci_clip(double x[4], const double lb[4], const double ub[4]){
  int j; for(j=0;j<4;j++){ if(x[j]<lb[j])x[j]=lb[j]; if(x[j]>ub[j])x[j]=ub[j]; }
}
/* PoreAnalyser penalty_overlap_4dim: -a if no atom overlaps ellipse(a,beff,th,cx,cy) else 1e9. */
static double sci_pen(const double x[4], const double *ax, const double *ay, const double *ar, int na, double beff){
  int i;
  /* theta (x[1]) and the centre (x[2],x[3]) are the same for every atom in this call -
     see the pa_on/pa_ev comment. */
  double c_nth = cos(-x[1]), s_nth = sin(-x[1]), c_th = cos(x[1]), s_th = sin(x[1]);
  double rc1 = x[2]*c_nth-x[3]*s_nth, rc2 = x[2]*s_nth+x[3]*c_nth;
  for(i=0;i<na;i++) {
    if(pa_ev(x[0],beff,c_nth,s_nth,c_th,s_th,rc1,rc2,x[2],x[3],ax[i],ay[i],ar[i])<0) return 1e9;
  }
  return -x[0];
}
static void sci_sort5(double sim[5][4], double f[5]){
  int i,j,k; for(i=1;i<5;i++){ double tf=f[i],tx[4]; for(k=0;k<4;k++)tx[k]=sim[i][k]; j=i-1;
    while(j>=0 && f[j]>tf){ f[j+1]=f[j]; for(k=0;k<4;k++)sim[j+1][k]=sim[j][k]; j--; }
    f[j+1]=tf; for(k=0;k<4;k++)sim[j+1][k]=tx[k]; }
}
/* scipy _minimize_neldermead (adaptive, bounds=clip), N=4, maxiter iters. Returns best x + *bf. */
static void sci_nm(double sim[5][4], const double *ax,const double *ay,const double *ar,int na,
                   double beff, const double lb[4], const double ub[4], int maxiter,
                   double best[4], double *bf){
  const int N=4; int i,j,k,it;
  double rho=1.0, chi=1.0+2.0/N, psi=0.75-1.0/(2.0*N), sigma=1.0-1.0/N, xatol=1e-4, fatol=1e-4;
  double f[5];
  for(i=0;i<5;i++){ for(j=0;j<4;j++){ if(sim[i][j]>ub[j]) sim[i][j]=2*ub[j]-sim[i][j]; }
    sci_clip(sim[i],lb,ub); }
  for(i=0;i<5;i++) f[i]=sci_pen(sim[i],ax,ay,ar,na,beff);
  sci_sort5(sim,f); it=1;
  while(it<maxiter){
    double dx=0,df=0,xbar[4],xr[4]; int doshrink=0; double fxr;
    for(i=1;i<5;i++) for(j=0;j<4;j++){ double a=fabs(sim[i][j]-sim[0][j]); if(a>dx)dx=a; }
    for(i=1;i<5;i++){ double a=fabs(f[0]-f[i]); if(a>df)df=a; }
    if(dx<=xatol && df<=fatol) break;
    for(j=0;j<4;j++){ xbar[j]=0; for(i=0;i<N;i++) xbar[j]+=sim[i][j]; xbar[j]/=N; }
    for(j=0;j<4;j++) xr[j]=(1+rho)*xbar[j]-rho*sim[N][j]; sci_clip(xr,lb,ub);
    fxr=sci_pen(xr,ax,ay,ar,na,beff);
    if(fxr<f[0]){ double xe[4]; for(j=0;j<4;j++) xe[j]=(1+rho*chi)*xbar[j]-rho*chi*sim[N][j]; sci_clip(xe,lb,ub);
      double fxe=sci_pen(xe,ax,ay,ar,na,beff);
      if(fxe<fxr){ for(j=0;j<4;j++)sim[N][j]=xe[j]; f[N]=fxe; } else { for(j=0;j<4;j++)sim[N][j]=xr[j]; f[N]=fxr; } }
    else { if(fxr<f[N-1]){ for(j=0;j<4;j++)sim[N][j]=xr[j]; f[N]=fxr; }
      else { if(fxr<f[N]){ double xc[4]; for(j=0;j<4;j++) xc[j]=(1+psi*rho)*xbar[j]-psi*rho*sim[N][j]; sci_clip(xc,lb,ub);
          double fxc=sci_pen(xc,ax,ay,ar,na,beff);
          if(fxc<=fxr){ for(j=0;j<4;j++)sim[N][j]=xc[j]; f[N]=fxc; } else doshrink=1; }
        else { double xcc[4]; for(j=0;j<4;j++) xcc[j]=(1-psi)*xbar[j]+psi*sim[N][j]; sci_clip(xcc,lb,ub);
          double fxcc=sci_pen(xcc,ax,ay,ar,na,beff);
          if(fxcc<f[N]){ for(j=0;j<4;j++)sim[N][j]=xcc[j]; f[N]=fxcc; } else doshrink=1; }
        if(doshrink){ for(k=1;k<=N;k++){ for(j=0;j<4;j++) sim[k][j]=sim[0][j]+sigma*(sim[k][j]-sim[0][j]);
          sci_clip(sim[k],lb,ub); f[k]=sci_pen(sim[k],ax,ay,ar,na,beff); } } } }
    it++; sci_sort5(sim,f);
  }
  for(j=0;j<4;j++) best[j]=sim[0][j]; *bf=f[0];
}
/* PoreAnalyser two-pass insert_ellipse, faithfully. Returns a; minor(reported)->*ob, theta->*oth, centre->*ocx/ocy. */
static double pa_fit(const double *ax, const double *ay, const double *ar, int na,
                     double b, double px, double py, double n_xy, double *ob, double *oth, double *ocx, double *ocy)
{
  double cogx=0, cogy=0; int i; double PI=3.141592653589793;
  /* PoreAnalyser's probe-shrink: while penalty_overlap_4dim([r,0,px,py],[r,a_vec])>0, r*=0.95.
     Their penalty builds a CIRCLE ellipse(a=r,b=r) and tests it with dist_ellipse_vdwSphere,
     so we call pa_ev with a=b=r rather than a hand-rolled centre-distance test - same
     predicate, same rounding. Unbounded while, exactly as theirs (it terminates: r shrinks
     geometrically until no atom overlaps). */
  /* theta=0.0 and the centre (px,py) are the same for every atom AND every shrink
     iteration below - see the pa_on/pa_ev comment. Hoisted once for the whole loop,
     not just one na-scan (only b changes per iteration). */
  { double c_nth0 = cos(-0.0), s_nth0 = sin(-0.0), c_th0 = cos(0.0), s_th0 = sin(0.0);
    double rc10 = px*c_nth0-py*s_nth0, rc20 = px*s_nth0+py*c_nth0;
    for (;;) {
      int ov=0;
      for(i=0;i<na;i++)
        if(pa_ev(b,b,c_nth0,s_nth0,c_th0,s_th0,rc10,rc20,px,py,ax[i],ay[i],ar[i])<0){ov=1;break;}
      if(!ov) break;
      b*=0.95;
    }
  }
  *ob=b;
  for(i=0;i<na;i++){ cogx+=ax[i]; cogy+=ay[i]; } if(na){cogx/=na;cogy/=na;}
  { double dx1=0.1*b, sim[5][4], lb[4], ub[4], bh[4],fh, bc[4],fc, b1[4], b2[4],f2, dx2;
    int j;
    /* pass 1 bounds (centre box around HOLE centre px,py) */
    lb[0]=0; ub[0]=n_xy; lb[1]=-PI; ub[1]=PI; lb[2]=px-dx1; ub[2]=px+dx1; lb[3]=py-dx1; ub[3]=py+dx1;
    /* HOLE simplex, rad_fac=0.9 -> beff=0.9*b */
    sim[0][0]=0.9*b; sim[0][1]=0;    sim[0][2]=px;         sim[0][3]=py;
    sim[1][0]=b+0.1; sim[1][1]=PI/4; sim[1][2]=px;         sim[1][3]=py;
    sim[2][0]=b+0.11;sim[2][1]=PI/2; sim[2][2]=px;         sim[2][3]=py;
    sim[3][0]=b+0.12;sim[3][1]=PI/4; sim[3][2]=px+dx1*0.5; sim[3][3]=py+dx1*0.5;
    sim[4][0]=b+0.13;sim[4][1]=PI/2; sim[4][2]=px-dx1*0.5; sim[4][3]=py-dx1*0.5;
    sci_nm(sim,ax,ay,ar,na,0.9*b,lb,ub,800,bh,&fh);
    /* COG simplex (bounds still around HOLE centre) */
    sim[0][0]=0.9*b; sim[0][1]=0;     sim[0][2]=cogx;         sim[0][3]=cogy;
    sim[1][0]=b+0.13;sim[1][1]=-PI/4; sim[1][2]=cogx;         sim[1][3]=cogy;
    sim[2][0]=b+0.12;sim[2][1]=PI/2;  sim[2][2]=cogx;         sim[2][3]=cogy;
    sim[3][0]=b+0.11;sim[3][1]=-PI/4; sim[3][2]=cogx+dx1*0.5; sim[3][3]=cogy+dx1*0.5;
    sim[4][0]=b+0.10;sim[4][1]=PI/2;  sim[4][2]=cogx-dx1*0.5; sim[4][3]=cogy-dx1*0.5;
    sci_nm(sim,ax,ay,ar,na,0.9*b,lb,ub,800,bc,&fc);
    /* optimisation_ellipsoid returns p0 (the seed CIRCLE, a=b, theta=0, at THAT seed's own
       centre) when result.fun > 0, else p1. So the HOLE run falls back to a circle at
       (px,py) and the COG run to a circle at (cogx,cogy) - not both at (px,py). Their
       predicate is strictly `fun > 0`, so fun==0 keeps p1. Then: if p1_COG.a > p1_HOLE.a
       take COG else HOLE. */
    { double ah, ac, hole_c[4], cog_c[4];
      if(fh>0){ hole_c[0]=b; hole_c[1]=0; hole_c[2]=px; hole_c[3]=py; }
      else    { for(j=0;j<4;j++) hole_c[j]=bh[j]; }
      if(fc>0){ cog_c[0]=b; cog_c[1]=0; cog_c[2]=cogx; cog_c[3]=cogy; }
      else    { for(j=0;j<4;j++) cog_c[j]=bc[j]; }
      ah=hole_c[0]; ac=cog_c[0];
      if(ac>ah){ for(j=0;j<4;j++) b1[j]=cog_c[j]; }
      else     { for(j=0;j<4;j++) b1[j]=hole_c[j]; } }
    /* pass 2: rad_fac=0.99, bounds a in [b1.a,n_xy], centre px +/- 0.5*b1.a, PA pass-2 simplex */
    dx2=0.5*b1[0];
    lb[0]=b1[0]; ub[0]=n_xy; lb[2]=px-dx2; ub[2]=px+dx2; lb[3]=py-dx2; ub[3]=py+dx2;
    { double a1=b1[0], th1=b1[1], c1x=b1[2], c1y=b1[3], dr=0.15;
      sim[0][0]=0.99*a1; sim[0][1]=th1; sim[0][2]=c1x;              sim[0][3]=c1y;
      sim[1][0]=0.99*a1; sim[1][1]=th1; sim[1][2]=c1x+dr*cos(th1);  sim[1][3]=c1y+dr*sin(th1);
      sim[2][0]=0.99*a1; sim[2][1]=th1; sim[2][2]=c1x-dr*cos(th1);  sim[2][3]=c1y-dr*sin(th1);
      sim[3][0]=0.99*a1; sim[3][1]=th1; sim[3][2]=c1x-dr*sin(th1);  sim[3][3]=c1y+dr*cos(th1);
      sim[4][0]=0.99*a1; sim[4][1]=th1; sim[4][2]=c1x+dr*sin(th1);  sim[4][3]=c1y-dr*cos(th1); }
    sci_nm(sim,ax,ay,ar,na,0.99*b,lb,ub,800,b2,&f2);
    /* pass 2's p0 IS p1, so `fun > 0` falls back to p1 (their strict >, not >=). */
    if(f2>0){ for(j=0;j<4;j++) b2[j]=b1[j]; }
    /* PoreAnalyser reverts (insert_ellipse, after the pass-2 call) */
    { double mv=hypot(b2[2]-b1[2],b2[3]-b1[3]), thr=(b>7?b:7);
      /* theirs is `p2.a/p1.a > 1.5`. p1.a==0 cannot actually WIN pass 1 (sim[0] is the
         0.9b circle, always feasible after the shrink, scoring -0.9b < -0.0), so this is
         DEFENSIVE only - but the bound admits a==0 and the Tcl mirror would throw
         "divide by zero" outright, so both sides guard it identically: a1==0 with any
         a2>0 is a runaway, the same verdict an unguarded +inf compare reaches. */
      if(mv>thr || (b1[0]>0.0 ? b2[0]/b1[0]>1.5 : b2[0]>0.0)){ for(j=0;j<4;j++) b2[j]=b1[j]; }
      if(na<30){
        for(j=0;j<4;j++) b2[j]=b1[j];
        /* theirs: `if p1.a > 3*p0.a: return -1, -1` -> the slice is DROPPED, not
           emitted as a circle. Signal that to the caller with a=-1. */
        if(b1[0]>3.0*b){ *ob=-1.0; *oth=0; *ocx=px; *ocy=py; return -1.0; }
      } }
    *oth=b2[1]; *ocx=b2[2]; *ocy=b2[3]; return (b2[0]>b?b2[0]:b);
  }
}/* Per real centerline sphere: build the local tangent frame, project near atoms into the  */
/* perpendicular plane (pu,pv with projected vdW radius pr), then fit the PoreAnalyser      */
/* ellipse. Same sphere-keep and near-atom gather the Tcl path uses, so C and Tcl      */
/* align sphere-for-sphere. Emits "b a 0" per sphere (rmin=b, rmax=a) - or, with_geo,    */
/* "b a 0 theta ecx ecy" (fitted orientation + in-plane centre offset from the HOLE sphere,  */
/* for the reshaped-surface geometry, which needs the true fitted centre, not just a/b).     */
/* Mirrors _asym_ellipse_tcl; C and Tcl agree within float. */

static void compute_ellipse(int N, FILE *out, int with_geo)
{
  int i, ki, nk = 0;
  int *keep;
  double *rbs, *ra, *rth, *recx, *recy;  /* per-slice results, emitted in ki order after the loop */
  keep = (int*) malloc((n_sph > 0 ? n_sph : 1) * sizeof(int));
  if (!keep) return;
  for (i = 0; i < n_sph; i++) if (sph_r[i] > 0.005) keep[nk++] = i;
  /* PoreAnalyser aligns the pore's principal axis to z and slices in FIXED global z-planes. We use
     ONE fixed slicing axis for all slices (not a per-sphere tangent, which wobbles): the pore vector
     passed in asym_axis (the HOLE cvect) when given - exactly PoreAnalyser's z - else, as a fallback,
     the principal axis (PCA, power iteration) of the near-pore ATOM cloud. A fixed in-plane basis is
     built from it by Gram-Schmidt. */
  double tx, ty, tz, bx, by, bz, wx, wy, wz;
  {
    double ex,ey,ez,edt,bn;
    if (asym_axis[0]!=0.0 || asym_axis[1]!=0.0 || asym_axis[2]!=0.0) {
      double an=sqrt(asym_axis[0]*asym_axis[0]+asym_axis[1]*asym_axis[1]+asym_axis[2]*asym_axis[2]);
      tx=asym_axis[0]/an; ty=asym_axis[1]/an; tz=asym_axis[2]/an;
    } else {
      double mx=0,my=0,mz=0, cxx=0,cxy=0,cxz=0,cyy=0,cyz=0,czz=0; int it, na3=(n_at3>0?n_at3:1);
      for (i=0; i<n_at3; i++){ mx+=at3_x[i]; my+=at3_y[i]; mz+=at3_z[i]; }
      mx/=na3; my/=na3; mz/=na3;
      for (i=0; i<n_at3; i++){ double dx=at3_x[i]-mx, dy=at3_y[i]-my, dz=at3_z[i]-mz;
        cxx+=dx*dx; cxy+=dx*dy; cxz+=dx*dz; cyy+=dy*dy; cyz+=dy*dz; czz+=dz*dz; }
      tx=0; ty=0; tz=1;
      for (it=0; it<128; it++){ double nx=cxx*tx+cxy*ty+cxz*tz, ny=cxy*tx+cyy*ty+cyz*tz, nz=cxz*tx+cyz*ty+czz*tz;
        double nn=sqrt(nx*nx+ny*ny+nz*nz); if(nn<1e-12) break; tx=nx/nn; ty=ny/nn; tz=nz/nn; }
    }
    if (fabs(tx) < 0.9){ ex=1; ey=0; ez=0; } else { ex=0; ey=1; ez=0; }
    edt=ex*tx+ey*ty+ez*tz; bx=ex-edt*tx; by=ey-edt*ty; bz=ez-edt*tz;
    bn=sqrt(bx*bx+by*by+bz*bz); bx/=bn; by/=bn; bz/=bn;
    wx=ty*bz-tz*by; wy=tz*bx-tx*bz; wz=tx*by-ty*bx;
  }
  rbs  = (double*) xa_malloc((nk > 0 ? nk : 1) * sizeof(double));
  ra   = (double*) xa_malloc((nk > 0 ? nk : 1) * sizeof(double));
  rth  = (double*) malloc((nk > 0 ? nk : 1) * sizeof(double));
  recx = (double*) malloc((nk > 0 ? nk : 1) * sizeof(double));
  recy = (double*) malloc((nk > 0 ? nk : 1) * sizeof(double));
  if (!rbs || !ra || !rth || !recx || !recy) {
    free(keep); free(rbs); free(ra); free(rth); free(recx); free(recy); return;
  }
  /* Each slice's ellipse fit is independent and pure (no shared mutable state), so the slice
     loop parallelises with BYTE-IDENTICAL results: per-thread scratch (pu/pv/pr), one result
     slot per slice (no write races), output emitted in ki order AFTER the loop. Thread count
     defaults to 1 (asym_threads / --asym-threads N); the single-frame caller opts up to nproc
     while each BATCH worker keeps 1 thread, so N worker PROCESSES don't oversubscribe the cores.
     Pragmas are no-ops without -fopenmp, so the binary still builds and runs serially there. */
  #pragma omp parallel num_threads(asym_threads > 0 ? asym_threads : 1)
  {
    double *pu = (double*) xa_malloc((n_at3 > 0 ? n_at3 : 1) * sizeof(double));
    double *pv = (double*) xa_malloc((n_at3 > 0 ? n_at3 : 1) * sizeof(double));
    double *pr = (double*) xa_malloc((n_at3 > 0 ? n_at3 : 1) * sizeof(double));
    int kj;
    double t_gather_local = 0.0, t_fit_local = 0.0; /* PROFILING ONLY, see g_ellipse_timing */
    #pragma omp for schedule(dynamic, 8)
    for (kj = 0; kj < nk; kj++) {
      if (!pu || !pv || !pr) { ra[kj] = -1.0; rbs[kj] = 0.0; rth[kj] = 0.0; recx[kj] = 0.0; recy[kj] = 0.0; continue; }
      {
      int idx = keep[kj];
      double cx = sph_x[idx], cy = sph_y[idx], cz = sph_z[idx], b = sph_r[idx];
      double nxf = 3.0; int tries, kk, np = 0;
      double a, th = 0.0, ecx = 0.0, ecy = 0.0, bs = 0.0;
      double t0 = g_ellipse_timing ? now_sec() : 0.0;
      /* PoreAnalyser neighbor_vec: xy-box |u|,|v|<n_xy=n_xy_fac*b, z-slab |dt|<2 AND |dt|<R0
         (R_projected>0); adapt n_xy_fac to keep 30..150 atoms (calls<4), like their recursion. */
      for (tries = 0; tries < 5; tries++) {
        double nxy = nxf*b; np = 0;
        for (kk = 0; kk < n_at3; kk++) {
          double ddx = at3_x[kk]-cx, ddy = at3_y[kk]-cy, ddz = at3_z[kk]-cz;
          double dt = ddx*tx+ddy*ty+ddz*tz, R0 = at3_v[kk], u, v;
          if (fabs(dt) >= 2.0 || fabs(dt) >= R0) continue;
          u = ddx*bx+ddy*by+ddz*bz; v = ddx*wx+ddy*wy+ddz*wz;
          if (u <= -nxy || u >= nxy || v <= -nxy || v >= nxy) continue;
          pr[np] = sqrt(R0*R0 - dt*dt); pu[np] = u; pv[np] = v; np++;
        }
        if (np > 150 && tries < 4) nxf *= 0.75;
        else if (np < 30 && tries < 4) nxf *= 1.25;
        else break;
      }
      if (g_ellipse_timing) { double t1 = now_sec(); t_gather_local += (t1-t0); t0 = t1; }
      a = pa_fit(pu, pv, pr, np, b, 0.0, 0.0, nxf*b, &bs, &th, &ecx, &ecy);
      if (g_ellipse_timing) t_fit_local += now_sec() - t0;
      ra[kj] = a; rbs[kj] = bs; rth[kj] = th; recx[kj] = ecx; recy[kj] = ecy;
      }
    }
    free(pu); free(pv); free(pr);
    if (g_ellipse_timing) {
      #pragma omp atomic
      g_time_gather += t_gather_local;
      #pragma omp atomic
      g_time_fit += t_fit_local;
    }
  }
  /* Emit in slice order. pa_fit returns a<0 for PoreAnalyser's own `return -1,-1` drop rule
     (<30 neighbours AND pass-1 a > 3*probe.r); nesc=-1 lets the Tcl side tell that apart from
     the all-rays-escaped case (rmin<0 with nesc>=0). */
  for (ki = 0; ki < nk; ki++) {
    double a = ra[ki], bs = rbs[ki];
    if (a < 0) {
      if (with_geo) fprintf(out, "-1.000000 -1.000000 -1 0.000000 0.000000 0.000000\n");
      else          fprintf(out, "-1.000000 -1.000000 -1\n");
    } else if (with_geo) {
      fprintf(out, "%.6f %.6f %d %.6f %.6f %.6f\n", bs, (a > bs ? a : bs), 0, rth[ki], recx[ki], recy[ki]);
    } else {
      fprintf(out, "%.6f %.6f %d\n", bs, (a > bs ? a : bs), 0);
    }
  }
  free(keep); free(rbs); free(ra); free(rth); free(recx); free(recy);
}

/* Render-only atom clip for the reshaped-pore surface. Reads the (already smoothed) per-slice
   ellipse geometry from geofile - one line "cx cy cz bhx bhy bhz whx why whz a b th" per slice -
   rebuilds each slice's `ring` polar-radius vertices, and pulls any vertex that would poke into a
   protein vdW sphere back to that atom's surface (2-D ray-sphere in the slice plane). Emits the
   clipped radii, `ring` per line. Does NOT touch the fit or any reported number: it only stops the
   drawn tube from bulging past atoms the fit's neighbour box let it grow past (see compute_ellipse:
   PoreAnalyser's box is sized by the MINOR axis, so the major can overshoot - PA has the same, so
   our numbers still match; we fix the DRAWING, not the fit). Atoms are sliced by a z-slab along the
   fixed axis (asym_axis, or z), so each vertex tests only the ~hundreds of atoms near its slice. */
typedef struct { double g; int k; } clip_gpair;
static int clip_cmp_gpair(const void *A, const void *B){
  double d = ((const clip_gpair*)A)->g - ((const clip_gpair*)B)->g;
  return d < 0 ? -1 : (d > 0 ? 1 : 0);
}
static void clip_rings(const char *geofile, FILE *out, int ring)
{
  FILE *gf = fopen(geofile, "r");
  if (!gf) return;
  double axx = asym_axis[0], axy = asym_axis[1], axz = asym_axis[2];
  double an = sqrt(axx*axx + axy*axy + axz*axz);
  if (an < 1e-9) { axx = 0; axy = 0; axz = 1; } else { axx/=an; axy/=an; axz/=an; }
  clip_gpair *gp = (clip_gpair*) xa_malloc((n_at3 > 0 ? n_at3 : 1) * sizeof(clip_gpair));
  if (gp) {
    int i;
    for (i = 0; i < n_at3; i++) { gp[i].g = at3_x[i]*axx + at3_y[i]*axy + at3_z[i]*axz; gp[i].k = i; }
    qsort(gp, n_at3, sizeof(clip_gpair), clip_cmp_gpair);
  }
  double PI = 3.14159265358979323846;
  char buf[512];
  while (fgets(buf, sizeof buf, gf)) {
    double cx,cy,cz,bhx,bhy,bhz,whx,why,whz,a,b,th;
    int k;
    if (sscanf(buf, "%lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf %lf",
               &cx,&cy,&cz,&bhx,&bhy,&bhz,&whx,&why,&whz,&a,&b,&th) != 12) continue;
    /* z-slab of atoms about this slice (|dt| < vdW <= ~2.1, use 3.0 margin) */
    double s = cx*axx + cy*axy + cz*axz;
    int blo = 0, bhi = n_at3, bi;
    if (gp) {
      double klo = s - 3.0, khi = s + 3.0; int lo, hi, m;
      lo = 0; hi = n_at3; while (lo < hi) { m = (lo+hi)/2; if (gp[m].g < klo) lo = m+1; else hi = m; } blo = lo;
      lo = 0; hi = n_at3; while (lo < hi) { m = (lo+hi)/2; if (gp[m].g <= khi) lo = m+1; else hi = m; } bhi = lo;
    }
    for (k = 0; k < ring; k++) {
      double ph = 2.0*PI*k/ring, cc = cos(ph-th), ss = sin(ph-th);
      double rr = a*b / sqrt(b*b*cc*cc + a*a*ss*ss);
      double dx = cos(ph), dy = sin(ph), rrc = rr;
      for (bi = blo; bi < bhi; bi++) {
        int ai = gp ? gp[bi].k : bi;
        double ddx = at3_x[ai]-cx, ddy = at3_y[ai]-cy, ddz = at3_z[ai]-cz;
        double dt = ddx*axx + ddy*axy + ddz*axz, ar = at3_v[ai];
        if (fabs(dt) >= ar || ar <= 0.0) continue;
        double u = ddx*bhx + ddy*bhy + ddz*bhz, v = ddx*whx + ddy*why + ddz*whz;
        double pr = sqrt(ar*ar - dt*dt);              /* atom's radius projected into the slice */
        double ex = -u, ey = -v, edd = ex*dx + ey*dy; /* 2-D ray from centre (origin) along (dx,dy) */
        double disc = edd*edd - ((ex*ex + ey*ey) - pr*pr);
        if (disc <= 0.0) continue;
        double tn = -edd - sqrt(disc);
        if (tn > 0.0 && tn < rrc) rrc = tn;
      }
      fprintf(out, k ? " %.6f" : "%.6f", rrc);
    }
    fprintf(out, "\n");
  }
  free(gp);
  fclose(gf);
}

static void push_res3d(double x, double y, double z, double h)
{
  if (n_res3d == res3d_cap) {
    res3d_cap = res3d_cap ? res3d_cap * 2 : 256;
    res3d_x = xrealloc(res3d_x, res3d_cap*sizeof(double), "res3d_x");
    res3d_y = xrealloc(res3d_y, res3d_cap*sizeof(double), "res3d_y");
    res3d_z = xrealloc(res3d_z, res3d_cap*sizeof(double), "res3d_z");
    res3d_h = xrealloc(res3d_h, res3d_cap*sizeof(double), "res3d_h");
  }
  res3d_x[n_res3d]=x; res3d_y[n_res3d]=y; res3d_z[n_res3d]=z; res3d_h[n_res3d]=h;
  n_res3d++;
}

/* Build the res3d[] Nadaraya-Watson contributors from the atom sidecar by doing */
/* the pore-lining (and, in residue mode, facing) test in C - the exact same     */
/* test the Tcl _lining_facing_sets/compute_sphere_hydro did, just here so it     */
/* runs inside the parallel batch. Lining: an atom is within thresh of the local */
/* surface iff |dist_to_nearest_sphere_centre - that_sphere_radius| <= thresh.    */
static void hydro3d_build_contributors(void)
{
  int i;
  int *al = NULL;   /* per-atom "within thresh of the surface" lining flag */
  if (n_sph <= 0 || n_at3 <= 0) return;
  /* The per-atom nearest-sphere lining test is O(n_at3 x n_sph) and is the single
     hot spot of a CONNOLLY recolour: n_sph is the whole ~185k flood-fill cloud, so
     each hydro3d_nearest_sphere() is a 185k linear scan. Each atom is independent,
     so compute every atom's lining flag in ONE OpenMP pass here; the accumulation
     and push below then stay SERIAL, so res3d[] keeps its exact order and
     hydro_at_point_3d's FP sum is identical to the serial build. Falls back to
     the original inline serial test if the flag array can't be allocated.
     ONLY built when actually threading (recolor_threads > 1): the serial path
     below keeps the original per-residue early-stop (test atoms only until the
     residue is found lining), which the pre-computed all-atoms flag would defeat -
     so a batch worker (1 thread) is never slower than before. */
  if (recolor_threads > 1) {
    al = xa_malloc((size_t)n_at3 * sizeof(int));
    if (al) {
#ifdef _OPENMP
#pragma omp parallel for schedule(static) num_threads(recolor_threads)
#endif
      for (i = 0; i < n_at3; i++) {
        double d2, r;
        hydro3d_nearest_sphere(at3_x[i], at3_y[i], at3_z[i], &d2, &r);
        al[i] = (fabs(sqrt(d2) - r) <= hydro3d_thresh) ? 1 : 0;
      }
    }
  }
  if (hydro3d_lining == 2) {
    /* ATOM mode (KR): each atom within thresh of the surface is its own
       contributor, carrying its own +/-1 value. No facing (atom-level). Pushed in
       file order so res3d[] order matches the serial path exactly. */
    for (i = 0; i < n_at3; i++) {
      int lining;
      if (al) { lining = al[i]; }
      else { double d2, r; hydro3d_nearest_sphere(at3_x[i], at3_y[i], at3_z[i], &d2, &r);
             lining = (fabs(sqrt(d2) - r) <= hydro3d_thresh); }
      if (lining) push_res3d(at3_x[i], at3_y[i], at3_z[i], at3_v[i]);
    }
    free(al);
    return;
  }
  /* RESIDUE mode: group by integer resid; per residue compute COG + CA, test
     "any atom within thresh" for lining, and (if facing) COG closer to a sphere
     centre than the CA. Contributor = COG, value = the residue's property. */
  {
    int maxr = -1;
    for (i = 0; i < n_at3; i++) {
      if (at3_resid[i] < 0) continue;          /* skip malformed (negative) residue ids */
      if (at3_resid[i] > maxr) maxr = at3_resid[i];
    }
    if (maxr < 0) { free(al); return; }
    /* Residue ids are 0-based and dense, so a bound tied to the atom count is safe;
       reject a corrupt sidecar with a garbage-huge id before it triggers a wild alloc. */
    if (maxr > n_at3 + 1000000) { free(al); return; }
    int nres = maxr + 1;
    double *sx = xa_calloc(nres, sizeof(double)), *sy = xa_calloc(nres, sizeof(double));
    double *sz = xa_calloc(nres, sizeof(double)), *val = xa_calloc(nres, sizeof(double));
    int    *cnt = calloc(nres, sizeof(int)), *lin = calloc(nres, sizeof(int));
    double *cax = calloc(nres, sizeof(double)), *cay = calloc(nres, sizeof(double));
    double *caz = calloc(nres, sizeof(double)); int *hasca = calloc(nres, sizeof(int));
    if (!sx||!sy||!sz||!val||!cnt||!lin||!cax||!cay||!caz||!hasca) {
      free(sx);free(sy);free(sz);free(val);free(cnt);free(lin);
      free(cax);free(cay);free(caz);free(hasca); free(al); return;
    }
    for (i = 0; i < n_at3; i++) {
      int r = at3_resid[i];
      if (r < 0 || r >= nres) continue;   /* skip malformed ids (defensive) */
      sx[r] += at3_x[i]; sy[r] += at3_y[i]; sz[r] += at3_z[i];
      cnt[r]++; val[r] = at3_v[i];        /* constant per residue */
      if (at3_isca[i]) { cax[r]=at3_x[i]; cay[r]=at3_y[i]; caz[r]=at3_z[i]; hasca[r]=1; }
      if (!lin[r]) {
        int lining;
        if (al) { lining = al[i]; }
        else { double d2, rr; hydro3d_nearest_sphere(at3_x[i], at3_y[i], at3_z[i], &d2, &rr);
               lining = (fabs(sqrt(d2) - rr) <= hydro3d_thresh); }
        if (lining) lin[r] = 1;
      }
    }
    for (i = 0; i < nres; i++) {
      if (cnt[i] == 0 || !lin[i]) continue;
      double cogx = sx[i]/cnt[i], cogy = sy[i]/cnt[i], cogz = sz[i]/cnt[i];
      if (hydro3d_facing) {
        if (!hasca[i]) continue;                 /* facing needs a CA */
        double d2c, rc, d2a, ra;
        hydro3d_nearest_sphere(cogx, cogy, cogz, &d2c, &rc);
        hydro3d_nearest_sphere(cax[i], cay[i], caz[i], &d2a, &ra);
        if (!(d2c < d2a)) continue;              /* COG must be closer to axis than CA */
      }
      push_res3d(cogx, cogy, cogz, val[i]);
    }
    free(sx);free(sy);free(sz);free(val);free(cnt);free(lin);
    free(cax);free(cay);free(caz);free(hasca);
  }
  free(al);
}

/* True 3D Gaussian-kernel-weighted (Nadaraya-Watson) hydrophobicity at a real   */
/* surface point - same formula as the plugin's Tcl compute_sphere_hydro        */
/* residue-mode smoother, but using REAL 3D Euclidean distance from (px,py,pz)   */
/* to every qualifying residue instead of 1D distance along the channel axis.   */
/* This is what actually varies by angular position around the pore, not just   */
/* by height - see hydro_at_point() above for the axial-only equivalent this    */
/* sits alongside (not replaces). O(n_res3d) per call; n_res3d is a few dozen   */
/* (the qualifying lining residues for this frame), so no spatial index is      */
/* needed even at thousands of triangle calls.                                  */
static double hydro_at_point_3d(double px, double py, double pz)
{
  int i;
  double ksum = 0.0, wsum = 0.0;
  double inv2bw2 = 1.0 / (2.0 * hydro3d_bandwidth * hydro3d_bandwidth);
  for (i = 0; i < n_res3d; i++) {
    double dx = px-res3d_x[i], dy = py-res3d_y[i], dz = pz-res3d_z[i];
    double d2 = dx*dx + dy*dy + dz*dz;
    double k = exp(-d2 * inv2bw2);
    ksum += k;
    wsum += k * res3d_h[i];
  }
  return (ksum > 1e-300) ? (wsum / ksum) : 0.0;
}

/* --hydro3d-props: score every (deduplicated) dot with hydro_at_point_3d(),
   bin it to its nearest INPUT sphere (linear scan - n_dots x n_sph is still
   only a few million ops even at thousands of dots and hundreds of spheres,
   negligible next to the triangulation this mode skips), and write the
   per-sphere MEAN to hydro3d_props_path, one value per line, in .sph file
   order. Spheres with zero nearby dots (should not happen for a real,
   non-degenerate surface, but guarded anyway) get 0.0 rather than an
   uninitialized or NaN value. */
static void hydro3d_write_props(void)
{
  double *sum; int *cnt;
  int i, s;
  FILE *f;
  if (n_sph <= 0 || max_dots <= 0) return;
  sum = calloc(n_sph, sizeof(double));
  cnt = calloc(n_sph, sizeof(int));
  if (!sum || !cnt) { free(sum); free(cnt); return; }
  for (i = 0; i < max_dots; i++) {
    double px = dots[i][0], py = dots[i][1], pz = dots[i][2];
    double v = hydro_at_point_3d(px, py, pz);
    double best = 1e30; int besti = 0;
    for (s = 0; s < n_sph; s++) {
      double dx = px-sph_x[s], dy = py-sph_y[s], dz = pz-sph_z[s];
      double d2 = dx*dx + dy*dy + dz*dz;
      if (d2 < best) { best = d2; besti = s; }
    }
    sum[besti] += v; cnt[besti]++;
  }
  f = fopen(hydro3d_props_path, "w");
  if (f) {
    for (s = 0; s < n_sph; s++)
      fprintf(f, "%.8g\n", cnt[s] > 0 ? sum[s]/(double)cnt[s] : 0.0);
    fclose(f);
  }
  free(sum); free(cnt);
}

/* Read the plugin's channel-local atom sidecar: whitespace-separated rows of   */
/* "x y z h_kd h_ww". h_kd/h_ww are the per-atom hydropathy on each scale,      */
/* computed in Tcl so the scales have one source of truth.                      */
static void hydro_read_atoms(void)
{
  FILE *f = fopen(hydro_atoms_path, "r");
  char line[512];
  int cap = 0;
  if (!f) { fprintf(stderr, "\nhydro: cannot open atom file '%s'", hydro_atoms_path); return; }
  while (fgets(line, sizeof(line), f)) {
    /* strtod avoids sscanf's format re-parse in this hot loop (the sidecar can
       hold 10^5+ atoms) and parses each field to the same correctly-rounded
       double, so the averaged hydropathy is unchanged. A line missing any of the
       5 fields is skipped exactly as the old sscanf-!=5 guard did. */
    char *p = line, *e;
    double x,y,z,hkd,hww;
    x   = strtod(p, &e); if (e == p) continue; p = e;
    y   = strtod(p, &e); if (e == p) continue; p = e;
    z   = strtod(p, &e); if (e == p) continue; p = e;
    hkd = strtod(p, &e); if (e == p) continue; p = e;
    hww = strtod(p, &e); if (e == p) continue; p = e;
    if (n_atom == cap) {
      cap = cap ? cap * 2 : 4096;
      atom_x = xrealloc(atom_x, cap*sizeof(double), "atom_x"); atom_y = xrealloc(atom_y, cap*sizeof(double), "atom_y");
      atom_z = xrealloc(atom_z, cap*sizeof(double), "atom_z");
      atom_hkd = xrealloc(atom_hkd, cap*sizeof(double), "atom_hkd"); atom_hww = xrealloc(atom_hww, cap*sizeof(double), "atom_hww");
      if (hydro_residue_mode)
        atom_resid = xrealloc(atom_resid, cap*sizeof(int), "atom_resid");
    }
    atom_x[n_atom]=x; atom_y[n_atom]=y; atom_z[n_atom]=z;
    atom_hkd[n_atom]=hkd; atom_hww[n_atom]=hww;
    if (hydro_residue_mode && atom_resid) {
      /* Optional 6th column: integer residue ID assigned by Tcl write_hydro_sidecar_batch.
         If absent (old sidecar), fall back to atom index so each atom is its own residue
         (equivalent to atom-mean). strtod advances p past whitespace automatically. */
      long rid = strtol(p, &e, 10);
      atom_resid[n_atom] = (e != p) ? (int)rid : n_atom;
      if (atom_resid[n_atom] > max_resid_val) max_resid_val = atom_resid[n_atom];
    }
    n_atom++;
  }
  fclose(f);
}

/* For every sphere, average the hydropathy of atoms within (r + shell) A, then  */
/* thin the spheres to <=200 keeping the last one -- exactly as the Tcl does     */
/* -- so the per-triangle nearest-sphere lookup matches.                         */
/*                                                                               */
/* A uniform spatial grid over the atoms makes this O(n_atom + n_sph) instead of */
/* the naive O(n_sph * n_atom): the cell size is (max sphere radius + shell), so */
/* every atom within a sphere's probe radius lies in the sphere's own cell or an */
/* immediate (27-cell) neighbour. The distance test inside the loop is unchanged */
/* (d2 <= probe2), so the grid accepts the SAME SET of atoms as the brute-force  */
/* scan and each average matches to floating-point rounding. NOTE: the summation */
/* ORDER differs from the input-order scan (cells are visited in grid order, and */
/* each cell's list is head-inserted), so the result is NOT guaranteed identical */
/* at the last ULP -- and for adversarial non-associative inputs it can differ.  */
/* For real hydropathy values the difference is negligible; do not rely on it    */
/* being bit-exact against an input-order reference.                             */
/* Thin the spheres to <=200 (stride = ceil(n/200), always keep the final one)  */
/* and build the thin[] index list. Both the atom-averaging and the pre-computed */
/* --hydro-values paths share this so the per-triangle nearest-sphere lookup is   */
/* identical regardless of how sph_h[] was filled.                                */
static void hydro_thin_spheres(void)
{
  int i, cap = 200;
  thin = xa_malloc((n_sph + 1) * sizeof(int));
  n_thin = 0;
  if (n_sph > cap) {
    int stride = (int)ceil(n_sph / (double)cap);
    if (stride < 1) stride = 1;
    for (i = 0; i < n_sph; i += stride) thin[n_thin++] = i;
    if (n_thin == 0 || thin[n_thin-1] != n_sph-1) thin[n_thin++] = n_sph-1;
  } else {
    for (i = 0; i < n_sph; i++) thin[n_thin++] = i;
  }
}

/* Safe replacement for `(int)((v-origin)/cell)` in the atom/sphere grid
 * below: the same NaN/Inf-cast UB cell_index() closes for .sos dot cells
 * (see its own comment above), reached here from a corrupt atom or sphere
 * coordinate instead of a corrupt dot.
 *
 * Keeps the exact truncating cast - not floor() - for every finite result,
 * so binning and lookup stay bit-identical for real coordinates including
 * ones outside the atom bounding box (spheres are not bbox-clamped, and
 * truncation of a negative quotient already differs from floor there; this
 * must not add a second difference). GRID_OOR is a huge, clearly-outside
 * sentinel, not a clamp into [0,dim): the +-1 neighbour walk's own
 * `ni<0||ni>=gx` bounds check already discards a real coordinate that far
 * outside the grid, so a NaN/Inf one is discarded the identical way.
 */
#define GRID_OOR (1<<28)
static int hydro_cell(double v, double origin, double cell)
{
  double q = (v - origin) / cell;
  if (!(q > -(double)GRID_OOR && q < (double)GRID_OOR)) return GRID_OOR;
  return (int)q;
}

static void hydro_compute_sphere_h(void)
{
  int i, j;
  double *col = hydro_kd ? atom_hkd : atom_hww;
  double cell, ox, oy, oz;
  double max_r = 0.0;
  int gx, gy, gz;                 /* grid dimensions */
  int *ghead = NULL, *gnext = NULL;
  long ncells;

  if (n_sph <= 0) { thin = xa_malloc(sizeof(int)); n_thin = 0; return; }

  /* Grid only pays off when there are atoms to bin; fall back to direct scan
     for the degenerate empty-atom case. */
  if (n_atom > 0) {
    double xlo=atom_x[0], xhi=atom_x[0];
    double ylo=atom_y[0], yhi=atom_y[0];
    double zlo=atom_z[0], zhi=atom_z[0];
    for (i = 0; i < n_sph; i++) if (sph_r[i] > max_r) max_r = sph_r[i];
    cell = max_r + hydro_shell_cut;
    if (cell < 1.0) cell = 1.0;
    for (j = 1; j < n_atom; j++) {
      if (atom_x[j]<xlo) xlo=atom_x[j]; else if (atom_x[j]>xhi) xhi=atom_x[j];
      if (atom_y[j]<ylo) ylo=atom_y[j]; else if (atom_y[j]>yhi) yhi=atom_y[j];
      if (atom_z[j]<zlo) zlo=atom_z[j]; else if (atom_z[j]>zhi) zhi=atom_z[j];
    }
    ox = xlo; oy = ylo; oz = zlo;
    /* atom_x[0] etc. seeded xlo/xhi before any finiteness check ran; a NaN
       seed makes every later `<`/`>` comparison in the bbox scan above false,
       so xlo/xhi silently stay NaN instead of being overwritten by the next
       finite atom. Route that the same place OOM already goes: no grid,
       direct O(n_atom) scan below, which has no cast to be undefined. */
    if (isfinite(xhi-xlo) && isfinite(yhi-ylo) && isfinite(zhi-zlo)) {
      gx = (int)((xhi-xlo)/cell) + 1;
      gy = (int)((yhi-ylo)/cell) + 1;
      gz = (int)((zhi-zlo)/cell) + 1;
      if (gx < 1) gx = 1;
      if (gy < 1) gy = 1;
      if (gz < 1) gz = 1;
      ncells = (long)gx * gy * gz;
      ghead = xa_malloc(ncells * sizeof(int));
      gnext = xa_malloc(n_atom * sizeof(int));
    }
    if (ghead && gnext) {
      long c;
      for (c = 0; c < ncells; c++) ghead[c] = -1;
      for (j = 0; j < n_atom; j++) {
        int ai = hydro_cell(atom_x[j], ox, cell);
        int aj = hydro_cell(atom_y[j], oy, cell);
        int ak = hydro_cell(atom_z[j], oz, cell);
        long idx;
        /* ai/aj/ak land in [0,gx)/[0,gy)/[0,gz) for every finite atom_x[j]
           by construction (xlo<=atom_x[j]<=xhi, same as gx's own derivation
           above) - this only ever fires for the GRID_OOR sentinel, i.e. a
           non-finite coordinate on THIS atom specifically (xlo/xhi can be
           finite while one later atom still isn't). Unlike the sphere
           lookup below, there is no bounds check downstream of the index
           write, so a corrupt atom must be excluded from the grid here,
           not merely have its cast made safe. */
        if (ai < 0 || ai >= gx || aj < 0 || aj >= gy || ak < 0 || ak >= gz) continue;
        idx = ((long)ak*gy + aj)*gx + ai;
        gnext[j] = ghead[idx];
        ghead[idx] = j;
      }
    } else { free(ghead); free(gnext); ghead = gnext = NULL; }  /* OOM: direct scan */
  }

  /* Residue-mean mode: stamp array lets us dedup by residue ID in O(1) per atom.
     stamp[rid] == i means residue rid was already counted for sphere i.
     Initialized to -1; sphere index i is used as the stamp value so no per-sphere
     memset is needed (each new i differs from any -1 or prior i). */
  int *restamp = NULL;
  if (hydro_residue_mode && atom_resid && max_resid_val >= 0) {
    restamp = xa_malloc((max_resid_val + 1) * sizeof(int));
    if (restamp) memset(restamp, -1, (max_resid_val + 1) * sizeof(int));
  }

  for (i = 0; i < n_sph; i++) {
    double probe = sph_r[i] + hydro_shell_cut;
    double probe2 = probe * probe;
    double sum = 0.0; int cnt = 0;
    if (ghead) {
      /* Spheres are not bbox-clamped like the atoms above (a probe can sit
         outside the atom cloud), so ci/cj/ck legitimately land outside
         [0,gx) for real coordinates too - the `ni<0||ni>=gx` check just
         below already discards every cell that's out of range, whatever
         the reason. GRID_OOR from a NaN/Inf sphere coordinate is discarded
         the same way, so no separate check is needed here. */
      int ci = hydro_cell(sph_x[i], ox, cell);
      int cj = hydro_cell(sph_y[i], oy, cell);
      int ck = hydro_cell(sph_z[i], oz, cell);
      int di, dj, dk;
      for (dk = -1; dk <= 1; dk++) for (dj = -1; dj <= 1; dj++) for (di = -1; di <= 1; di++) {
        int ni = ci+di, nj = cj+dj, nk = ck+dk;
        long idx; int a;
        if (ni < 0 || ni >= gx || nj < 0 || nj >= gy || nk < 0 || nk >= gz) continue;
        idx = ((long)nk*gy + nj)*gx + ni;
        for (a = ghead[idx]; a != -1; a = gnext[a]) {
          double dx = atom_x[a]-sph_x[i], dy = atom_y[a]-sph_y[i], dz = atom_z[a]-sph_z[i];
          double d2 = dx*dx + dy*dy + dz*dz;
          if (d2 <= probe2) {
            if (restamp) {
              /* restamp is sized from max_resid_val, which is only ever raised,
                 so a NEGATIVE id writes below the block - typically over the
                 chunk header freed at the end of this function. The sibling
                 hydro3d_build_contributors already skips negative ids; this
                 lookup did not. Ids come from a caller-supplied sidecar on the
                 public --hydro-residue CLI, so they are not guaranteed dense. */
              int rid = atom_resid[a];
              if (rid >= 0 && rid <= max_resid_val) {
                if (restamp[rid] != i) { restamp[rid] = i; sum += col[a]; cnt++; }
              }
            } else { sum += col[a]; cnt++; }
          }
        }
      }
    } else {
      for (j = 0; j < n_atom; j++) {
        double dx = atom_x[j]-sph_x[i], dy = atom_y[j]-sph_y[i], dz = atom_z[j]-sph_z[i];
        double d2 = dx*dx + dy*dy + dz*dz;
        if (d2 <= probe2) {
          if (restamp) {
            int rid = atom_resid[j];          /* bounds: see the grid branch above */
            if (rid >= 0 && rid <= max_resid_val) {
              if (restamp[rid] != i) { restamp[rid] = i; sum += col[j]; cnt++; }
            }
          } else { sum += col[j]; cnt++; }
        }
      }
    }
    if (cnt > 0) sph_h[i] = sum / (double)cnt;
  }
  free(restamp);
  free(ghead); free(gnext);
  hydro_thin_spheres();
}

/* Round to 3 decimals, matching the "%8.3f" the surface is written with. The
   Tcl colorize_hydrophobic reads triangle vertices back from that printed mesh,
   so basing the centroid on the rounded coordinates makes the compiled colours
   identical to the Tcl reference, not merely within rounding. */
static double r3(double v) { return nearbyint(v * 1000.0) / 1000.0; }

/* Nearest thinned sphere to a point; returns its averaged hydropathy. */
static double hydro_at_point(double px, double py, double pz)
{
  int k; double best = 1e20, best_h = 0.0;
  if (hydro_bands_mode) {
    for (k = 0; k < n_cl; k++) {
      int s = cl_idx[k];
      double dx = px-sph_x[s], dy = py-sph_y[s], dz = pz-sph_z[s];
      double d = sqrt(dx*dx + dy*dy + dz*dz) - sph_r[s];
      if (d < best) { best = d; best_h = sph_r[s]; }
    }
    return best_h;
  }
  for (k = 0; k < n_thin; k++) {
    int s = thin[k];
    double dx = px-sph_x[s], dy = py-sph_y[s], dz = pz-sph_z[s];
    double d2 = dx*dx + dy*dy + dz*dz;
    if (d2 < best) { best = d2; best_h = sph_h[s]; }
  }
  return best_h;
}

/* Fill sph_h[] + thin[] for the current job. Always reads the spheres; then      */
/* either loads pre-computed per-sphere values (--hydro-values, the agnostic fast */
/* path used for every scheme and lining/facing/side-chain mode) or averages the  */
/* atom sidecar (legacy kd/ww path). Leaves n_sph==0 for the caller to detect an  */
/* unusable input and fall back to an uncoloured surface.                         */
static void hydro_load(void)
{
  hydro_read_spheres();
  /* hydro3d contributor list. Two ways to get it:
     - hydro3d_lining != 0: the plugin handed us ALL channel-local atoms and we
       do the pore-lining/facing test here (needs the spheres, read above), then
       build the qualifying-contributor list (build 2026-07-08g).
     - else (legacy): the plugin already did the lining test in Tcl and handed us
       the pre-filtered {x y z value} contributor rows directly. */
  if (hydro3d_mode) {
    if (n_sph <= 0) return;
    if (hydro3d_precomputed) {
      /* --hydro3d-values-in: no per-frame residue positions needed - colours   */
      /* come from an already-averaged per-triangle values file (see             */
      /* recolor_vmd_plot) - skip both contributor-loading branches below.       */
    } else if (hydro3d_lining) { hydro3d_read_atoms_lining(); hydro3d_build_contributors(); }
    else                { hydro3d_read_residues(); }
    /* Still thin the spheres (--hydro-sph is passed for the n_sph>0 guards
       elsewhere), but skip the legacy atom sidecar entirely - hydro3d_mode
       never reads sph_h[] at colouring time. */
    hydro_thin_spheres();
    return;
  }
  if (n_sph <= 0) return;
  if (hydro_bands_mode) {
    int i;
    cl_idx = xa_malloc((n_sph + 1) * sizeof(int)); n_cl = 0;
    for (i = 0; i < n_sph; i++)
      if (!sph_flood[i] && sph_r[i] > 0.005 && sph_r[i] < 999.0) cl_idx[n_cl++] = i;
    hydro_thin_spheres();
    return;
  }
  if (hydro_values_mode) {
    hydro_read_values();
    hydro_thin_spheres();
  } else {
    hydro_read_atoms();
    hydro_compute_sphere_h();
  }
}

/* --recolor: read an already-triangulated base .vmd_plot and re-emit it with
   colours recomputed from the nearest channel sphere's hydropathy, skipping
   triangulation entirely. The base mesh's vertices are printed with %8.3f, i.e.
   r3()-rounded, so the centroid here matches vmd_out()'s exactly -> the colours
   are identical to a full --hydro pass, just far cheaper. Old "draw color" lines
   in the input are dropped and replaced; every other line is passed through. */
/* Original streaming implementation, kept as the fallback for the parallel
   version below when a buffer can't be allocated (or the input is tiny). */
static void recolor_vmd_plot_serial(const char *path)
{
  FILE *f = fopen(path, "r");
  char line[8192];
  const char *cur = "";
  if (!f) { fprintf(stderr, "\n--recolor: cannot open base surface: %s\n", path); return; }
  precomputed_idx = 0;
  while (fgets(line, sizeof(line), f)) {
    char *p = strstr(line, "draw triangle");
    if (!p) p = strstr(line, "draw trinorm");
    if (strstr(line, "draw color")) continue;   /* drop old colours */
    if (p) {
      double v[3][3];
      char *q = p;
      int i, got = 0;
      for (i = 0; i < 3; i++) {
        q = strchr(q, '{');
        if (!q) break;
        if (sscanf(q, "{ %lf %lf %lf", &v[i][0], &v[i][1], &v[i][2]) != 3 &&
            sscanf(q, "{%lf %lf %lf",  &v[i][0], &v[i][1], &v[i][2]) != 3) break;
        q++; got++;
      }
      if (got == 3) {
        double cx = (v[0][0]+v[1][0]+v[2][0])/3.0;
        double cy = (v[0][1]+v[1][1]+v[2][1])/3.0;
        double cz = (v[0][2]+v[1][2]+v[2][2])/3.0;
        double h;
        if (hydro3d_precomputed) {
          h = (precomputed_idx < n_precomputed) ? precomputed_vals[precomputed_idx] : 0.0;
          precomputed_idx++;
        } else {
          h = hydro3d_mode ? hydro_at_point_3d(cx,cy,cz) : hydro_at_point(cx,cy,cz);
        }
        const char *col = surface_color_name(h);
        if (strcmp(col, cur) != 0) { fprintf(stdout, "draw color %s\n", col); cur = col; }
      }
      fputs(line, stdout);          /* triangle geometry unchanged */
    } else {
      fputs(line, stdout);          /* "draw delete all", blank lines, etc. */
    }
  }
  fclose(f);
  fflush(stdout);
}

/* --recolor: read an already-triangulated base .vmd_plot and re-emit it with
   colours recomputed from each triangle's centroid, skipping triangulation.
   Parallelised over triangles: the per-triangle colour lookup (hydro_at_point_3d,
   the O(n_tri x n_atoms) hot spot for the CONNOLLY shell) is embarrassingly
   parallel, so this reads the whole base mesh into memory, computes every
   triangle's colour in an OpenMP loop, then emits the run-length "draw color"
   stream SEQUENTIALLY - identical to recolor_vmd_plot_serial() (same
   per-triangle FP sum, same colour bands, same encounter order, same colour-change
   encoding), just multi-core. hydro_at_point/_3d and the colour-name functions
   only READ globals and return string literals, so the loop needs no locks.
   Falls back to the serial streamer if a buffer can't be allocated. */
static void recolor_vmd_plot(const char *path)
{
  FILE *f;
  char buf[8192];
  char **lines = NULL;
  int n_lines = 0, cap_lines = 0, li, t;
  int    *tri_line = NULL;   /* line index of the i-th valid triangle */
  double *cxs = NULL, *cys = NULL, *czs = NULL;
  const char **tri_col = NULL;
  int n_tri = 0;
  const char *cur = "";
  int next_tri = 0;

  f = fopen(path, "r");
  if (!f) { fprintf(stderr, "\n--recolor: cannot open base surface: %s\n", path); return; }
  /* 1. slurp every line (order preserved). */
  while (fgets(buf, sizeof(buf), f)) {
    if (n_lines >= cap_lines) {
      int nc = cap_lines ? cap_lines * 2 : 8192;
      char **nl = realloc(lines, (size_t)nc * sizeof(char *));
      if (!nl) { /* out of memory - free + fall back to the serial streamer */
        for (li = 0; li < n_lines; li++) free(lines[li]);
        free(lines); fclose(f); recolor_vmd_plot_serial(path); return;
      }
      lines = nl; cap_lines = nc;
    }
    lines[n_lines] = xa_strdup(buf);
    if (!lines[n_lines]) {
      for (li = 0; li < n_lines; li++) free(lines[li]);
      free(lines); fclose(f); recolor_vmd_plot_serial(path); return;
    }
    n_lines++;
  }
  fclose(f);

  /* 2. parse the valid triangle lines + centroids, in file order. */
  if (n_lines > 0) {
    tri_line = xa_malloc((size_t)n_lines * sizeof(int));
    cxs = xa_malloc((size_t)n_lines * sizeof(double));
    cys = xa_malloc((size_t)n_lines * sizeof(double));
    czs = malloc((size_t)n_lines * sizeof(double));
    tri_col = malloc((size_t)n_lines * sizeof(char *));
  }
  if (n_lines == 0 || !tri_line || !cxs || !cys || !czs || !tri_col) {
    free(tri_line); free(cxs); free(cys); free(czs); free(tri_col);
    for (li = 0; li < n_lines; li++) free(lines[li]);
    free(lines);
    recolor_vmd_plot_serial(path);   /* re-reads the file; simplest safe fallback */
    return;
  }
  for (li = 0; li < n_lines; li++) {
    char *p = strstr(lines[li], "draw triangle");
    if (!p) p = strstr(lines[li], "draw trinorm");
    if (!p) continue;
    if (strstr(lines[li], "draw color")) continue;  /* a colour line, never a tri */
    {
      double v[3][3];
      char *q = p; int i, got = 0;
      for (i = 0; i < 3; i++) {
        q = strchr(q, '{');
        if (!q) break;
        if (sscanf(q, "{ %lf %lf %lf", &v[i][0], &v[i][1], &v[i][2]) != 3 &&
            sscanf(q, "{%lf %lf %lf",  &v[i][0], &v[i][1], &v[i][2]) != 3) break;
        q++; got++;
      }
      if (got == 3) {
        tri_line[n_tri] = li;
        cxs[n_tri] = (v[0][0]+v[1][0]+v[2][0])/3.0;
        cys[n_tri] = (v[0][1]+v[1][1]+v[2][1])/3.0;
        czs[n_tri] = (v[0][2]+v[1][2]+v[2][2])/3.0;
        n_tri++;
      }
    }
  }

  /* 3. per-triangle colour, in parallel. precomputed_vals is indexed by the
     valid-triangle ordinal t - identical to the serial precomputed_idx++. */
#ifdef _OPENMP
#pragma omp parallel for schedule(static) num_threads(recolor_threads > 0 ? recolor_threads : 1)
#endif
  for (t = 0; t < n_tri; t++) {
    double h;
    if (hydro3d_precomputed) {
      h = (t < n_precomputed) ? precomputed_vals[t] : 0.0;
    } else {
      h = hydro3d_mode ? hydro_at_point_3d(cxs[t], cys[t], czs[t])
                       : hydro_at_point(cxs[t], cys[t], czs[t]);
    }
    tri_col[t] = surface_color_name(h);
  }
  precomputed_idx = n_tri;   /* keep the global consistent with the serial path */

  /* 4. emit sequentially - identical run-length colour stream. */
  for (li = 0; li < n_lines; li++) {
    if (strstr(lines[li], "draw color")) continue;   /* drop old colours */
    if (next_tri < n_tri && tri_line[next_tri] == li) {
      const char *col = tri_col[next_tri];
      if (strcmp(col, cur) != 0) { fprintf(stdout, "draw color %s\n", col); cur = col; }
      next_tri++;
    }
    fputs(lines[li], stdout);
  }
  fflush(stdout);

  for (li = 0; li < n_lines; li++) free(lines[li]);
  free(lines); free(tri_line); free(cxs); free(cys); free(czs); free(tri_col);
}

/* Accumulate hydro_at_point_3d(triangle centroid) into sum[], one slot per
   triangle in the SAME encounter order recolor_vmd_plot walks the base mesh -
   used by --batch-hydro3d-average to build a trajectory average across many
   frames' true-3D evaluations for ONE fixed mesh (the Mean Profile tube),
   instead of live-colouring a single frame. *cap tracks the allocated size of
   *sum (grown as needed); *n_tri is updated to the largest triangle count
   seen so far (every job should see the same count, since the base mesh never
   changes across frames). */
static void accumulate_hydro3d_pass(const char *path, double **sum, int *cap, int *n_tri)
{
  FILE *f = fopen(path, "r");
  char line[8192];
  int idx = 0;
  if (!f) { fprintf(stderr, "\n--batch-hydro3d-average: cannot open base surface: %s\n", path); return; }
  while (fgets(line, sizeof(line), f)) {
    char *p = strstr(line, "draw triangle");
    if (!p) p = strstr(line, "draw trinorm");
    if (p) {
      double v[3][3];
      char *q = p;
      int i, got = 0;
      for (i = 0; i < 3; i++) {
        q = strchr(q, '{');
        if (!q) break;
        if (sscanf(q, "{ %lf %lf %lf", &v[i][0], &v[i][1], &v[i][2]) != 3 &&
            sscanf(q, "{%lf %lf %lf",  &v[i][0], &v[i][1], &v[i][2]) != 3) break;
        q++; got++;
      }
      if (got == 3) {
        double cx = (v[0][0]+v[1][0]+v[2][0])/3.0;
        double cy = (v[0][1]+v[1][1]+v[2][1])/3.0;
        double cz = (v[0][2]+v[1][2]+v[2][2])/3.0;
        double h = hydro_at_point_3d(cx, cy, cz);
        if (idx >= *cap) {
          int ncap = *cap ? (*cap * 2) : 4096, k;
          double *ns = realloc(*sum, ncap * sizeof(double));
          if (!ns) { fprintf(stderr, "\nOOM in accumulate_hydro3d_pass\n"); exit(1); }
          *sum = ns;
          for (k = *cap; k < ncap; k++) (*sum)[k] = 0.0;
          *cap = ncap;
        }
        (*sum)[idx] += h;
        idx++;
      }
    }
  }
  fclose(f);
  if (idx > *n_tri) *n_tri = idx;
}

/* ---- Batch-mode helpers -------------------------------------------------- */

/* Free all malloc'd edge-list nodes and reset the edge hash.  Called between
   batch jobs so heap growth does not accumulate across thousands of frames. */
/* Free the advancing-front tree. Nothing did: struct base_line is allocated
   once per emitted triangle (root plus both children per node) and no free of
   one existed anywhere in the file, so a --batch worker grew by roughly one
   node per triangle for every job it ran - measured ~190 KB/job on a
   3119-triangle surface, and ~1.7 MB/frame at the paper's ~42k triangles.
   reset_for_batch_job was written so "heap growth does not accumulate across
   thousands of frames" and already frees the edge list; the tree at the same
   allocation rate was missed.

   Iterative, not recursive: the tree is as deep as the triangulation is long,
   which is exactly why calc_tri_root runs the BUILD on a dedicated 768 MB
   stack. A recursive teardown would overflow the ordinary stack on a surface
   the build itself completed. Children are read before the parent is freed. */
/* Every root allocated during the current job. See track_base_root's call site
   for why they cannot be released as they are superseded. */
static struct base_line **bt_roots = NULL;
static size_t bt_nroots = 0, bt_rootcap = 0;

static void track_base_root(struct base_line *r)
{
    if (bt_nroots == bt_rootcap) {
        size_t nc = bt_rootcap ? bt_rootcap * 2 : 64;
        struct base_line **g = realloc(bt_roots, nc * sizeof *g);
        if (!g) return;            /* untracked: leaks one tree, never corrupts */
        bt_roots = g; bt_rootcap = nc;
    }
    bt_roots[bt_nroots++] = r;
}

static void free_base_tree(struct base_line *n)
{
    struct base_line **stk;
    size_t cap = 4096, top = 0;
    if (!n) return;
    stk = malloc(cap * sizeof *stk);
    if (!stk) return;              /* teardown-time OOM: leak rather than crash */
    stk[top++] = n;
    while (top > 0) {
        struct base_line *c = stk[--top];
        struct base_line *c1 = c->base1, *c2 = c->base2;
        if (c1 || c2) {
            if (top + 2 > cap) {
                struct base_line **g = realloc(stk, (cap * 2) * sizeof *g);
                if (!g) { free(c); break; }   /* cannot grow: stop, do not corrupt */
                stk = g; cap *= 2;
            }
            if (c1) stk[top++] = c1;
            if (c2) stk[top++] = c2;
        }
        free(c);
    }
    free(stk);
}

/* Release every tree this job built. MUST run after free_edge_list_and_hash:
   the edge nodes hold pointers into these trees and destroy() walks them. */
static void free_all_base_trees(void)
{
    size_t i;
    for (i = 0; i < bt_nroots; i++) free_base_tree(bt_roots[i]);
    free(bt_roots);
    bt_roots = NULL; bt_nroots = bt_rootcap = 0;
}

static void free_edge_list_and_hash(void)
{
    struct edge_list *cur, *nx;
    if (!start) return;
    cur = start->next;
    while (cur) { nx = cur->next; free(cur); cur = nx; }
    start->next = NULL;
    end = start;
    /* eh_head/eh_tail now hold stale pointers from the finished job. */
    memset(eh_head, 0, sizeof(eh_head));
    memset(eh_tail, 0, sizeof(eh_tail));
}

/* Release per-surface hydro data allocated by the previous job (the hydro_mode
   flag itself stays constant across all batch jobs). Shared by reset_for_batch_job
   (triangulation batch) and the --batch-recolor loop (which never touches the
   dots/tri/edge-list state below, so it calls just this, not the full reset). */
static void reset_hydro_state(void)
{
    if (sph_x) { free(sph_x); free(sph_y); free(sph_z); free(sph_r); free(sph_h); free(sph_flood);
                 sph_x=sph_y=sph_z=sph_r=sph_h=NULL; sph_flood=NULL; n_sph=0; }
    if (atom_x) { free(atom_x); free(atom_y); free(atom_z); free(atom_hkd); free(atom_hww);
                  atom_x=atom_y=atom_z=atom_hkd=atom_hww=NULL; n_atom=0; }
    if (atom_resid) { free(atom_resid); atom_resid=NULL; }
    max_resid_val = -1;
    if (thin) { free(thin); thin=NULL; n_thin=0; }
    /* hydro3d residue list: must be cleared between batch jobs too, or a later
       frame with a SMALLER (or zero) lining-residue set would silently keep
       colouring from the previous frame's stale, larger n_res3d. */
    if (res3d_x) { free(res3d_x); free(res3d_y); free(res3d_z); free(res3d_h);
                   res3d_x=res3d_y=res3d_z=res3d_h=NULL; n_res3d=0; }
    res3d_cap = 0;
    /* C-side-lining per-atom input (same reasoning: a stale larger set from the
       previous batch job must not leak into this one). */
    if (at3_x) { free(at3_x); free(at3_y); free(at3_z); free(at3_v);
                 free(at3_resid); free(at3_isca);
                 at3_x=at3_y=at3_z=at3_v=NULL; at3_resid=at3_isca=NULL; n_at3=0; }
}

/* Reset all per-surface state between batch jobs.  Only clears the elements
   that were actually written (up to prev_max_dots / prev_tri_count) so the
   partial-clear cost is proportional to the surface size, not MAX_COORD.
   hb_head is reset inside cull_coords(); ng_head inside build_neighbour_grid();
   no explicit memset needed for those two. */
static void reset_for_batch_job(int prev_max_dots, int prev_in_dots_total,
                                  int prev_tri_count)
{
    int i;
    for (i = 0; i < prev_max_dots; i++) {
        dots[i][0] = dots[i][1] = dots[i][2] = dots[i][3] = -1.0;
        point_used[i] = 0;
        pt_emitted[i] = 0;
    }
    for (i = 0; i < prev_in_dots_total; i++)
        in_dots[i][0] = in_dots[i][1] = in_dots[i][2] = in_dots[i][3] = -1.0;
    for (i = 0; i < prev_tri_count; i++)
        tri[i][0] = tri[i][1] = tri[i][2] = tri[i][3] = -1;

    in_dots_total = 0; max_dots = 0; tri_count = 0; culled_tri_count = 0;
    NCELL = 0.0; hn_count = 0; start_point = 0; flipped = 0;

    free_edge_list_and_hash();
    /* The tree, and then the sentinel free_edge_list_and_hash deliberately
       keeps alive - the replacement below allocates a fresh one, so without
       this the old sentinel leaks one node per job. */
    free_all_base_trees();
    root = NULL;
    free(start);
    start = NULL;
    /* Re-allocate the sentinel head node for the next job's edge list. */
    start = malloc(sizeof(struct edge_list));
    if (!start) { fprintf(stderr, "\nOOM allocating edge list in batch reset\n"); exit(1); }
    start->next = NULL; end = start;

    reset_hydro_state();
}

/* atomsfile: "x y z r ..." per line (extra columns ignored - same sidecar
   format --hydro3d-atoms already uses).
   Emits, per kept tunnel: one "T <id> <bottleneck> <length>" header line then
   "P <id> <x> <y> <z> <rho>" for each path point, seed end first. */
/* want_max: also emit the symmetric HAUSDORFF distance (the largest
   nearest-point distance in either direction) as a 4th column. The scans
   below already visit every pair of points to build the MEAN, so the max
   costs nothing extra - and computing it in Tcl instead measured 296 s
   against 17 s for the whole clustering pass. Off by default so the output
   format stays exactly 3 columns for any caller that has not asked. */
/* Average-link (UPGMA) clustering of tunnel centrelines, done entirely in C.
   Emits one "index cluster_representative" line per input tunnel.

   WHY this exists: the matrix itself was never the bottleneck. Profiled at
   n=1837 (191k points, 1.69M pairs) the split was
       C compute            3228 ms
       Tcl read + lassign   3670 ms
       array set D          1589 ms
       normalisation fill    880 ms
       Tcl agglomeration    4341 ms
   i.e. 64% of the time was Tcl marshalling and re-implementing what the kernel
   had just computed, over a 38 MB intermediate file. Clustering here drops that
   file to n lines and deletes the Tcl side outright.

   The agglomeration mirrors the Tcl reference EXACTLY, including tie-breaks:
   the nearest-neighbour scan and the global argmin both use a strict "<", so
   the LOWEST index wins a tie, and the surviving representative is always the
   lower of the two merged indices. maxdev, when > 0, blanks any pair whose
   symmetric Hausdorff distance exceeds it BEFORE clustering - the same guard
   the Tcl path applies, computed from the scan that already runs here. */
static void cc_scan_nn(int n, const unsigned char *alive, const double *D,
                       int i, int *bj_out, double *bd_out)
{
    int k, bj = -1;
    double bd = 1e30, d;
    for (k = 0; k < n; k++) {
        if (k == i || !alive[k]) continue;
        d = (i < k) ? D[(size_t)i*n + k] : D[(size_t)k*n + i];
        if (d < bd) { bd = d; bj = k; }
    }
    *bj_out = bj; *bd_out = bd;
}

static int tc_find(int *par, int x)
{
    while (par[x] != x) { par[x] = par[par[x]]; x = par[x]; }
    return x;
}

/* Symmetric mean-nearest-point distance between two pathways, with the maxdev
   guard applied. ONE pass over the na x nb grid, not two: the old code ran the
   grid twice - row-wise for A's nearest neighbours in B, then column-wise for
   B's in A - recomputing every squared distance a second time. Keeping a
   running per-column minimum during the row pass gets both from a single
   traversal, which is exactly half the work and bit-identical: the two minima
   are over the same value sets (min is order-independent), and sab/sba still
   accumulate in A-order and B-order, so no floating-point sum is reassociated.
   colbest is caller-supplied per-thread scratch of at least nb doubles. The
   same metric is also implemented in tunnel_dist below (which additionally
   reports the Hausdorff) - keep the two in step. */
static double tc_pair_dist(const double *ax, const double *ay, const double *az, int na,
                           const double *qx, const double *qy, const double *qz, int nb,
                           double *colbest, double threshold, double maxdev)
{
    double sab = 0.0, sba = 0.0, d, mx = 0.0, r;
    int a, b;
    for (b = 0; b < nb; b++) colbest[b] = 1e30;
    for (a = 0; a < na; a++) {
        double bestr = 1e30, xa = ax[a], ya = ay[a], za = az[a];
        for (b = 0; b < nb; b++) {
            double dx = xa-qx[b], dy = ya-qy[b], dz = za-qz[b];
            d = dx*dx + dy*dy + dz*dz;
            if (d < bestr)      bestr      = d;
            if (d < colbest[b]) colbest[b] = d;
        }
        r = sqrt(bestr); sab += r; if (r > mx) mx = r;
    }
    for (b = 0; b < nb; b++) { r = sqrt(colbest[b]); sba += r; if (r > mx) mx = r; }
    d = 0.5*(sab/na + sba/nb);
    /* Only pairs that would otherwise MERGE are blanked. Blanking a pair whose
       mean is already past the threshold would inject 1e30 into the
       Lance-Williams averages of later merges and split clusters that should
       survive - measured as 508 clusters against the Tcl reference's 488
       before this guard was narrowed. */
    if (maxdev > 0.0 && d <= threshold && mx > maxdev) d = 1e30;
    return d;
}

/* Threads for the two pair-distance passes in tunnel_cluster_c.
 *
 * PHYSICAL cores, not logical, and ONLY when the caller did not ask for a
 * specific count (OMP_NUM_THREADS unset). Measured on a Ryzen 7700X (8
 * physical / 16 logical) with A/B runs INTERLEAVED, so CPU-clock drift hits
 * both arms equally - a non-interleaved comparison of the same two arms
 * disagreed with itself twice, because what separates them is a bimodal tail,
 * not the median:
 *
 *   145-pathway pool  :  8 thr median 10.5 ms, max 13.0, NO outliers
 *                     : 16 thr median 10.7 ms, but 6 of 20 runs 26-33 ms
 *   1740-pathway pool :  8 thr median 121.1 ms  |  16 thr median 119.1 ms
 *                       (2%, inside the noise - both arms max out ~145 ms)
 *
 * So the cap costs nothing on a big pool and removes a ~30%-likely 3x spike on
 * a small one. The spike is what a caller actually reports as "clustering got
 * 3x slower"; the median never moved.
 *
 * NOTE, because this project has been here before and reverted it: a physical-
 * core cap was previously tried for the plugin's HOLE WORKER PROCESS count
 * (resolve_job_count) and was REFUTED - 15 worker processes measured genuinely
 * better there, and capping only hurt. That result stands and this is not a
 * revival of it. Different thing entirely: those are N independent, long-lived,
 * partly-I/O processes that benefit from SMT; this is one short-lived process
 * running a tight all-FP pair-distance loop where SMT siblings contend for the
 * same FPU and the team is spawned and torn down inside a few milliseconds.
 * The cap here is backed by the interleaved measurement above, on this loop. */
#ifdef _OPENMP
static int tc_pass_threads(void)
{
    FILE *f;
    char line[256];
    int seen[4096], nseen = 0, phys = 0, i, cur_pkg = -1, cur_core = -1;
    /* An explicit OMP_NUM_THREADS is the caller's decision - never override it. */
    if (getenv("OMP_NUM_THREADS")) return omp_get_max_threads();
    f = fopen("/proc/cpuinfo", "r");
    if (!f) return omp_get_max_threads();
    /* SMT siblings repeat the same (physical id, core id) pair - the standard
       Linux ABI, not a vendor quirk. Count distinct pairs. */
    while (fgets(line, sizeof line, f)) {
        if (!strncmp(line, "physical id", 11)) sscanf(line, "physical id : %d", &cur_pkg);
        else if (!strncmp(line, "core id", 7)) sscanf(line, "core id : %d", &cur_core);
        if (cur_pkg >= 0 && cur_core >= 0) {
            int key = cur_pkg*1024 + cur_core, dup = 0;
            for (i = 0; i < nseen; i++) if (seen[i] == key) { dup = 1; break; }
            if (!dup && nseen < (int)(sizeof seen/sizeof seen[0])) seen[nseen++] = key;
            cur_pkg = cur_core = -1;
        }
    }
    fclose(f);
    phys = nseen;
    if (phys < 1) return omp_get_max_threads();
    if (phys > omp_get_max_threads()) return omp_get_max_threads();
    return phys;
}
#endif /* _OPENMP - only the num_threads() clause below references this, so an
          unconditional definition is an unused function in a serial build. */

static int tunnel_cluster_c(const char *infile, const char *outfile,
                            double threshold, double maxdev)
{
    FILE *f, *o;
    char line[512];
    int nt = 0, cap = 0, *cnt = NULL, i, k, maxcnt = 0, oom = 0;
    double **px = NULL, **py = NULL, **pz = NULL, *D = NULL;
    unsigned char *alive = NULL;
    int *size = NULL, *nn = NULL, *rep = NULL, *comp = NULL, *par = NULL;
    double *nnd = NULL, *rd = NULL;
    double *bxlo = NULL, *bxhi = NULL, *bylo = NULL, *byhi = NULL, *bzlo = NULL, *bzhi = NULL;
    int nactive;

    f = fopen(infile, "r");
    if (!f) { fprintf(stderr,"\n--tunnel-cluster: cannot open %s\n", infile); return 1; }
    while (fgets(line, sizeof line, f)) {
        int n = 0;
        if (line[0] != 'T') continue;
        if (sscanf(line+1, "%d", &n) != 1 || n <= 0) continue;
        if (nt >= cap) {
            cap = cap ? cap*2 : 64;
            cnt = xrealloc(cnt, cap*sizeof(int), "cnt");
            px = xrealloc(px, cap*sizeof(double*), "px");
            py = xrealloc(py, cap*sizeof(double*), "py");
            pz = xrealloc(pz, cap*sizeof(double*), "pz");
            if (!cnt||!px||!py||!pz) { fclose(f); fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1; }
        }
        cnt[nt] = n;
        px[nt] = xa_malloc(n*sizeof(double));
        py[nt] = xa_malloc(n*sizeof(double));
        pz[nt] = xa_malloc(n*sizeof(double));
        if (!px[nt]||!py[nt]||!pz[nt]) { fclose(f); fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1; }
        for (k = 0; k < n; k++) {
            if (!fgets(line, sizeof line, f) ||
                sscanf(line, "%lf %lf %lf", &px[nt][k], &py[nt][k], &pz[nt][k]) != 3) {
                px[nt][k] = py[nt][k] = pz[nt][k] = 0.0;
            }
        }
        nt++;
    }
    fclose(f);
    if (nt == 0) { fprintf(stderr,"\n--tunnel-cluster: no tunnels in %s\n", infile); return 1; }

    D = malloc((size_t)nt*nt*sizeof(double));
    if (!D) { fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1; }

    for (i = 0; i < nt; i++) if (cnt[i] > maxcnt) maxcnt = cnt[i];

    /* Axis-aligned bounding box per pathway, for the prefilter below. */
    bxlo = xa_malloc(nt*sizeof(double)); bxhi = xa_malloc(nt*sizeof(double));
    bylo = malloc(nt*sizeof(double)); byhi = malloc(nt*sizeof(double));
    bzlo = malloc(nt*sizeof(double)); bzhi = malloc(nt*sizeof(double));
    comp = malloc(nt*sizeof(int));    par  = malloc(nt*sizeof(int));
    if (!bxlo||!bxhi||!bylo||!byhi||!bzlo||!bzhi||!comp||!par) {
        fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1;
    }
    for (i = 0; i < nt; i++) {
        double lo0 = 1e30, hi0 = -1e30, lo1 = 1e30, hi1 = -1e30, lo2 = 1e30, hi2 = -1e30;
        for (k = 0; k < cnt[i]; k++) {
            if (px[i][k] < lo0) lo0 = px[i][k];  if (px[i][k] > hi0) hi0 = px[i][k];
            if (py[i][k] < lo1) lo1 = py[i][k];  if (py[i][k] > hi1) hi1 = py[i][k];
            if (pz[i][k] < lo2) lo2 = pz[i][k];  if (pz[i][k] > hi2) hi2 = pz[i][k];
        }
        bxlo[i]=lo0; bxhi[i]=hi0; bylo[i]=lo1; byhi[i]=hi1; bzlo[i]=lo2; bzhi[i]=hi2;
        par[i] = i;
    }
    /* -1 marks "distance not computed yet". A real distance is never negative,
       so this needs no separate bitmap. */
    for (i = 0; i < nt; i++) {
        int jj;
        for (jj = i+1; jj < nt; jj++) D[(size_t)i*nt + jj] = -1.0;
    }

    /* PASS 1 - only the pairs that could possibly be within threshold.
       If the two bounding boxes are separated by (gx,gy,gz) then EVERY
       point-pair is at least sqrt(gx^2+gy^2+gz^2) apart, so the symmetric mean
       is too: gap is a rigorous lower bound on d, and gap > threshold proves
       d > threshold without computing it. Measured on the 50-frame GABA pool
       (1837 pathways, 1.69M pairs): the box test rejects 96.9%, and only 0.86%
       of pairs are genuinely within threshold. An older note in this project
       claimed a bounding-SPHERE bound was too weak to help here; measured on
       real data it rejects 95.1%, so that claim was wrong - boxes are simply
       tighter still for a long curved path. */
#ifdef _OPENMP
#pragma omp parallel num_threads(tc_pass_threads())
#endif
    {
        double *colbest = xa_malloc((size_t)maxcnt*sizeof(double));
        int i2, jj;
#ifdef _OPENMP
#pragma omp for schedule(dynamic)
#endif
        for (i2 = 0; i2 < nt; i2++) {
            for (jj = i2+1; jj < nt; jj++) {
                double gx = (bxlo[jj] > bxhi[i2]) ? bxlo[jj]-bxhi[i2]
                          : ((bxlo[i2] > bxhi[jj]) ? bxlo[i2]-bxhi[jj] : 0.0);
                double gy = (bylo[jj] > byhi[i2]) ? bylo[jj]-byhi[i2]
                          : ((bylo[i2] > byhi[jj]) ? bylo[i2]-byhi[jj] : 0.0);
                double gz = (bzlo[jj] > bzhi[i2]) ? bzlo[jj]-bzhi[i2]
                          : ((bzlo[i2] > bzhi[jj]) ? bzlo[i2]-bzhi[jj] : 0.0);
                if (gx*gx + gy*gy + gz*gz > threshold*threshold) continue;
                if (!colbest) { oom = 1; continue; }
                D[(size_t)i2*nt + jj] =
                    tc_pair_dist(px[i2],py[i2],pz[i2],cnt[i2],
                                 px[jj],py[jj],pz[jj],cnt[jj],
                                 colbest, threshold, maxdev);
            }
        }

        /* Components of the "within threshold" graph, computed here (one
           thread, via omp single) between the two passes below rather than
           in a THIRD, separate serial section - see the merge note above
           PASS 2 for why this whole function stays inside one parallel
           region. Average-link can only ever merge clusters inside one
           component: its cluster distance is a weighted mean of the
           original pair distances, so if every cross pair exceeds the
           threshold the mean does too, and the agglomeration stops before
           joining them. Cross-component distances therefore never need
           their true value - but distances INSIDE a component do, including
           the ones above threshold, because Lance-Williams averages them
           in. Ordering: omp single has NO entry barrier of its own - what
           guarantees D is fully written before this reads it is the implicit
           barrier at the END of Pass 1's omp for above (so do not add nowait
           there); the implicit barrier at the END of this single is what
           lets Pass 2 read a fully-finished comp[]. */
#ifdef _OPENMP
#pragma omp single
#endif
        {
            int ci, cj;
            for (ci = 0; ci < nt; ci++) {
                for (cj = ci+1; cj < nt; cj++) {
                    double dv = D[(size_t)ci*nt + cj];
                    if (dv >= 0.0 && dv <= threshold) {
                        int ri = tc_find(par, ci), rj = tc_find(par, cj);
                        if (ri != rj) par[ri] = rj;
                    }
                }
            }
            for (ci = 0; ci < nt; ci++) comp[ci] = tc_find(par, ci);
        }

        /* PASS 2 - fill in the within-component pairs the box test skipped. On
           the GABA pool that is 12% of all pairs (152 components, largest 452),
           so the two passes together do ~14% of the dense work. Kept in the SAME
           parallel region as PASS 1 (colbest reused, not reallocated) rather than
           its own #pragma omp parallel: each process invocation pays full
           thread-team creation/teardown itself (no persistent pool to amortize
           it against), and on a small pool that fixed cost, paid twice, measured
           as sometimes exceeding the entire computation done serially (22-24ms
           serial floor vs a 10-31ms bimodal spread over 8 runs at nproc=16, the
           145-pathway CAVER-comparison fixture, some individual runs slower than
           serial). One thread-team now pays it once. */
#ifdef _OPENMP
#pragma omp for schedule(dynamic)
#endif
        for (i2 = 0; i2 < nt; i2++) {
            for (jj = i2+1; jj < nt; jj++) {
                if (D[(size_t)i2*nt + jj] >= 0.0) continue;
                if (comp[i2] != comp[jj]) continue;
                if (!colbest) { oom = 1; continue; }
                D[(size_t)i2*nt + jj] =
                    tc_pair_dist(px[i2],py[i2],pz[i2],cnt[i2],
                                 px[jj],py[jj],pz[jj],cnt[jj],
                                 colbest, threshold, maxdev);
            }
        }
        free(colbest);
    }
    /* A failed scratch alloc would leave those pairs at -1 and silently cluster
       every pathway on its own - a plausible-looking wrong answer rather than
       obvious garbage. Fail loudly instead. */
    if (oom) { fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1; }
    /* Everything still unset is a cross-component pair: proven above threshold,
       and never the minimum the agglomeration picks, so its exact value cannot
       change any merge. */
    for (i = 0; i < nt; i++) {
        int jj;
        for (jj = i+1; jj < nt; jj++)
            if (D[(size_t)i*nt + jj] < 0.0) D[(size_t)i*nt + jj] = 1e30;
    }
    free(bxlo); free(bxhi); free(bylo); free(byhi); free(bzlo); free(bzhi);
    free(comp); free(par);
    /* The point arrays are NOT freed here any more: the third output column
       below needs them after the agglomeration has run. D cannot serve - the
       Lance-Williams update overwrites it in place, and the maxdev guard above
       has already replaced blanked pairs with 1e30, while the column wants the
       true mean. Points are far smaller than the matrix anyway. */
    alive = malloc((size_t)nt); size = malloc(nt*sizeof(int));
    nn = malloc(nt*sizeof(int)); nnd = malloc(nt*sizeof(double));
    rep = malloc(nt*sizeof(int));
    if (!alive||!size||!nn||!nnd||!rep) { fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1; }
    for (i = 0; i < nt; i++) { alive[i] = 1; size[i] = 1; rep[i] = i; }
    for (i = 0; i < nt; i++) cc_scan_nn(nt, alive, D, i, &nn[i], &nnd[i]);

    nactive = nt;
    while (nactive > 1) {
        int bi = -1, bj, t2;
        double bd = 1e30;
        for (i = 0; i < nt; i++) {
            if (!alive[i]) continue;
            if (nnd[i] < bd) { bd = nnd[i]; bi = i; }
        }
        if (bi < 0 || bd > threshold) break;
        bj = nn[bi];
        if (bj < 0 || !alive[bj]) { nnd[bi] = 1e30; continue; }
        if (bj < bi) { t2 = bi; bi = bj; bj = t2; }
        {
            int si = size[bi], sj = size[bj];
            for (k = 0; k < nt; k++) {
                double dik, djk, nd;
                if (k == bi || k == bj || !alive[k]) continue;
                dik = (bi < k) ? D[(size_t)bi*nt + k] : D[(size_t)k*nt + bi];
                djk = (bj < k) ? D[(size_t)bj*nt + k] : D[(size_t)k*nt + bj];
                nd = (si*dik + sj*djk) / (double)(si + sj);
                if (bi < k) D[(size_t)bi*nt + k] = nd; else D[(size_t)k*nt + bi] = nd;
            }
            alive[bj] = 0;
            size[bi] = si + sj;
        }
        for (i = 0; i < nt; i++) if (rep[i] == bj) rep[i] = bi;
        nactive--;
        cc_scan_nn(nt, alive, D, bi, &nn[bi], &nnd[bi]);
        for (k = 0; k < nt; k++) {
            if (!alive[k] || k == bi) continue;
            if (nn[k] == bi || nn[k] == bj) cc_scan_nn(nt, alive, D, k, &nn[k], &nnd[k]);
        }
    }

    /* Third column: each tunnel's distance to its cluster's representative.
       rep[] is written in exactly two places - the init above and the merge
       loop, which always keeps the LOWER index (bi<bj is enforced by the swap)
       - so rep[i] is the smallest member index of i's cluster. That is exactly
       the pathway the Tcl caller picks as its per-cluster reference (earliest
       frame, lowest rank, which is lowest pool index because the pool is built
       frame-major). Handing this back turns the caller's per-collision
       O(points^2) Tcl distance into an array lookup: 15.3 s -> 0 at n=1837.
       Plain symmetric mean, no maxdev blanking, matching the Tcl reference
       _tunnel_pair_distance exactly. */
    rd = malloc(nt*sizeof(double));
    if (!rd) { fprintf(stderr,"\n--tunnel-cluster: out of memory\n"); return 1; }
#ifdef _OPENMP
#pragma omp parallel for schedule(dynamic)
#endif
    for (i = 0; i < nt; i++) {
        int r = rep[i], a, b;
        double sab = 0.0, sba = 0.0, d;
        if (r == i) { rd[i] = 0.0; continue; }
        for (a = 0; a < cnt[r]; a++) {
            double best = 1e30;
            for (b = 0; b < cnt[i]; b++) {
                double dx = px[r][a]-px[i][b], dy = py[r][a]-py[i][b], dz = pz[r][a]-pz[i][b];
                d = dx*dx + dy*dy + dz*dz;
                if (d < best) best = d;
            }
            sab += sqrt(best);
        }
        for (b = 0; b < cnt[i]; b++) {
            double best = 1e30;
            for (a = 0; a < cnt[r]; a++) {
                double dx = px[r][a]-px[i][b], dy = py[r][a]-py[i][b], dz = pz[r][a]-pz[i][b];
                d = dx*dx + dy*dy + dz*dz;
                if (d < best) best = d;
            }
            sba += sqrt(best);
        }
        rd[i] = 0.5*(sab/cnt[r] + sba/cnt[i]);
    }
    for (i = 0; i < nt; i++) { free(px[i]); free(py[i]); free(pz[i]); }
    free(px); free(py); free(pz); free(cnt);

    o = fopen(outfile, "w");
    if (!o) { fprintf(stderr,"\n--tunnel-cluster: cannot open %s\n", outfile); return 1; }
    for (i = 0; i < nt; i++) fprintf(o, "%d %d %.17g\n", i, rep[i], rd[i]);
    fclose(o);
    free(D); free(alive); free(size); free(nn); free(nnd); free(rep); free(rd);
    return 0;
}

/* Same symmetric mean-nearest-point metric as tc_pair_dist above - keep the two
   in step if the definition ever changes. Kept separate deliberately: this one
   emits the per-pair HAUSDORFF as its own output column and applies no maxdev
   guard, so it cannot just call the other. */
/* --ionflow-project IN OUT
   The Ion Flow tab's per-frame water/ion pass, moved out of Tcl. For every
   candidate point it does what the plugin's Tcl loop does for an ion: offset
   from the frame's protein centre of mass, min-image that offset per box
   dimension, project onto the frame's axis (z), take the perpendicular
   distance (R), and measure the signed distance to the nearest sphere SURFACE
   of the frame's union-of-spheres pore (d3, negative = inside). Points at
   R >= scan_r are dropped, as are points outside the axial window when one is
   given.

   IN:  scan_r <r>
        zwin <zlo> <zhi>                   optional axial window (see below)
        coords <nw>  then one line holding the stream's path
        index <nw>  then nw lines "<atom index>"      (required with coords)
        group 1                            optional; group output by atom index
        S <id> <n>  then n lines "cx cy cz r"         (a sphere set)
        F <frame> <setid> comx comy comz Lx Ly Lz ux uy uz <n>
             n >= 0 : n inline lines "idx x y z"
             n <  0 : this frame's nw points come from the next block of the
                      coordinate stream, with atom indices from the index list
        path 1                             optional: sphere lines carry
             "cx cy cz r s tx ty tz" (arc length from the route's start and
             the unit tangent there); z and R are then the arc length and the
             distance from the route at the nearest centre's tangent, in
             place of the axis projection - a tunnel is measured along
             itself, so a bend does not read as bulk. u is still read but
             unused; zwin and scan_r apply to the path coordinates.
   OUT: per frame, in input order:
            F <frame> <nkept>   then nkept lines "idx z R d3"
        or, with "group 1", one line per atom index that was ever kept:
            T <idx> <n> <n frames> <n z> <n R> <n d3>

   The coordinate stream is little-endian 32-bit floats, per frame nw x values,
   then nw y, then nw z - what Tcl's [binary format r*] writes for a whole
   atomselect in one call. It exists because the alternative, having VMD
   prefilter each frame with an atomselect expression carrying that frame's
   centre of mass, costs 14 ms per frame in selection PARSING alone against
   2.2 ms to dump every water coordinate; the filter is far cheaper here.
   The caller bounds the stream's size by splitting a long trajectory into
   several jobs, so reading it whole is bounded by the caller's own budget.

   Arithmetic is written in the same order as the Tcl expressions it replaces
   so the two paths agree bit for bit on x86-64; d3 is only ever compared
   against a shell threshold downstream. Frames are independent: OpenMP over
   frames, output written afterwards in order. */
struct ifp_set { int n; double *x, *y, *z, *r, *s, *tx, *ty, *tz; };
struct ifp_frame {
    int frame, set, n;              /* n < 0: points come from the stream */
    long slot;                      /* stream block index when n < 0 */
    double com[3], L[3], u[3];
    int *idx; double *px, *py, *pz; /* inline points only */
    int nkept, *kidx, *kslot;       /* kept: atom index and (stream mode) its slot */
    double *kz, *kr, *kd3, *kaz;
};

/* Read a little-endian 32-bit float without assuming the host's byte order or
   that a float may be aliased from arbitrary bytes. */
static double ifp_le_float(const unsigned char *b)
{
    unsigned int u = (unsigned int)b[0] | ((unsigned int)b[1]<<8) |
                     ((unsigned int)b[2]<<16) | ((unsigned int)b[3]<<24);
    float f;
    memcpy(&f, &u, 4);
    return (double)f;
}

static int ionflow_project(const char *infile, const char *outfile)
{
    FILE *f, *o;
    char line[512];
    double scan_r = -1.0, zlo = 0.0, zhi = 0.0;
    int have_zwin = 0, group = 0, path = 0;
    char coords_path[4096]; int have_coords = 0; long nw = 0;
    int *widx = NULL; long nwidx = 0;
    unsigned char *stream = NULL; long nstream = 0;
    struct ifp_set *sets = NULL; int nsets = 0, scap = 0;
    struct ifp_frame *fr = NULL; int nfr = 0, fcap = 0;
    int i, k, rc = 1;

    coords_path[0] = '\0';
    f = fopen(infile, "r");
    if (!f) { fprintf(stderr,"\n--ionflow-project: cannot open %s\n", infile); return 1; }
    while (fgets(line, sizeof line, f)) {
        if (strncmp(line, "scan_r", 6) == 0) {
            if (sscanf(line, "scan_r %lf", &scan_r) != 1) goto bad_line;
        } else if (strncmp(line, "zwin", 4) == 0) {
            if (sscanf(line, "zwin %lf %lf", &zlo, &zhi) != 2) goto bad_line;
            have_zwin = 1;
        } else if (strncmp(line, "path", 4) == 0) {
            if (sscanf(line, "path %d", &path) != 1) goto bad_line;
        } else if (strncmp(line, "group", 5) == 0) {
            if (sscanf(line, "group %d", &group) != 1) goto bad_line;
        } else if (strncmp(line, "coords", 6) == 0) {
            size_t plen;
            if (sscanf(line, "coords %ld", &nw) != 1 || nw <= 0) goto bad_line;
            /* The path is a whole line of its own: a scratch directory may
               contain spaces, which a %s field would truncate. */
            if (!fgets(coords_path, sizeof coords_path, f)) goto bad_line;
            plen = strlen(coords_path);
            while (plen > 0 && (coords_path[plen-1] == '\n' || coords_path[plen-1] == '\r')) coords_path[--plen] = '\0';
            if (plen == 0) goto bad_line;
            have_coords = 1;
        } else if (strncmp(line, "index", 5) == 0) {
            if (sscanf(line, "index %ld", &nwidx) != 1 || nwidx < 0) goto bad_line;
            widx = xa_malloc((nwidx ? nwidx : 1)*sizeof(int));
            for (k = 0; k < nwidx; k++) {
                if (!fgets(line, sizeof line, f) || sscanf(line, "%d", &widx[k]) != 1) {
                    fprintf(stderr,"\n--ionflow-project: short index list\n"); goto done;
                }
            }
        } else if (line[0] == 'S') {
            int id = -1, n = -1;
            if (sscanf(line+1, "%d %d", &id, &n) != 2 || id < 0 || n < 0) goto bad_line;
            if (id >= scap) {
                int nc = scap ? scap : 64;
                while (nc <= id) nc *= 2;
                sets = xrealloc(sets, nc*sizeof(*sets), "sets");
                for (k = scap; k < nc; k++) { sets[k].n = -1; sets[k].x = sets[k].y = sets[k].z = sets[k].r = NULL;
                                              sets[k].s = sets[k].tx = sets[k].ty = sets[k].tz = NULL; }
                scap = nc;
            }
            sets[id].n = n;
            sets[id].x = xa_malloc((n?n:1)*sizeof(double)); sets[id].y = xa_malloc((n?n:1)*sizeof(double));
            sets[id].z = xa_malloc((n?n:1)*sizeof(double)); sets[id].r = xa_malloc((n?n:1)*sizeof(double));
            sets[id].s = sets[id].tx = sets[id].ty = sets[id].tz = NULL;
            if (path) {
                sets[id].s  = xa_malloc((n?n:1)*sizeof(double)); sets[id].tx = xa_malloc((n?n:1)*sizeof(double));
                sets[id].ty = xa_malloc((n?n:1)*sizeof(double)); sets[id].tz = xa_malloc((n?n:1)*sizeof(double));
            }
            for (k = 0; k < n; k++) {
                if (!fgets(line, sizeof line, f)) { fprintf(stderr,"\n--ionflow-project: short sphere set %d\n", id); goto done; }
                if (path ? sscanf(line, "%lf %lf %lf %lf %lf %lf %lf %lf", &sets[id].x[k], &sets[id].y[k], &sets[id].z[k], &sets[id].r[k],
                                  &sets[id].s[k], &sets[id].tx[k], &sets[id].ty[k], &sets[id].tz[k]) != 8
                         : sscanf(line, "%lf %lf %lf %lf", &sets[id].x[k], &sets[id].y[k], &sets[id].z[k], &sets[id].r[k]) != 4) {
                    fprintf(stderr,"\n--ionflow-project: short sphere set %d\n", id); goto done;
                }
            }
            if (id >= nsets) nsets = id+1;
        } else if (line[0] == 'F') {
            struct ifp_frame *p;
            if (nfr >= fcap) { fcap = fcap ? fcap*2 : 64; fr = xrealloc(fr, fcap*sizeof(*fr), "frames"); }
            p = &fr[nfr];
            memset(p, 0, sizeof *p);
            if (sscanf(line+1, "%d %d %lf %lf %lf %lf %lf %lf %lf %lf %lf %d", &p->frame, &p->set,
                       &p->com[0], &p->com[1], &p->com[2], &p->L[0], &p->L[1], &p->L[2],
                       &p->u[0], &p->u[1], &p->u[2], &p->n) != 12) goto bad_line;
            if (p->n < 0) {
                p->slot = nstream++;
            } else {
                p->idx = xa_malloc((p->n?p->n:1)*sizeof(int));
                p->px = xa_malloc((p->n?p->n:1)*sizeof(double));
                p->py = xa_malloc((p->n?p->n:1)*sizeof(double));
                p->pz = xa_malloc((p->n?p->n:1)*sizeof(double));
                for (k = 0; k < p->n; k++) {
                    if (!fgets(line, sizeof line, f) ||
                        sscanf(line, "%d %lf %lf %lf", &p->idx[k], &p->px[k], &p->py[k], &p->pz[k]) != 4) {
                        fprintf(stderr,"\n--ionflow-project: short frame %d\n", p->frame); goto done;
                    }
                }
            }
            nfr++;
        }
    }
    fclose(f); f = NULL;

    if (scan_r < 0.0) { fprintf(stderr,"\n--ionflow-project: no scan_r in %s\n", infile); goto done; }
    if (nstream > 0) {
        long need;
        FILE *cf;
        if (!have_coords) { fprintf(stderr,"\n--ionflow-project: streamed frames but no coords record\n"); goto done; }
        if (nwidx != nw) { fprintf(stderr,"\n--ionflow-project: index list (%ld) does not match coords width (%ld)\n", nwidx, nw); goto done; }
        need = nstream * nw * 12;
        stream = malloc((size_t)need);
        if (!stream) { fprintf(stderr,"\n--ionflow-project: out of memory for %ld coordinate bytes\n", need); goto done; }
        cf = fopen(coords_path, "rb");
        if (!cf) { fprintf(stderr,"\n--ionflow-project: cannot open %s\n", coords_path); goto done; }
        if ((long)fread(stream, 1, (size_t)need, cf) != need) {
            fclose(cf); fprintf(stderr,"\n--ionflow-project: %s is shorter than %ld bytes\n", coords_path, need); goto done;
        }
        fclose(cf);
    }
    if (group && nstream <= 0) { fprintf(stderr,"\n--ionflow-project: group needs the coords stream\n"); goto done; }
    for (i = 0; i < nfr; i++)
        if (fr[i].set < 0 || fr[i].set >= scap || sets[fr[i].set].n < 0) {
            fprintf(stderr,"\n--ionflow-project: frame %d uses undefined sphere set %d\n", fr[i].frame, fr[i].set);
            goto done;
        }

#ifdef _OPENMP
#pragma omp parallel for schedule(dynamic)
#endif
    for (i = 0; i < nfr; i++) {
        struct ifp_frame *p = &fr[i];
        const struct ifp_set *S = &sets[p->set];
        const unsigned char *bx = NULL, *by = NULL, *bz = NULL;
        long np = p->n, j;
        int kept = 0, kk;   /* own indices: the function-scope k is shared across threads */
        int *tslot; double *tz, *tr, *td3, *taz; double e1[3], e2[3];
        if (p->n < 0) {
            const unsigned char *blk = stream + p->slot * nw * 12;
            bx = blk; by = blk + nw*4; bz = blk + nw*8;
            np = nw;
        }
        tslot = xa_malloc((np?np:1)*sizeof(int));
        tz  = xa_malloc((np?np:1)*sizeof(double));
        tr  = xa_malloc((np?np:1)*sizeof(double));
        td3 = xa_malloc((np?np:1)*sizeof(double));
        taz = xa_malloc((np?np:1)*sizeof(double));
        for (j = 0; j < np; j++) {
            double X, Y, Z, rx, ry, rz, z, qx, qy, qz, R, wx, wy, wz, mind = 1e30;
            int m;
            if (bx) { X = ifp_le_float(bx+4*j); Y = ifp_le_float(by+4*j); Z = ifp_le_float(bz+4*j); }
            else    { X = p->px[j]; Y = p->py[j]; Z = p->pz[j]; }
            rx = X-p->com[0]; ry = Y-p->com[1]; rz = Z-p->com[2];
            if (p->L[0] > 0) rx = rx - p->L[0]*round(rx/p->L[0]);
            if (p->L[1] > 0) ry = ry - p->L[1]*round(ry/p->L[1]);
            if (p->L[2] > 0) rz = rz - p->L[2]*round(rz/p->L[2]);
            wx = p->com[0]+rx; wy = p->com[1]+ry; wz = p->com[2]+rz;
            if (path) {
                /* nearest centre's tangent frame: same arithmetic order as
                   the plugin's _ion_flow_path_coord */
                double best = 1e30, proj, perp; int bi = -1;
                for (m = 0; m < S->n; m++) {
                    double dx = wx-S->x[m], dy = wy-S->y[m], dz = wz-S->z[m];
                    double dd = dx*dx+dy*dy+dz*dz;
                    double surf = sqrt(dd)-S->r[m];
                    if (surf < mind) mind = surf;
                    if (dd < best) { best = dd; bi = m; }
                }
                if (bi < 0) continue;
                {
                    double dx = wx-S->x[bi], dy = wy-S->y[bi], dz = wz-S->z[bi];
                    proj = dx*S->tx[bi]+dy*S->ty[bi]+dz*S->tz[bi];
                }
                z = S->s[bi]+proj;
                perp = best-proj*proj;
                R = perp > 0.0 ? sqrt(perp) : 0.0;
                if (have_zwin && (z <= zlo || z >= zhi)) continue;
                if (R >= scan_r) continue;
                tslot[kept] = (int)j; tz[kept] = z; tr[kept] = R; td3[kept] = mind;
                /* A branching tunnel has no single axis to take an azimuth
                   about. 1e30 is the "none" marker the Tcl side maps to an
                   empty value - a fabricated 0.0 would be attributed to
                   whichever opening happens to sit at zero. */
                taz[kept] = 1e30;
                kept++;
                continue;
            }
            /* Same basis _conn_axis_basis builds in Tcl: derived from the
               axis alone so every frame shares one zero-point, or no opening
               could be recognised from one frame to the next. */
            {
                double ax = (fabs(p->u[0]) < 0.9) ? 1.0 : 0.0;
                double ay = (fabs(p->u[0]) < 0.9) ? 0.0 : 1.0;
                double n1;
                e1[0] = ay*p->u[2] - 0.0*p->u[1];
                e1[1] = 0.0*p->u[0] - ax*p->u[2];
                e1[2] = ax*p->u[1] - ay*p->u[0];
                n1 = sqrt(e1[0]*e1[0] + e1[1]*e1[1] + e1[2]*e1[2]);
                if (n1 < 1e-9) { e1[0]=1.0; e1[1]=0.0; e1[2]=0.0; n1=1.0; }
                e1[0]/=n1; e1[1]/=n1; e1[2]/=n1;
                e2[0] = p->u[1]*e1[2] - p->u[2]*e1[1];
                e2[1] = p->u[2]*e1[0] - p->u[0]*e1[2];
                e2[2] = p->u[0]*e1[1] - p->u[1]*e1[0];
            }
            z = rx*p->u[0]+ry*p->u[1]+rz*p->u[2];
            if (have_zwin && (z <= zlo || z >= zhi)) continue;
            qx = rx-z*p->u[0]; qy = ry-z*p->u[1]; qz = rz-z*p->u[2];
            R = sqrt(qx*qx+qy*qy+qz*qz);
            if (R >= scan_r) continue;
            for (m = 0; m < S->n; m++) {
                double dx = wx-S->x[m], dy = wy-S->y[m], dz = wz-S->z[m];
                double surf = sqrt(dx*dx+dy*dy+dz*dz)-S->r[m];
                if (surf < mind) mind = surf;
            }
            tslot[kept] = (int)j; tz[kept] = z; tr[kept] = R; td3[kept] = mind;
            taz[kept] = atan2(qx*e2[0] + qy*e2[1] + qz*e2[2],
                              qx*e1[0] + qy*e1[1] + qz*e1[2]);
            kept++;
        }
        /* Copy to exact-size arrays: a frame keeps a few hundred of tens of
           thousands of candidates, and every frame's worst case held at once
           would be two orders of magnitude more memory than the answer. */
        p->nkept = kept;
        p->kidx  = xa_malloc((kept?kept:1)*sizeof(int));
        p->kslot = xa_malloc((kept?kept:1)*sizeof(int));
        p->kz    = xa_malloc((kept?kept:1)*sizeof(double));
        p->kr    = xa_malloc((kept?kept:1)*sizeof(double));
        p->kd3   = xa_malloc((kept?kept:1)*sizeof(double));
        p->kaz   = xa_malloc((kept?kept:1)*sizeof(double));
        for (kk = 0; kk < kept; kk++) {
            p->kslot[kk] = tslot[kk];
            p->kidx[kk]  = bx ? widx[tslot[kk]] : p->idx[tslot[kk]];
            p->kz[kk] = tz[kk]; p->kr[kk] = tr[kk]; p->kd3[kk] = td3[kk]; p->kaz[kk] = taz[kk];
        }
        free(tslot); free(tz); free(tr); free(td3);
    }

    o = fopen(outfile, "w");
    if (!o) { fprintf(stderr,"\n--ionflow-project: cannot write %s\n", outfile); goto done; }
    if (group) {
        /* One record per atom index that was ever kept, in index-list order,
           each carrying its whole time series - the shape the plugin builds
           its per-molecule traces from, so it never walks the samples again. */
        long ii;
        long *cnt = calloc((size_t)(nw?nw:1), sizeof(long));
        long *off = calloc((size_t)(nw?nw:1)+1, sizeof(long));
        long total = 0, *fill = NULL;
        int *gf = NULL; double *gz = NULL, *gr = NULL, *gd = NULL, *ga = NULL;
        if (!cnt || !off) { fclose(o); free(cnt); free(off); fprintf(stderr,"\n--ionflow-project: out of memory\n"); goto done; }
        for (i = 0; i < nfr; i++) for (k = 0; k < fr[i].nkept; k++) cnt[fr[i].kslot[k]]++;
        for (ii = 0; ii < nw; ii++) { off[ii] = total; total += cnt[ii]; }
        off[nw] = total;
        fill = calloc((size_t)(nw?nw:1), sizeof(long));
        gf = malloc((size_t)(total?total:1)*sizeof(int));
        gz = malloc((size_t)(total?total:1)*sizeof(double));
        gr = malloc((size_t)(total?total:1)*sizeof(double));
        gd = malloc((size_t)(total?total:1)*sizeof(double));
        ga = malloc((size_t)(total?total:1)*sizeof(double));
        if (!fill || !gf || !gz || !gr || !gd) { fclose(o); fprintf(stderr,"\n--ionflow-project: out of memory\n"); goto done; }
        for (i = 0; i < nfr; i++) {
            for (k = 0; k < fr[i].nkept; k++) {
                long sl = fr[i].kslot[k], at = off[sl] + fill[sl]++;
                gf[at] = fr[i].frame; gz[at] = fr[i].kz[k]; gr[at] = fr[i].kr[k]; gd[at] = fr[i].kd3[k];
                ga[at] = fr[i].kaz[k];
            }
        }
        for (ii = 0; ii < nw; ii++) {
            long b = off[ii], n = cnt[ii], q;
            if (n == 0) continue;
            fprintf(o, "T %d %ld", widx[ii], n);
            for (q = 0; q < n; q++) fprintf(o, " %d", gf[b+q]);
            for (q = 0; q < n; q++) fprintf(o, " %.17g", gz[b+q]);
            for (q = 0; q < n; q++) fprintf(o, " %.17g", gr[b+q]);
            for (q = 0; q < n; q++) fprintf(o, " %.17g", gd[b+q]);
            /* Fifth block: azimuth. Readers that predate it stop after the
               fourth and ignore the rest, so the format stays backward
               compatible in the direction that matters. */
            for (q = 0; q < n; q++) fprintf(o, " %.17g", ga[b+q]);
            fputc('\n', o);
        }
        free(cnt); free(off); free(fill); free(gf); free(gz); free(gr); free(gd); free(ga);
    } else {
        for (i = 0; i < nfr; i++) {
            fprintf(o, "F %d %d\n", fr[i].frame, fr[i].nkept);
            for (k = 0; k < fr[i].nkept; k++)
                fprintf(o, "%d %.17g %.17g %.17g %.17g\n", fr[i].kidx[k], fr[i].kz[k],
                        fr[i].kr[k], fr[i].kd3[k], fr[i].kaz[k]);
        }
    }
    fclose(o);
    rc = 0;

done:
    if (f) fclose(f);
    for (i = 0; i < nfr; i++) {
        free(fr[i].idx); free(fr[i].px); free(fr[i].py); free(fr[i].pz);
        free(fr[i].kidx); free(fr[i].kslot); free(fr[i].kz); free(fr[i].kr); free(fr[i].kd3);
    }
    free(fr);
    for (k = 0; k < scap; k++) { free(sets[k].x); free(sets[k].y); free(sets[k].z); free(sets[k].r);
                                 free(sets[k].s); free(sets[k].tx); free(sets[k].ty); free(sets[k].tz); }
    free(sets); free(widx); free(stream);
    return rc;

bad_line:
    fprintf(stderr,"\n--ionflow-project: malformed record: %s", line);
    goto done;
}

static int tunnel_dist(const char *infile, const char *outfile, int want_max)
{
    FILE *f, *o;
    char line[512];
    int nt = 0, cap = 0, *cnt = NULL, i, k;
    double **px = NULL, **py = NULL, **pz = NULL, *out = NULL, *omax = NULL;

    f = fopen(infile, "r");
    if (!f) { fprintf(stderr,"\n--tunnel-dist: cannot open %s\n", infile); return 1; }
    while (fgets(line, sizeof line, f)) {
        int n = 0;
        if (line[0] != 'T') continue;
        if (sscanf(line+1, "%d", &n) != 1 || n <= 0) continue;
        if (nt >= cap) {
            cap = cap ? cap*2 : 64;
            cnt = xrealloc(cnt, cap*sizeof(int), "cnt");
            px = xrealloc(px, cap*sizeof(double*), "px");
            py = xrealloc(py, cap*sizeof(double*), "py");
            pz = xrealloc(pz, cap*sizeof(double*), "pz");
            if (!cnt||!px||!py||!pz) { fclose(f); fprintf(stderr,"\n--tunnel-dist: out of memory\n"); return 1; }
        }
        cnt[nt] = n;
        px[nt] = xa_malloc(n*sizeof(double));
        py[nt] = xa_malloc(n*sizeof(double));
        pz[nt] = xa_malloc(n*sizeof(double));
        if (!px[nt]||!py[nt]||!pz[nt]) { fclose(f); fprintf(stderr,"\n--tunnel-dist: out of memory\n"); return 1; }
        for (k = 0; k < n; k++) {
            if (!fgets(line, sizeof line, f) ||
                sscanf(line, "%lf %lf %lf", &px[nt][k], &py[nt][k], &pz[nt][k]) != 3) {
                px[nt][k] = py[nt][k] = pz[nt][k] = 0.0;
            }
        }
        nt++;
    }
    fclose(f);
    if (nt == 0) { fprintf(stderr,"\n--tunnel-dist: no tunnels in %s\n", infile); return 1; }

    /* Collected into an array, then written in index order: writing from inside
       the parallel loop would need a critical section and would emit pairs in
       whatever order the threads finished, making the output non-reproducible. */
    out = malloc((size_t)nt*nt*sizeof(double));
    if (!out) { fprintf(stderr,"\n--tunnel-dist: out of memory\n"); return 1; }
    if (want_max) {
        omax = malloc((size_t)nt*nt*sizeof(double));
        if (!omax) { fprintf(stderr,"\n--tunnel-dist: out of memory\n"); return 1; }
    }

#ifdef _OPENMP
#pragma omp parallel for schedule(dynamic)
#endif
    for (i = 0; i < nt; i++) {
        int jj, a, b;
        for (jj = i+1; jj < nt; jj++) {
            double sab = 0.0, sba = 0.0, d, mx = 0.0, r;
            for (a = 0; a < cnt[i]; a++) {
                double best = 1e30;
                for (b = 0; b < cnt[jj]; b++) {
                    double dx = px[i][a]-px[jj][b], dy = py[i][a]-py[jj][b], dz = pz[i][a]-pz[jj][b];
                    d = dx*dx + dy*dy + dz*dz;
                    if (d < best) best = d;
                }
                r = sqrt(best);
                sab += r;
                if (r > mx) mx = r;
            }
            for (b = 0; b < cnt[jj]; b++) {
                double best = 1e30;
                for (a = 0; a < cnt[i]; a++) {
                    double dx = px[i][a]-px[jj][b], dy = py[i][a]-py[jj][b], dz = pz[i][a]-pz[jj][b];
                    d = dx*dx + dy*dy + dz*dz;
                    if (d < best) best = d;
                }
                r = sqrt(best);
                sba += r;
                if (r > mx) mx = r;
            }
            out[(size_t)i*nt + jj] = 0.5*(sab/cnt[i] + sba/cnt[jj]);
            if (want_max) omax[(size_t)i*nt + jj] = mx;
        }
    }

    o = fopen(outfile, "w");
    if (!o) { fprintf(stderr,"\n--tunnel-dist: cannot open %s\n", outfile); return 1; }
    for (i = 0; i < nt; i++) {
        int jj;
        for (jj = i+1; jj < nt; jj++) {
            if (want_max)
                fprintf(o, "%d %d %.12g %.12g\n", i, jj,
                        out[(size_t)i*nt + jj], omax[(size_t)i*nt + jj]);
            else
                fprintf(o, "%d %d %.12g\n", i, jj, out[(size_t)i*nt + jj]);
        }
    }
    fclose(o);
    for (i = 0; i < nt; i++) { free(px[i]); free(py[i]); free(pz[i]); }
    free(px); free(py); free(pz); free(cnt); free(out); free(omax);
    return 0;
}

/* Run the full surface pipeline for one .sos input already opened on stdin,
   writing to stdout.  Reads hydro_mode / hydro_atoms_path / hydro_sph_path /
   smooth / format / max_vertex_length / points_mode from globals, which are set
   once from the command line and kept fixed across all batch jobs. */
static void process_one_surface(void)
{
    int current_point;
    /* Save hydro_mode so a batch frame with zero spheres doesn't disable hydro
       for all subsequent frames (the load fails for that frame only). */
    int saved_hydro_mode = hydro_mode;

    /* --write-props: compute per-sphere hydropathy values from the sidecar files
       and write them to stdout (one value per line, sph order), then return without
       reading the .sos surface or triangulating. Used by the heatmap fast path. */
    if (write_props_mode) {
        hydro_load();
        if (n_sph > 0) {
            int i;
            for (i = 0; i < n_sph; i++)
                fprintf(stdout, "%.8g\n", sph_h[i]);
        }
        fflush(stdout);
        hydro_mode = saved_hydro_mode;
        return;
    }

    read_cord();
    cull_coords();
    build_neighbour_grid();

    if (hydro_mode) {
        hydro_load();
        /* Mirror the single-job arm's TWO conditions, not just the sphere one.
           In hydro3d mode hydro_load returns after thinning regardless of how
           many residues were parsed, so n_res3d == 0 with n_sph > 0 is
           reachable - and then hydro_at_point_3d's 0.0 sentinel maps through
           norm_color_name to "white" for every centroid, emitting a uniformly
           white mesh instead of the native radius colouring. --batch's own
           contract is that the global hydro flags apply to every job, so this
           is not a deliberate carve-out. Disabled per surface, as above. */
        if (hydro3d_mode) {
            if (n_res3d <= 0) {
                hydro_mode = 0;
                fprintf(stderr, "\nbatch-hydro3d: no residues parsed - "
                                "emitting uncoloured surface for this job\n");
            }
        } else if (n_sph <= 0) {
            hydro_mode = 0;             /* disable for this surface only */
        }
    }

    for (current_point = 0; current_point < max_dots; current_point++) {
        if (check_point(current_point) == 0) {
            start_point = current_point;
            polygonize();
        }
    }
    cull_triangles();
    if (smooth) reorder_triangle();

    switch (format) {
    case 0: vrml_out(); vrml_end(); break;
    case 1: molscript_out(); break;
    case 2: prepi_out(); break;
    case 3: povray_out(); break;
    case 4:
    default:
        if (points_mode) vmd_points_out(); else vmd_out();
        break;
    }
    fflush(stdout);
    hydro_mode = saved_hydro_mode; /* restore so next batch job sees the flag */
}

/* --sos-smooth OUT RHO CENTRE.sos WITH.sos...: a local average of dot clouds.
   Every dot of the centre frame moves to the mean of itself and its nearest
   same-facing dot (within RHO, normals agreeing) in each window frame; its
   normal is the renormalised mean of theirs. Header and centreline records
   are copied as they are, so the colour bands and the dot count of the
   centre frame survive and the result triangulates exactly like any .sos.
   The plugin's pure-Tcl port (hole::sos_smooth) does the same sums in the
   same order and is byte-identical to this. */
typedef struct { double x, y, z, nx, ny, nz; } sm_dot;
typedef struct { sm_dot *d; int n; int *head, *next; int gx, gy, gz; double ox, oy, oz, cell; } sm_cloud;

static int sm_read(const char *path, sm_dot **out) {
  FILE *f = fopen(path, "r"); if (!f) return -1;
  char line[512]; int n = 0, cap = 0; sm_dot *d = NULL;
  while (fgets(line, sizeof line, f)) {
    double v[7]; char *p = line, *e; int k;
    for (k = 0; k < 7; k++) { v[k] = strtod(p, &e); if (e == p) break; p = e; }
    if (k < 7 || v[0] != 4.0) continue;
    if (n == cap) { cap = cap ? cap * 2 : 4096; d = xrealloc(d, cap * sizeof(sm_dot), "sm_dot"); }
    d[n].x = v[1]; d[n].y = v[2]; d[n].z = v[3]; d[n].nx = v[4]; d[n].ny = v[5]; d[n].nz = v[6]; n++;
  }
  fclose(f); *out = d; return n;
}

static void sm_grid(sm_cloud *c, double cell) {
  c->cell = cell;
  double lo[3] = {1e30, 1e30, 1e30}, hi[3] = {-1e30, -1e30, -1e30};
  for (int i = 0; i < c->n; i++) {
    double q[3] = {c->d[i].x, c->d[i].y, c->d[i].z};
    for (int j = 0; j < 3; j++) { if (q[j] < lo[j]) lo[j] = q[j]; if (q[j] > hi[j]) hi[j] = q[j]; }
  }
  if (c->n == 0) { lo[0] = lo[1] = lo[2] = 0; hi[0] = hi[1] = hi[2] = 0; }
  c->ox = lo[0] - cell; c->oy = lo[1] - cell; c->oz = lo[2] - cell;
  c->gx = (int)((hi[0] - c->ox) / cell) + 2; c->gy = (int)((hi[1] - c->oy) / cell) + 2; c->gz = (int)((hi[2] - c->oz) / cell) + 2;
  size_t ncell = (size_t)c->gx * c->gy * c->gz;
  c->head = xrealloc(NULL, ncell * sizeof(int), "sm_head"); for (size_t i = 0; i < ncell; i++) c->head[i] = -1;
  c->next = xrealloc(NULL, (c->n > 0 ? c->n : 1) * sizeof(int), "sm_next");
  /* insert in DESCENDING index order so each cell's chain reads ascending */
  for (int i = c->n - 1; i >= 0; i--) {
    int ix = (int)((c->d[i].x - c->ox) / cell), iy = (int)((c->d[i].y - c->oy) / cell), iz = (int)((c->d[i].z - c->oz) / cell);
    size_t id = ((size_t)ix * c->gy + iy) * c->gz + iz;
    c->next[i] = c->head[id]; c->head[id] = i;
  }
}

/* nearest same-facing dot of cloud c within rho of (x,y,z) with normal n; -1 if none */
static int sm_nearest(const sm_cloud *c, double x, double y, double z, double nx, double ny, double nz, double rho) {
  int ix = (int)((x - c->ox) / c->cell), iy = (int)((y - c->oy) / c->cell), iz = (int)((z - c->oz) / c->cell);
  double best = rho * rho; int bi = -1;
  for (int dx = -1; dx <= 1; dx++) for (int dy = -1; dy <= 1; dy++) for (int dz = -1; dz <= 1; dz++) {
    int cx = ix + dx, cy = iy + dy, cz = iz + dz;
    if (cx < 0 || cy < 0 || cz < 0 || cx >= c->gx || cy >= c->gy || cz >= c->gz) continue;
    for (int i = c->head[((size_t)cx * c->gy + cy) * c->gz + cz]; i >= 0; i = c->next[i]) {
      double ex = c->d[i].x - x, ey = c->d[i].y - y, ez = c->d[i].z - z;
      double d2 = ex*ex + ey*ey + ez*ez;
      if (d2 > best) continue;
      if (c->d[i].nx*nx + c->d[i].ny*ny + c->d[i].nz*nz <= 0.0) continue;
      if (d2 < best || bi < 0 || i < bi) { best = d2; bi = i; }
    }
  }
  return bi;
}

static int sos_smooth(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "\n--sos-smooth needs OUT RHO CENTRE.sos [WITH.sos...]\n"); return 1; }
  const char *outp = argv[2]; double rho = atof(argv[3]); const char *centre = argv[4];
  int nw = argc - 5; sm_cloud *w = xrealloc(NULL, (nw > 0 ? nw : 1) * sizeof(sm_cloud), "sm_cloud");
  for (int k = 0; k < nw; k++) {
    w[k].n = sm_read(argv[5 + k], &w[k].d);
    if (w[k].n < 0) { fprintf(stderr, "\n--sos-smooth: cannot read %s\n", argv[5 + k]); return 1; }
    sm_grid(&w[k], rho);
  }
  FILE *in = fopen(centre, "r"); if (!in) { fprintf(stderr, "\n--sos-smooth: cannot read %s\n", centre); return 1; }
  FILE *out = fopen(outp, "w"); if (!out) { fprintf(stderr, "\n--sos-smooth: cannot write %s\n", outp); fclose(in); return 1; }
  char line[512]; long ndots = 0;
  while (fgets(line, sizeof line, in)) {
    double v[7]; char *p = line, *e; int k;
    for (k = 0; k < 7; k++) { v[k] = strtod(p, &e); if (e == p) break; p = e; }
    if (k < 7 || v[0] != 4.0) { fputs(line, out); continue; }
    double sx = v[1], sy = v[2], sz = v[3], snx = v[4], sny = v[5], snz = v[6]; int cnt = 1;
    for (int j = 0; j < nw; j++) {
      int i = sm_nearest(&w[j], v[1], v[2], v[3], v[4], v[5], v[6], rho);
      if (i < 0) continue;
      sx += w[j].d[i].x; sy += w[j].d[i].y; sz += w[j].d[i].z;
      snx += w[j].d[i].nx; sny += w[j].d[i].ny; snz += w[j].d[i].nz; cnt++;
    }
    sx /= cnt; sy /= cnt; sz /= cnt;
    double nl = sqrt(snx*snx + sny*sny + snz*snz);
    if (nl > 1e-12) { snx /= nl; sny /= nl; snz /= nl; } else { snx = v[4]; sny = v[5]; snz = v[6]; }
    fprintf(out, "%12.5f%12.5f%12.5f%12.5f%12.5f%12.5f%12.5f\n", 4.0, sx, sy, sz, snx, sny, snz);
    ndots++;
  }
  fclose(in); fclose(out);
  for (int k = 0; k < nw; k++) { free(w[k].d); free(w[k].head); free(w[k].next); }
  free(w);
  fprintf(stderr, "sos-smooth: %ld dots over %d window frames (rho %.2f)\n", ndots, nw, rho);
  return 0;
}

int main (int argc, char *argv[])
{
#ifdef VMDPATHFINDER_MULTICALL
  /* One shipped binary carries VMDPathFinder's own tools as well: sos_triangle
     --nm-search|--mesh|--conn-lobes ARGS... runs nm_search, mesh_csg or
     conn_lobes with ARGS as its own argv. The plugin finds them here when no
     standalone build sits beside this file. */
  if (argc > 1) {
    if (strcmp(argv[1], "--nm-search")  == 0) {
      /* nm_search re-execs itself once to pin OMP_WAIT_POLICY=PASSIVE, with
         the argv it was handed - which here would be the shifted one, minus
         this subcommand. Do that re-exec at this level with the full argv. */
#ifndef _WIN32
      if (!getenv("OMP_WAIT_POLICY") && !getenv("NM_NO_REEXEC")) {
        setenv("OMP_WAIT_POLICY", "PASSIVE", 1);
        setenv("NM_NO_REEXEC", "1", 1);
        execv("/proc/self/exe", argv);
        execv(argv[0], argv);
      }
#endif
      argv[1] = argv[0]; return nm_search_main(argc - 1, argv + 1);
    }
    if (strcmp(argv[1], "--mesh")       == 0) { argv[1] = argv[0]; return mesh_csg_main(argc - 1, argv + 1); }
    if (strcmp(argv[1], "--conn-lobes") == 0) { argv[1] = argv[0]; return conn_lobes_main(argc - 1, argv + 1); }
  }
#endif

  int exists;
  int current_point;
  int loop1,loop2;

  /* PROFILING ONLY - see g_ellipse_timing's declaration comment. */
  g_ellipse_timing = (getenv("SOS_ELLIPSE_TIMING") != NULL);

  fprintf (stderr,"sos_triangle: A Hole surface generation program\n");
  fprintf (stderr,"Copyright 1997-9 Guy M.P. Coates \n");
  fprintf (stderr,"Copyright 2000, 2004 Oliver S. Smart \n"); 
  fprintf (stderr,"Copyright 2014-2015 SmartSci Limited, All rights reserved.\n"); 
  fprintf (stderr,"For help on HOLE suite see  http://www.smartsci.uk/hole/\n");
  
  /* initialize the arrays.... */
  
  for (loop1=0;loop1<MAX_COORD;loop1++)
    {
      for (loop2=0;loop2<4;loop2++)
	{
	  dots[loop1][loop2]=-1;
	  tri[loop1][loop2]=-1;
	}
    }


  
  
  /* parse the command line options */

  /*  two options -h for help and -smooth for smooth surfaces -n for number*/
  /* add other options for molscript output */

  while ((argc>1) && (argv[1][0] == '-'))
	
    {
      switch (argv[1][1])
	{
	  
	  /* -h  help!*/
	case 'h':
	  
	  help();
	  return(0);
	  
	case 's':
	  smooth=1;
	  fprintf (stderr,"\nProducing Smooth surface (buggy!).");
	  break;
	  
	case 'm':
	  format=1;
	  fprintf (stderr,"\nProducing Molscript surface.");
	  break;
	  
	case 'l':
	  format=0;
	  fprintf (stderr,"\nProducing VRML surface.");
	  break;
	  
	case 'p':
	  format=2;
	  fprintf (stderr,"\nProducing Prepi surface.");
	  break;
	  
	case 'r':
	  format=3;
	  fprintf (stderr,"\nProducing Povray surface.");
	  break;
	  
       
	case 'd':
	  dump=1;
	  fprintf (stderr,"\nDumping colour records for molscript.");
	  break;

        /* OSS 11/00 vmd surface */
	case 'v':
	  format=4;
	  fprintf (stderr,"\nProducing vmd surface");
	  break;

        case 'X':
	  /* OSS 11/00 maximum distance for a triangle for output */
	  /* pickup number from next arg */
          /* Arity check. The one_arg/two_arg tables below guard the "--" options
             only; this short-option switch is a separate path, so a bare "-X"
             dereferenced argv[2] past the end of argv and segfaulted (confirmed
             under AddressSanitizer). */
          if (argc < 3) {
            fprintf(stderr, "\n-X requires a distance argument\n");
            return(1);
          }
          sscanf(argv[2],"%f",&max_vertex_length);
	  argc--;
          argv++; /* ignore next arg */
	  /*
	  fprintf(stderr,"\nDistance stuff");	
          fprintf(stderr,"\n next arg= `%s`",argv[2]);	    
 	  fprintf(stderr,"\n max_vertex_length= %f",max_vertex_length);
	  */
	  break;

	case '-':
	  /* long options (VMDPathFinder hydrophobicity extension) */
	  /* Arity guard: the options below read argv[2] (some also argv[3]) as operands.
	     Reject a missing operand with a message instead of dereferencing past argv.
	     --asymmetry is excluded on purpose: its output file is optional. */
	  {
	    static const char *one_arg[] = {
	      "--recolor","--hydro-atoms","--hydro-sph","--asym-rays","--hydro-values",
	      "--hydro3d-values","--hydro3d-values-in","--hydro3d-atoms","--hydro3d-lining",
	      "--hydro3d-facing","--hydro3d-thresh","--hydro3d-bandwidth","--hydro3d-props",
	      "--hydro-signed","--hydro-scheme","--hydro-shell","--batch","--batch-recolor",
	      "--bands","--band-names",
	      "--batch-hydro3d-props","--batch-hydro3d-recolor",
	      "--batch-asym-ellipse","--asym-threads","--recolor-threads",NULL };
	    static const char *two_arg[] = { "--hydro-range","--batch-hydro3d-average","--clip-geo",NULL };
	    int gi;
	    for (gi = 0; one_arg[gi]; gi++)
	      if (strcmp(argv[1], one_arg[gi]) == 0 && argc < 3) {
	        fprintf(stderr, "\n%s requires an argument\n", argv[1]); return(1); }
	    for (gi = 0; two_arg[gi]; gi++)
	      if (strcmp(argv[1], two_arg[gi]) == 0 && argc < 4) {
	        fprintf(stderr, "\n%s requires two arguments\n", argv[1]); return(1); }
	  }
	  if (strcmp(argv[1], "--hole-features") == 0) {
	    /* capability probe: the plugin greps stdout for these tokens to decide
	       which accelerated outputs this binary supports. */
	    fprintf(stdout, "hole_features: hydro points batch recolor values props residue batchrecolor hydro3d hydro3dprops batchhydro3dprops hydrorange hydro3dlining batchhydro3drecolor hydro3daverage asymellipse batchasymellipse asymellipsegeo asymthreads clipgeo esp recolorthreads tunneldist tunneldistmax tunnelcluster tunnelclusterdist ionflowproject ionflowcoords ionflowpath sossmooth"
#ifdef VMDPATHFINDER_MULTICALL
	            " nm mesh lobes tunnelserve"
#endif
	            "\n");
	    return(0);
	  } else if (strcmp(argv[1], "--recolor") == 0) {
	    /* --recolor BASE.vmd_plot: recolour an existing mesh by hydropathy
	       without re-triangulating (implies hydro colouring). */
	    recolor_mode = 1;
	    hydro_mode = 1;
	    strncpy(recolor_path, argv[2], sizeof(recolor_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--batch") == 0) {
	    /* --batch FILE: process multiple surfaces sequentially from a batch file.
	       Each line: sos_file<TAB>out_file[<TAB>atoms_file<TAB>sph_file]
	       Global flags (-s, --points, global hydro flags) apply to every job. */
	    if (argc < 3) {
	      fprintf(stderr, "\n--batch requires a FILE argument\n");
	      return(1);
	    }
	    {
	      FILE *bf = fopen(argv[2], "r");
	      char line[8192];
	      char sos_path[2048], out_path[2048];
	      char atoms_path[2048], sph_path_buf[2048];
	      int job_num = 0;
	      int prev_max_dots = 0, prev_in_dots = 0, prev_tri = 0;
	      if (!bf) {
	        fprintf(stderr, "\n--batch: cannot open batch file: %s\n", argv[2]);
	        return(1);
	      }
	      /* Consume remaining argv so the outer parse loop exits cleanly. */
	      argc = 1;
	      while (fgets(line, sizeof(line), bf)) {
	        int n;
	        line[strcspn(line, "\n")] = 0;
	        if (line[0] == '#' || line[0] == '\0') continue;
	        /* Parse TAB-delimited fields so paths with spaces are handled correctly.
	           Format: sos<TAB>out[<TAB>atoms<TAB>sph] */
	        {
	          char *tok;
	          n = 0;
	          tok = strtok(line, "\t");
	          if (tok) { strncpy(sos_path,     tok, 2047); sos_path[2047]     = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(out_path,     tok, 2047); out_path[2047]     = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(atoms_path,   tok, 2047); atoms_path[2047]   = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(sph_path_buf, tok, 2047); sph_path_buf[2047] = 0; n++; }
	        }
	        if (n < 2) continue;
	        if (n >= 4) {
	          /* Per-job hydro paths override the command-line paths. */
	          strncpy(hydro_atoms_path, atoms_path, sizeof(hydro_atoms_path)-1);
	          strncpy(hydro_sph_path,   sph_path_buf, sizeof(hydro_sph_path)-1);
	        }
	        if (freopen(sos_path, "r", stdin)  == NULL) {
	          fprintf(stderr, "\nbatch[%d]: cannot open sos input: %s\n",
	                  job_num, sos_path);
	          continue;
	        }
	        if (freopen(out_path, "w", stdout) == NULL) {
	          fprintf(stderr, "\nbatch[%d]: cannot open output: %s\n",
	                  job_num, out_path);
	          continue;
	        }
	        if (job_num > 0) {
	          reset_for_batch_job(prev_max_dots, prev_in_dots, prev_tri);
	        } else {
	          /* First job: allocate the edge-list sentinel (main() does it below
	             for the single-job path; we do it here for the batch path). */
	          start = malloc(sizeof(struct edge_list));
	          if (!start) { fprintf(stderr, "\nOOM\n"); fclose(bf); return(1); }
	          start->next = NULL; end = start;
	        }
	        process_one_surface();
	        prev_max_dots = max_dots;
	        prev_in_dots  = in_dots_total;
	        prev_tri      = tri_count;
	        job_num++;
	      }
	      fclose(bf);
	      return(0);
	    }
	  } else if (strcmp(argv[1], "--batch-recolor") == 0) {
	    /* --batch-recolor FILE: recolour multiple already-triangulated base meshes
	       in ONE process (the caller round-robin distributes frames across several
	       batch files, one process per worker), instead of spawning one --recolor
	       process per frame. Each individual recolour is cheap (no triangulation),
	       so per-process spawn overhead would otherwise be a large fraction of the
	       total cost - this is the same motivation as --batch, applied to the
	       recolour path instead of the triangulation path.
	       Each line (4 required fields, values-path only - the --hydro-atoms legacy
	       path is not supported here):
	       base_vmd_plot<TAB>out_vmd_plot<TAB>values_path<TAB>sph_path
	       --hydro-signed applies to every job (parsed before --batch-recolor
	       consumes argv, exactly like --batch's global flags). */
	    if (argc < 3) {
	      fprintf(stderr, "\n--batch-recolor requires a FILE argument\n");
	      return(1);
	    }
	    {
	      FILE *bf = fopen(argv[2], "r");
	      char line[8192];
	      char base_path[2048], out_path[2048];
	      char values_path_buf[2048], sph_path_buf[2048];
	      int job_num = 0;
	      if (!bf) {
	        fprintf(stderr, "\n--batch-recolor: cannot open batch file: %s\n", argv[2]);
	        return(1);
	      }
	      /* Consume remaining argv so the outer parse loop exits cleanly. */
	      argc = 1;
	      while (fgets(line, sizeof(line), bf)) {
	        int n;
	        line[strcspn(line, "\n")] = 0;
	        if (line[0] == '#' || line[0] == '\0') continue;
	        {
	          char *tok;
	          n = 0;
	          tok = strtok(line, "\t");
	          if (tok) { strncpy(base_path,       tok, 2047); base_path[2047]       = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(out_path,        tok, 2047); out_path[2047]        = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(values_path_buf, tok, 2047); values_path_buf[2047] = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(sph_path_buf,    tok, 2047); sph_path_buf[2047]    = 0; n++; }
	        }
	        if (n < 4) {
	          fprintf(stderr, "\nbatch-recolor[%d]: expected 4 tab-separated fields, got %d - skipping\n",
	                  job_num, n);
	          continue;
	        }
	        if (freopen(out_path, "w", stdout) == NULL) {
	          fprintf(stderr, "\nbatch-recolor[%d]: cannot open output: %s\n",
	                  job_num, out_path);
	          continue;
	        }
	        if (job_num > 0) reset_hydro_state();
	        strncpy(hydro_values_path, values_path_buf, sizeof(hydro_values_path)-1);
	        strncpy(hydro_sph_path,   sph_path_buf,     sizeof(hydro_sph_path)-1);
	        hydro_values_mode = 1;
	        hydro_load();
	        if (n_sph > 0) {
	          recolor_vmd_plot(base_path);
	        } else {
	          fprintf(stderr, "\nbatch-recolor[%d]: no spheres parsed for %s - skipping\n",
	                  job_num, base_path);
	        }
	        job_num++;
	      }
	      fclose(bf);
	      return(0);
	    }
	  } else if (strcmp(argv[1], "--batch-hydro3d-props") == 0) {
	    /* --batch-hydro3d-props FILE: compute --hydro3d-props for multiple frames
	       in ONE process (same per-process-spawn-overhead motivation as
	       --batch-recolor) - this is what makes the unified true-3D pipeline fast
	       enough for the Over Time heatmap / Mean Profile across thousands of
	       frames, not just a single interactive frame.
	       Each line (4 required fields):
	       sos_path<TAB>residues_path<TAB>sph_path<TAB>out_props_path
	       --hydro3d-bandwidth applies to every job (parsed before this flag
	       consumes argv, exactly like --batch-recolor's --hydro-signed). */
	    if (argc < 3) {
	      fprintf(stderr, "\n--batch-hydro3d-props requires a FILE argument\n");
	      return(1);
	    }
	    {
	      FILE *bf = fopen(argv[2], "r");
	      char line[8192];
	      char sos_path[2048], res_path[2048], sph_path_buf[2048], out_path[2048];
	      int job_num = 0;
	      int prev_max_dots = 0, prev_in_dots = 0, prev_tri = 0;
	      if (!bf) {
	        fprintf(stderr, "\n--batch-hydro3d-props: cannot open batch file: %s\n", argv[2]);
	        return(1);
	      }
	      argc = 1;
	      while (fgets(line, sizeof(line), bf)) {
	        int n;
	        FILE *sf;
	        line[strcspn(line, "\n")] = 0;
	        if (line[0] == '#' || line[0] == '\0') continue;
	        {
	          char *tok;
	          n = 0;
	          tok = strtok(line, "\t");
	          if (tok) { strncpy(sos_path,     tok, 2047); sos_path[2047]     = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(res_path,     tok, 2047); res_path[2047]     = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(sph_path_buf, tok, 2047); sph_path_buf[2047] = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(out_path,     tok, 2047); out_path[2047]     = 0; n++; }
	        }
	        if (n < 4) {
	          fprintf(stderr, "\nbatch-hydro3d-props[%d]: expected 4 tab-separated fields, got %d - skipping\n",
	                  job_num, n);
	          continue;
	        }
	        if (job_num > 0) {
	          reset_hydro_state();
	          reset_for_batch_job(prev_max_dots, prev_in_dots, prev_tri);
	        }
	        strncpy(hydro3d_path,   res_path,     sizeof(hydro3d_path)-1);
	        strncpy(hydro_sph_path, sph_path_buf, sizeof(hydro_sph_path)-1);
	        strncpy(hydro3d_props_path, out_path, sizeof(hydro3d_props_path)-1);
	        hydro3d_mode = 1;
	        hydro_load();
	        /* freopen(), not fopen()+"stdin = sf": stdin is a plain assignable
	           FILE* on glibc but a non-lvalue macro on the Windows CRT, so a
	           direct assignment fails to compile there. freopen() redirects
	           the stream portably and is meant to be re-called like this every
	           iteration; the reopened stream is closed by the next freopen()
	           (or at exit), so it is not fclose()'d here. */
	        sf = freopen(sos_path, "r", stdin);
	        if (!sf) {
	          fprintf(stderr, "\nbatch-hydro3d-props[%d]: cannot open sos file: %s - skipping\n",
	                  job_num, sos_path);
	          job_num++;
	          continue;
	        }
	        read_cord();
	        cull_coords();
	        /* n_res3d==0 (no qualifying contributors this frame) is NOT skipped:
	           hydro3d_write_props then writes n_sph zeros (hydro_at_point_3d
	           returns 0 with no contributors), keeping the per-frame value COUNT
	           consistent with every other frame so the Tcl reader never drops a
	           frame on a length mismatch. Only a genuinely empty surface is
	           skipped. */
	        if (n_sph > 0) {
	          hydro3d_write_props();
	        } else {
	          fprintf(stderr, "\nbatch-hydro3d-props[%d]: no spheres parsed - skipping\n",
	                  job_num);
	        }
	        prev_max_dots = max_dots; prev_in_dots = in_dots_total; prev_tri = tri_count;
	        job_num++;
	      }
	      fclose(bf);
	      return(0);
	    }
	  } else if (strcmp(argv[1], "--batch-hydro3d-recolor") == 0) {
	    /* --batch-hydro3d-recolor FILE: true-3D per-triangle recolour of multiple
	       already-triangulated base meshes in ONE process - the --hydro3d-atoms
	       equivalent of --batch-recolor, so "Accurate 3D colouring" prebuilds every
	       frame's coloured mesh instead of building it lazily on first scrub/settle.
	       recolor_vmd_plot() doesn't touch the dots[]/tri[] triangulation-phase
	       arrays at all (it re-parses the base mesh's own triangle lines directly),
	       so only reset_hydro_state() is needed between jobs - same as
	       --batch-recolor, no reset_for_batch_job() call needed.
	       Requires --hydro3d-atoms atom|residue [--hydro3d-facing 0|1]
	       [--hydro3d-thresh N] and --hydro3d-bandwidth N to be given BEFORE this
	       flag (parsed globally and held fixed across every job in the batch,
	       same convention as --batch-recolor's --hydro-signed / --hydro-range).
	       Each line (4 required fields):
	       base_vmd_plot<TAB>out_vmd_plot<TAB>atoms_or_residues_path<TAB>sph_path */
	    if (argc < 3) {
	      fprintf(stderr, "\n--batch-hydro3d-recolor requires a FILE argument\n");
	      return(1);
	    }
	    {
	      FILE *bf = fopen(argv[2], "r");
	      char line[8192];
	      char base_path[2048], out_path[2048];
	      char res_path_buf[2048], sph_path_buf[2048];
	      int job_num = 0;
	      if (!bf) {
	        fprintf(stderr, "\n--batch-hydro3d-recolor: cannot open batch file: %s\n", argv[2]);
	        return(1);
	      }
	      /* Consume remaining argv so the outer parse loop exits cleanly. */
	      argc = 1;
	      while (fgets(line, sizeof(line), bf)) {
	        int n;
	        line[strcspn(line, "\n")] = 0;
	        if (line[0] == '#' || line[0] == '\0') continue;
	        {
	          char *tok;
	          n = 0;
	          tok = strtok(line, "\t");
	          if (tok) { strncpy(base_path,    tok, 2047); base_path[2047]    = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(out_path,     tok, 2047); out_path[2047]     = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(res_path_buf, tok, 2047); res_path_buf[2047] = 0; n++; }
	          tok = strtok(NULL, "\t");
	          if (tok) { strncpy(sph_path_buf, tok, 2047); sph_path_buf[2047] = 0; n++; }
	        }
	        if (n < 4) {
	          fprintf(stderr, "\nbatch-hydro3d-recolor[%d]: expected 4 tab-separated fields, got %d - skipping\n",
	                  job_num, n);
	          continue;
	        }
	        if (freopen(out_path, "w", stdout) == NULL) {
	          fprintf(stderr, "\nbatch-hydro3d-recolor[%d]: cannot open output: %s\n",
	                  job_num, out_path);
	          continue;
	        }
	        if (job_num > 0) reset_hydro_state();
	        strncpy(hydro3d_path,   res_path_buf, sizeof(hydro3d_path)-1);
	        strncpy(hydro_sph_path, sph_path_buf, sizeof(hydro_sph_path)-1);
	        hydro3d_mode = 1;
	        hydro_load();
	        if (n_sph > 0) {
	          recolor_vmd_plot(base_path);
	        } else {
	          fprintf(stderr, "\nbatch-hydro3d-recolor[%d]: no spheres parsed for %s - skipping\n",
	                  job_num, base_path);
	        }
	        job_num++;
	      }
	      fclose(bf);
	      return(0);
	    }
	  } else if (strcmp(argv[1], "--batch-hydro3d-average") == 0) {
	    /* --batch-hydro3d-average JOBLIST OUTFILE: trajectory-average true-3D
	       per-triangle colouring for ONE FIXED base mesh (the Mean Profile
	       tube, whose geometry never changes across frames) - each JOBLIST
	       line is one frame's residue-sidecar path (same convention as
	       --hydro3d-values). --recolor, --hydro-sph and --hydro3d-bandwidth
	       must be given first and are held fixed across every job, like every
	       other --batch* mode. Writes OUTFILE as: job-count on line 1, then
	       one ACCUMULATED (not yet divided) SUM per triangle, in
	       recolor_vmd_plot's own encounter order - dispatched across N worker
	       processes (this plugin's normal batch-parallelism pattern), each
	       covering a distinct frame subset, so the partial sums are merged
	       (and divided) by the Tcl caller afterward. A frame with zero
	       qualifying residues is skipped entirely (not counted in job-count):
	       hydro_at_point_3d()'s 0.0 sentinel for "no contributors" would
	       otherwise pull every triangle's average toward a spurious neutral
	       value (VMDPathFinder extension). */
	    if (argc < 4 || recolor_path[0] == '\0') {
	      fprintf(stderr, "\n--batch-hydro3d-average requires --recolor BASE first, then JOBLIST OUTFILE\n");
	      return(1);
	    }
	    {
	      FILE *jf = fopen(argv[2], "r");
	      char jline[2048];
	      double *sum = NULL; int cap = 0, n_tri = 0, job_count = 0, job_idx = 0;
	      FILE *of;
	      if (!jf) {
	        fprintf(stderr, "\n--batch-hydro3d-average: cannot open joblist: %s\n", argv[2]);
	        return(1);
	      }
	      while (fgets(jline, sizeof(jline), jf)) {
	        char *tab;
	        jline[strcspn(jline, "\n")] = 0;
	        if (jline[0] == '#' || jline[0] == '\0') continue;
	        if (job_idx > 0) reset_hydro_state();
	        /* Optional per-frame sph as a 2nd TAB-separated field. The legacy path
	           hands us PRE-LINED residues (Tcl did the lining), which need no real sph
	           here - only the n_sph>0 guard - so a global --hydro-sph suffices. The
	           atoms path (--hydro3d-lining set: the plugin hands us ALL channel atoms
	           and C does the lining in hydro_load) MUST use each frame\047s OWN pore
	           geometry, so its sph is passed per line and overrides the global. */
	        tab = strchr(jline, '\t');
	        if (tab) {
	          *tab = '\0';
	          strncpy(hydro_sph_path, tab + 1, sizeof(hydro_sph_path)-1);
	          hydro_sph_path[sizeof(hydro_sph_path)-1] = '\0';
	        }
	        strncpy(hydro3d_path, jline, sizeof(hydro3d_path)-1);
	        hydro3d_mode = 1;
	        hydro_load();
	        if (n_sph > 0 && n_res3d > 0) {
	          accumulate_hydro3d_pass(recolor_path, &sum, &cap, &n_tri);
	          job_count++;
	        }
	        job_idx++;
	      }
	      fclose(jf);
	      of = fopen(argv[3], "w");
	      if (!of) {
	        fprintf(stderr, "\n--batch-hydro3d-average: cannot open output: %s\n", argv[3]);
	        free(sum);
	        return(1);
	      }
	      fprintf(of, "%d\n", job_count);
	      { int ti; for (ti = 0; ti < n_tri; ti++) fprintf(of, "%.10g\n", sum[ti]); }
	      fclose(of);
	      free(sum);
	      return(0);
	    }
	  } else if (strcmp(argv[1], "--points") == 0) {
	    points_mode = 1;
	  } else if (strcmp(argv[1], "--hydro-atoms") == 0) {
	    hydro_mode = 1;
	    strncpy(hydro_atoms_path, argv[2], sizeof(hydro_atoms_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro-sph") == 0) {
	    strncpy(hydro_sph_path, argv[2], sizeof(hydro_sph_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--asym-rays") == 0) {
	    asym_rays = atoi(argv[2]); if (asym_rays < 3) asym_rays = 36;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--asym-threads") == 0) {
	    asym_threads = atoi(argv[2]); if (asym_threads < 1) asym_threads = 1;
	    asym_threads_explicit = 1;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--recolor-threads") == 0) {
	    recolor_threads = atoi(argv[2]); if (recolor_threads < 1) recolor_threads = 1;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--asym-ellipse") == 0) {
	    /* --asym-ellipse [OUTFILE [tx ty tz]]: per-sphere ellipse-probe asymmetry (PoreAnalyser
	       method). Same inputs as --asymmetry (--hydro-sph + --hydro3d-atoms first). Optional
	       tx ty tz = the fixed slicing axis (the HOLE cvect); omit to derive it from the atoms.
	       Emits "b a 0" per sphere (minor=HOLE radius, major grown to atom contact). */
	    FILE *aout = stdout;
	    double _tp0 = g_ellipse_timing ? now_sec() : 0.0, _tp1, _tc0, _tc1;
	    hydro_read_spheres();
	    hydro_splice_spheres();
	    hydro3d_read_atoms_lining();
	    if (argc >= 6 && argv[2][0] != '-' && argv[3][0] != '-') {
	      asym_axis[0] = atof(argv[3]); asym_axis[1] = atof(argv[4]); asym_axis[2] = atof(argv[5]);
	    }
	    if (argc >= 3 && argv[2][0] != '-') {
	      aout = fopen(argv[2], "w");
	      if (!aout) { fprintf(stderr, "\n--asym-ellipse: cannot open output %s\n", argv[2]); return(1); }
	      argc--; argv++;
	    }
	    asym_threads_auto_single_frame();
	    _tp1 = g_ellipse_timing ? now_sec() : 0.0;
	    _tc0 = _tp1;
	    if (n_sph > 0) compute_ellipse(asym_rays, aout, 0);
	    _tc1 = g_ellipse_timing ? now_sec() : 0.0;
	    if (aout != stdout) fclose(aout);
	    if (g_ellipse_timing) {
	      fprintf(stderr, "SOS_ELLIPSE_TIMING n_sph=%d n_at3=%d threads=%d parse_s=%.6f "
	                       "compute_wall_s=%.6f gather_sum_s=%.6f fit_sum_s=%.6f\n",
	              n_sph, n_at3, asym_threads, _tp1-_tp0, _tc1-_tc0, g_time_gather, g_time_fit);
	    }
	    return(0);
	  } else if (strcmp(argv[1], "--asym-ellipse-geo") == 0) {
	    /* --asym-ellipse-geo [OUTFILE [tx ty tz]]: same fit as --asym-ellipse, but also emits
	       the fitted orientation + in-plane centre offset ("b a 0 theta ecx ecy") so the
	       reshaped-pore surface can place each ellipse at its true fitted centre, not the HOLE
	       sphere's - PoreAnalyser's own optimiser moves the centre, so the surface should
	       follow it exactly like the reported a/b do. Single-frame only (no batch variant):
	       the surface is built for one viewed frame at a time, never a whole trajectory. */
	    FILE *aout = stdout;
	    hydro_read_spheres();
	    hydro_splice_spheres();
	    hydro3d_read_atoms_lining();
	    if (argc >= 6 && argv[2][0] != '-' && argv[3][0] != '-') {
	      asym_axis[0] = atof(argv[3]); asym_axis[1] = atof(argv[4]); asym_axis[2] = atof(argv[5]);
	    }
	    if (argc >= 3 && argv[2][0] != '-') {
	      aout = fopen(argv[2], "w");
	      if (!aout) { fprintf(stderr, "\n--asym-ellipse-geo: cannot open output %s\n", argv[2]); return(1); }
	      argc--; argv++;
	    }
	    asym_threads_auto_single_frame();
	    if (n_sph > 0) compute_ellipse(asym_rays, aout, 1);
	    if (aout != stdout) fclose(aout);
	    return(0);
	  } else if (strcmp(argv[1], "--sos-smooth") == 0) {
	    return sos_smooth(argc, argv);
	  } else if (strcmp(argv[1], "--esp") == 0) {
	    /* --esp CHARGEFILE OUTFILE: mean centerline electrostatic potential (needs
	       --hydro-sph first). Pure speedup for electrostatic_potential_for_frame;
	       Tcl computes the same thing when this binary/flag is absent. */
	    if (argc < 4) { fprintf(stderr, "\n--esp needs CHARGEFILE OUTFILE\n"); return(1); }
	    hydro_read_spheres();
	    hydro_splice_spheres();
	    return( esp_compute(argv[2], argv[3], 0) );
	  } else if (strcmp(argv[1], "--esp-points") == 0) {
	    /* --esp-points CHARGEFILE OUTFILE: the potential at EVERY .sph point (file
	       order, one per line), for the ESP surface-colouring overlay. No splice/
	       filter - lines up 1:1 with the sph ATOM/HETATM records. */
	    if (argc < 4) { fprintf(stderr, "\n--esp-points needs CHARGEFILE OUTFILE\n"); return(1); }
	    hydro_read_spheres();
	    return( esp_compute(argv[2], argv[3], 1) );
	  } else if (strcmp(argv[1], "--ionflow-project") == 0) {
	    /* --ionflow-project IN OUT: see ionflow_project(). */
	    if (argc < 4) { fprintf(stderr, "\n--ionflow-project needs IN OUT\n"); return(1); }
	    return ionflow_project(argv[2], argv[3]);
	  } else if (strcmp(argv[1], "--tunnel-dist") == 0) {
	    /* --tunnel-dist IN OUT
	       Pairwise tunnel dissimilarity matrix for the average-link clustering.
	       IN is "T <n>" then n "x y z" lines, repeated. OUT is "i j d" per pair.

	       Exists because the matrix IS the cost of clustering: measured on 49
	       tunnels it was 12.6 s of a 12.8 s clustering in Tcl, while the
	       agglomeration itself was 0.18 s. The algorithm was never the problem;
	       an interpreted O(n^2 m^2) inner loop was. */
	    if (argc < 4) { fprintf(stderr, "\n--tunnel-dist needs IN OUT\n"); return(1); }
	    return tunnel_dist(argv[2], argv[3], argc > 4 && atoi(argv[4]) ? 1 : 0);
	  /* A bare `}` + fresh `if` here silently ends the
	     if/else-if chain here. Every flag below (--tunnel-cluster onward,
	     including --batch-asym-ellipse) was UNREACHABLE whenever it followed
	     ANY flag above (--asym-rays, --hydro-sph, --points, ...) that fell
	     through without its own return() - the combined invocation always
	     hit the chain's OWN "unrecognized flag" catch-all (help(); return(0))
	     a few lines below, silently, with rc=0 and no output file. Confirmed
	     with gdb: `--asym-rays 36 --batch-asym-ellipse JOBLIST` never reached
	     the --batch-asym-ellipse branch. Reconnecting with `else if` restores
	     ONE chain, so every later flag is reachable in combination again. */
	  } else if (argc >= 5 && !strcmp(argv[1], "--tunnel-cluster")) {
	    return tunnel_cluster_c(argv[2], argv[3], atof(argv[4]),
	                            argc > 5 ? atof(argv[5]) : 0.0);
	  } else if (strcmp(argv[1], "--clip-geo") == 0) {
	    /* --clip-geo GEOFILE OUTFILE [tx ty tz]: render-only atom clip for the reshaped-pore
	       surface. GEOFILE has the (already smoothed) per-slice ellipse geometry, 12 numbers/line
	       (cx cy cz bhx bhy bhz whx why whz a b th); needs --hydro3d-atoms (x y z vdw ...) first and
	       --asym-rays for the ring count. Emits the clipped polar radii, `ring` per line. The optional
	       tx ty tz is the slicing axis for the z-slab; omit to use z. */
	    FILE *cout;
	    if (argc < 4) { fprintf(stderr, "\n--clip-geo requires GEOFILE and OUTFILE\n"); return(1); }
	    hydro3d_read_atoms_lining();
	    if (argc >= 7 && argv[4][0] != '-') {
	      asym_axis[0] = atof(argv[4]); asym_axis[1] = atof(argv[5]); asym_axis[2] = atof(argv[6]);
	    }
	    cout = fopen(argv[3], "w");
	    if (!cout) { fprintf(stderr, "\n--clip-geo: cannot open output %s\n", argv[3]); return(1); }
	    clip_rings(argv[2], cout, asym_rays);
	    fclose(cout);
	    return(0);
	  } else if (strcmp(argv[1], "--batch-asym-ellipse") == 0) {
	    /* --batch-asym-ellipse JOBLIST: trajectory ellipse-probe asymmetry, one process,
	       many frames. Each line: atoms<TAB>sph<TAB>outfile[<TAB>tx<TAB>ty<TAB>tz] . The
	       optional trailing tx ty tz is the fixed slicing axis (the pore vector), so a batch
	       slices on the SAME axis the single-frame --asym-ellipse uses; omit it to derive the
	       axis from the atom cloud instead. */
	    FILE *jf; char jline[8192]; int job = 0;
	    if (argc < 3) { fprintf(stderr, "\n--batch-asym-ellipse requires a JOBLIST\n"); return(1); }
	    jf = fopen(argv[2], "r");
	    if (!jf) { fprintf(stderr, "\n--batch-asym-ellipse: cannot open joblist %s\n", argv[2]); return(1); }
	    while (fgets(jline, sizeof(jline), jf)) {
	      char *t1, *t2, *t3; FILE *aout;
	      double atx=0, aty=0, atz=0; int have_ax=0;
	      jline[strcspn(jline, "\r\n")] = 0;
	      if (jline[0] == '#' || jline[0] == '\0') continue;
	      t1 = strchr(jline, '\t'); if (!t1) continue; *t1++ = 0;
	      t2 = strchr(t1, '\t');    if (!t2) continue; *t2++ = 0;
	      t3 = strchr(t2, '\t');    /* optional axis after the outfile */
	      if (t3) { *t3++ = 0; if (sscanf(t3, "%lf %lf %lf", &atx, &aty, &atz) == 3) have_ax = 1; }
	      reset_hydro_state();
	      /* asym_axis is a global; set (or clear) it per job so a job without an axis
	         doesn't inherit the previous job's. */
	      asym_axis[0] = have_ax ? atx : 0.0;
	      asym_axis[1] = have_ax ? aty : 0.0;
	      asym_axis[2] = have_ax ? atz : 0.0;
	      strncpy(hydro3d_path,  jline, sizeof(hydro3d_path)-1);  hydro3d_path[sizeof(hydro3d_path)-1]=0;
	      strncpy(hydro_sph_path, t1,   sizeof(hydro_sph_path)-1); hydro_sph_path[sizeof(hydro_sph_path)-1]=0;
	      hydro_read_spheres();
	      hydro_splice_spheres();
	      hydro3d_read_atoms_lining();
	      aout = fopen(t2, "w");
	      if (aout) { if (n_sph > 0) compute_ellipse(asym_rays, aout, 0); fclose(aout); }
	      job++;
	    }
	    fclose(jf);
	    return(0);
	  } else if (strcmp(argv[1], "--value-radius") == 0) {
	    /* Colour by the nearest centreline sphere's own radius (see --bands). */
	    hydro_mode = 1;
	    hydro_bands_mode = 1;
	  } else if (strcmp(argv[1], "--bands") == 0) {
	    char *tok;
	    n_band_edges = 0;
	    for (tok = strtok(argv[2], ","); tok && n_band_edges <= SOS_MAXBANDS; tok = strtok(NULL, ","))
	      band_edge[n_band_edges++] = atof(tok);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--band-names") == 0) {
	    char *tok;
	    n_bands = 0;
	    for (tok = strtok(argv[2], ","); tok && n_bands < SOS_MAXBANDS; tok = strtok(NULL, ","))
	      band_name[n_bands++] = tok;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro-values") == 0) {
	    /* Pre-computed per-sphere normalized values (any scale, any lining mode):
	       turns on hydro colouring AND selects the agnostic values path. */
	    hydro_mode = 1;
	    hydro_values_mode = 1;
	    strncpy(hydro_values_path, argv[2], sizeof(hydro_values_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-values") == 0) {
	    /* TRUE per-triangle colouring: "x y z value" per qualifying pore-lining
	       residue (VMDPathFinder extension, not part of stock sos_triangle/HOLE) -
	       see hydro_at_point_3d(). Additive: turns on hydro colouring same as
	       --hydro-values, but picks the real-3D-distance lookup instead of the
	       nearest-centerline-sphere one, so colour varies by angular position
	       around the pore, not just by height. */
	    hydro_mode = 1;
	    hydro3d_mode = 1;
	    strncpy(hydro3d_path, argv[2], sizeof(hydro3d_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-values-in") == 0) {
	    /* Colour from an ALREADY-AVERAGED per-triangle values file (one float
	       per triangle, in the SAME encounter order recolor_vmd_plot walks the
	       base mesh) instead of live-evaluating hydro_at_point_3d() - the final
	       colourise pass for the Mean Profile's trajectory-averaged "Accurate
	       3D" feature, fed by --batch-hydro3d-average's merged output
	       (VMDPathFinder extension). */
	    hydro_mode = 1;
	    hydro3d_mode = 1;
	    hydro3d_precomputed = 1;
	    {
	      FILE *pf = fopen(argv[2], "r");
	      char pline[64];
	      if (pf) {
	        while (fgets(pline, sizeof(pline), pf)) {
	          if (n_precomputed == precomputed_cap) {
	            precomputed_cap = precomputed_cap ? precomputed_cap*2 : 4096;
	            precomputed_vals = xrealloc(precomputed_vals, precomputed_cap*sizeof(double), "precomputed_vals");
	          }
	          precomputed_vals[n_precomputed++] = atof(pline);
	        }
	        fclose(pf);
	      }
	    }
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-atoms") == 0) {
	    /* C-side pore lining (build 2026-07-08g): like --hydro3d-values but the
	       FILE carries ALL channel-local atoms ("x y z value resid is_ca"), not
	       the pre-filtered qualifying residues - the binary does the lining/facing
	       test itself (hydro3d_build_contributors). Needs --hydro3d-lining to pick
	       residue vs atom mode. Reuses hydro3d_path; hydro3d_lining picks reader. */
	    hydro_mode = 1;
	    hydro3d_mode = 1;
	    if (hydro3d_lining == 0) hydro3d_lining = 1;  /* default residue */
	    strncpy(hydro3d_path, argv[2], sizeof(hydro3d_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-lining") == 0) {
	    /* residue = contributor per qualifying residue COG; atom = per qualifying
	       atom (KR). Applies to every --batch* job (parsed before the batch flag
	       consumes argv, like --hydro3d-bandwidth). */
	    hydro3d_lining = (strcmp(argv[2], "atom") == 0) ? 2 : 1;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-facing") == 0) {
	    hydro3d_facing = (atoi(argv[2]) != 0);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-thresh") == 0) {
	    hydro3d_thresh = atof(argv[2]);
	    if (hydro3d_thresh < 0.05) hydro3d_thresh = 3.0;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-bandwidth") == 0) {
	    hydro3d_bandwidth = atof(argv[2]);
	    if (hydro3d_bandwidth < 0.05) hydro3d_bandwidth = 3.0;
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro3d-props") == 0) {
	    /* Per-sphere MEAN of the true-3D dot values nearest each sphere - the
	       single authoritative source for Profile Fill / Heatmap / Mean Profile
	       (see the comment above hydro3d_props_path). Requires --hydro3d-values
	       to also be given. */
	    hydro3d_props_mode = 1;
	    strncpy(hydro3d_props_path, argv[2], sizeof(hydro3d_props_path)-1);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--write-props") == 0) {
    /* Write one per-sphere hydropathy value per line to stdout, then exit without
       triangulating. Combine with --batch for multi-frame heatmap pre-computation. */
    write_props_mode = 1;
    hydro_mode = 1;
  } else if (strcmp(argv[1], "--hydro-residue") == 0) {
    /* Average by unique residue (6th column of the atom sidecar) rather than by
       atom count, matching the Tcl residue-mean path for kd/ww. Requires the
       atom sidecar to carry the integer residue ID written by write_hydro_sidecar_batch. */
    hydro_residue_mode = 1;
  } else if (strcmp(argv[1], "--hydro-signed") == 0) {
	    /* Colour ramp for the values path: 1 = diverging (blue-white-red),
	       0 = sequential (white-red). Matches the scale's "signed" flag. */
	    hydro_signed = (atoi(argv[2]) != 0);
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro-range") == 0) {
	    /* --hydro-range LO HI: the property scale's real extremes, so RAW
	       sidecar values colour identically to the old normalized path.
	       Consumes TWO args; applies to every --batch* job (parsed before
	       the batch flag consumes argv, like --hydro-signed). */
	    hydro_lo = atof(argv[2]);
	    hydro_hi = atof(argv[3]);
	    hydro_have_range = 1;
	    argc -= 2; argv += 2;
	  } else if (strcmp(argv[1], "--hydro-scheme") == 0) {
	    hydro_kd = (strcmp(argv[2], "ww") != 0); /* anything but "ww" = kd */
	    argc--; argv++;
	  } else if (strcmp(argv[1], "--hydro-shell") == 0) {
	    /* Lining-shell thickness in A (default 3.0). Parsed before --batch
	       consumes argv, so it applies to every job in batch mode too. */
	    hydro_shell_cut = atof(argv[2]);
	    if (hydro_shell_cut < 0.5) hydro_shell_cut = 3.0;
	    argc--; argv++;
	  } else {
	    help();
	    return(0);
	  }
	  break;

	default:
	  help();
	  return(0);

	}
      
      
      argc--;
      argv++;
    }
  
  
  /* --recolor: re-colour an existing base mesh and exit, skipping the whole
     read/triangulate pipeline (this is the cheap recolour the plugin uses for a
     hydrophobicity scheme/colour change). */
  if (recolor_mode) {
    hydro_load();
    if (n_sph <= 0) {
      fprintf(stderr, "\n--recolor: no spheres parsed; nothing to do.\n");
      return(1);
    }
    if (hydro3d_mode) {
      fprintf(stderr, "\nrecolour: true-3D per-triangle values (%d residues), base %s",
              n_res3d, recolor_path);
    } else if (hydro_values_mode) {
      fprintf(stderr, "\nrecolour: pre-computed values (%d spheres), base %s",
              n_sph, recolor_path);
    } else {
      fprintf(stderr, "\nrecolour: %s scale (%d spheres, %d atoms), base %s",
              hydro_kd ? "Kyte-Doolittle" : "Wimley-White", n_sph, n_atom, recolor_path);
    }
    recolor_vmd_plot(recolor_path);
    fprintf(stderr, "\nProgram COMPLETE\n");
    return(0);
  }

  /* --write-props (single-job path): compute per-sphere h values and write to stdout,
     then exit without reading the .sos surface or triangulating. */
  if (write_props_mode) {
    hydro_load();
    if (n_sph > 0) {
      int i;
      for (i = 0; i < n_sph; i++)
        fprintf(stdout, "%.8g\n", sph_h[i]);
    }
    fflush(stdout);
    return(0);
  }

  /* --hydro3d-props (single-job path): unlike --write-props, this DOES need the
     dot cloud (read_cord/cull_coords) - the per-sphere value is a mean over
     nearby dots' true-3D values, not a sphere-atom shell average - but still
     skips the expensive triangulation itself (build_neighbour_grid/polygonize). */
  if (hydro3d_props_mode) {
    hydro_load();
    if (n_sph > 0) {
      read_cord();
      cull_coords();
      hydro3d_write_props();
      fprintf(stderr, "\nhydro3d-props: wrote %d per-sphere values (%d contributors, %d dots) to %s",
              n_sph, n_res3d, max_dots, hydro3d_props_path);
    } else {
      fprintf(stderr, "\nhydro3d-props: no spheres parsed - nothing written.\n");
    }
    return(0);
  }

  if (smooth==0)
    {
      fprintf(stderr,"\nProducing Faceted surface.");
    }

  /* read in data and purge dupliacte coordinates */

  read_cord();
  cull_coords();
  build_neighbour_grid();   /* speedup 5: index dots for the neighbour search */

  /* VMDPathFinder hydrophobicity: load spheres + atoms and pre-average so vmd_out()
     can colour each triangle by its nearest channel sphere. If the inputs are
     unusable, fall back to the normal (uncoloured) output and let the plugin's
     Tcl path take over. */
  if (hydro_mode) {
    hydro_load();
    if (hydro3d_mode) {
      if (n_res3d > 0) {
        fprintf(stderr, "\nhydro: coloured by true-3D per-triangle values (%d residues).", n_res3d);
      } else {
        hydro_mode = 0;
        fprintf(stderr, "\nhydro3d: no residues parsed - emitting uncoloured surface.");
      }
    } else if (hydro_bands_mode) {
      if (n_cl > 0 && n_bands >= 1 && n_band_edges == n_bands + 1) {
        fprintf(stderr, "\nhydro: coloured by radius in %d bands (%d centreline spheres).", n_bands, n_cl);
      } else {
        hydro_mode = 0; hydro_bands_mode = 0;
        fprintf(stderr, "\nhydro: radius bands need --bands with one more edge than --band-names and a centreline - emitting uncoloured surface.");
      }
    } else if (n_sph > 0) {
      if (hydro_values_mode) {
        fprintf(stderr, "\nhydro: coloured by pre-computed values (%d spheres).", n_sph);
      } else {
        fprintf(stderr, "\nhydro: coloured by %s scale (%d spheres, %d atoms).",
                hydro_kd ? "Kyte-Doolittle" : "Wimley-White", n_sph, n_atom);
      }
    } else {
      hydro_mode = 0;
      fprintf(stderr, "\nhydro: no spheres parsed - emitting uncoloured surface.");
    }
  }

   
  
  /* each point is chosen: if is has been incorporated into
     a triangle it is skipped over; if not it is used 
     as the start point for the next polyonisation. */

  exists=0;
  start_point=0;
  current_point=0;

  /* generate start of linked lists for lists of edges and pointers... */
  
  start=xa_malloc(sizeof(struct edge_list)); /* generate start of list */
  end=start;

  fprintf (stderr,"\nGenerating surface: This could take some time....");

  
  for (current_point=0;current_point<max_dots;current_point++)
    {

      /* check to see if point has been incorporated into the surface yet :
	 if it has not use it as the starting point to generate the surface from */

      if (check_point(current_point)==0)
	{
	  start_point=current_point;
	  polygonize();
	}
    }

  fprintf (stderr,"\nNumber of polygons: %i",tri_count);


  
  /* remove redundant triangles */

  
  cull_triangles();




 /* generate the normals for the polygons: */

  /* This step is now done in the sph-->sos conversion: The new HOLE algorithm
 broke it though. This code may be reintroduced is further releases:  */


  /*

  fprintf (stderr,"\nCalculating Normals to the triangles.\n");
  
  
  
  for (loop1=0;loop1<culled_tri_count;loop1++)
    {
      tri_normal(culled_tri[loop1][0],culled_tri[loop1][1],culled_tri[loop1][2],
		 &triangle_normals[loop1][0],
		 &triangle_normals[loop1][1],
		 &triangle_normals[loop1][2]);
    }
    
    */

  /* find incorrectly facing polygons and flip them around */
  /* set the normal of the first triangle as the default direction */

/*  
  for (loop1=0;loop1<culled_tri_count;loop1++)
    {
      
      back_check(loop1);
    }
  
  
  fflush (stderr);
 */ 
  
  /* if producing smooth surface reorder triangles as necessary*/		 
  if (smooth==1)
    {
    reorder_triangle();
    }

		 
		   
  /* write out the surface in the appropriate format */
  
  
  switch (format)
    
    {
    case 0:
      fprintf (stderr,"\nWriting VRML world file:");
      vrml_out();
      vrml_end ();
      break;
  
    case 1:
      fprintf (stderr,"\nWriting Molscript object file:");
      molscript_out();
      break;
      
    case 2:
      fprintf (stderr,"\nWriting Prepi object file:");
      prepi_out();
      break;
      
    case 3:
      fprintf (stderr,"\nWriting Povray file:");
      povray_out();
      break;
      
    case 4:
      fprintf (stderr,"\nWriting vmd file:");
      if (points_mode) vmd_points_out(); else vmd_out();
      break;
    }
  
  fprintf (stderr,"\nProgram COMPLETE\n\b\b");
  return (0);
  
}

void read_cord()

{

  int total_dots=0;
  float num1,num2,num3,num4,num5,num6,num7;
  int   nfields;
  char line_in[LINE_LEN];
  float colour=1.000;

  /* gets the coordinates from stdin */

  fprintf (stderr,"\nWaiting for  coordinates:");
  
  while (fgets(line_in,LINE_LEN,stdin)!=NULL)
    {
      /* HONOUR the field count. sscanf leaves unmatched variables UNCHANGED, so a
         short or malformed line inherits stack garbage on the first record and the
         PREVIOUS line's values on every one after. AddressSanitizer cannot see this:
         reading an uninitialised float is not an invalid access, and a carried-over
         value is perfectly valid memory.

         Only the fields that are actually consumed are required: a point needs 4
         (type + xyz) and a colour record 2, so a record whose geometry is usable
         is not discarded for want of a normal.

         num5-num7 (the per-vertex normal, stored into dots[][4..6]) are NOT
         vestigial, despite what this comment used to claim. The recomputation
         that would overwrite them is unreachable: vertex_normals() returns at
         its own line 4828, before the loop that assigns dots[][4]. So the
         normal read here flows through to the output, and reorder_triangle()
         sums the three vertex normals into tot_norm and swaps two corners when
         the dot product comes out negative - a short record inheriting the
         PREVIOUS record's normal can therefore change emitted vertex order, and
         on the first record it would inherit an indeterminate value.

         Zeroing them before the scan makes a short record read as "no normal"
         instead of "the last one's". Valid .sos input always supplies all seven
         fields, so nothing changes there. */
      num5 = num6 = num7 = 0.0f;
      nfields = sscanf(line_in,"%f%f%f%f%f%f%f",&num1,&num2,&num3,&num4,&num5,&num6,&num7);
      if (nfields < 1) continue;
      
      /* what happens next depends on the first number */
      /* if num1 =4 then the line is a point */
      /* if num1 =3 then its a change in colour */
      /* colour selections are hard coded for now ...*/

      if (num1==1.000000)
	{
	  if (nfields < 2) continue;   /* colour record needs num2 */
	  colour=num2;
	  continue;
	}


      if (num1==4.000000)
	{
	  if (nfields < 4) continue;   /* a point needs type + x,y,z; normals are recomputed */

	  if (total_dots==MAX_COORD)
	    {
	      fprintf (stderr,"\n\n\b\b\bERROR:Maximum number of co-ordinates exceeded!");
	      fprintf (stderr,"\nProgram TERMINATED\n");
	      exit (1);
	    }
	  

	  in_dots[total_dots][0]=num2;
	  in_dots[total_dots][1]=num3;
	  in_dots[total_dots][2]=num4;
	  in_dots[total_dots][3]=colour;
	  in_dots[total_dots][4]=num5;
	  in_dots[total_dots][5]=num6;
	  in_dots[total_dots][6]=num7;
	  total_dots++;
	}
    }
  
  /* max_dots is the total number of dots; GLOBAL variable used all
     over the place */
  
  in_dots_total=total_dots;
  fprintf (stderr,"\n%i coordinates read.",in_dots_total);
  return;
    
}

void polygonize()
{
  
  int initb;
  double distance,mindistance;
  int loop;
  int dummy;
  int first_loop_flag=0;
  
 

  /* find the nearest neigbour to the first dot */

  for (loop=0;loop<max_dots;loop++)
    {
      if (loop==start_point)
	continue;
      
      distance=(pow(dots[loop][0]-dots[start_point][0],2)+
		pow(dots[loop][1]-dots[start_point][1],2)+
		pow(dots[loop][2]-dots[start_point][2],2));
      if ((distance < mindistance) || (first_loop_flag==0))
	{
	  first_loop_flag=1;
	  mindistance=distance;
	  initb=loop;
	}
    }
  
  /* add the first baseline to the root node in the tree */

  root=xa_malloc(sizeof(struct base_line));
  /* polygonize() runs once per disconnected surface piece, so `root` is
     reassigned several times per job (8 on a 3119-triangle fixture) and every
     previous tree would otherwise be unreachable. The trees cannot be freed
     HERE: the edge list outlives them and its nodes point into them, so an
     early free is a use-after-free in destroy() (confirmed with ASan). Record
     each root instead and release them all at end of job, after the edge list
     has gone. */
  track_base_root(root);
  root->a=start_point;
  root->b=initb;
  root->z=initb;
  root->c=0;
  root->base1=NULL;
  root->base2=NULL;
  root->base1_active=1;
  root->base2_active=1;
  
  /* add baseline to the edge list */

  if (end==start)
    {
      /* must be the first entry in the list...*/
      end->next=NULL;
      end->x1=start_point;
      end->x2=initb;
      end->own_base=&dummy;
      end->order=2;
    }
  else
    {
      end->next=xa_malloc(sizeof(struct edge_list));
      end=end->next;
      end->next=NULL;
      end->x1=start_point;
      end->x2=initb;
      end->own_base=&dummy;
      end->order=2;
    }
  edge_hash_insert(end);   /* speedup 4: index this baseline edge */
  calc_tri_root(root);
	      
return;

}
  
long ct_depth = 0;

/* Run one triangulation from its root on a thread with a big stack (guard 1).
   Falls back to calling it directly if the thread cannot be created, so the
   program still works everywhere - just with the old 8 MB ceiling. */
static struct base_line *ct_root_arg;
static void *ct_thread_main(void *unused)
{
  (void)unused;
  calc_tri(ct_root_arg);
  return NULL;
}
void calc_tri_root(struct base_line *node)
{
  pthread_attr_t attr;
  pthread_t      tid;
  ct_depth = 0;
  ct_root_arg = node;
  if (pthread_attr_init(&attr) == 0)
    {
      if (pthread_attr_setstacksize(&attr, CT_STACK_BYTES) == 0 &&
          pthread_create(&tid, &attr, ct_thread_main, NULL) == 0)
        {
          pthread_join(tid, NULL);
          pthread_attr_destroy(&attr);
          return;
        }
      pthread_attr_destroy(&attr);
    }
  calc_tri(node);
}

static int calc_tri_body(struct base_line *node);

int calc_tri(struct base_line *node)
{
  int r;
  /* guard 2: bail out cleanly rather than run off the end of the stack */
  if (++ct_depth > CT_MAX_DEPTH)
    {
      fprintf (stderr,"\nERROR: Maximum surface recursion depth exceeded!");
      fprintf (stderr,"\nProgram TERMINATED\n");
      exit(1);
    }
  r = calc_tri_body(node);
  ct_depth--;
  return r;
}

static int calc_tri_body(struct base_line *node)

{
  
  double max_angle;
  double prev_dist;
  node->c=(max_dots+1);
  max_angle=cos( VOODOO_ANGLE ); /* defines cone of space to search for thessian neighbour:
		     value is cos, so time consuming acos need not be calculated */

  /* find the thessian neighbour */

  node->c=neighbour(node,max_angle,&prev_dist); 
 
  /* if returned values is = max_dots+1 it means no neighbour
     has been found; must be at a boundry */

  if (node->c==(max_dots+1))
    {
      return(0);
    }
    
 
  
  gen_triangle(node);
  

  /* search to see if 2 new edges have connected with
     a previous edge.*/

  destroy(node->a,node->c,&node->base1_active);
  destroy(node->b,node->c,&node->base2_active);
  
  
  /* If the edge had not connected, add it to the list 
     and generate a triangle from it */
  

  if ((node->base2_active)==1)
    {
      add_edge(node->b,node->c,&node->base2_active,2); 
    }     
  
  
  if ((node->base1_active)==1)
    {
      add_edge(node->a,node->c,&node->base1_active,1); 
      node->base1=xa_malloc(sizeof(struct base_line));
      node->base1->a=node->a;
      node->base1->b=node->c;
      node->base1->z=node->b;
      node->base1->c=0;
      node->base1->base1_active=1;
      node->base1->base2_active=1;
      node->base1->base2=NULL;
      node->base1->base1=NULL;
      calc_tri(node->base1);
    }
  
  /* Do the same for the second edge */
  /* (check is needed here due to recursive nature of function )*/
    
  if ((node->base2_active)==1)
    {
      node->base2=xa_malloc(sizeof(struct base_line));
      node->base2->a=node->c;
      node->base2->b=node->b;
      node->base2->z=node->a;
      node->base2->c=0;
      node->base2->base1_active=1;
      node->base2->base2_active=1;
      node->base2->base1=NULL;
      node->base2->base2=NULL;
      calc_tri(node->base2);
    }
  
  
  return(0);
 
}

/* find nearest neighbour */
/* Neighbour C is point which subtends greatest angle */
/* with the baseline AB */

int neighbour (struct base_line *node, double angle_limit, double *prev_dist)
{
  double pointm[3];  /* midpoint a-b */
  double veczm[3];   /* vector for z-> m */
  double magzm;
  double min_ang=1.0;
  int c=(max_dots+1);
  int loop;
  double base_dist;

  /* speedups 3 + 5. The edge-dependent quantities (pointm, veczm, magzm,
     base_dist) are hoisted out of the per-dot work, pow() is gone, and instead
     of scanning every dot we query the spatial grid for dots within 3*|base| of
     vertex a (the only dots that can ever be selected). nb_consider() applies
     the exact original test/selection, so the chosen neighbour is identical.
     Falls back to a full scan when the query would span more cells than there
     are dots (i.e. a very long baseline), which keeps the worst case at the
     original O(N) rather than wasting time walking empty cells. */

  pointm[0]=0.5*(dots[node->a][0]+dots[node->b][0]);
  pointm[1]=0.5*(dots[node->a][1]+dots[node->b][1]);
  pointm[2]=0.5*(dots[node->a][2]+dots[node->b][2]);
  veczm[0]=pointm[0]-dots[node->z][0];
  veczm[1]=pointm[1]-dots[node->z][1];
  veczm[2]=pointm[2]-dots[node->z][2];
  magzm=sqrt(veczm[0]*veczm[0]+veczm[1]*veczm[1]+veczm[2]*veczm[2]);
  base_dist=((dots[node->a][0]-dots[node->b][0])*(dots[node->a][0]-dots[node->b][0])+
	     (dots[node->a][1]-dots[node->b][1])*(dots[node->a][1]-dots[node->b][1])+
	     (dots[node->a][2]-dots[node->b][2])*(dots[node->a][2]-dots[node->b][2]));

  {
    int ax=cell_index(dots[node->a][0],NCELL);
    int ay=cell_index(dots[node->a][1],NCELL);
    int az=cell_index(dots[node->a][2],NCELL);
    /* cr is the cell radius covering the 3*|base| search sphere. Computing it
       as `(int)(sqrt(9*base_dist)/NCELL)+1` is UNDEFINED when base_dist is NaN
       (a non-finite dot): the cast yields INT_MIN, cr becomes INT_MIN+1, and
       the very next line cubes 2L*cr+1 = -4294967293 -- which overflows long
       BEFORE the `ncells > max_dots` guard below can reject it. UBSan:
         runtime error: signed integer overflow:
         -4294967293 * -4294967293 cannot be represented in type 'long int'
       Resolve cr in double first, so a non-finite or oversized radius selects
       the full scan WITHOUT ever forming an overflowing ncells -- which is the
       same branch the guard would have chosen for it. CR_CAP is far above any
       cr that could pass that guard (it fails already at cr > 29 for the
       largest MAX_COORD) and far below the cube overflowing long, so every
       finite input keeps its existing branch and its existing result. */
    #define CR_CAP 100000
    double crd = sqrt(9.0*base_dist)/NCELL;
    int cr;
    long ncells;
    if (!(crd >= 0.0) || crd > (double)CR_CAP) {   /* negated >=: NaN lands here */
      cr = CR_CAP;
      ncells = (long)max_dots + 1;                 /* forces the full scan below */
    } else {
      cr = (int)crd + 1;
      ncells = (2L*cr+1); ncells = ncells*ncells*ncells;
    }

    if (NCELL<=0.0 || ncells > (long)max_dots)
      {
	for (loop=0;loop<max_dots;loop++)
	  nb_consider(node,pointm,veczm,magzm,base_dist,angle_limit,loop,&min_ang,&c);
      }
    else
      {
	int dx,dy,dz,n,qx,qy,qz;
	for (dx=-cr;dx<=cr;dx++)
	 for (dy=-cr;dy<=cr;dy++)
	  for (dz=-cr;dz<=cr;dz++)
	    {
	      qx=ax+dx; qy=ay+dy; qz=az+dz;
	      n=ng_head[hash_cell(qx,qy,qz)];
	      while (n!=-1)
		{
		  if (ng_cx[n]==qx && ng_cy[n]==qy && ng_cz[n]==qz)
		    nb_consider(node,pointm,veczm,magzm,base_dist,angle_limit,n,&min_ang,&c);
		  n=ng_dotnext[n];
		}
	    }
      }
  }

  return (c);
}



int gen_triangle (struct base_line *node)

{

  /* writes triangle to array of generated triangles */


  if (tri_count==MAX_COORD)
    {
      fprintf (stderr,"\nERROR: Maximum number of polygons exceeded!");
      fprintf (stderr,"\nProgram TERMINATED\n");
      exit(1);
    }


  tri[tri_count][0]=node->a;
  tri[tri_count][1]=node->b;
  tri[tri_count][2]=node->c;

  /* speedup 2: mark these three dots as used so check_point() is O(1). This
     covers every triangle since all triangle vertices are written here. */
  point_used[node->a]=1;
  point_used[node->b]=1;
  point_used[node->c]=1;

  /* work out colour */

  /* if two or more of the dots have the same colour make the triangle 
that colour */
  
  if ((dots[node->a][3]==dots[node->b][3]) ||
      (dots[node->a][3]==dots[node->c][3]))
    {
    tri[tri_count][3]=(int)(dots[node->a][3]);
    tri_count++;
    return(0);
    }

  if (dots[node->b][3]==dots[node->c][3])
    {
      tri[tri_count][3]=(int)(dots[node->b][3]);
      tri_count++;
      return(0);
    }
  /* if each dot is different assign it A's colour*/
  
  tri[tri_count][3]=(int)(dots[node->a][3]);
  tri_count++;
  return(0);
			  
}

  
/* function to add edge to list of edges  */

int add_edge(int x1, int x2,int *own_base,int order)

{
  end->next=xa_malloc(sizeof(struct edge_list));
  end=end->next;
  end->x1=x1;
  end->x2=x2;
  end->order=order;
  end->own_base=own_base;
  end->next=NULL;
  edge_hash_insert(end);   /* speedup 4: index this edge for destroy() */
  return(0);
}


void vrml_out()
{
  
  /* writes out the start of the VRML file */
  int loop=0;

  /* VRML header */
  /* required for all VRML files */

  printf ("#VRML V1.0 ascii");

  /* Add some shapehints to help the renders render the shapes */

  printf ("\nSeparator {");
  printf ("\n Separator{");
  printf ("\n ShapeHints \n {");
  printf ("\n vertexOrdering COUNTERCLOCKWISE ");
  printf ("\n shapeType UNKNOWN_SHAPE_TYPE");
 
  /* turn on or off the smooth or faceted surface */

  if (smooth==0)
    printf ("\n creaseAngle 0");
  else
    printf ("\n creaseAngle 2");
  
  
  printf ("\n faceType CONVEX\n }\n");
  printf ("\nCoordinate3 { \n   point [\n");
  
  /* write out all the raw Coordinates  (VRML PointSet field)*/

  for (loop=0;loop<max_dots;loop++)
    {
      /* each line has to end with a , except the last one */
      if (loop!=0)
	{
	  printf(",\n");
	}
      
      printf ("%f   %f   %f",dots[loop][0],dots[loop][1],dots[loop][2]);
    }
  printf("\n");
  printf("] \n }\n");
  /*  printf("PointSet {\n");
  printf("startIndex 0 \n numPoints -1 \n } \n ");*/
  
  return;
}

void vrml_end()
{
  
  /* writes out the generated polygons: All triangles of the same
     colour are written out together. */


  int loop_cntr;
  int first_polygon=0;
  
  /* print out red spheres */
  /* write out the material description for a shiny red */

  printf ("\n Separator { \n");
  printf ("Material { \n");
  printf ("diffuseColor 0.8 0.0 0.0\n ");
  printf ("specularColor 1.0 1.0 1.0\n");
  printf ("ambientColor 0.4 0.0 0.0 \n");
  printf ("shininess 0.5");
  printf ("}\n");
  
  /* writes out the connectivites of the red triangles */
  /* ( VRML IndexedFaceSet field) */

  printf ("\nIndexedFaceSet { \n");
  printf ("coordIndex [ \n");
  
  for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
    {
      if (culled_tri[loop_cntr][3]==3)
	{
	  if (first_polygon!=0)
	    {
	      printf(",\n");
	    }
	  printf ("%i, %i, %i, -1",culled_tri[loop_cntr][0],culled_tri[loop_cntr][1],
		  culled_tri[loop_cntr][2]);
	  first_polygon=1;
	}
    }
  printf ("\n]\n}\n}");

  /* now print out the green spheres */

 printf ("\n Separator { \n");
  printf ("Material { \n");
  printf ("diffuseColor 0.0 0.8 0.0\n ");
  printf ("ambientColor 0.0 0.4 0.0\n");
  printf ("specularColor 1.0 1.0 1.0 \n");
  printf ("shininess 0.5");
  printf ("}\n");

  printf ("\nIndexedFaceSet { \n");
  printf ("coordIndex [ \n");
  
  first_polygon=0;
  for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
    {
      if (culled_tri[loop_cntr][3]==7)
	{
	  if (first_polygon!=0)
	    printf(",\n");
	  
	  first_polygon=1;
	  printf ("%i, %i, %i, -1",culled_tri[loop_cntr][0],culled_tri[loop_cntr][1],
		  culled_tri[loop_cntr][2]);
	}
    }
  printf ("\n]\n}\n}");

  /* ...and finally print out blue spheres */

printf ("\n Separator { \n");
  printf ("Material { \n");
  printf ("diffuseColor 0.0 0.0 0.8\n ");
  printf ("ambientColor 0.0 0.0 0.4\n ");
  printf ("specularColor 1.0 1.0 1.0 \n");
  printf ("shininess 0.5 \n");
  printf ("}\n");

  printf ("\nIndexedFaceSet { \n");
  printf ("coordIndex [ \n");
  
  first_polygon=0;
  for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
    {
      if (culled_tri[loop_cntr][3]==2)
	{
	  if (first_polygon!=0)
	    printf(",\n");
	  
	  printf ("%i, %i, %i, -1",culled_tri[loop_cntr][0],culled_tri[loop_cntr][1],
		  culled_tri[loop_cntr][2]);
	  first_polygon=1;
	}
    }
  printf ("\n]\n}\n}");
  printf ("\n}\n}");
  return;
}



void destroy (int edge1,int edge2, int *active)

{
  struct edge_list *list_ptr;

  /* speedup 4: only the edges sharing this endpoint pair can match, so walk
     that hash bucket (in creation order) instead of the whole list. The match
     test and the actions on it are byte-for-byte the original. */
  list_ptr = eh_head[hash_edge(edge1,edge2)];

  /* go thorugh the list the see if edges have already been
     generated */


  while (list_ptr!=NULL)
    {



      if (((edge1==list_ptr->x1) && (edge2==list_ptr->x2)) ||
	  ((edge1==list_ptr->x2) && (edge2==list_ptr->x1)))
	{

	  /* if edge is the same both connecting edges must be
	     flagged as being connected: the active flag in
	     the edge tree is voided to signal triangulation
	     must not continue */

	  *active=0;
	  *(list_ptr->own_base)=0;
	  list_ptr->order=1;
	  return;
	}

      list_ptr=list_ptr->hnext;

    }
  return;
}


int check_point (int current_point)
{
  /* speedup 2: O(1). point_used[p] is set in gen_triangle() whenever p is
     written as a triangle vertex, so this is exactly equivalent to the
     original "does current_point appear in any triangle?" scan. */
  return point_used[current_point];
}
	    

void molscript_out ()
{
  
  int loop_cntr=0;
  int tri=0;
  double red,green,blue;

  
  /* Print total number of triangles */
  if (smooth==0 && dump==0 )
    {
      fprintf (stdout,"TC %i\n",(culled_tri_count*3));
    }
 
  if (smooth==1 && dump==0)
    {
      /* vertex_normals(); */
      fprintf (stdout,"TNC %i\n",(culled_tri_count*3));
    }
  if (dump==1 && smooth==0)
    {
      fprintf (stdout,"T %i \n",(culled_tri_count*3));
    }
  if (dump==1 && smooth==1 )
    {
      fprintf (stdout,"TN %i \n",(culled_tri_count*3));
    }


  /* output the coordinates for each triangle */

 for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
   {
   
     for (tri=0;tri<3;tri++)
       {
	 /* print out the coordinates */
	 
	 
	 fprintf (stdout,"%f %f %f ",
		  dots[culled_tri[loop_cntr][tri]][0],
		  dots[culled_tri[loop_cntr][tri]][1],
		  dots[culled_tri[loop_cntr][tri]][2]);
	 
	 /*do we need normals? */
	 
	 if (smooth==1)
	   {
	     fprintf (stdout,"%f %f %f ",
		      dots[culled_tri[loop_cntr][tri]][4],
		      dots[culled_tri[loop_cntr][tri]][5],
		      dots[culled_tri[loop_cntr][tri]][6]);
	   }
	 
	 /*Do we need colours? */
	 
	 if (dump==0)
	   {
	 colour_conv  (dots[culled_tri[loop_cntr][tri]][3],&red,&green,&blue);
	 fprintf (stdout, "%f %f %f ",
		  red,green,blue);
	   }
	 
     
     /* Go onto the next line... */
     fprintf (stdout, " \n");
       }
   }

 fprintf (stdout,"Q\n");
 return;
 
 
}
	
 	

void colour_conv(int col_index,double *red_ptr, double *green_ptr, double *blue_ptr)  

{
  
  switch (col_index)
    {
    case 2:
     /* blue dot */
      *red_ptr=0.0;
      *green_ptr=0.0;
      *blue_ptr=1.0;
      break;


    case 3:
      /* red dot */
      *red_ptr=1.0;
      *green_ptr=0.0;
      *blue_ptr=0.0;
      break;


    case 7:
      /* green dot */
      *red_ptr=0.0;
      *green_ptr=1.0;
      *blue_ptr=0.0;
      break;
      
    default:
      /* this should never happen! */
      *red_ptr=0.5;
      *green_ptr=0.5;
      *blue_ptr=0.5;
    }
  return;
}

void cull_triangles () 
     
{ 
  int loop_cntr=0; 
  int cull_end_count=0,cull_big_count=0; 
  int dlistA, dlistB, dlistC;
  double lenAB, lenAC, lenCB, max_v_sq;
  
   /* the maximum length squared */  
   max_v_sq = max_vertex_length*max_vertex_length;
  
   /*   Check To See If The Triangles Have Zero Area: Cull Them If  So */ 
   
   for (loop_cntr=0;loop_cntr<tri_count;loop_cntr++) 
     { 
   
       /*      Compare A And B Coordinate */
       /* CHECK NOT NEEDED: THIS BLOCK INTENTIONALLY COMMENTED OUT! */
       /* We now cull duplicate coordinates instead: The hole surface can produce */
       /* two points with the same coordiantes. This breaks the algorithm in intersting */
       /* ways.... */
       /*if (  
	 
	   vec_compare(tri[loop_cntr][0],tri[loop_cntr][1]) ||  
 	   vec_compare(tri[loop_cntr][0],tri[loop_cntr][2]) ||  
 	   vec_compare(tri[loop_cntr][2],tri[loop_cntr][1]))  
	 
	{  
 	   cull_count++; 
           continue; 
 	} */
	
	/* check the length**2 of AB AC CB */
        /* find A B C indices */
        dlistA = tri[loop_cntr][0];
	dlistB = tri[loop_cntr][1];
	dlistC = tri[loop_cntr][2];
        /* length**2 */
	lenAB = (dots[dlistB][0]-dots[dlistA][0])*(dots[dlistB][0]-dots[dlistA][0])+
 	        (dots[dlistB][1]-dots[dlistA][1])*(dots[dlistB][1]-dots[dlistA][1])+
		(dots[dlistB][2]-dots[dlistA][2])*(dots[dlistB][2]-dots[dlistA][2]);
	
	lenAC = (dots[dlistC][0]-dots[dlistA][0])*(dots[dlistC][0]-dots[dlistA][0])+
 	        (dots[dlistC][1]-dots[dlistA][1])*(dots[dlistC][1]-dots[dlistA][1])+
		(dots[dlistC][2]-dots[dlistA][2])*(dots[dlistC][2]-dots[dlistA][2]);
	
	lenCB = (dots[dlistB][0]-dots[dlistC][0])*(dots[dlistB][0]-dots[dlistC][0])+
 	        (dots[dlistB][1]-dots[dlistC][1])*(dots[dlistB][1]-dots[dlistC][1])+
		(dots[dlistB][2]-dots[dlistC][2])*(dots[dlistB][2]-dots[dlistC][2]);
		
	/* 11-2000 new use for this loop */
	/* check for end records - colour -1 */	 			
        /* vble dots[MAX_COORD][7]; holds the  */
	/*      xcoor:ycoor:zcoor:colour:nx:ny:nz records of the points */     
        /* i.e. color is in dots[blah][3] where blah is a list number */
        /* list numbers for each triangle are */
        /* tri[loop_cntr][0] and tri[loop_cntr][1] and tri[loop_cntr][2]*/
	if ( dots[tri[loop_cntr][0]][3]<0 ||
	     dots[tri[loop_cntr][1]][3]<0 ||
	     dots[tri[loop_cntr][2]][3]<0 		
	   ) 
	  { /* triangle rejected */
 	   cull_end_count++; 
           continue; 
	  }
	else 
	  {
	  if ( (lenAB > max_v_sq) || (lenAC > max_v_sq) || (lenCB > max_v_sq) )
	    { /* one of the triangle vertices over 5 angs */
	    cull_big_count++;
	    continue; 
	    }
	  else
	    {  /* triangle accepted */		
            culled_tri[culled_tri_count][0]=tri[loop_cntr][0];
       	    culled_tri[culled_tri_count][1]=tri[loop_cntr][1];
       	    culled_tri[culled_tri_count][2]=tri[loop_cntr][2];  
       	    culled_tri[culled_tri_count][3]=tri[loop_cntr][3];
       	    culled_tri[culled_tri_count][4]=0;
       	    culled_tri_count++;
            }
	  }
   } 
   fprintf(stderr,"\n%i End triangles culled.",cull_end_count); 
   fprintf(stderr,"\n%i Triangles culled as a vertex greater than %f angs",cull_big_count,max_vertex_length); 
   fprintf(stderr,"\n%i polgons remaining.",culled_tri_count);
   return; 
} 

int vec_compare (int vec_a,int vec_b)
{
  
  
  if (
      ((fabs(in_dots[vec_a][0]- dots[vec_b][0]))<(1.0E-3)) &&
      ((fabs(in_dots[vec_a][1]- dots[vec_b][1]))<(1.0E-3)) &&
      ((fabs(in_dots[vec_a][2]- dots[vec_b][2]))<(1.0E-3))
      )

    {
      return(1);
    }
  
  
  return(0);
}

void cull_coords()
{
  /* speedup 1: spatial-hash duplicate removal. Output is identical to the
     original O(N^2) version below (preserved in a comment for reference): the
     same dots are kept, in the same input order, using the same vec_compare()
     box test -- only the set of candidates compared against is pruned to the
     27 cells around each point instead of every accepted dot. */
  int in_cntr;
  int cull_counter=0;
  int b, n;
  int cx, cy, cz, dx, dy, dz;
  int is_dup;

  fprintf (stderr,"\nCulling duplicate coordinates.");

  for (b=0;b<HASH_BUCKETS;b++) hb_head[b] = -1;
  hn_count = 0;

  for (in_cntr=0;in_cntr<in_dots_total;in_cntr++)
    {
      cx = cell_index(in_dots[in_cntr][0],CELL_TOL);
      cy = cell_index(in_dots[in_cntr][1],CELL_TOL);
      cz = cell_index(in_dots[in_cntr][2],CELL_TOL);

      is_dup = 0;
      /* scan the 3x3x3 neighbourhood of cells (covers any accepted dot within
         CELL_TOL on every axis), confirming with the original vec_compare. */
      for (dx=-1; dx<=1 && !is_dup; dx++)
       for (dy=-1; dy<=1 && !is_dup; dy++)
        for (dz=-1; dz<=1 && !is_dup; dz++)
          {
            n = hb_head[hash_cell(cx+dx, cy+dy, cz+dz)];
            while (n != -1)
              {
                if (hn_cx[n]==cx+dx && hn_cy[n]==cy+dy && hn_cz[n]==cz+dz)
                  {
                    if (vec_compare(in_cntr, hn_dot[n])==1) { is_dup = 1; break; }
                  }
                n = hn_next[n];
              }
          }

      if (!is_dup)
	{
	  dots[max_dots][0]=in_dots[in_cntr][0];
	  dots[max_dots][1]=in_dots[in_cntr][1];
	  dots[max_dots][2]=in_dots[in_cntr][2];
	  dots[max_dots][3]=in_dots[in_cntr][3];
	  dots[max_dots][4]=in_dots[in_cntr][4];
	  dots[max_dots][5]=in_dots[in_cntr][5];
	  dots[max_dots][6]=in_dots[in_cntr][6];

	  /* register the accepted dot in its own cell */
	  b = hash_cell(cx, cy, cz);
	  hn_cx[hn_count]=cx; hn_cy[hn_count]=cy; hn_cz[hn_count]=cz;
	  hn_dot[hn_count]=max_dots;
	  hn_next[hn_count]=hb_head[b];
	  hb_head[b]=hn_count;
	  hn_count++;

	  max_dots++;
	}
      else
	{
	  cull_counter++;
	}
    }

  fprintf (stderr,"\n%i coordinates removed.",cull_counter);
  fprintf (stderr, "\n%i coordinates remaining.",max_dots);

  return;

}

int tri_normal (int a,int b,int c,double *x_ptr, double *y_ptr, double *z_ptr)
{
  
  
  

  double AB[3];
  double AC[3];

  double normal[3];
  double crossp[3];
  double  mag;
  double vector;


  return (0);

  /* generate two vectors, AB and AC */

  AB[0]=dots[b][0]-dots[a][0];
  AB[1]=dots[b][1]-dots[a][1];
  AB[2]=dots[b][2]-dots[a][2];
  
  AC[0]=dots[c][0]-dots[a][0];
  AC[1]=dots[c][1]-dots[a][1];
  AC[2]=dots[c][2]-dots[a][2];

  /* normal is the crosss  product of the two vectors */
  
  crossp[0]=(AB[1]*AC[2])-(AB[2]*AC[1]);
  crossp[1]=(AB[2]*AC[0])-(AB[0]*AC[2]);
  crossp[2]=(AB[0]*AC[1])-(AB[1]*AC[0]);

  /* convert normal to a unit vector */

  mag=sqrt (pow(crossp[0],2)+pow(crossp[1],2)+pow(crossp[2],2));
  normal[0]=crossp[0]/mag;
  normal[1]=crossp[1]/mag;
  normal[2]=crossp[2]/mag;

  
  *x_ptr=(float)normal[0];
  *y_ptr=(float)normal[1];
  *z_ptr=(float)normal[2];
  
  return(0);
}

/* prepi out: Write prepi surface format */

void prepi_out ()
{

  int loop_cntr;
  
  if (smooth==1)
    {
      fprintf (stderr,"\b\b\nWARNING: Smooth surface option not available in Prepi format!\n");
      fprintf (stderr,"The colour records may be ignored in some versions of Prepi. \n");
    }

  /* vertex normals needed */
  vertex_normals();
  
  fprintf (stdout,"saisurpol\n");
   
  for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
   {
     
     
     /* Print out the prepi surface: V1 x y z V2 x y z V3 x y z V1 Nx Ny Nz etc */     
     
     fprintf (stdout,"%6.1f%6.1f%6.1f",
	      dots[culled_tri[loop_cntr][0]][0],
	      dots[culled_tri[loop_cntr][0]][1],
	      dots[culled_tri[loop_cntr][0]][2]);
     
     fprintf (stdout,"%6.1f%6.1f%6.1f",
	      dots[culled_tri[loop_cntr][1]][0],
	      dots[culled_tri[loop_cntr][1]][1],
	      dots[culled_tri[loop_cntr][1]][2]);

     fprintf (stdout,"%6.1f%6.1f%6.1f",
	      dots[culled_tri[loop_cntr][2]][0],
	      dots[culled_tri[loop_cntr][2]][1],
	      dots[culled_tri[loop_cntr][2]][2]);

     fprintf (stdout,"%6.1f%6.1f%6.1f",
	      dots[culled_tri[loop_cntr][0]][4],
	      dots[culled_tri[loop_cntr][0]][5],
	      dots[culled_tri[loop_cntr][0]][6]);

     fprintf (stdout,"%6.1f%6.1f%6.1f",
	      dots[culled_tri[loop_cntr][1]][4],
	      dots[culled_tri[loop_cntr][1]][5],
	      dots[culled_tri[loop_cntr][1]][6]);

     fprintf (stdout,"%6.1f%6.1f%6.1f\n",
	      dots[culled_tri[loop_cntr][2]][4],
	      dots[culled_tri[loop_cntr][2]][5],
	      dots[culled_tri[loop_cntr][2]][6]);
     
     
   }

}
  
int vertex_normals()

{
  
  
  

  
  double nx=0.0;
  double ny=0.0;
  double nz=0.0;
  int normal_count=0;
  int loop_cntr;
  int loop_cntr2;
  double dotp;
  double vector=0.0;
  
  return(0);

  fprintf (stderr,"\ncalculating Normals at the vertices.\n");


  /* calculate average normal at each vertex */

  /* check each point in turn: average the triangle normals of every triangle it forms
     a vertex to. */
  
  for (loop_cntr=0;loop_cntr<max_dots;loop_cntr++)
    {
      for (loop_cntr2=0;loop_cntr2<culled_tri_count;loop_cntr2++)
	{

	  if ((culled_tri[loop_cntr2][0]==loop_cntr) ||
	      (culled_tri[loop_cntr2][1]==loop_cntr) ||
	      (culled_tri[loop_cntr2][2]==loop_cntr))

	    {
	     nx+=triangle_normals[loop_cntr2][0];
	     ny+=triangle_normals[loop_cntr2][1];
	     nz+=triangle_normals[loop_cntr2][2];
	     normal_count++;
	    }
	}

      

      dots[loop_cntr][4]=(nx/normal_count);
      dots[loop_cntr][5]=(ny/normal_count);
      dots[loop_cntr][6]=(nz/normal_count);
      
      nx=0;
      ny=0;
      nz=0;
      normal_count=0;
    }
  

  return(0);
}

int back_check (int a)
{
  



  int loop1,loop2;
  int tri_neigh[100]; /* CULLED_TRI index */
  int hit=0;
  int cntr1;
  int ncount=0;
  double dotp;
  int old;

  return(0);

  if (culled_tri[a][5]==1)
    return(0);
  

  /* find adjoining traingles */
  

  /* go through all triangles and find number of shared vertices: if the traingles have
     two shared vertices then they are neighbours */

  for (loop1=0;loop1<culled_tri_count;loop1++)
    {

      if (loop1==a)
	continue;

      for (loop2=0;loop2<3;loop2++)
	{
	  if ((culled_tri[loop1][loop2]==culled_tri[a][0]) || 
	      (culled_tri[loop1][loop2]==culled_tri[a][1]) || 
	      (culled_tri[loop1][loop2]==culled_tri[a][2]))
	    {
	      hit++;
	    }
	}
      
      if (hit==2)
	{
	  if (ncount<3)
	    {
	      tri_neigh[ncount]=loop1;
	      ncount++;
	    }
	}

      hit=0;
    }
  


  /* compare the normals of the neighbouring traingles to A: if the dotp of the 
     triangles is < 0 then the normals are running anti parallel to one another and the
     triangle must be flipped: */
  
  for (loop1=0;loop1<ncount;loop1++)
    {
      dotp=((triangle_normals[a][0]*triangle_normals[tri_neigh[loop1]][0])+
	    (triangle_normals[a][1]*triangle_normals[tri_neigh[loop1]][1])+
	    (triangle_normals[a][2]*triangle_normals[tri_neigh[loop1]][2]));
      
      if (dotp<0)
	{
	
	  /* reverse the normal */
	  if ( culled_tri[tri_neigh[loop1]][4]==0)
	    {
	      old=culled_tri[tri_neigh[loop1]][0];
	      culled_tri[tri_neigh[loop1]][0]=culled_tri[tri_neigh[loop1]][2];
	      culled_tri[tri_neigh[loop1]][2]=old;
	      
	      tri_normal(culled_tri[tri_neigh[loop1]][0],
			 culled_tri[tri_neigh[loop1]][1],
			 culled_tri[tri_neigh[loop1]][2],
			 &triangle_normals[tri_neigh[loop1]][0],
			 &triangle_normals[tri_neigh[loop1]][1],
			 &triangle_normals[tri_neigh[loop1]][2]);
	    }
	}
    }
  
  
  culled_tri[a][5]=1;
  
   for (loop1=0;loop1<ncount;loop1++)
    {
      back_check ( tri_neigh[loop1] );
    }
  
  

  return(0);


}

void povray_out()
{

/* I've primarily written this to interface with the Prepi povray output: Prepi does not output the HOLE surface,
so this function will output some povray commands that you can append to the Prepi file:
*/

  int loop_cntr;

  /* basic texture definitions */
  
  fprintf (stdout,"\n// Povray Mesh file of hole surface: append where neccesary!");
  fprintf (stdout,"\n#declare holefinish = finish {ambient 0.1 diffuse 0.9 phong 0.45 phong_size 10}");
  fprintf (stdout,"\n#declare holetex1 = texture {pigment {color rgbt <1.000,0.000,0.000,0.000>} finish {holefinish}} /* RED           */");
  fprintf (stdout,"\n#declare holetex2 = texture {pigment {color rgbt <0.000,1.000,0.000,0.000>} finish {holefinish}} /* GREEN         */");
  fprintf (stdout,"\n#declare holetex3 = texture {pigment {color rgbt <0.000,0.000,1.000,0.000>} finish {holefinish}} /* BLUE          */");
  fprintf (stdout,"\nmesh {\n");
  

  switch (smooth)
    {
    case 0:
      
      for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
	{
	  if (culled_tri[loop_cntr][3]==3)
	    {
	      fprintf (stdout,"\ntriangle { < %f, %f, %f>, < %f, %f,%f>, < %f, %f, %f> texture{holetex1} }",
		       dots[culled_tri[loop_cntr][0]][0],
		       dots[culled_tri[loop_cntr][0]][1],
		       dots[culled_tri[loop_cntr][0]][2],
		       dots[culled_tri[loop_cntr][1]][0],
		       dots[culled_tri[loop_cntr][1]][1],
		       dots[culled_tri[loop_cntr][1]][2],
		       dots[culled_tri[loop_cntr][2]][0],
		       dots[culled_tri[loop_cntr][2]][1],
		       dots[culled_tri[loop_cntr][2]][2]);
	      continue;
	    }
	  
	  if (culled_tri[loop_cntr][3]==7)
	    {
	      fprintf (stdout,"\ntriangle { < %f, %f, %f>, < %f, %f,%f>, < %f, %f, %f> texture{holetex2} }",
		       dots[culled_tri[loop_cntr][0]][0],
		       dots[culled_tri[loop_cntr][0]][1],
		       dots[culled_tri[loop_cntr][0]][2],
		       dots[culled_tri[loop_cntr][1]][0],
		       dots[culled_tri[loop_cntr][1]][1],
		       dots[culled_tri[loop_cntr][1]][2],
		       dots[culled_tri[loop_cntr][2]][0],
		       dots[culled_tri[loop_cntr][2]][1],
		       dots[culled_tri[loop_cntr][2]][2]);
	      continue;
	    }
	  
	  fprintf (stdout,"\ntriangle { < %f, %f, %f>, < %f, %f,%f>, < %f, %f, %f> texture{holetex3} }",
		   dots[culled_tri[loop_cntr][0]][0],
		   dots[culled_tri[loop_cntr][0]][1],
		   dots[culled_tri[loop_cntr][0]][2],
		   dots[culled_tri[loop_cntr][1]][0],
		   dots[culled_tri[loop_cntr][1]][1],
		   dots[culled_tri[loop_cntr][1]][2],
		   dots[culled_tri[loop_cntr][2]][0],
		   dots[culled_tri[loop_cntr][2]][1],
		   dots[culled_tri[loop_cntr][2]][2]);
	}
      break;
      
    case 1:
      vertex_normals();
      /* file format is: smooth_triangle {<corner1>,<normal1>,<corner2>,<normal2>,<corner3>,<normal3> {texture}} */
      
      for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
	{
	  if (culled_tri[loop_cntr][3]==3)
	    {
	      fprintf (stdout,"\nsmooth_triangle { < %f, %f, %f>, < %f, %f,%f>,",
		       dots[culled_tri[loop_cntr][0]][0],
		       dots[culled_tri[loop_cntr][0]][1],
		       dots[culled_tri[loop_cntr][0]][2],
		       dots[culled_tri[loop_cntr][0]][4],
		       dots[culled_tri[loop_cntr][0]][5],
		       dots[culled_tri[loop_cntr][0]][6]);

	      fprintf (stdout,"\n < %f, %f, %f>, < %f, %f,%f>,",
		       dots[culled_tri[loop_cntr][1]][0],
		       dots[culled_tri[loop_cntr][1]][1],
		       dots[culled_tri[loop_cntr][1]][2],
		       dots[culled_tri[loop_cntr][1]][4],
		       dots[culled_tri[loop_cntr][1]][5],
		       dots[culled_tri[loop_cntr][1]][6]);
	      
	      fprintf (stdout,"\n < %f, %f, %f>, < %f, %f,%f> texture{holetex1} } ",
		       dots[culled_tri[loop_cntr][2]][0],
		       dots[culled_tri[loop_cntr][2]][1],
		       dots[culled_tri[loop_cntr][2]][2],
		       dots[culled_tri[loop_cntr][2]][4],
		       dots[culled_tri[loop_cntr][2]][5],
		       dots[culled_tri[loop_cntr][2]][6]);
	      
	      continue;
	    }
	  
	  if (culled_tri[loop_cntr][3]==7)
	    {
	      fprintf (stdout,"\nsmooth_triangle { < %f, %f, %f>, < %f, %f,%f>,",
		       dots[culled_tri[loop_cntr][0]][0],
		       dots[culled_tri[loop_cntr][0]][1],
		       dots[culled_tri[loop_cntr][0]][2],
		       dots[culled_tri[loop_cntr][0]][4],
		       dots[culled_tri[loop_cntr][0]][5],
		       dots[culled_tri[loop_cntr][0]][6]);

	      fprintf (stdout,"\n < %f, %f, %f>, < %f, %f,%f>,",
		       dots[culled_tri[loop_cntr][1]][0],
		       dots[culled_tri[loop_cntr][1]][1],
		       dots[culled_tri[loop_cntr][1]][2],
		       dots[culled_tri[loop_cntr][1]][4],
		       dots[culled_tri[loop_cntr][1]][5],
		       dots[culled_tri[loop_cntr][1]][6]);
	      
	      fprintf (stdout,"\n < %f, %f, %f>, < %f, %f,%f> texture{holetex2} } ",
		       dots[culled_tri[loop_cntr][2]][0],
		       dots[culled_tri[loop_cntr][2]][1],
		       dots[culled_tri[loop_cntr][2]][2],
		       dots[culled_tri[loop_cntr][2]][4],
		       dots[culled_tri[loop_cntr][2]][5],
		       dots[culled_tri[loop_cntr][2]][6]);   

   
	      continue;
	    }
	  
	   fprintf (stdout,"\nsmooth_triangle { < %f, %f, %f>, < %f, %f,%f>,",
		    dots[culled_tri[loop_cntr][0]][0],
		    dots[culled_tri[loop_cntr][0]][1],
		    dots[culled_tri[loop_cntr][0]][2],
		    dots[culled_tri[loop_cntr][0]][4],
		    dots[culled_tri[loop_cntr][0]][5],
		    dots[culled_tri[loop_cntr][0]][6]);
	   
	   fprintf (stdout,"\n < %f, %f, %f>, < %f, %f,%f>,",
		    dots[culled_tri[loop_cntr][1]][0],
		    dots[culled_tri[loop_cntr][1]][1],
		    dots[culled_tri[loop_cntr][1]][2],
		    dots[culled_tri[loop_cntr][1]][4],
		    dots[culled_tri[loop_cntr][1]][5],
		    dots[culled_tri[loop_cntr][1]][6]);
	   
	   fprintf (stdout,"\n < %f, %f, %f>, < %f, %f,%f> texture{holetex3} } ",
		    dots[culled_tri[loop_cntr][2]][0],
		    dots[culled_tri[loop_cntr][2]][1],
		    dots[culled_tri[loop_cntr][2]][2],
		    dots[culled_tri[loop_cntr][2]][4],
		    dots[culled_tri[loop_cntr][2]][5],
		    dots[culled_tri[loop_cntr][2]][6]);

	   
	}
      break;
    }
  
  fprintf (stdout,"\n}");
  
  return;
}

/* OSS 1/11/00 vmd_out - based on GC's molscript_out */
void vmd_out ()
{
  
  int loop_cntr=0;
  int current_col=-1000;
  const char *hydro_cur = "";    /* last hydrophobicity colour emitted */

  /* Print header */
  fprintf (stdout, "draw delete all\n");


  /* output the coordinates for each triangle */

 for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
   {

     if (hydro_mode)
       {
	 /* colour by the nearest channel sphere to the triangle centroid */
	 int a = culled_tri[loop_cntr][0];
	 int b = culled_tri[loop_cntr][1];
	 int c = culled_tri[loop_cntr][2];
	 double cx = (r3(dots[a][0])+r3(dots[b][0])+r3(dots[c][0]))/3.0;
	 double cy = (r3(dots[a][1])+r3(dots[b][1])+r3(dots[c][1]))/3.0;
	 double cz = (r3(dots[a][2])+r3(dots[b][2])+r3(dots[c][2]))/3.0;
	 double h = hydro3d_mode ? hydro_at_point_3d(cx,cy,cz) : hydro_at_point(cx,cy,cz);
	 const char *col = surface_color_name(h);
	 if (strcmp(col, hydro_cur) != 0)
	   { fprintf (stdout, "draw color %s\n", col); hydro_cur = col; }
       }
     else
       {
     /* is this a different colour? */
     if (culled_tri[loop_cntr][3] != current_col)
        {
	   current_col = culled_tri[loop_cntr][3];
	   switch (current_col)
           {
	       case(2): { fprintf (stdout,"draw color blue\n");
                          break;
		        }
	       case(3): { fprintf (stdout,"draw color red\n");
                          break;
		        }
               case(7): { fprintf (stdout,"draw color green\n");
                          break;
		        }
	       default: { fprintf (stdout,"draw color yellow\n");
                          break;
		        }
            }
	}
       }

     /* are we going for a normal or smoothed surface? */ 
     switch (smooth)
       {  case(0): { fprintf (stdout,"draw triangle ");
                   break;
		   }
          case(1): { fprintf (stdout,"draw trinorm ");
                   break;
		   }
       }		 
  

	
     /* vertex a */
     fprintf (stdout," { %8.3f %8.3f %8.3f } ",      
	       dots[culled_tri[loop_cntr][0]][0],
	       dots[culled_tri[loop_cntr][0]][1],
	       dots[culled_tri[loop_cntr][0]][2]);
     /* vertex b */
     fprintf (stdout," { %8.3f %8.3f %8.3f } ",      
	       dots[culled_tri[loop_cntr][1]][0],
	       dots[culled_tri[loop_cntr][1]][1],
	       dots[culled_tri[loop_cntr][1]][2]);
     /* vertex c */
     fprintf (stdout," { %8.3f %8.3f %8.3f } ",      
	       dots[culled_tri[loop_cntr][2]][0],
	       dots[culled_tri[loop_cntr][2]][1],
	       dots[culled_tri[loop_cntr][2]][2]);	
	       
     	 
     /*do we need normals? */
	 
     if (smooth==1)
       {
         /* normal a */
         fprintf (stdout," { %8.5f %8.5f %8.5f } ",      
	           dots[culled_tri[loop_cntr][0]][4],
	           dots[culled_tri[loop_cntr][0]][5],
	           dots[culled_tri[loop_cntr][0]][6]);
         /* normal b */
         fprintf (stdout," { %8.5f %8.5f %8.5f } ",      
	           dots[culled_tri[loop_cntr][1]][4],
	           dots[culled_tri[loop_cntr][1]][5],
	           dots[culled_tri[loop_cntr][1]][6]);
         /* normal c */
         fprintf (stdout," { %8.5f %8.5f %8.5f } ",      
	           dots[culled_tri[loop_cntr][2]][4],
	           dots[culled_tri[loop_cntr][2]][5],
	           dots[culled_tri[loop_cntr][2]][6]);
        }
	 
     /* Go onto the next line... */
     fprintf (stdout, " \n");
      
   }

 return;
 
}

/* VMDPathFinder --points output: write each surface vertex once as a "draw point",
   preserving the per-triangle colour so hole_def (radius) colouring carries
   over. Reproduces the plugin's dots_from_trinorm: vertices are emitted in the
   order first encountered while scanning triangles, each carrying the colour
   active for the triangle that introduced it. */
void vmd_points_out ()
{
  int i, v;
  const char *written = "";
  fprintf (stdout, "draw delete all\n");
  for (i = 0; i < culled_tri_count; i++)
    {
      const char *col;
      switch (culled_tri[i][3])
        {
          case 2:  col = "blue";  break;
          case 3:  col = "red";   break;
          case 7:  col = "green"; break;
          default: col = "yellow";break;
        }
      for (v = 0; v < 3; v++)
        {
          int di = culled_tri[i][v];
          if (di < 0 || pt_emitted[di]) continue;
          pt_emitted[di] = 1;
          if (strcmp (col, written) != 0)
            { fprintf (stdout, "draw color %s\n", col); written = col; }
          fprintf (stdout, "draw point { %8.3f %8.3f %8.3f }\n",
                   dots[di][0], dots[di][1], dots[di][2]);
        }
    }
}

/* OSS 5/11/00 reorder_triangle */
void reorder_triangle()
{   
  /* 4/11/00 found problem with smoothed surfaces 
     order of outputing triangle critical.  
     From vmd documentation 
     http://www.ks.uiuc.edu/Research/vmd/current/ug/node157.html
      "One caution about defining the vertices and normals: they must be given
       in counter-clockwise order or the shading will be wrong."  
   
      So what we are going to do is 
      (a) add all three normal vectors to get one vector tot_norm
      (b) for triangle
                            A---C
			     \ /
                              B
	find cross product ABcrossAC
      (c) find the dot product = ABcrossAC.tot_norm
      (d) depending on the sign of this dot product
      
          reverse the order of outputing triangles using vbles
          swapping first and second list number
  */
  int iswap;
  double AB[3];
  double AC[3];
  double ABcrossAC[3];
  double tot_norm[3];
  double ABcrossAC_dot_totnom;
  int loop_cntr=0;   
  

 for (loop_cntr=0;loop_cntr<culled_tri_count;loop_cntr++)
   {  /* go thru triangle list */



     
     if (smooth==1)
       { /* only do if producing smooth surface */ 
	       
       /* must check ordering */
       /* (a) add all three normal vectors to get one vector tot_norm */
       tot_norm[0] = dots[culled_tri[loop_cntr][0]][4] +
                     dots[culled_tri[loop_cntr][1]][4] +
                     dots[culled_tri[loop_cntr][2]][4];  /* X */      
       tot_norm[1] = dots[culled_tri[loop_cntr][0]][5] +
                     dots[culled_tri[loop_cntr][1]][5] +
                     dots[culled_tri[loop_cntr][2]][5];  /* Y */    
       tot_norm[2] = dots[culled_tri[loop_cntr][0]][6] +
                     dots[culled_tri[loop_cntr][1]][6] +
                     dots[culled_tri[loop_cntr][2]][6];  /* Z */
       /* (b) for triangle
                            A---C
			     \ /
                              B
	  find cross product ABcrossAC */
          AB[0] = dots[culled_tri[loop_cntr][1]][0] -
	          dots[culled_tri[loop_cntr][0]][0];   /* X */
          AB[1] = dots[culled_tri[loop_cntr][1]][1] -
	          dots[culled_tri[loop_cntr][0]][1];   /* Y */
          AB[2] = dots[culled_tri[loop_cntr][1]][2] -
	          dots[culled_tri[loop_cntr][0]][2];   /* Z */
          
	  AC[0] = dots[culled_tri[loop_cntr][2]][0] -
	          dots[culled_tri[loop_cntr][0]][0];   /* X */
	  AC[1] = dots[culled_tri[loop_cntr][2]][1] -
	          dots[culled_tri[loop_cntr][0]][1];   /* Y */
	  AC[2] = dots[culled_tri[loop_cntr][2]][2] -
	          dots[culled_tri[loop_cntr][0]][2];  /* Z */
	  /* the cross product */ 
	  ABcrossAC[0] = AB[1]*AC[2] - AB[2]*AC[1];
          ABcrossAC[1] = AB[2]*AC[0] - AB[0]*AC[2];
          ABcrossAC[2] = AB[0]*AC[1] - AB[1]*AC[0];
 
	  
          /* (c) find the dot product = ABcrossAC.tot_norm */
          ABcrossAC_dot_totnom = ABcrossAC[0]*tot_norm[0] +
	                         ABcrossAC[1]*tot_norm[1] +
	                         ABcrossAC[2]*tot_norm[2];
				 
          /* (d) depending on the sign of this dot product
             reverse the order of outputing triangles using vbles
             first_write  = 0 or 1
	     second_write = 1 or 0 */
	  if (ABcrossAC_dot_totnom < 0.)
            {
            /* swap culled_tri[loop_cntr][0] with */
	    /*      culled_tri[loop_cntr][1]      */
               iswap = culled_tri[loop_cntr][1];
	       culled_tri[loop_cntr][1] = culled_tri[loop_cntr][0];
	       culled_tri[loop_cntr][0] = iswap;
	    }
		     
       } /* only do if producing smooth surface */ 
   }  /* go thru triangle list */
	  
 return;
 
 
} /* end of: void reorder_triangle() */
void help ()
{
  
  printf("\nsos_triangle: Generates a Hole surface from a sos plot file.");
  printf("\n              (use sph_process to generate the sos file).");
  printf("\n Program reads a sos file from STDIN and writes file to STDOUT.");
  printf("\n \n Usage: surface  [ -h -m -p -r -s -v -l -d ] < infile > outfile");
  printf ("\n OPTIONS:");
  printf ("\n -h Prints this help file.");
  printf ("\n -s Produces a smooth rather than faceted surface.\n");
  printf ("\n -m Produces a Molscript v2.0 surface.\n");
  printf ("\n -d Removes colour information from Molscript objects.\n");
  printf ("\n -l Produces a VRML surface.\n");
  printf ("\n -p Produced as Prepi surface.\n");
  printf ("\n -r Produces a Povray v3.0 surface.\n"); 
  printf ("\n -v Produces a vmd surface (the default).\n"); 
  printf ("\n -X NUMB Use a maximum vertex cull distance of NUMB angs (default 5.0).\n");
  printf ("\n VMDPathFinder extensions:");
  printf ("\n --hole-features         Print build capabilities and exit (probe).");
  printf ("\n --points                Emit unique surface vertices as 'draw point'.");
  printf ("\n --batch FILE            Process multiple surfaces from a batch file.");
  printf ("\n                         Each line: sos_in<TAB>vmd_out[<TAB>atoms<TAB>sph].");
  printf ("\n                         Global flags (-s, --points, etc.) apply to all jobs.");
  printf ("\n --recolor FILE          Re-colour an existing .vmd_plot mesh by nearest-");
  printf ("\n                         sphere hydropathy (with --hydro-atoms/--hydro-sph/");
  printf ("\n                         --hydro-scheme), skipping triangulation.");
  printf ("\n --hydro-atoms FILE      Colour each triangle by nearest-sphere hydropathy.");
  printf ("\n                         FILE has rows 'x y z h_kd h_ww' (channel-local atoms).");
  printf ("\n --hydro-sph FILE        HOLE .sph file with the channel sphere centres.");
  printf ("\n --hydro-scheme kd|ww    Hydrophobicity scale (default kd).");
  printf ("\n --hydro-range LO HI     Real extremes of the property scale, so RAW");
  printf ("\n                         --hydro-values/--hydro3d-values colour identically");
  printf ("\n                         to the old normalized path (kept in real units).");
  printf ("\n --hydro-shell A         Lining-shell thickness in Angstrom (default 3.0):");
  printf ("\n                         atoms within (sphere_radius + A) are averaged.");
  printf ("\n --hydro3d-values FILE   TRUE per-triangle colouring (VMDPathFinder extension):");
  printf ("\n                         FILE has rows 'x y z value', one per qualifying");
  printf ("\n                         pore-lining residue. Colours by real 3D distance");
  printf ("\n                         to every residue, not nearest-centerline-sphere,");
  printf ("\n                         so colour varies by angle around the pore too.");
  printf ("\n --hydro3d-atoms FILE    Like --hydro3d-values but FILE has ALL channel-");
  printf ("\n                         local atoms 'x y z value resid is_ca'; the binary");
  printf ("\n                         does the pore-lining/facing test itself (moves the");
  printf ("\n                         Tcl hot loop into the parallel batch).");
  printf ("\n --hydro3d-lining M      residue|atom - contributor per qualifying residue");
  printf ("\n                         COG, or per qualifying atom (KR). For --hydro3d-atoms.");
  printf ("\n --hydro3d-facing 0|1    residue mode: keep only pore-facing residues.");
  printf ("\n --hydro3d-thresh A      pore-lining distance threshold (Angstrom, default 3.0).");
  printf ("\n --hydro3d-bandwidth A   Gaussian-kernel bandwidth for --hydro3d-values");
  printf ("\n                         (Angstrom, default 3.0).");
  printf ("\n --hydro3d-props FILE    Per-sphere MEAN of the true-3D dot values (one");
  printf ("\n                         value per line, .sph order) - the single source");
  printf ("\n                         for Profile Fill/Heatmap/Mean Profile. Needs");
  printf ("\n                         --hydro3d-values too; skips triangulation.");
  printf ("\n --batch-hydro3d-props FILE  Multi-frame --hydro3d-props in one process.");
  printf ("\n                         Each line: sos<TAB>residues<TAB>sph<TAB>out_props.");
  printf ("\n --batch-hydro3d-recolor FILE  Multi-frame --hydro3d-atoms --recolor in");
  printf ("\n                         one process. Requires --hydro3d-atoms/-facing/");
  printf ("\n                         -thresh/-bandwidth first. Each line:");
  printf ("\n                         base<TAB>out<TAB>atoms_or_residues<TAB>sph.\n");
  printf ("\n --hydro3d-values-in FILE  Colour from an already-averaged per-triangle");
  printf ("\n                         values file (one float per triangle, --recolor's");
  printf ("\n                         own encounter order) instead of a live");
  printf ("\n                         hydro_at_point_3d() evaluation.\n");
  printf ("\n --batch-hydro3d-average JOBLIST OUTFILE  Trajectory-average true-3D");
  printf ("\n                         per-triangle colouring for ONE fixed base mesh.");
  printf ("\n                         Requires --recolor/--hydro-sph/-bandwidth first.");
  printf ("\n                         JOBLIST: one residue-sidecar path per line.\n");

 return;
}

#ifdef VMDPATHFINDER_MULTICALL
/* The resident mesher (mesh_csg --serve, same binary) answers the tunnel
   clustering kernels for the plugin: forking VMD costs ~33 ms per call on a
   loaded trajectory, the kernel itself a few ms per frame. */
int vmdpathfinder_tunnel_cluster(const char *in, const char *out, double threshold, double maxdev)
{ return tunnel_cluster_c(in, out, threshold, maxdev); }
int vmdpathfinder_tunnel_dist(const char *in, const char *out, int want_max)
{ return tunnel_dist(in, out, want_max); }
#endif
