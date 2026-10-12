#!/usr/bin/env python3
"""Regenerates Sources/PixmaKit/ModelTable.swift from SANE's pixma_mp150.c device table.

Usage: scripts/generate-model-table.py path/to/sane-backends/backend/pixma/pixma_mp150.c
Only facts (model names, USB product IDs, resolutions, glass sizes) are taken from the table.
"""
import re, sys

src = open(sys.argv[1]).read()
pids = {m.group(1): int(m.group(2), 16) for m in re.finditer(r'#define (\w+_PID)\s+0x([0-9a-fA-F]+)', src)}
P = lambda n: pids[n + '_PID']

def generation(pid):  # same rules as SANE's mp150_open()
    g = 2 if pid >= P('MP160') else 1
    if pid >= P('MX7600'): g = 3
    if pid >= P('MP250'): g = 4
    if pid >= P('MG2100'): g = 5
    if pid == P('MP140'): g = 2
    return g

# Models that send high-resolution lines as interleaved sub-images (see post_process_image_data()).
reorder5 = {P(x) for x in ['MG2200', 'MG3200', 'MG4200', 'MG5600', 'MG5700', 'MG6200', 'MP230', 'MX470', 'MX510', 'XK90', 'MX520']}
no_reorder = {P(x) for x in ['MP220', 'MP280', 'MX360']}

rows, seen = [], set()
for m in re.finditer(r'^\s*DEVICE \("([^"]+)",\s*"([^"]+)",\s*(\w+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*(\d+),\s*([^)]*)\)', src, re.M):
    name, model, pidn, min_dpi, dpi, _, _, w, h, cap = m.groups()
    if pidn not in pids or model in seen:
        continue
    pid = pids[pidn]
    g = generation(pid)
    if g < 3:
        continue
    seen.add(model)
    adf = 'PIXMA_CAP_ADF' in cap
    h = min(int(h), 877) if adf else int(h)   # ADF models: the glass itself is A4
    unit = 0 if pid in no_reorder else 1200 if pid == P('XK90') else 600 if (g < 5 or pid in reorder5) else 0
    rows.append(f'        .init(name: "Canon {name.replace("Canon ", "", 1)}", match: "{model}", pid: 0x{pid:04X}, '
                f'generation: {g}, minDPI: {min_dpi}, maxDPI: {dpi}, bedWidth75: {w}, bedHeight75: {h}, '
                f'hasADF: {"true" if adf else "false"}, interleaveUnit: {unit}),')

header = '''// Generated from the device table of the SANE project's `pixma_mp150` backend
// (backend/pixma/pixma_mp150.c): model names, USB product IDs, resolutions and glass sizes.
// Only PIXMA protocol generations 3–5 are included; those use the command set PixmaKit implements.
// Regenerate with scripts/generate-model-table.py.

extension PixmaModel {
    /// Every flatbed PIXMA/MAXIFY that shares the MG7150's scan protocol. Only the MG7100 series has
    /// been tested with real hardware; the others are expected to work.
    public static let table: [PixmaModel] = [
'''
open('Sources/PixmaKit/ModelTable.swift', 'w').write(header + "\n".join(rows) + "\n    ]\n}\n")
print(f"{len(rows)} models written")
