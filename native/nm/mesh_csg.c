/* mesh_csg.c - HOLE surface from profile spheres via exact-SDF CSG marching
 * cubes. Implements the rule found in sphqpu.f (doc/02-meshing.md):
 *
 *     surface = boundary( union(dot spheres) ) minus union(clip spheres),
 *     open where the clip spheres cut (no mouth caps).
 *
 * Field: f(p) = max( sdf_dot(p), -sdf_clip(p) ), marching cubes at iso 0,
 * then drop triangles whose centroid is owned by the clip term.
 *
 *   cc -O2 -fopenmp -o mesh_csg mesh_csg.c -lm
 *   ./mesh_csg out.sph mesh.vmd_plot VOXEL
 *
 * VOXEL is "H" (uniform) or "H/HF[/R]": a rectilinear grid, H everywhere and
 * HF inside every H-cell that touches a pore sphere of radius < R (default
 * 3H). One grid, so no seams; the HF cells lie on the same lattice as a
 * uniform HF run, so a narrow neck meshes identically at either setting.
 *
 * Reads .sph directly (occupancy = radius; beta > 0 = dot sphere, else clip).
 * Writes gpusurf-layout .tri: 18 float32 per triangle (3 x xyz + normal).
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#ifdef _OPENMP
#include <omp.h>
#endif
#include "mc_tables.h"
#include "../hole_io.h"
#include "nm_threads.h"
#ifdef VMDPATHFINDER_MULTICALL
int vmdpathfinder_tunnel_cluster(const char *in, const char *out, double threshold, double maxdev);
int vmdpathfinder_tunnel_dist(const char *in, const char *out, int want_max);
#endif

/* Every record is a CAPSULE: the points within sr of the segment (sx,sy,sz)-
   (ex,ey,ez). A sphere is the degenerate one with both ends equal, so one
   distance function serves HOLE's spherical, Connolly and capsule output.
   seff is the colour-band radius: sr for a sphere, the equal-area radius
   sqrt((pi R^2 + 2 R L)/pi) HOLE reports for a capsule slice. */
static double *sx, *sy, *sz, *ex, *ey, *ez, *sr, *seff;
static int *isclip;
static int nsph = 0, sphcap = 0;
#define MAXWITH 64
static const char *with_path[MAXWITH]; static int nwith = 0;
static double wlo[3] = {1e30, 1e30, 1e30}, whi[3] = {-1e30, -1e30, -1e30};
static void sph_reserve(void) {
    if (nsph < sphcap) return;
    sphcap = sphcap ? sphcap * 2 : 8192;
    sx = realloc(sx, sphcap * sizeof(double)); sy = realloc(sy, sphcap * sizeof(double));
    sz = realloc(sz, sphcap * sizeof(double)); sr = realloc(sr, sphcap * sizeof(double));
    ex = realloc(ex, sphcap * sizeof(double)); ey = realloc(ey, sphcap * sizeof(double));
    ez = realloc(ez, sphcap * sizeof(double)); seff = realloc(seff, sphcap * sizeof(double));
    isclip = realloc(isclip, sphcap * sizeof(int));
}
/* squared distance from a point to the segment a-b */
static inline double seg_d2(double px, double py, double pz, double ax, double ay, double az,
                            double bx, double by, double bz) {
    double vx = bx - ax, vy = by - ay, vz = bz - az, wx = px - ax, wy = py - ay, wz = pz - az;
    double vv = vx*vx + vy*vy + vz*vz;
    double t = vv > 1e-24 ? (wx*vx + wy*vy + wz*vz) / vv : 0.0;
    if (t < 0) t = 0; if (t > 1) t = 1;
    double dx = wx - t*vx, dy = wy - t*vy, dz = wz - t*vz;
    return dx*dx + dy*dy + dz*dz;
}
static inline int is_capsule(int s) { return ex[s] != sx[s] || ey[s] != sy[s] || ez[s] != sz[s]; }
/* --axis CX CY CZ VX VY VZ ENDRAD: the run's CPOINT/CVECT/ENDRAD. HOLE's capsule
   search leaves escaped slices in the file - cap centres far off the axis, or a
   fit whose equal-area radius passed ENDRAD - with nothing marking them. A slice
   is kept only when both cap centres lie within ENDRAD of the axis and its
   equal-area radius does not exceed ENDRAD, the rule HOLE's own profile applies. */
static double ax_c[3], ax_v[3], ax_endrad = 0; static int ax_have = 0;
static int axis_ok(double x, double y, double z) {
    if (!ax_have || ax_endrad <= 0) return 1;
    double wx = x - ax_c[0], wy = y - ax_c[1], wz = z - ax_c[2];
    double t = wx*ax_v[0] + wy*ax_v[1] + wz*ax_v[2];
    double dx = wx - t*ax_v[0], dy = wy - t*ax_v[1], dz = wz - t*ax_v[2];
    return sqrt(dx*dx + dy*dy + dz*dz) <= ax_endrad;
}
/* --bands E0,E1,...,En --band-names N0,...,N(n-1): colour the mesh by the
   owning sphere's radius in n absolute bands, edges inclusive below, the
   last band open above (the plugin's watermelon scale). Without it HOLE's
   three groups (red < 1.15, green < 2.30, blue) are written. */
#define MAXBANDS 32
static double band_edge[MAXBANDS + 1]; static const char *band_name[MAXBANDS];
static int nbands = 0, nband_edges = 0;
static int band_of(float r) {
    for (int b = 0; b < nbands; b++) if (r < band_edge[b + 1]) return b;
    return nbands - 1;
}
static void bands_reset(void) { nbands = 0; nband_edges = 0; }
static void bands_parse_edges(char *spec) {
    nband_edges = 0;
    for (char *tok = strtok(spec, ","); tok && nband_edges <= MAXBANDS; tok = strtok(NULL, ",")) band_edge[nband_edges++] = atof(tok);
}
static void bands_parse_names(char *spec) {
    nbands = 0;
    for (char *tok = strtok(spec, ","); tok && nbands < MAXBANDS; tok = strtok(NULL, ",")) band_name[nbands++] = tok;
}
static int bands_ok(void) { return nbands >= 1 && nband_edges == nbands + 1; }
static void axis_parse(int argc, char **argv) {
    for (int a = 0; a < argc; a++) {
        if (!strcmp(argv[a], "--bands") && a + 1 < argc) bands_parse_edges(argv[a+1]);
        if (!strcmp(argv[a], "--band-names") && a + 1 < argc) bands_parse_names(argv[a+1]);
        if (!strcmp(argv[a], "--with")) {
            for (int b = a + 1; b < argc && strncmp(argv[b], "--", 2); b++)
                if (nwith < MAXWITH) with_path[nwith++] = argv[b];
        }
        if (!strcmp(argv[a], "--axis") && a + 7 < argc) {
            for (int i = 0; i < 3; i++) ax_c[i] = atof(argv[a+1+i]);
            for (int i = 0; i < 3; i++) ax_v[i] = atof(argv[a+4+i]);
            ax_endrad = atof(argv[a+7]);
            double n = sqrt(ax_v[0]*ax_v[0] + ax_v[1]*ax_v[1] + ax_v[2]*ax_v[2]);
            if (n > 1e-12) { for (int i = 0; i < 3; i++) ax_v[i] /= n; ax_have = 1; }
        }
    }
}
static inline double prim_sdf(int s, double x, double y, double z) {
    return sqrt(seg_d2(x, y, z, sx[s], sy[s], sz[s], ex[s], ey[s], ez[s])) - sr[s];
}
/* --with FILE...: the neighbouring frames of a smoothing window. Their fields
   are averaged with the centre frame's on one grid and the mean is marched:
   a local average of the surfaces themselves, so a feature most frames share
   stays where it is and a flicker averages down. Colour bands and mouth caps
   come from the centre frame. */
