#!/usr/bin/env python3
"""Generate HOLE radius files for Martini 2.2 and Martini 3 beads.

Writes vmdpathfinder/rad/martini2.rad and martini3.rad from the force-field
sources (fetched from GitHub at pinned commits, Apache-2.0):

  Martini 3  bead types per residue/atom: vermouth-martinize martini3001/*.ff
             and marrink-lab/martini-forcefields gmx_files/*.itp [atoms];
             bead size: the self sigma on the nonbond_params diagonal of
             martini_v3.0.0.itp.
  Martini 2.2 bead types per residue/atom: vermouth-martinize martini22/*.ff;
             bead size: 0.47 nm, ring (S*) beads 0.43 nm (Marrink 2007).

Radius = sigma / 2 in Angstrom. HOLE reads the residue as 3 characters, so
4-character names (POPC) are truncated; a conflict between two residues
sharing a prefix keeps the larger radius and is listed in the file header.

    python3 tools/martini_rad.py [--out vmdpathfinder/rad] [--cache DIR]
"""
import argparse
import collections
import os
import re
import sys
import urllib.request

RAW = "https://raw.githubusercontent.com"
FF_REPO = "marrink-lab/martini-forcefields"
FF_SHA = "784591ebdc91"
VM_REPO = "marrink-lab/vermouth-martinize"
VM_SHA = "cfcad6ecc231"

M3_ITPS = [
    "martini_v3.0.0.itp",
    "martini_v3.0.0_ions_v1.itp",
    "martini_v3.0.0_nucleobases_v1.itp",
    "martini_v3.0.0_phospholipids_v1.itp",
    "martini_v3.0.0_solvents_v1.itp",
]
# HOLE reads at most 100 VDWR rules (MAXLST in horadr.f), so the file is
# compressed with wildcards and limited to what a pore analysis meets:
# proteins, water, ions, lipids and nucleobases. Any other bead falls to
# the regular-bead catch-all (2.35 A; small and tiny beads would be 2.05 / 1.70).
MAX_RULES = 100
SOLVENT_KEEP = ("W",)   # water beads only, not DMSO/ACN/...
M3_FF = ["05-aminoacids.ff"]
M2_FF = ["05-aminoacids.ff", "15-nucleotides.ff"]

CATCHALL = 2.35   # a regular bead, sigma 0.47 nm


def fetch(url, cache):
    name = os.path.join(cache, re.sub(r"[^A-Za-z0-9._-]", "_", url.split("//", 1)[1]))
    if not os.path.exists(name):
        os.makedirs(cache, exist_ok=True)
        with urllib.request.urlopen(url) as r, open(name, "wb") as f:
            f.write(r.read())
    with open(name, encoding="utf-8", errors="replace") as f:
        return f.read()


def sections(text):
    """Yield (section_name, [data lines]) for a GROMACS-style file."""
    cur, buf = None, []
    for raw in text.splitlines():
        line = raw.split(";", 1)[0].strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[\s*(\S+)\s*\]$", line)
        if m:
            if cur:
                yield cur, buf
            cur, buf = m.group(1).lower(), []
            continue
        buf.append(line)
    if cur:
        yield cur, buf


def atoms_of(text):
    """(residue, atom, beadtype) triples from every [atoms] section.
    vermouth .ff files may write a bead type as a $macro from [ macros ]."""
    out, macros = [], {}
    for sec, lines in sections(text):
        if sec == "macros":
            for l in lines:
                p = l.split(None, 1)
                if len(p) == 2:
                    macros[p[0]] = p[1].strip()
            continue
        if sec != "atoms":
            continue
        for l in lines:
            p = l.split()
            if len(p) < 5 or p[1].startswith("{"):
                continue
            # id type resnr residue atom ...
            bt = macros.get(p[1][1:], p[1]) if p[1].startswith("$") else p[1]
            out.append((p[3], p[4], bt))
    return out


def m3_sigma(itp):
    sig = {}
    for sec, lines in sections(itp):
        if sec != "nonbond_params":
            continue
        for l in lines:
            p = l.split()
            if len(p) >= 4 and p[0] == p[1]:
                sig[p[0]] = float(p[3])
    return sig