typedef struct { double *sx, *sy, *sz, *ex, *ey, *ez, *sr, *seff; int *isclip; int nsph, sphcap; } sphset;
static sphset sph_save(void) {
    sphset t = {sx, sy, sz, ex, ey, ez, sr, seff, isclip, nsph, sphcap};
    sx = sy = sz = ex = ey = ez = sr = seff = NULL; isclip = NULL; nsph = sphcap = 0;
    return t;
}
static void sph_free_current(void) {
    free(sx); free(sy); free(sz); free(ex); free(ey); free(ez); free(sr); free(seff); free(isclip);
    sx = sy = sz = ex = ey = ez = sr = seff = NULL; isclip = NULL; nsph = sphcap = 0;
}
static void sph_restore(sphset t) {
    sph_free_current();
    sx = t.sx; sy = t.sy; sz = t.sz; ex = t.ex; ey = t.ey; ez = t.ez; sr = t.sr; seff = t.seff;
    isclip = t.isclip; nsph = t.nsph; sphcap = t.sphcap;
}
/* bounding box of the DOT spheres (clips only carve, never extend) */
static void sph_bbox(double *lo, double *hi) {
    for (int s = 0; s < nsph; s++) {
        if (isclip[s]) continue;
        double a[3] = {sx[s], sy[s], sz[s]}, b[3] = {ex[s], ey[s], ez[s]};
        for (int i = 0; i < 3; i++) {
            if (a[i]-sr[s] < lo[i]) lo[i] = a[i]-sr[s]; if (a[i]+sr[s] > hi[i]) hi[i] = a[i]+sr[s];
            if (b[i]-sr[s] < lo[i]) lo[i] = b[i]-sr[s]; if (b[i]+sr[s] > hi[i]) hi[i] = b[i]+sr[s];
        }
    }
}
static int track_own = 1;

static void sph_add(double x, double y, double z, double x2, double y2, double z2, double r, int clip) {
    sph_reserve();
    sx[nsph] = x; sy[nsph] = y; sz[nsph] = z; ex[nsph] = x2; ey[nsph] = y2; ez[nsph] = z2;
    sr[nsph] = r; isclip[nsph] = clip;
    double L = sqrt((x2-x)*(x2-x) + (y2-y)*(y2-y) + (z2-z)*(z2-z));
    seff[nsph] = L > 0 ? sqrt(r*r + 2.0*r*L / 3.141592653589793) : r;
    nsph++;
}

#ifndef NEWHOLE_EMBED
static double now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}
#endif

static int load_sph(const char *path) {
    /* HOLE marks a CUTTER by writing LAST-REC-END after it. In a spherical
       .sph every marked record also has beta 0; in a CONNOLLY one the marked
       escaped spheres keep beta 999.99, and meshing those as surface put
       blobs on the ends of the lateral openings. */
    /* HOLE's CAPSULE card writes each slice as a QC1 record followed by its
       QC2 partner (wpdbsp.f), radius in occupancy and beta 0.00 on every
       record - so the beta rule below cannot apply to a pair. */
    hio_reader rd; hio_rec a;
    if (!hio_open(&rd, path)) { perror(path); return 0; }
    nsph = 0;
    int have1 = 0, ncapsule = 0; double q1x = 0, q1y = 0, q1z = 0, q1r = 0;
    while (hio_next(&rd, &a)) {
        if (!(a.occ > 0)) { have1 = 0; continue; }
        if (!strncmp(a.name, " QC1", 4)) { have1 = 1; q1x = a.x; q1y = a.y; q1z = a.z; q1r = a.occ; continue; }
        if (!strncmp(a.name, " QC2", 4)) {
            if (have1 && axis_ok(q1x, q1y, q1z) && axis_ok(a.x, a.y, a.z)) {
                sph_add(q1x, q1y, q1z, a.x, a.y, a.z, q1r, 0);
                if (ax_have && ax_endrad > 0 && seff[nsph-1] > ax_endrad) nsph--;
                ncapsule++;
            }
            have1 = 0; continue;
        }
        have1 = 0;
        sph_add(a.x, a.y, a.z, a.x, a.y, a.z, a.occ, (a.beta <= 0.0) || a.marked);
    }
    hio_close(&rd);
    if (ncapsule) {
        /* A capsule run's escaped records are failed search attempts, not the
           mouth cutters a spherical run writes: dropping them keeps the tube. */
        int w = 0;
        for (int s = 0; s < nsph; s++) {
            if (isclip[s]) continue;
            if (w != s) { sx[w] = sx[s]; sy[w] = sy[s]; sz[w] = sz[s]; ex[w] = ex[s]; ey[w] = ey[s]; ez[w] = ez[s];
                          sr[w] = sr[s]; seff[w] = seff[s]; isclip[w] = 0; }
            w++;
        }
        nsph = w;
    }
    return 1;
}

/* grid: rectilinear, per-axis tick arrays */
static double h = 0.8, hf = 0.8, rfine = 0.0, ox, oy, oz;
/* 1 = emit HOLE's own "draw ..." records instead of addressing a molecule.
   sos_triangle's per-triangle recolour modes find triangles by searching for
   the literal "draw trinorm", so a mesh that is going to be recoloured has to
   be written in that form. */
static int draw_form = 0;
/* 1 = the dots display: one "draw point" per distinct mesh vertex, in HOLE's
   own records and colour bands, instead of triangles. */
static int dots_form = 0;
static int gnx, gny, gnz;
static double *tx, *ty, *tz;

/* cell index i with t[i] <= x < t[i+1], clamped to [0, n-2] */
static inline int locate(const double *t, int n, double x) {
    if (x <= t[0]) return 0;
    if (x >= t[n-1]) return n - 2;
    int lo = 0, hi = n - 1;
    while (hi - lo > 1) { int mid = (lo + hi) / 2; if (t[mid] <= x) lo = mid; else hi = mid; }
    return lo;
}

/* coarse ticks origin + i*h, i < ncoarse; cells meeting a fine interval are
 * split into round(h/hf) sub-cells. Returns the tick count. */
static int build_axis(double origin, int ncoarse, const double *ivlo, const double *ivhi,
                      int niv, double **out) {
    int ksub = (int)(h / hf + 0.5); if (ksub < 1) ksub = 1;
    double *t = malloc((size_t)ncoarse * ksub * sizeof(double));
    int n = 0;
    for (int i = 0; i < ncoarse - 1; i++) {
        double a = origin + i * h, b = a + h;
        int fine = 0;
        for (int q = 0; q < niv && !fine; q++) if (ivhi[q] > a && ivlo[q] < b) fine = 1;
        t[n++] = a;
        if (fine) for (int s2 = 1; s2 < ksub; s2++) t[n++] = a + s2 * (h / ksub);
    }
    t[n++] = origin + (ncoarse - 1) * h;
    *out = t;
    return n;
}
static float *fpos, *fclip;      /* per-corner signed distances, init +INF */
static int *fown, *fownc;        /* per-corner nearest DOT / CLIP sphere (argmin) */

#define IDX(i,j,k) (((size_t)(i) * gny + (j)) * gnz + (k))

static void fill_field(float *fld, int want_clip) {
    /* per z-slab parallel fill: race-free because each thread owns whole k
       planes; every sphere overlapping the plane contributes */
    #pragma omp parallel for schedule(dynamic, 4)
    for (int k = 0; k < gnz; k++) {
        double pz = tz[k];
        for (int s = 0; s < nsph; s++) {
            if (isclip[s] != want_clip) continue;
            int *own = want_clip ? fownc : fown;
            double reach = sr[s] + 2.0 * h;          /* accurate band */
            double zlo_s = sz[s] < ez[s] ? sz[s] : ez[s], zhi_s = sz[s] > ez[s] ? sz[s] : ez[s];
            if (pz < zlo_s - reach || pz > zhi_s + reach) continue;
            double xlo_s = sx[s] < ex[s] ? sx[s] : ex[s], xhi_s = sx[s] > ex[s] ? sx[s] : ex[s];
            double ylo_s = sy[s] < ey[s] ? sy[s] : ey[s], yhi_s = sy[s] > ey[s] ? sy[s] : ey[s];
            int i0 = locate(tx, gnx, xlo_s - reach);
            int i1 = locate(tx, gnx, xhi_s + reach) + 1; if (i1 >= gnx) i1 = gnx - 1;
            int j0 = locate(ty, gny, ylo_s - reach);
            int j1 = locate(ty, gny, yhi_s + reach) + 1; if (j1 >= gny) j1 = gny - 1;
            for (int i = i0; i <= i1; i++) {
                for (int j = j0; j <= j1; j++) {
                    float d = (float)prim_sdf(s, tx[i], ty[j], pz);
                    size_t id = IDX(i, j, k);
                    if (d < fld[id]) { fld[id] = d; if (track_own) own[id] = s; }
                }
            }
        }
    }
}

static inline float fval(size_t id) {
    float a = fpos[id], b = -fclip[id];
    return a > b ? a : b;
}

/* trilinear sample of one field at world point */
static float trisample(const float *fld, double x, double y, double z) {
    int i = locate(tx, gnx, x), j = locate(ty, gny, y), k = locate(tz, gnz, z);
    double a = (x - tx[i]) / (tx[i+1] - tx[i]), b = (y - ty[j]) / (ty[j+1] - ty[j]),
           c = (z - tz[k]) / (tz[k+1] - tz[k]);
    if (a < 0) a = 0; if (a > 1) a = 1;
    if (b < 0) b = 0; if (b > 1) b = 1;
    if (c < 0) c = 0; if (c > 1) c = 1;
    #define F(ii,jj,kk) fld[IDX(i+ii, j+jj, k+kk)]
    return (float)(
        (1-a)*((1-b)*((1-c)*F(0,0,0) + c*F(0,0,1)) + b*((1-c)*F(0,1,0) + c*F(0,1,1))) +
           a *((1-b)*((1-c)*F(1,0,0) + c*F(1,0,1)) + b*((1-c)*F(1,1,0) + c*F(1,1,1))));
    #undef F
}

typedef struct { float v[9]; float n[9]; float band; } Tri;

/* fixed-point "%9.Nf" without printf: the plot write was half the mesh time */
static inline char *put_fixed(char *o, double v, int dec) {
    static const long long pw[] = {1, 10, 100, 1000, 10000, 100000, 1000000};
    long long scale = pw[dec];
    long long x = llround(fabs(v) * (double)scale);
    int neg = v < 0 && x != 0;
    char tmp[24]; int n = 0;
    for (int d = 0; d < dec; d++) { tmp[n++] = (char)('0' + x % 10); x /= 10; }
    tmp[n++] = '.';
    do { tmp[n++] = (char)('0' + x % 10); x /= 10; } while (x);
    if (neg) tmp[n++] = '-';
    for (int pad = n; pad < 9; pad++) *o++ = ' ';
    while (n) *o++ = tmp[--n];
    return o;
}
static inline char *put_vec3(char *o, const float *v, int dec) {
    *o++ = '{';
    o = put_fixed(o, v[0], dec); o = put_fixed(o, v[1], dec); o = put_fixed(o, v[2], dec);
    *o++ = ' '; *o++ = '}'; *o++ = ' '; *o++ = ' ';
    return o;
}

/* Edge crossing. The field is a union/difference of SPHERES, so the crossing
 * on this segment lies exactly on one of them: take the sphere governing the
 * inside corner and intersect the segment with it analytically. Linear
 * interpolation of the sampled field (the textbook step) is only first order
 * and is what makes a coarse grid look like a different surface - this makes
 * vertex accuracy nearly independent of the voxel size. Falls back to the
 * linear estimate when the quadratic has no root on the segment (a corner
 * whose nearest sphere does not own the crossing, e.g. right at a seam). */
static void vert_interp(double *out, const double *p1, const double *p2,
                        float v1, float v2, int sph_id) {
    double mu = (fabs(v1 - v2) > 1e-12) ? (0.0 - v1) / (v2 - v1) : 0.5;
    if (mu < 0) mu = 0; if (mu > 1) mu = 1;
    if (sph_id >= 0 && is_capsule(sph_id)) {
        /* no closed form on a capsule: bisect the exact distance (16 steps) */
        double g1 = prim_sdf(sph_id, p1[0], p1[1], p1[2]), g2 = prim_sdf(sph_id, p2[0], p2[1], p2[2]);
        if ((g1 < 0) != (g2 < 0)) {
            double lo = 0, hi = 1;
            for (int it = 0; it < 16; it++) {
                double m2 = 0.5 * (lo + hi);
                double gm = prim_sdf(sph_id, p1[0] + m2*(p2[0]-p1[0]), p1[1] + m2*(p2[1]-p1[1]), p1[2] + m2*(p2[2]-p1[2]));
                if ((gm < 0) == (g1 < 0)) lo = m2; else hi = m2;
            }
            mu = 0.5 * (lo + hi);
        }
    } else if (sph_id >= 0) {
        double dx = p2[0]-p1[0], dy = p2[1]-p1[1], dz = p2[2]-p1[2];
        double ex = p1[0]-sx[sph_id], ey = p1[1]-sy[sph_id], ez = p1[2]-sz[sph_id];
        double A = dx*dx + dy*dy + dz*dz;
        double B = 2.0 * (ex*dx + ey*dy + ez*dz);
        double C = ex*ex + ey*ey + ez*ez - sr[sph_id]*sr[sph_id];
        double disc = B*B - 4.0*A*C;
        if (disc >= 0 && A > 1e-18) {
            double q = sqrt(disc);
            double t1 = (-B - q) / (2.0*A), t2 = (-B + q) / (2.0*A);
            double best = -1, bd = 1e30;
            if (t1 >= -1e-9 && t1 <= 1 + 1e-9) { double d = fabs(t1-mu); if (d < bd) { bd = d; best = t1; } }
            if (t2 >= -1e-9 && t2 <= 1 + 1e-9) { double d = fabs(t2-mu); if (d < bd) { bd = d; best = t2; } }
            if (best >= 0) { if (best < 0) best = 0; if (best > 1) best = 1; mu = best; }
        }
    }
    for (int i = 0; i < 3; i++) out[i] = p1[i] + mu * (p2[i] - p1[i]);
}

/* sphere governing this corner: the term that decides fval() there */
static inline int corner_sphere(size_t id) {
    return (fpos[id] > -fclip[id]) ? fown[id] : fownc[id];
}

/* mesh the spheres currently in sx/sy/sz/sr/isclip at voxel h; writes the
 * .tri file and returns the triangle count (-1 on I/O failure) */
/* plotpath, if non-NULL, writes a sos_triangle-compatible vmd_plot (draw
 * trinorm lines) straight from the in-memory triangle buffers - avoids
 * the write-then-reopen-and-reread round trip a separate conversion pass
 * would need. */