def m2_sigma(beadtype):
    return 0.43 if beadtype.startswith("S") else 0.47


def build_rules(triples, sigma_of, label):
    """{(atom4, res3): radius}, plus a list of prefix conflicts.
    HOLE reads 3 residue characters, so CYSP collapses onto CYS: a residue
    whose name IS the 3-character key wins, else the first source listed."""
    order = {}
    for i, (res, atom, bt) in enumerate(triples):
        order.setdefault((atom[:4].upper(), res[:3].upper(), res), i)
    rules, chosen, seen = {}, {}, collections.defaultdict(dict)
    for res, atom, bt in triples:
        s = sigma_of(bt)
        if s is None:
            print(f"{label}: no sigma for bead type {bt} ({res} {atom})", file=sys.stderr)
            continue
        key = (atom[:4].upper(), res[:3].upper())
        r = round(s * 5.0, 2)   # sigma nm -> radius A = sigma*10/2
        seen[key][res] = r
        rank = (0 if len(res) == 3 else 1, order[(key[0], key[1], res)])
        if key not in rules or rank < chosen[key]:
            rules[key], chosen[key] = r, rank
    conflicts = [(k, v) for k, v in seen.items() if len(set(v.values())) > 1]
    return rules, conflicts


def compress(rules):
    """Fewest first-match VDWR lines reproducing {(atom, res): radius}.
    Beads at the catch-all radius need no line. An atom name with one radius
    everywhere gets one wildcard line; a mixed name gets its minority residues
    as exceptions before the majority wildcard."""
    byatom = collections.defaultdict(dict)
    for (atom, res), r in rules.items():
        byatom[atom][res] = r
    specific, wild = [], []
    for atom, byres in sorted(byatom.items()):
        cnt = collections.Counter(byres.values())
        maj = cnt.most_common(1)[0][0]
        for res, r in sorted(byres.items()):
            if r != maj:
                specific.append((atom, res, r))
        if maj != CATCHALL:
            wild.append((atom, "???", maj))
    return specific + wild


def check(lines, rules):
    """Every (atom, res) resolves to its radius by first match."""
    import fnmatch
    for (atom, res), r in rules.items():
        for a, rr, v in lines:
            if fnmatch.fnmatchcase(atom, a.replace("?", "?")) and (rr == "???" or rr == res):
                assert v == r, (atom, res, r, v)
                break
        else:
            assert r == CATCHALL, (atom, res, r)


def dump_table(path, rules):
    with open(path, "w") as f:
        for (atom, res), r in sorted(rules.items(), key=lambda kv: (kv[0][1], kv[0][0])):
            f.write(f"{atom}\t{res}\t{r:.2f}\n")