static long mesh_run(const char *outpath, const char *plotpath) {
    double t0 = now_ms();
    int ndot = 0; for (int s = 0; s < nsph; s++) if (!isclip[s]) ndot++;

    /* grid over the DOT spheres (clips only carve, never extend), and over
       the window frames' too when smoothing */
    double lo[3] = {1e30, 1e30, 1e30}, hi[3] = {-1e30, -1e30, -1e30};
    sph_bbox(lo, hi);
    for (int i = 0; nwith && i < 3; i++) { if (wlo[i] < lo[i]) lo[i] = wlo[i]; if (whi[i] > hi[i]) hi[i] = whi[i]; }
    double xlo = lo[0], ylo = lo[1], zlo = lo[2], xhi = hi[0], yhi = hi[1], zhi = hi[2];
    if (ndot == 0) {
        /* nothing to mesh: an empty plot, not a crash */
        if (plotpath) { FILE *e = fopen(plotpath, "wb"); if (e) fclose(e); }
        if (outpath) { FILE *e = fopen(outpath, "wb"); if (e) fclose(e); }
        return 0;
    }
    /* origin snapped to the fine lattice so a refined draft and a uniform
       fine run share corner positions exactly */
    double m = 2.0 * h;
    ox = floor((xlo - m) / hf) * hf; oy = floor((ylo - m) / hf) * hf; oz = floor((zlo - m) / hf) * hf;
    int ncx = (int)((xhi + m - ox) / h) + 2;
    int ncy = (int)((yhi + m - oy) / h) + 2;
    int ncz = (int)((zhi + m - oz) / h) + 2;
    /* fine intervals: one coarse cell around every small pore sphere */
    int niv = 0;
    double *ivx0 = NULL, *ivx1 = NULL, *ivy0 = NULL, *ivy1 = NULL, *ivz0 = NULL, *ivz1 = NULL;
    if (rfine > 0 && hf < h) {
        ivx0 = malloc(nsph * sizeof(double)); ivx1 = malloc(nsph * sizeof(double));
        ivy0 = malloc(nsph * sizeof(double)); ivy1 = malloc(nsph * sizeof(double));
        ivz0 = malloc(nsph * sizeof(double)); ivz1 = malloc(nsph * sizeof(double));
        for (int s = 0; s < nsph; s++) {
            if (isclip[s] || sr[s] >= rfine) continue;
            double pad = sr[s] + h;
            ivx0[niv] = (sx[s] < ex[s] ? sx[s] : ex[s]) - pad; ivx1[niv] = (sx[s] > ex[s] ? sx[s] : ex[s]) + pad;
            ivy0[niv] = (sy[s] < ey[s] ? sy[s] : ey[s]) - pad; ivy1[niv] = (sy[s] > ey[s] ? sy[s] : ey[s]) + pad;
            ivz0[niv] = (sz[s] < ez[s] ? sz[s] : ez[s]) - pad; ivz1[niv] = (sz[s] > ez[s] ? sz[s] : ez[s]) + pad;
            niv++;
        }
    }
    gnx = build_axis(ox, ncx, ivx0, ivx1, niv, &tx);
    gny = build_axis(oy, ncy, ivy0, ivy1, niv, &ty);
    gnz = build_axis(oz, ncz, ivz0, ivz1, niv, &tz);
    free(ivx0); free(ivx1); free(ivy0); free(ivy1); free(ivz0); free(ivz1);
    size_t ncorner = (size_t)gnx * gny * gnz;
    fpos  = malloc(ncorner * sizeof(float));
    fclip = malloc(ncorner * sizeof(float));
    fown  = malloc(ncorner * sizeof(int));
    fownc = malloc(ncorner * sizeof(int));
    for (size_t i = 0; i < ncorner; i++) { fpos[i] = 1e9f; fclip[i] = 1e9f; fown[i] = -1; fownc[i] = -1; }
    double t1 = now_ms();

    fill_field(fpos, 0);
    fill_field(fclip, 1);
    /* smoothing: the mean of every frame's field, marched in place of the
       centre's; the centre's own fields still decide caps and colour */
    /* The field marching cubes actually marches, kept so the normals can be
       its gradient. The corner values are fval() = max(fpos, -fclip), the
       pore minus the ENDRAD clip spheres; where fpos governs this holds the
       same bits, so only the mouth caps get a different normal from fpos
       alone. The smoothing path takes its normals from favg the same way.
       A frame smoothed against copies of itself does not give back the
       unsmoothed mesh: the averaged field is identical (CSG_DEBUG_IDENT
       below reports it), but an averaged field is no longer a union of
       spheres, so vert_interp gets no sphere to refine against. */
    float *fvalf = malloc(ncorner * sizeof(float));
    for (size_t i = 0; i < ncorner; i++) fvalf[i] = fval(i);

    float *favg = NULL;
    if (nwith > 0) {
        /* Every corner is averaged over ALL frames, sentinel included: a
           corner beyond fill_field's radius+2h band is known to be far
           outside in that frame, so its 1e9 must count, or a feature one
           frame has survives smoothing at full strength. Accumulated in
           double so that n identical frames average to exactly themselves. */
        double *acc = malloc(ncorner * sizeof(double));
        favg = malloc(ncorner * sizeof(float));
        for (size_t i = 0; i < ncorner; i++) acc[i] = fval(i);
        sphset centre = sph_save();
        float *fp2 = malloc(ncorner * sizeof(float)), *fc2 = malloc(ncorner * sizeof(float));
        float *sp = fpos, *sc = fclip;
        track_own = 0;
        int nused = 1;
        for (int k = 0; k < nwith; k++) {
            if (!load_sph(with_path[k])) continue;
            for (size_t i = 0; i < ncorner; i++) { fp2[i] = 1e9f; fc2[i] = 1e9f; }
            fpos = fp2; fclip = fc2;
            fill_field(fpos, 0);
            fill_field(fclip, 1);
            for (size_t i = 0; i < ncorner; i++) {
                float a = fp2[i], b = -fc2[i];
                acc[i] += a > b ? a : b;
            }
            nused++;
            sph_free_current();
        }
        fpos = sp; fclip = sc;
        track_own = 1;
        free(fp2); free(fc2);
        sph_restore(centre);
        for (size_t i = 0; i < ncorner; i++) favg[i] = (float)(acc[i] / (double)nused);
        /* CSG_DEBUG_IDENT=1: how far the averaged field is from the centre's
           own; the identity test reads this. */
        if (getenv("CSG_DEBUG_IDENT")) {
            double mx = 0; size_t nd = 0, nsent = 0;
            for (size_t i = 0; i < ncorner; i++) {
                float v = fval(i);
                if (v >= 1e8f || favg[i] >= 1e8f) { nsent++; continue; }
                double d = fabs((double)favg[i] - (double)v);
                if (d > 0) nd++;
                if (d > mx) mx = d;
            }
            fprintf(stderr, "IDENT corners=%zu differing=%zu maxdiff=%.9g sentinel=%zu\n",
                    ncorner, nd, mx, nsent);
        }
        free(acc);
    }
    double t2 = now_ms();

    /* marching cubes, parallel over k-slabs with per-thread buffers */
    /* One buffer per z-slab, not per thread: the file is then emitted in slab
       order and is byte-identical whatever the schedule does. Order matters
       downstream - conn_lobes' region split memoises the first triangle to
       land in each grid cell, so a mesh whose triangle order moved between
       runs would colour a few lobe triangles differently each time. */
    int nslab = gnz - 1; if (nslab < 1) nslab = 1;
    Tri **tbuf = calloc(nslab, sizeof(Tri *));
    int *tcnt = calloc(nslab, sizeof(int)), *tcap = calloc(nslab, sizeof(int));

    #pragma omp parallel for schedule(dynamic, 4)
    for (int k = 0; k < gnz - 1; k++) {
        int th = k;
        for (int i = 0; i < gnx - 1; i++)
        for (int j = 0; j < gny - 1; j++) {
            /* Bourke corner order */
            size_t c[8] = { IDX(i,j,k),     IDX(i+1,j,k),   IDX(i+1,j+1,k),   IDX(i,j+1,k),
                            IDX(i,j,k+1),   IDX(i+1,j,k+1), IDX(i+1,j+1,k+1), IDX(i,j+1,k+1) };
            float val[8]; int cube = 0;
            for (int q = 0; q < 8; q++) {
                val[q] = favg ? favg[c[q]] : fval(c[q]);
                if (val[q] < 0) cube |= 1 << q;
            }
            if (edgeTable[cube] == 0) continue;
            static const int coff[8][3] = {{0,0,0},{1,0,0},{1,1,0},{0,1,0},
                                           {0,0,1},{1,0,1},{1,1,1},{0,1,1}};
            double P[8][3];
            for (int q = 0; q < 8; q++) {
                P[q][0] = tx[i + coff[q][0]];
                P[q][1] = ty[j + coff[q][1]];
                P[q][2] = tz[k + coff[q][2]];
            }
            static const int e2c[12][2] = {{0,1},{1,2},{2,3},{3,0},{4,5},{5,6},
                                           {6,7},{7,4},{0,4},{1,5},{2,6},{3,7}};
            double ev[12][3];
            for (int e = 0; e < 12; e++)
                if (edgeTable[cube] & (1 << e)) {
                    int q1 = e2c[e][0], q2 = e2c[e][1];
                    /* the inside corner's governing sphere carries the crossing */
                    int inq = (val[q1] < 0) ? q1 : q2;
                    vert_interp(ev[e], P[q1], P[q2], val[q1], val[q2],
                                favg ? -1 : corner_sphere(c[inq]));
                }
            for (int t = 0; triTable[cube][t] != -1; t += 3) {
                double *a = ev[triTable[cube][t]], *b = ev[triTable[cube][t+1]],
                       *cc = ev[triTable[cube][t+2]];
                /* A crossing that lands on a grid node gives two edges the same
                   point and a zero-area facet. It draws nothing, but one such
                   facet in a batch makes VMD's OptiX renderer shade the whole
                   mesh flat, so it is dropped here. */
                {
                    double e1[3] = {b[0]-a[0], b[1]-a[1], b[2]-a[2]};
                    double e2[3] = {cc[0]-a[0], cc[1]-a[1], cc[2]-a[2]};
                    double e3[3] = {cc[0]-b[0], cc[1]-b[1], cc[2]-b[2]};
                    double l1 = e1[0]*e1[0]+e1[1]*e1[1]+e1[2]*e1[2];
                    double l2 = e2[0]*e2[0]+e2[1]*e2[1]+e2[2]*e2[2];
                    double l3 = e3[0]*e3[0]+e3[1]*e3[1]+e3[2]*e3[2];
                    double nx = e1[1]*e2[2] - e1[2]*e2[1];
                    double ny = e1[2]*e2[0] - e1[0]*e2[2];
                    double nz = e1[0]*e2[1] - e1[1]*e2[0];
                    /* corners closer than 1e-3 A print identically at the
                       plot's precision, so they count as one corner */
                    if (l1 < 1e-6 || l2 < 1e-6 || l3 < 1e-6) continue;
                    if (nx*nx + ny*ny + nz*nz < 1e-10) continue;
                }
                /* ownership test at the centroid: clip term dominating means
                   this facet is a mouth cap HOLE never draws */
                double gx2 = (a[0]+b[0]+cc[0])/3, gy2 = (a[1]+b[1]+cc[1])/3,
                       gz2 = (a[2]+b[2]+cc[2])/3;
                if (-trisample(fclip, gx2, gy2, gz2) >
                     trisample(fpos,  gx2, gy2, gz2)) continue;
                if (tcnt[th] >= tcap[th]) {
                    tcap[th] = tcap[th] ? tcap[th] * 2 : 4096;
                    tbuf[th] = realloc(tbuf[th], tcap[th] * sizeof(Tri));
                }
                Tri *tr = &tbuf[th][tcnt[th]++];
                {   /* colour band = radius of the dot sphere whose surface is
                       nearest the centroid, chosen among the owners of the
                       cell's eight corners (the owner at a corner is the
                       sphere with the least distance there, so the centroid's
                       owner is one of them) */
                    int oi = locate(tx, gnx, gx2), oj = locate(ty, gny, gy2), ok = locate(tz, gnz, gz2);
                    int own = -1; double bestd = 1e30;
                    for (int ci = oi - 1; ci <= oi + 2; ci++)
                    for (int cj = oj - 1; cj <= oj + 2; cj++)
                    for (int ck = ok - 1; ck <= ok + 2; ck++) {
                        if (ci < 0 || cj < 0 || ck < 0 || ci > gnx - 1 || cj > gny - 1 || ck > gnz - 1) continue;
                        int cand = fown[IDX(ci,cj,ck)];
                        if (cand < 0 || isclip[cand]) continue;
                        double d = prim_sdf(cand, gx2, gy2, gz2);
                        if (d < bestd) { bestd = d; own = cand; }
                    }
                    tr->band = own >= 0 ? (float)seff[own] : 0.0f;
                }
                /* b,cc swapped: winding must agree with the outward normal
                   (VMD lights the back face dark otherwise) */
                const double *vv[3] = {a, cc, b};
                for (int q = 0; q < 3; q++) {
                    tr->v[q*3+0] = (float)vv[q][0];
                    tr->v[q*3+1] = (float)vv[q][1];
                    tr->v[q*3+2] = (float)vv[q][2];
                    /* outward normal = gradient of f (central differences) */
                    double e = 0.5 * hf;
                    const float *nf = favg ? favg : fvalf;
                    double nx2 = trisample(nf, vv[q][0]+e, vv[q][1], vv[q][2]);
                    double nx1 = trisample(nf, vv[q][0]-e, vv[q][1], vv[q][2]);
                    double ny2 = trisample(nf, vv[q][0], vv[q][1]+e, vv[q][2]);
                    double ny1 = trisample(nf, vv[q][0], vv[q][1]-e, vv[q][2]);
                    double nz2 = trisample(nf, vv[q][0], vv[q][1], vv[q][2]+e);
                    double nz1 = trisample(nf, vv[q][0], vv[q][1], vv[q][2]-e);
                    double gx = nx2-nx1, gy = ny2-ny1, gz = nz2-nz1;
                    double gn = sqrt(gx*gx + gy*gy + gz*gz);
                    if (gn < 1e-12) gn = 1;
                    tr->n[q*3+0] = (float)(gx/gn);
                    tr->n[q*3+1] = (float)(gy/gn);
                    tr->n[q*3+2] = (float)(gz/gn);
                }
            }
        }
    }
    double t3 = now_ms();

    long total = 0;
    for (int th = 0; th < nslab; th++) total += tcnt[th];
    FILE *out = outpath ? fopen(outpath, "wb") : NULL;
    if (outpath && !out) { perror(outpath); total = -1; }
    if (out) {
        static char obuf[1 << 20]; setvbuf(out, obuf, _IOFBF, sizeof obuf);
        for (int th = 0; th < nslab; th++)
            for (int t = 0; t < tcnt[th]; t++) {
                Tri *tr = &tbuf[th][t];
                for (int q = 0; q < 3; q++) {
                    fwrite(&tr->v[q*3], sizeof(float), 3, out);
                    fwrite(&tr->n[q*3], sizeof(float), 3, out);
                }
            }
        fclose(out);
    }
    /* HOLE's radius bands (sph_process -colour: red < 1.15, green < 2.3,
       blue) as three colour groups. Same records as a sos_triangle plot, but
       addressed to one molecule ("graphics $mol", not "draw") so the plugin
       can replay the file by SOURCING it: `draw` is a Tcl proc that resolves
       the top molecule on every call, which costs more per triangle than the
       drawing itself. The opening line makes the file stand alone if someone
       sources it by hand. The plugin's parser accepts either form. */
    FILE *plot = plotpath ? fopen(plotpath, "w") : NULL;
    if (plotpath && !plot) { perror(plotpath); total = -1; }
    if (plot) {
        static char pbuf[1 << 20]; setvbuf(plot, pbuf, _IOFBF, sizeof pbuf);
        struct { long kx, ky, kz; int used; } *dseen = NULL; size_t dseen_cap = 0;
        if (dots_form) {
            dseen_cap = 1; while (dseen_cap < (size_t)total * 4) dseen_cap <<= 1;
            dseen = calloc(dseen_cap, sizeof *dseen);
        }
        const char *G = (draw_form || dots_form) ? "draw " : "graphics $::VMDPathFinder::_gmol ";
        const size_t GL = strlen(G);
        if (!draw_form)
            fprintf(plot, "if {![info exists ::VMDPathFinder::_gmol]} "
                          "{ set ::VMDPathFinder::_gmol [molinfo top] }\n");
        /* "delete all" only in HOLE's own form, where the plugin's parser skips
           it. In the addressed form the file is SOURCED, and deleting there
           would discard the material the plugin set just before sourcing -
           every surface came out in VMD's default material. The plugin clears
           the molecule itself before it draws. */
        if (draw_form) fprintf(plot, "%sdelete all\n", G);
        static const char *hole_names[3] = {"red", "green", "blue"};
        int use_bands = bands_ok();
        if (!use_bands && (nbands || nband_edges))
            fprintf(stderr, "mesh_csg: --bands needs one more edge than --band-names (%d edges, %d names) - HOLE's three groups written instead\n", nband_edges, nbands);
        int ngroups = use_bands ? nbands : 3;
        for (int band = 0; band < ngroups; band++) {
            int any = 0;
            for (int th = 0; th < nslab && !any; th++)
                for (int t = 0; t < tcnt[th]; t++) {
                    float r = tbuf[th][t].band;
                    int b = use_bands ? band_of(r) : (r < 1.15f ? 0 : (r < 2.30f ? 1 : 2));
                    if (b == band) { any = 1; break; }
                }
            if (!any) continue;
            fprintf(plot, "%scolor %s\n", G, use_bands ? band_name[band] : hole_names[band]);
            for (int th = 0; th < nslab; th++)
                for (int t = 0; t < tcnt[th]; t++) {
                    Tri *tr = &tbuf[th][t];
                    float r = tr->band;
                    int b = use_bands ? band_of(r) : (r < 1.15f ? 0 : (r < 2.30f ? 1 : 2));
                    if (b != band) continue;
                    if (dots_form) {
                        /* a vertex is shared by ~6 triangles: emit it from the
                           triangle whose slab/index is lowest, found by a
                           lattice hash, so each point appears once */
                        for (int q = 0; q < 3; q++) {
                            long kx = lround(tr->v[q*3+0] * 1000.0), ky = lround(tr->v[q*3+1] * 1000.0), kz = lround(tr->v[q*3+2] * 1000.0);
                            unsigned long hh = (unsigned long)kx * 73856093UL ^ (unsigned long)ky * 19349663UL ^ (unsigned long)kz * 83492791UL;
                            size_t slot = hh & (dseen_cap - 1);
                            int dup = 0;
                            while (dseen[slot].used) {
                                if (dseen[slot].kx == kx && dseen[slot].ky == ky && dseen[slot].kz == kz) { dup = 1; break; }
                                slot = (slot + 1) & (dseen_cap - 1);
                            }
                            if (dup) continue;
                            dseen[slot].used = 1; dseen[slot].kx = kx; dseen[slot].ky = ky; dseen[slot].kz = kz;
                            fprintf(plot, "draw point {%.3f %.3f %.3f}\n", tr->v[q*3+0], tr->v[q*3+1], tr->v[q*3+2]);
                        }
                        continue;
                    }
                    char lb[256], *o = lb;
                    memcpy(o, G, GL); o += GL;
                    memcpy(o, "trinorm  ", 9); o += 9;
                    o = put_vec3(o, tr->v, 3); o = put_vec3(o, tr->v + 3, 3); o = put_vec3(o, tr->v + 6, 3);
                    o = put_vec3(o, tr->n, 5); o = put_vec3(o, tr->n + 3, 5); o = put_vec3(o, tr->n + 6, 5);
                    *o++ = '\n';
                    fwrite(lb, 1, (size_t)(o - lb), plot);
                }
        }
        fclose(plot);
        free(dseen);
    }
    for (int th = 0; th < nslab; th++) free(tbuf[th]);
    free(tbuf); free(tcnt); free(tcap);
    free(fvalf);
    free(fpos); free(fclip); free(fown); free(fownc); free(favg);
    fpos = fclip = NULL; fown = fownc = NULL;
    free(tx); free(ty); free(tz); tx = ty = tz = NULL;
    double t4 = now_ms();
    fprintf(stderr, "spheres %d (%d dot)  with %d  grid %dx%dx%d @ %.2f/%.2f A (r<%.1f fine)  "
            "alloc %.1f  fill %.1f  mc %.1f  io %.1f  total %.1f ms  tris %ld\n",
            nsph, ndot, nwith, gnx, gny, gnz, h, hf, rfine,
            t1-t0, t2-t1, t3-t2, t4-t3, t4-t0, total);
    return total;
}

/* ------------------------------------------------------------------ colour
 * Per-triangle property colouring, the same rule sos_triangle's --recolor
 * --hydro3d-atoms applies, done here so a property surface needs neither a
 * second process nor a second read of the mesh:
 *   contributors = pore-lining residues (any atom within THRESH of the
 *     nearest centreline sphere's surface; with --facing, the residue's COG
 *     must be nearer that sphere centre than its CA), one per residue at its
 *     COG with the residue's value - or, in atom mode, every lining atom;
 *   value at a triangle = Gaussian-kernel (bandwidth BW) Nadaraya-Watson mean
 *     of the contributors at the triangle centroid;
 *   colour = the seven-step ramp on value/range (signed) or (value-lo)/(hi-lo).
 * Contributor order and the centroid text are the same as sos_triangle's, so
 * the two colour the same mesh identically. */
typedef struct { double x, y, z, x2, y2, z2, v; } cpt;   /* segment x-x2 swept by v */
static cpt *csph = NULL; static int ncsph = 0;      /* centreline spheres, r in v */
static cpt *ccon = NULL; static int nccon = 0, ccap = 0; /* contributors */
static int col_signed = 1, col_have_range = 0, col_facing = 0, col_atom_mode = 0;
static double col_lo = 0, col_hi = 0, col_thresh = 3.0, col_bw = 3.0;