def write_rad(path, rules, conflicts, header):
    lines = [f"remark: {h}" for h in header]
    lines.append("remark: radius = sigma/2. Residue names are the 3 characters HOLE reads.")
    lines.append("remark: HOLE reads at most 100 VDWR lines: a bead at the regular size has no")
    lines.append("remark: line of its own, the last line covers it.")
    if conflicts:
        lines.append("remark: residues sharing a 3-character name (the exact name wins):")
        for (atom, res), byres in sorted(conflicts):
            lines.append("remark:   " + atom + " " + res + " " + " ".join(f"{n}={r}" for n, r in sorted(byres.items())))
    vdwr = compress(rules)
    check(vdwr, rules)
    if len(vdwr) + 1 > MAX_RULES:
        raise SystemExit(f"{path}: {len(vdwr) + 1} VDWR lines exceed HOLE's limit of {MAX_RULES}")
    for atom, res, r in vdwr:
        lines.append(f"VDWR {atom:<4} {res:<3} {r:.2f}")
    lines.append("remark: any other bead: a regular Martini bead")
    lines.append(f"VDWR ???? ??? {CATCHALL:.2f}")
    lines.append("remark: bond radii are only read by HOLE's molqpt option")
    lines.append("BOND ???? 1.00")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")
    return len(vdwr) + 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "vmdpathfinder", "rad"))
    ap.add_argument("--cache", default=os.path.join(os.path.dirname(__file__), ".martini_cache"))
    ap.add_argument("--table", help="also write every (atom residue radius) before compression to this TSV prefix")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    # ---- Martini 3
    itp_base = f"{RAW}/{FF_REPO}/{FF_SHA}/martini_forcefields/regular/v3.0.0/gmx_files/"
    ff_base = f"{RAW}/{VM_REPO}/{VM_SHA}/vermouth/data/force_fields/martini3001/"
    sig3 = m3_sigma(fetch(itp_base + M3_ITPS[0], a.cache))
    triples = []
    for n in M3_FF:
        triples += atoms_of(fetch(ff_base + n, a.cache))
    for n in M3_ITPS[1:]:
        t = atoms_of(fetch(itp_base + n, a.cache))
        if "solvents" in n:
            t = [x for x in t if x[0] in SOLVENT_KEEP]
        triples += t
    rules, conflicts = build_rules(triples, sig3.get, "martini3")
    if a.table:
        dump_table(a.table + "3.tsv", rules)
    n3 = write_rad(os.path.join(a.out, "martini3.rad"), rules, conflicts, [
        "Martini 3 bead radii for HOLE (generated by tools/martini_rad.py)",
        f"bead types: {VM_REPO}@{VM_SHA} martini3001/{{{','.join(M3_FF)}}} and",
        f"            {FF_REPO}@{FF_SHA} gmx_files/{{{','.join(M3_ITPS[1:])}}}",
        f"bead size:  self sigma, nonbond_params of {M3_ITPS[0]} (same commit)",
        "sources are Apache-2.0; Souza et al. (2021) Nat. Methods 18, 382",
        "covers proteins, water, ions, phospholipids and nucleobases",
    ])

    # ---- Martini 2.2
    ff_base = f"{RAW}/{VM_REPO}/{VM_SHA}/vermouth/data/force_fields/martini22/"
    triples = []
    for n in M2_FF:
        triples += atoms_of(fetch(ff_base + n, a.cache))
    # solvent and ions are not in vermouth's protein force field: published values
    triples += [("W", "W", "P4"), ("WF", "WF", "BP4"),
                ("PW", "W", "POL"), ("PW", "WP", "D"), ("PW", "WM", "D"),
                ("NA+", "NA+", "Qd"), ("CL-", "CL-", "Qa"),
                ("NA", "NA", "Qd"), ("CL", "CL", "Qa"), ("ION", "NA", "Qd"), ("ION", "CL", "Qa")]

    # martinize2 writes histidine as HIS (and Amber names HID/HIE/HIP occur in
    # inputs); vermouth's martini22 names only the CHARMM tautomers
    for new, src in (("HIS", "HSE"), ("HIE", "HSE"), ("HID", "HSD"), ("HIP", "HSP")):
        triples += [(new, atom, bt) for res, atom, bt in list(triples) if res == src]

    def sig2(bt):
        if bt == "D":
            return 0.0   # polarizable water charge sites carry no LJ
        return m2_sigma(bt)
    rules, conflicts = build_rules(triples, sig2, "martini2")
    if a.table:
        dump_table(a.table + "2.tsv", rules)
    n2 = write_rad(os.path.join(a.out, "martini2.rad"), rules, conflicts, [
        "Martini 2.2 bead radii for HOLE (generated by tools/martini_rad.py)",
        f"bead types: {VM_REPO}@{VM_SHA} martini22/{{{','.join(M2_FF)}}} (Apache-2.0)",
        "bead size:  0.47 nm, ring (S*) beads 0.43 nm - Marrink et al. (2007)",
        "            J. Phys. Chem. B 111, 7812; de Jong et al. (2013) JCTC 9, 687",
        "water W/WF/PW and ions NA+/CL- (and NA/CL) added from the same papers",
    ])
    print(f"martini3.rad: {n3} rules; martini2.rad: {n2} rules")


if __name__ == "__main__":
    main()