static int col_load_spheres(const char *path) {
    hio_reader rd; hio_rec a;
    if (!hio_open(&rd, path)) return 0;
    int cap = 0; ncsph = 0;
    while (hio_next(&rd, &a)) {
        if (a.len < 60) continue;
        if (a.resseq == -999 || a.resseq == -888 || a.beta >= 999.0) continue;   /* flood dots, escaped, bulk */
        if (!strncmp(a.name, " QC2", 4) && ncsph > 0) {
            /* second cap centre of the capsule slice just read (wpdbsp.f order);
               an escaped slice (see axis_ok) leaves with its QC1 */
            if (!axis_ok(a.x, a.y, a.z) || !axis_ok(csph[ncsph-1].x, csph[ncsph-1].y, csph[ncsph-1].z)) { ncsph--; continue; }
            csph[ncsph-1].x2 = a.x; csph[ncsph-1].y2 = a.y; csph[ncsph-1].z2 = a.z;
            continue;
        }
        if (ncsph == cap) { cap = cap ? cap * 2 : 1024; csph = realloc(csph, cap * sizeof(cpt)); }
        csph[ncsph].x = csph[ncsph].x2 = a.x; csph[ncsph].y = csph[ncsph].y2 = a.y;
        csph[ncsph].z = csph[ncsph].z2 = a.z; csph[ncsph].v = a.occ;
        ncsph++;
    }
    hio_close(&rd); return ncsph > 0;
}
static void col_nearest(double x, double y, double z, double *d2, double *r) {
    double best = 1e30, br = 0;
    for (int s = 0; s < ncsph; s++) {
        double e = seg_d2(x, y, z, csph[s].x, csph[s].y, csph[s].z, csph[s].x2, csph[s].y2, csph[s].z2);
        if (e < best) { best = e; br = csph[s].v; }
    }
    *d2 = best; *r = br;
}
static void col_push(double x, double y, double z, double v) {
    if (nccon == ccap) { ccap = ccap ? ccap * 2 : 1024; ccon = realloc(ccon, ccap * sizeof(cpt)); }
    ccon[nccon].x = x; ccon[nccon].y = y; ccon[nccon].z = z; ccon[nccon].v = v; nccon++;
}
/* --values FILE: rows "x y z value" are the contributors as given */
static int col_load_values(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return 0;
    char line[512]; nccon = 0;
    while (fgets(line, sizeof line, f)) {
        double x, y, z, v; if (sscanf(line, "%lf %lf %lf %lf", &x, &y, &z, &v) != 4) continue;
        col_push(x, y, z, v);
    }
    fclose(f); return nccon > 0;
}
/* --atoms FILE: the plugin's pore-lining sidecar, in either of two layouts:
 *   rows "x y z value resid isCA" (what sos_triangle reads), or
 *   a PDB written by VMD with the residue value in the B-factor column and
 *   1.0 in occupancy on the CA atoms - one C-speed writepdb instead of a Tcl
 *   loop over every atom. The residue key is chain+resSeq+icode+segid. */
static int col_load_atoms(const char *path) {
    FILE *f = fopen(path, "r"); if (!f) return 0;
    char line[512]; int n = 0, cap = 0;
    double *ax = NULL, *ay = NULL, *az = NULL, *av = NULL; int *ar = NULL, *ac = NULL;
    char (*keys)[16] = NULL; int nkeys = 0, kcap = 0;   /* PDB residue keys -> index */
    while (fgets(line, sizeof line, f)) {
        double x, y, z, v, rid, ca;
        if (hio_is_atom(line)) {
            hio_rec a; char lbuf[512]; strcpy(lbuf, line); hio_parse(&a, lbuf);
            if (a.len < 66) continue;
            x = a.x; y = a.y; z = a.z; ca = a.occ > 0.5 ? 1 : 0; v = a.beta;
            char key[16];                                            /* chain, resSeq, icode, segid */
            snprintf(key, sizeof key, "%c%4d%c%s", a.chain, a.resseq, a.icode, a.len >= 76 ? a.segid : "");
            int idx = -1;
            for (int k = nkeys - 1; k >= 0 && k >= nkeys - 4; k--) if (!strcmp(keys[k], key)) { idx = k; break; }
            if (idx < 0) for (int k = 0; k < nkeys - 4; k++) if (!strcmp(keys[k], key)) { idx = k; break; }
            if (idx < 0) {
                if (nkeys == kcap) { kcap = kcap ? kcap * 2 : 1024; keys = realloc(keys, kcap * sizeof *keys); }
                strcpy(keys[nkeys], key); idx = nkeys++;
            }
            rid = idx;
        } else if (sscanf(line, "%lf %lf %lf %lf %lf %lf", &x, &y, &z, &v, &rid, &ca) != 6) continue;
        if (n == cap) { cap = cap ? cap * 2 : 8192;
            ax = realloc(ax, cap * sizeof(double)); ay = realloc(ay, cap * sizeof(double)); az = realloc(az, cap * sizeof(double));
            av = realloc(av, cap * sizeof(double)); ar = realloc(ar, cap * sizeof(int)); ac = realloc(ac, cap * sizeof(int)); }
        ax[n] = x; ay[n] = y; az[n] = z; av[n] = v; ar[n] = (int)(rid + 0.5); ac[n] = (int)(ca + 0.5); n++;
    }
    fclose(f);
    if (n == 0) return 0;
    int *lin = malloc(n * sizeof(int));
    #pragma omp parallel for schedule(static)
    for (int i = 0; i < n; i++) { double d2, r; col_nearest(ax[i], ay[i], az[i], &d2, &r); lin[i] = fabs(sqrt(d2) - r) <= col_thresh; }
    nccon = 0;
    if (col_atom_mode) {
        for (int i = 0; i < n; i++) if (lin[i]) col_push(ax[i], ay[i], az[i], av[i]);
    } else {
        int maxr = -1; for (int i = 0; i < n; i++) if (ar[i] > maxr) maxr = ar[i];
        if (maxr >= 0 && maxr <= n + 1000000) {
            int nres = maxr + 1;
            double *sx = calloc(nres, sizeof(double)), *sy = calloc(nres, sizeof(double)), *sz = calloc(nres, sizeof(double));
            double *val = calloc(nres, sizeof(double)), *cx = calloc(nres, sizeof(double)), *cy = calloc(nres, sizeof(double)), *cz = calloc(nres, sizeof(double));
            int *cnt = calloc(nres, sizeof(int)), *rl = calloc(nres, sizeof(int)), *hca = calloc(nres, sizeof(int));
            for (int i = 0; i < n; i++) { int r = ar[i]; if (r < 0 || r >= nres) continue;
                sx[r] += ax[i]; sy[r] += ay[i]; sz[r] += az[i]; cnt[r]++; val[r] = av[i];
                if (ac[i]) { cx[r] = ax[i]; cy[r] = ay[i]; cz[r] = az[i]; hca[r] = 1; }
                if (lin[i]) rl[r] = 1; }
            for (int r = 0; r < nres; r++) {
                if (!cnt[r] || !rl[r]) continue;
                double gx = sx[r]/cnt[r], gy = sy[r]/cnt[r], gz = sz[r]/cnt[r];
                if (col_facing) { if (!hca[r]) continue; double dg, rg, da, ra;
                    col_nearest(gx, gy, gz, &dg, &rg); col_nearest(cx[r], cy[r], cz[r], &da, &ra);
                    if (!(dg < da)) continue; }
                col_push(gx, gy, gz, val[r]);
            }
            free(sx); free(sy); free(sz); free(val); free(cx); free(cy); free(cz); free(cnt); free(rl); free(hca);
        }
    }
    free(lin); free(ax); free(ay); free(az); free(av); free(ar); free(ac); free(keys);
    return nccon > 0;
}
static double col_value(double x, double y, double z) {
    double ks = 0, ws = 0, inv = 1.0 / (2.0 * col_bw * col_bw);
    for (int i = 0; i < nccon; i++) {
        double dx = x - ccon[i].x, dy = y - ccon[i].y, dz = z - ccon[i].z;
        double k = exp(-(dx*dx + dy*dy + dz*dz) * inv);
        ks += k; ws += k * ccon[i].v;
    }
    return ks > 1e-300 ? ws / ks : 0.0;
}
static const char *col_name(double v) {
    double t = v;
    if (col_have_range) {
        if (col_signed) { t = v < 0 ? (col_lo < 0 ? v / (-col_lo) : 0) : (col_hi > 0 ? v / col_hi : 0);
                          if (t < -1) t = -1; if (t > 1) t = 1; }
        else { double sp = col_hi - col_lo; t = sp != 0 ? (v - col_lo) / sp : 0.5; if (t < 0) t = 0; if (t > 1) t = 1; }
    }
    if (col_signed) {
        if (t < -0.66) return "blue"; if (t < -0.33) return "iceblue"; if (t < -0.11) return "cyan";
        if (t <  0.11) return "white"; if (t <  0.33) return "yellow"; if (t <  0.66) return "orange"; return "red";
    }
    if (t < 0.25) return "white"; if (t < 0.50) return "yellow"; if (t < 0.75) return "orange"; return "red";
}
/* Recolour an existing draw-form mesh: every "draw trinorm"/"draw triangle"
 * line is kept verbatim under a run-length "draw color" stream; old colour
 * lines are dropped; anything else passes through. Returns the triangle
 * count, -1 on failure. */
static long col_recolor_plot(const char *inpath, const char *outpath) {
    FILE *in = fopen(inpath, "r"); if (!in) return -1;
    char **lines = NULL; size_t nl = 0, cap = 0; char buf[4096];
    while (fgets(buf, sizeof buf, in)) {
        if (nl == cap) { cap = cap ? cap * 2 : 4096; lines = realloc(lines, cap * sizeof(char *)); }
        lines[nl++] = strdup(buf);
    }
    fclose(in);
    const char **col = calloc(nl, sizeof(char *)); long ntri = 0;
    #pragma omp parallel for schedule(dynamic, 256) reduction(+:ntri)
    for (size_t i = 0; i < nl; i++) {
        const char *l = lines[i], *p = strstr(l, "draw triangle"); if (!p) p = strstr(l, "draw trinorm");
        if (!p) continue;
        double v[3][3]; const char *q = p; int got = 0;
        for (int k = 0; k < 3; k++) {
            q = strchr(q, '{'); if (!q) break;
            if (sscanf(q, "{ %lf %lf %lf", &v[k][0], &v[k][1], &v[k][2]) != 3 &&
                sscanf(q, "{%lf %lf %lf", &v[k][0], &v[k][1], &v[k][2]) != 3) break;
            q++; got++;
        }
        if (got != 3) continue;
        double cx = (v[0][0]+v[1][0]+v[2][0])/3.0, cy = (v[0][1]+v[1][1]+v[2][1])/3.0, cz = (v[0][2]+v[1][2]+v[2][2])/3.0;
        col[i] = col_name(col_value(cx, cy, cz)); ntri++;
    }
    FILE *out = fopen(outpath, "w"); if (!out) { for (size_t i = 0; i < nl; i++) free(lines[i]); free(lines); free(col); return -1; }
    static char obuf[1 << 20]; setvbuf(out, obuf, _IOFBF, sizeof obuf);
    const char *cur = "";
    for (size_t i = 0; i < nl; i++) {
        if (strstr(lines[i], "draw color")) continue;
        if (col[i] && strcmp(col[i], cur)) { fprintf(out, "draw color %s\n", col[i]); cur = col[i]; }
        fputs(lines[i], out);
        free(lines[i]);
    }
    fclose(out); free(lines); free(col);
    return ntri;
}
/* colour options, shared by the CLI and the serve line:
 *   --atoms FILE | --values FILE, --csph SPH, --lining residue|atom,
 *   --facing 0|1, --thresh A, --bandwidth A, --signed 0|1, --range LO HI */
static int col_parse(int argc, char **argv, const char **atoms, const char **values, const char **sph) {
    *atoms = *values = *sph = NULL; col_have_range = 0; col_atom_mode = 0; col_facing = 0;
    for (int a = 0; a < argc; a++) {
        if (!strcmp(argv[a], "--atoms") && a + 1 < argc) *atoms = argv[++a];
        else if (!strcmp(argv[a], "--values") && a + 1 < argc) *values = argv[++a];
        else if (!strcmp(argv[a], "--csph") && a + 1 < argc) *sph = argv[++a];
        else if (!strcmp(argv[a], "--lining") && a + 1 < argc) col_atom_mode = !strcmp(argv[++a], "atom");
        else if (!strcmp(argv[a], "--facing") && a + 1 < argc) col_facing = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--thresh") && a + 1 < argc) col_thresh = atof(argv[++a]);
        else if (!strcmp(argv[a], "--bandwidth") && a + 1 < argc) col_bw = atof(argv[++a]);
        else if (!strcmp(argv[a], "--signed") && a + 1 < argc) col_signed = atoi(argv[++a]);
        else if (!strcmp(argv[a], "--range") && a + 2 < argc) { col_lo = atof(argv[++a]); col_hi = atof(argv[++a]); col_have_range = 1; }
        else if (!strcmp(argv[a], "--axis") && a + 7 < argc) { axis_parse(8, argv + a); a += 7; }
        else return 0;
    }
    return 1;
}
static long col_run(const char *inplot, const char *outplot, int argc, char **argv) {
    const char *atoms, *values, *sph;
    if (!col_parse(argc, argv, &atoms, &values, &sph)) return -1;
    nccon = 0; ncsph = 0;
    if (values) { if (!col_load_values(values)) return -1; }
    else { if (!atoms || !sph || !col_load_spheres(sph) || !col_load_atoms(atoms)) return -1; }
    return col_recolor_plot(inplot, outplot);
}

#ifndef NEWHOLE_EMBED
static void usage(const char *a0) {
    fprintf(stderr,
        "usage: %s SPH OUT.vmd_plot VOXEL [--tri OUT.tri] [--draw]\n"
        "       %s --serve          (stdin: mesh<TAB>SPH<TAB>OUT.vmd_plot<TAB>VOXEL per line; stdout: OK n / ERR ...)\n"
        "  VOXEL: H (uniform) or H/HF[/R] (HF cells around pore spheres of radius < R, default 3H)\n"
        "  --draw: write \"draw ...\" records (what sos_triangle's recolour modes read)\n"
        "  --dots: the dots display - one \"draw point\" per distinct vertex (serve: meshdots)\n"
        "  --axis CX CY CZ VX VY VZ ENDRAD: keep only capsule slices within ENDRAD of the axis\n"
        "  --with SPH...: smoothing window - the mean of these frames' fields and the centre's is marched\n"
        "  --bands E0,..,En --band-names N0,..,N(n-1): colour by the owning sphere's radius in n bands\n"
        "       %s --recolor IN.vmd_plot OUT.vmd_plot COLOUR-OPTIONS\n"
        "  (serve: recolor<TAB>IN<TAB>OUT<TAB>COLOUR-OPTIONS)  colour a draw-form mesh by property:\n"
        "  --atoms FILE|--values FILE --csph SPH [--lining residue|atom] [--facing 0|1]\n"
        "  [--thresh A] [--bandwidth A] [--signed 0|1] [--range LO HI]\n",
        a0, a0, a0);
}
/* One request: returns triangle count or -1. */
static long serve_one(const char *sph, const char *plot, const char *spec, const char *tri) {
    double a = 0, b = 0, r = 0;
    int nf = sscanf(spec, "%lf/%lf/%lf", &a, &b, &r);
    if (nf < 1 || a <= 0.05) return -1;
    h = a; hf = h; rfine = 0.0;
    if (nf >= 2 && b > 0.05 && b < h) { hf = b; rfine = (nf >= 3 && r > 0) ? r : 3.0 * h; }
    for (int i = 0; i < 3; i++) { wlo[i] = 1e30; whi[i] = -1e30; }
    for (int k = 0; k < nwith; k++) {
        if (!load_sph(with_path[k])) continue;
        sph_bbox(wlo, whi);
        sph_free_current();
    }
    if (!load_sph(sph)) return -1;
    if (nsph < 1) return -1;
    return mesh_run(tri, plot);
}
#ifdef VMDPATHFINDER_MULTICALL
int mesh_csg_main(int argc, char **argv)
#else
int main(int argc, char **argv)
#endif
{
    nm_set_default_threads();
    if (argc >= 2 && !strcmp(argv[1], "--serve")) {
        /* Persistent: one process per VMD session instead of one fork per
           frame (forking the VMD process costs ~20 ms on a loaded trajectory). */
        static char line[65536];
        setvbuf(stdout, NULL, _IOLBF, 0);
        while (fgets(line, sizeof line, stdin)) {
            if (!strncmp(line, "quit", 4)) break;
            /* tab-separated so paths may contain spaces: mesh<TAB>SPH<TAB>PLOT<TAB>VOXEL */
            size_t L = strlen(line); while (L && (line[L-1] == '\n' || line[L-1] == '\r')) line[--L] = 0;
            char *f0 = strtok(line, "\t"), *sph = strtok(NULL, "\t"), *plot = strtok(NULL, "\t"), *vs = strtok(NULL, "");
            if (!f0 || !sph || !plot || !vs) { printf("ERR bad request\n"); continue; }
#ifdef VMDPATHFINDER_MULTICALL
            if (!strcmp(f0, "tunnelcluster") || !strcmp(f0, "tunneldist")) {
                /* tunnelcluster<TAB>IN<TAB>OUT<TAB>THRESHOLD MAXDEV, tunneldist<TAB>IN<TAB>OUT<TAB>WANTMAX:
                   sos_triangle's clustering kernels, run here so a per-frame call does not fork VMD */
                double a = 0, b = 0;
                sscanf(vs, "%lf %lf", &a, &b);
                int rc = !strcmp(f0, "tunnelcluster") ? vmdpathfinder_tunnel_cluster(sph, plot, a, b)
                                                      : vmdpathfinder_tunnel_dist(sph, plot, (int)a);
                if (rc) printf("ERR %s failed\n", f0); else printf("OK 0\n");
                continue;
            }
#endif
            ax_have = 0; ax_endrad = 0; nwith = 0; bands_reset();
            char *mopt = strcmp(f0, "recolor") ? strchr(vs, '\t') : NULL;   /* VOXEL<TAB>--axis ... */
            if (mopt) { *mopt++ = 0; char *av[512]; int ac = 0;
                for (char *tok = strtok(mopt, "\t"); tok && ac < 512; tok = strtok(NULL, "\t")) av[ac++] = tok;
                axis_parse(ac, av); }
            if (!strcmp(f0, "extent")) {
                /* extent<TAB>SPH: centreline bounding box + largest radius, the
                   same records the colouring's lining test uses */
                if (!col_load_spheres(sph)) { printf("ERR no centreline\n"); continue; }
                double lo[3] = {1e30,1e30,1e30}, hi[3] = {-1e30,-1e30,-1e30}, mr = 0;
                for (int i = 0; i < ncsph; i++) {
                    if (csph[i].x < lo[0]) lo[0] = csph[i].x; if (csph[i].x > hi[0]) hi[0] = csph[i].x;
                    if (csph[i].y < lo[1]) lo[1] = csph[i].y; if (csph[i].y > hi[1]) hi[1] = csph[i].y;
                    if (csph[i].z < lo[2]) lo[2] = csph[i].z; if (csph[i].z > hi[2]) hi[2] = csph[i].z;
                    if (csph[i].x2 < lo[0]) lo[0] = csph[i].x2; if (csph[i].x2 > hi[0]) hi[0] = csph[i].x2;
                    if (csph[i].y2 < lo[1]) lo[1] = csph[i].y2; if (csph[i].y2 > hi[1]) hi[1] = csph[i].y2;
                    if (csph[i].z2 < lo[2]) lo[2] = csph[i].z2; if (csph[i].z2 > hi[2]) hi[2] = csph[i].z2;
                    if (csph[i].v > mr) mr = csph[i].v;
                }
                printf("EXT %.4f %.4f %.4f %.4f %.4f %.4f %.4f\n", lo[0], hi[0], lo[1], hi[1], lo[2], hi[2], mr);
                continue;
            }
            if (!strcmp(f0, "recolor")) {
                /* recolor<TAB>IN<TAB>OUT<TAB>opts: sph/plot are IN/OUT, vs the options */
                char *av[32]; int ac = 0; char *opt = vs;
                for (char *tok = strtok(opt, "\t"); tok && ac < 32; tok = strtok(NULL, "\t")) av[ac++] = tok;
                long n = col_run(sph, plot, ac, av);
                if (n < 0) printf("ERR recolor failed\n"); else printf("OK %ld\n", n);
                continue;
            }
            /* "mesh" addresses a molecule; "meshdraw" writes HOLE's own records */
            dots_form = 0;
            if (!strcmp(f0, "mesh")) draw_form = 0;
            else if (!strcmp(f0, "meshdraw")) draw_form = 1;
            else if (!strcmp(f0, "meshdots")) { draw_form = 1; dots_form = 1; }
            else { printf("ERR bad request\n"); continue; }
            long n = serve_one(sph, plot, vs, NULL);
            if (n < 0) printf("ERR mesh failed\n"); else printf("OK %ld\n", n);
        }
        return 0;
    }
    if (argc >= 4 && !strcmp(argv[1], "--recolor")) {
        long n = col_run(argv[2], argv[3], argc - 4, argv + 4);
        if (n < 0) { fprintf(stderr, "recolor failed\n"); return 1; }
        fprintf(stderr, "recoloured %ld triangles from %d contributors\n", n, nccon);
        return 0;
    }
    if (argc < 4) { usage(argv[0]); return 2; }
    const char *tri = NULL;
    for (int a = 4; a < argc; a++) {
        if (!strcmp(argv[a], "--tri") && a + 1 < argc) tri = argv[++a];
        else if (!strcmp(argv[a], "--draw")) draw_form = 1;
        else if (!strcmp(argv[a], "--dots")) { draw_form = 1; dots_form = 1; }
        else if (!strcmp(argv[a], "--axis") && a + 7 < argc) { axis_parse(8, argv + a); a += 7; }
        else if (!strcmp(argv[a], "--with")) { int b = a; while (b + 1 < argc && strncmp(argv[b+1], "--", 2)) b++; axis_parse(b - a + 1, argv + a); a = b; }
        else if ((!strcmp(argv[a], "--bands") || !strcmp(argv[a], "--band-names")) && a + 1 < argc) { axis_parse(2, argv + a); a++; }
        else { usage(argv[0]); return 2; }
    }
    return serve_one(argv[1], argv[2], argv[3], tri) >= 0 ? 0 : 1;
}
#endif
