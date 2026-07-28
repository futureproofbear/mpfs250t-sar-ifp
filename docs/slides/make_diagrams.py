#!/usr/bin/env python
"""Generate the deck's figures as .drawio.svg -- ONE file that is both a rendered SVG (so Marp,
GitHub and any browser display it) and an editable draw.io document (the mxfile XML rides in the
root <svg content="..."> attribute, which is exactly what draw.io's "Editable SVG" export writes).

WHY a generator instead of hand-drawn files: the visual and the editable XML must agree. Drawing
them separately guarantees they drift the moment anyone edits one. Here a single spec emits both,
so `python make_diagrams.py` always reproduces a consistent set.

Editing: open any diagrams/*.drawio.svg directly in draw.io (File > Open) -- shapes, not a
picture. Re-running this script OVERWRITES manual edits, so either edit the spec here or stop
regenerating that file.

Usage:  python make_diagrams.py [--out diagrams]
"""
import argparse
import html
import pathlib
import subprocess
import xml.etree.ElementTree as ET

FORCE = set()        # basenames allowed to be overwritten; see --force


def _dirty_in_git(path):
    """True if `path` is tracked AND differs from HEAD, i.e. somebody edited it by hand.

    Untracked files are NOT treated as dirty: a brand-new figure has nothing to lose. If git is
    unavailable we return True and skip -- refusing to write is the safe failure here, because the
    thing being protected (a hand-drawn layout) cannot be reconstructed."""
    try:
        r = subprocess.run(["git", "status", "--porcelain", "--", str(path)],
                           capture_output=True, text=True, cwd=str(pathlib.Path(path).parent))
        if r.returncode != 0:
            return True
        line = r.stdout.strip()
        return bool(line) and not line.startswith("??")
    except Exception:
        return True

# ---------------------------------------------------------------- palette ----
# Deliberately few colours, each with a fixed meaning across every figure, so the reader learns
# the legend once. Chosen to stay legible projected and in greyscale print.
C = {
    "host":   ("#E8F0FE", "#3A6FB8"),   # host-PC / off-board
    "mss":    ("#FFF3E0", "#C77700"),   # MSS / CPU (U54 harts)
    "fab":    ("#E7F5EC", "#2E8B57"),   # fabric kernel (hand-written RTL)
    "hls":    ("#FDECEC", "#C0392B"),   # SmartHLS-generated (being retired)
    "ip":     ("#EDE7F6", "#6A4CA5"),   # hard IP (CoreFFT, interconnect)
    "mem":    ("#F5F5F5", "#666666"),   # memory (DDR / LSRAM / uSRAM)
    "ai":     ("#E3F2FD", "#1565C0"),   # agent / model
    "gate":   ("#FFFDE7", "#B8860B"),   # verification gate
    "bad":    ("#FFEBEE", "#B71C1C"),   # failure / defect
    "plain":  ("#FFFFFF", "#555555"),
}
FONT = "Helvetica,Arial,sans-serif"


class Diagram:
    """Minimal box-and-arrow builder. Emits mxGraphModel XML and matching SVG geometry."""

    def __init__(self, width, height, title=None, draw_title=True):
        """`title` always names the draw.io diagram. `draw_title=False` keeps that name but stops
        rendering it into the SVG -- use it wherever the slide heading already says the same thing,
        so the figure does not repeat it under the heading."""
        self.w, self.h, self.title = width, height, title
        self.draw_title = draw_title
        self.nodes = {}          # id -> dict
        self.edges = []
        self._n = 0

    def box(self, nid, x, y, w, h, label, style="plain", rounded=True, dashed=False, fs=13, bold=False):
        self.nodes[nid] = dict(x=x, y=y, w=w, h=h, label=label, style=style,
                               rounded=rounded, dashed=dashed, fs=fs, bold=bold)
        return nid

    def note(self, nid, x, y, w, h, label, fs=11):
        """Unboxed caption text -- for legends and annotations."""
        self.nodes[nid] = dict(x=x, y=y, w=w, h=h, label=label, style=None,
                               rounded=False, dashed=False, fs=fs, bold=False)
        return nid

    def edge(self, a, b, label="", side="auto", dashed=False, color="#444444", double=False):
        self.edges.append(dict(a=a, b=b, label=label, side=side,
                               dashed=dashed, color=color, double=double))

    # ---- geometry helpers -------------------------------------------------
    def _anchor(self, nid, other):
        """Pick the edge-crossing point on `nid`'s border facing `other`."""
        n, m = self.nodes[nid], self.nodes[other]
        ncx, ncy = n["x"] + n["w"] / 2, n["y"] + n["h"] / 2
        mcx, mcy = m["x"] + m["w"] / 2, m["y"] + m["h"] / 2
        dx, dy = mcx - ncx, mcy - ncy
        # leave by the side the target actually lies toward
        if abs(dx) * n["h"] >= abs(dy) * n["w"]:
            return (n["x"] + n["w"], ncy) if dx > 0 else (n["x"], ncy)
        return (ncx, n["y"] + n["h"]) if dy > 0 else (ncx, n["y"])

    # ---- SVG --------------------------------------------------------------
    def _svg_body(self):
        out = []
        out.append('<defs>'
                   '<marker id="ah" markerWidth="10" markerHeight="8" refX="9" refY="4" '
                   'orient="auto" markerUnits="strokeWidth">'
                   '<path d="M0,0 L10,4 L0,8 z" fill="#444444"/></marker>'
                   '<marker id="ahr" markerWidth="10" markerHeight="8" refX="1" refY="4" '
                   'orient="auto" markerUnits="strokeWidth">'
                   '<path d="M10,0 L0,4 L10,8 z" fill="#444444"/></marker>'
                   '</defs>')
        if self.title and self.draw_title:
            out.append(f'<text x="{self.w/2}" y="26" text-anchor="middle" font-family="{FONT}" '
                       f'font-size="17" font-weight="600" fill="#222">{html.escape(self.title)}</text>')
        # edges first so boxes sit on top
        for e in self.edges:
            x1, y1 = self._anchor(e["a"], e["b"])
            x2, y2 = self._anchor(e["b"], e["a"])
            dash = ' stroke-dasharray="6 4"' if e["dashed"] else ""
            end = ' marker-end="url(#ah)"'
            start = ' marker-start="url(#ahr)"' if e["double"] else ""
            out.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{e["color"]}" '
                       f'stroke-width="1.8"{dash}{end}{start}/>')
            if e["label"]:
                mx, my = (x1 + x2) / 2, (y1 + y2) / 2
                horiz = abs(x2 - x1) > abs(y2 - y1)
                ty = my - 7 if horiz else my
                tx = mx if horiz else mx + 6
                anch = "middle" if horiz else "start"
                lbl = html.escape(e["label"])
                out.append(f'<text x="{tx}" y="{ty}" text-anchor="{anch}" font-family="{FONT}" '
                           f'font-size="11" fill="#333">'
                           f'<tspan style="paint-order:stroke;stroke:#FFFFFF;stroke-width:4px">{lbl}</tspan></text>')
        for nid, n in self.nodes.items():
            if n["style"] is not None:
                fill, stroke = C[n["style"]]
                rx = 6 if n["rounded"] else 0
                dash = ' stroke-dasharray="6 4"' if n["dashed"] else ""
                out.append(f'<rect x="{n["x"]}" y="{n["y"]}" width="{n["w"]}" height="{n["h"]}" '
                           f'rx="{rx}" fill="{fill}" stroke="{stroke}" stroke-width="1.6"{dash}/>')
            lines = n["label"].split("\n")
            fs = n["fs"]
            total = len(lines) * (fs + 3)
            y0 = n["y"] + n["h"] / 2 - total / 2 + fs
            weight = "600" if n["bold"] else "400"
            for i, ln in enumerate(lines):
                col = "#111" if n["style"] is not None else "#444"
                out.append(f'<text x="{n["x"] + n["w"]/2}" y="{y0 + i*(fs+3)}" text-anchor="middle" '
                           f'font-family="{FONT}" font-size="{fs}" font-weight="{weight}" '
                           f'fill="{col}">{html.escape(ln)}</text>')
        return "\n".join(out)

    # ---- draw.io mxfile ---------------------------------------------------
    def _mxfile(self):
        mxfile = ET.Element("mxfile", host="make_diagrams.py", type="device")
        dia = ET.SubElement(mxfile, "diagram", name=self.title or "diagram", id="d0")
        model = ET.SubElement(dia, "mxGraphModel", dx="800", dy="600", grid="1", gridSize="10",
                              guides="1", tooltips="1", connect="1", arrows="1", fold="1",
                              page="1", pageScale="1",
                              pageWidth=str(self.w), pageHeight=str(self.h), math="0", shadow="0")
        root = ET.SubElement(model, "root")
        ET.SubElement(root, "mxCell", id="0")
        ET.SubElement(root, "mxCell", id="1", parent="0")
        for nid, n in self.nodes.items():
            if n["style"] is not None:
                fill, stroke = C[n["style"]]
                st = (f"rounded={1 if n['rounded'] else 0};whiteSpace=wrap;html=1;"
                      f"fillColor={fill};strokeColor={stroke};fontSize={n['fs']};"
                      f"fontFamily=Helvetica;align=center;verticalAlign=middle;")
                if n["dashed"]:
                    st += "dashed=1;"
                if n["bold"]:
                    st += "fontStyle=1;"
            else:
                st = (f"text;html=1;strokeColor=none;fillColor=none;align=center;"
                      f"verticalAlign=middle;fontSize={n['fs']};fontFamily=Helvetica;")
            cell = ET.SubElement(root, "mxCell", id=nid, value=n["label"], style=st,
                                 vertex="1", parent="1")
            ET.SubElement(cell, "mxGeometry", x=str(n["x"]), y=str(n["y"]),
                          width=str(n["w"]), height=str(n["h"]), **{"as": "geometry"})
        for i, e in enumerate(self.edges):
            st = ("edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;fontSize=11;"
                  f"strokeColor={e['color']};")
            if e["dashed"]:
                st += "dashed=1;"
            if e["double"]:
                st += "startArrow=classic;startFill=1;"
            cell = ET.SubElement(root, "mxCell", id=f"e{i}", value=e["label"], style=st,
                                 edge="1", parent="1", source=e["a"], target=e["b"])
            ET.SubElement(cell, "mxGeometry", relative="1", **{"as": "geometry"})
        return ET.tostring(mxfile, encoding="unicode")

    def write(self, path):
        content = html.escape(self._mxfile(), quote=True)
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" '
               f'xmlns:xlink="http://www.w3.org/1999/xlink" '
               f'width="{self.w}" height="{self.h}" viewBox="0 0 {self.w} {self.h}" '
               f'content="{content}">\n'
               f'<rect width="100%" height="100%" fill="#FFFFFF"/>\n'
               f'{self._svg_body()}\n</svg>\n')
        p = pathlib.Path(path)
        # REFUSE to clobber a figure the user has edited. These files open in draw.io as shapes and
        # get hand-tweaked there; an unconditional regenerate destroys that silently and the edit is
        # unrecoverable unless it was committed. A file that differs from HEAD is the user's.
        forced = p.name in FORCE or p.name.split(".")[0] in FORCE
        if p.exists() and _dirty_in_git(p) and not forced:
            print(f"  SKIPPED  {p.name}  (locally modified -- your edit is safe)")
            return path
        p.write_text(svg, encoding="utf-8")
        print(f"  wrote    {p.name}")
        return path


# ============================================================== diagrams =====

def fig_loop(out):
    """Why hardware/firmware breaks the usual agent loop: the feedback times."""
    d = Diagram(980, 400, "Feedback loops: software vs this FPGA/firmware project",
                draw_title=False)   # the slide heading already says this
    d.box("s1", 40, 70, 170, 54, "edit source", "ai")
    d.box("s2", 250, 70, 170, 54, "compile\nseconds", "gate")
    d.box("s3", 460, 70, 170, 54, "test\nseconds", "gate")
    d.box("s4", 670, 70, 250, 54, "result\nsame minute", "fab", bold=True)
    d.edge("s1", "s2"); d.edge("s2", "s3"); d.edge("s3", "s4")
    d.note("sl", 40, 20, 880, 24, "SOFTWARE  —  a wrong implementation costs seconds, so guessing is cheap", fs=13)

    d.note("hl", 40, 150, 880, 24, "FABRIC / FIRMWARE  —  a wrong implementation costs most of a day", fs=13)
    d.box("h1", 40, 195, 150, 58, "edit RTL", "ai")
    d.box("h2", 215, 195, 150, 58, "synth + P&R\n~50 min", "gate")
    d.box("h3", 390, 195, 150, 58, "program +\neNVM  ~5 min", "gate")
    d.box("h4", 565, 195, 150, 58, "power-cycle\nHUMAN", "bad")
    d.box("h5", 740, 195, 180, 58, "load scene\n81 s (eMMC)", "gate")
    d.edge("h1", "h2"); d.edge("h2", "h3"); d.edge("h3", "h4"); d.edge("h4", "h5")
    d.box("h6", 740, 290, 180, 52, "run + CRC\n~30 s", "fab", bold=True)
    d.edge("h5", "h6")
    d.box("h7", 40, 290, 660, 52,
          "and DDR is volatile: a power-cycle wipes both the scene AND every runtime knob", "bad")
    d.edge("h6", "h7")
    return d.write(out / "fig-loop.drawio.svg")


def fig_orchestration(out):
    """The orchestration model: main loop, subagents, skills, memory, gates.

    ROUTING NOTE: do NOT draw one edge per subagent. The renderer joins box borders with a straight
    segment, so a fan-out to eight boxes passes BEHIND the intermediate ones and only the gaps show
    -- which reads as `agent -> agent -> agent`, a pipeline. The subagents are independent and each
    returns to the main agent, so that reading is exactly backwards. One arrow into the group box
    says "any of these" without implying an order."""
    d = Diagram(1020, 560, "Orchestration model", draw_title=False)
    d.box("user", 30, 40, 160, 50, "engineer", "host", bold=True)
    d.box("main", 30, 128, 160, 74, "main agent\n(plans, decides,\nreports)", "ai", bold=True)
    d.edge("user", "main", "intent", double=True)

    # Container first (paints behind). MEMORY and SKILLS are both things the main agent draws on --
    # a mem -> sk arrow would claim skills come FROM memory, which is not the relationship.
    d.box("res", 22, 240, 176, 232, "", "plain", dashed=True)
    d.box("mem", 34, 262, 152, 92, "MEMORY\nCLAUDE.md rules\nrunbooks\nMEMORY.md facts", "mem")
    d.box("sk", 34, 380, 152, 76, "SKILLS\npackaged\nprocedures", "gate")
    d.edge("main", "res", "uses", double=True)

    # Container FIRST so it paints behind the agent boxes it encloses.
    d.box("pool", 250, 60, 740, 160, "", "plain", dashed=True)
    d.note("ca", 250, 26, 740, 30,
           "SUBAGENTS  —  each with its own tools, prompt and evidence bar. The sub-agents\n"
           "focus on specific tasks, and each returns a recommendation / conclusion.", fs=12)
    names = [("fpga-ref-\nverifier", 0, 0), ("architectural-\ncritic", 1, 0),
             ("ingestion-\ntriage", 2, 0), ("smartdebug-\nplanner", 3, 0),
             ("synthesis-\nrepair", 0, 1), ("libero-build", 1, 1),
             ("silicon-test-\nrunner", 2, 1), ("doc-accuracy", 3, 1)]
    for i, (nm, cx, cy) in enumerate(names):
        d.box(f"a{i}", 268 + cx * 182, 78 + cy * 82, 164, 64, nm, "ai")
    # ONE edge, into the group -- see the routing note above.
    d.edge("main", "pool", "invoke", dashed=True, color="#7A96B8", double=True)

    d.note("gl", 250, 250, 740, 22, "GATES  —  nothing advances without passing the one before it", fs=12)
    d.box("g1", 250, 282, 168, 62, "model gate\nbit-exact\nvs C", "gate")
    d.box("g2", 442, 282, 168, 62, "testbench\n+ mutation", "gate")
    d.box("g3", 634, 282, 168, 62, "timing gate\nsetup AND\nhold MET", "gate")
    d.box("g4", 826, 282, 164, 62, "silicon CRC\n0x319037b2\nbit-exact", "gate")
    d.edge("g1", "g2"); d.edge("g2", "g3"); d.edge("g3", "g4")

    d.box("hw", 826, 400, 164, 66, "the board\n(scarce, serial,\nhuman-gated)", "bad", bold=True)
    d.edge("g4", "hw")
    return d.write(out / "fig-orchestration.drawio.svg")


def fig_gates(out):
    """The board-free-first ladder, with what each rung actually caught."""
    d = Diagram(1000, 520, "The gate ladder — and what each rung really caught",
                draw_title=False)
    rows = [
        ("Python model vs C, bit-exact", "gate",
         "caught: pass-1 arithmetic before any RTL existed"),
        ("RTL testbench + mutation battery", "gate",
         "caught: 3 corner-turn bugs; a TB that cannot fail is worthless"),
        ("RE-ARM the same instance, no reset", "bad",
         "caught: corner-turn reported done instantly on every run after the first"),
        ("Synthesis + place & route", "gate",
         "caught: nothing functional — it passed the broken design"),
        ("Timing: setup AND hold MET", "gate",
         "caught: nothing here — a timing-failing bitstream programs silently"),
        ("Silicon: CRC bit-exact + timing", "fab",
         "THE gate. Everything above only earns the right to reach it"),
    ]
    y = 60
    prev = None
    for i, (label, style, note) in enumerate(rows):
        nid = f"r{i}"
        d.box(nid, 60, y, 380, 56, label, style, bold=(i == 5))
        d.note(f"n{i}", 470, y, 480, 56, note, fs=12)
        if prev:
            d.edge(prev, nid)
        prev = nid
        y += 74
    d.note("cap", 60, 470, 890, 40,
           "Cost per rung rises ~10x. The discipline is not 'test more', it is 'fail as early and "
           "as cheaply as possible' —\nand to distrust any rung that has never actually rejected anything.", fs=12)
    return d.write(out / "fig-gates.drawio.svg")


def fig_pfa(out):
    """The SAR signal-processing chain (algorithm level)."""
    d = Diagram(1020, 400, "Polar Format Algorithm — the processing chain",
                draw_title=False)
    d.box("in", 30, 120, 140, 70, "CPHD\nphase history\n(pulses x samples)", "host")
    d.box("s1", 200, 120, 150, 70, "1. Keystone\nresample\n(2-D interp)", "fab")
    d.box("s2", 380, 120, 140, 70, "2. Window\nHamming taper\n(fused)", "fab", dashed=True)
    d.box("s3", 550, 120, 140, 70, "3. FFT-1\n8192-pt", "ip")
    d.box("s4", 720, 120, 140, 70, "4. Corner-turn\ntranspose", "fab")
    d.box("s5", 720, 230, 140, 70, "5. FFT-2\n8192-pt", "ip")
    d.box("s6", 550, 230, 140, 70, "6. Detect\n|z| magnitude\n(fused)", "fab", dashed=True)
    d.box("out", 380, 230, 140, 70, "focused image\n8192 x 8192\nuint16", "host", bold=True)
    for a, b in [("in", "s1"), ("s1", "s2"), ("s2", "s3"), ("s3", "s4")]:
        d.edge(a, b)
    d.edge("s4", "s5"); d.edge("s5", "s6"); d.edge("s6", "out")
    d.note("trap", 30, 320, 960, 60,
           "NAMING TRAP, load-bearing: the field names are inverted. `rangeFFT` IS FFT-1 and performs the "
           "AZIMUTH transform;\n`azFFT` IS FFT-2 and performs the RANGE transform. Every table in this deck "
           "uses the physical meaning, not the field name.", fs=12)
    d.note("fu", 30, 40, 960, 44,
           "Dashed = no kernel of its own. Window is fused into the FFT-1 feeder and detect into the FFT-2 "
           "unloader,\nso two of the six stages cost zero time and zero DDR passes.", fs=12)
    return d.write(out / "fig-pfa.drawio.svg")


def fig_fabric(out):
    """Fabric block diagram: what is actually instantiated and how it is wired."""
    d = Diagram(1060, 560, "Fabric implementation — SAR_TOP",
                draw_title=False)
    d.box("mss", 30, 56, 190, 78, "MSS\n4x U54 @ 600 MHz\ndispatcher + 3 workers", "mss", bold=True)
    d.box("cic", 30, 168, 190, 50, "CIC\ncontrol interconnect", "ip")
    d.edge("mss", "cic", "AXI4-Lite")

    d.box("ddr", 840, 50, 190, 84, "DDR4  2 GiB\nfabric window\n0x8000_0000-0xBFFF_FFFF", "mem", bold=True)
    d.box("dic", 840, 168, 190, 50, "DIC\ndata interconnect", "ip")
    d.box("fic", 840, 246, 190, 50, "FIC_0  64-bit @ 100 MHz\nceiling ~800 MB/s", "ip")
    d.edge("dic", "ddr", "", double=True)
    d.edge("fic", "dic", "", double=True)

    # CoreFFT chain A, strictly left-to-right so the dataflow reads in one direction
    d.note("ca", 250, 222, 560, 18, "CoreFFT chain A   (chain B is a second identical instance)", fs=11)
    d.box("coef", 235, 246, 100, 50, "COEFG\ncoeffgen", "fab")
    d.box("feed", 395, 246, 120, 50, "FEED\nfeeder+gather\n+window", "fab")
    d.box("gbx", 535, 246, 55, 50, "GBX", "fab")
    d.box("fft", 610, 246, 90, 50, "CoreFFT\n8192-pt", "ip")
    d.box("unld", 720, 246, 100, 50, "UNLD\nunloader\n+detect", "fab")
    d.edge("coef", "feed", "idx/wq")
    d.edge("feed", "gbx")
    d.edge("gbx", "fft")
    d.edge("fft", "unld")

    d.box("ct", 375, 340, 130, 50, "CT\ncorner_turn_v", "fab", bold=True)
    d.box("res", 560, 340, 165, 50, "RES\nresample (SmartHLS)", "hls")

    for k in ["feed", "unld", "ct", "res"]:
        d.edge(k, "fic", "", dashed=True, color="#8AA")
    for k in ["coef", "ct", "res"]:
        d.edge("cic", k, "", dashed=True, color="#CBA")

    d.note("leg", 30, 410, 1000, 18,
           "green = hand-written Verilog   |   red = SmartHLS (the last one in the datapath)   "
           "|   purple = hard IP   |   grey = memory", fs=11)
    d.note("n1", 30, 438, 1000, 60,
           "Two complete chains run concurrently on disjoint row blocks (SAR_FFTBLK = 64 rows). "
           "Everything reaches DDR through\nONE 64-bit port, FIC_0 — so the interconnect, not the "
           "kernel count, is the shared resource every optimisation runs into.\nCoreFFT sits in a "
           "SEPARATE 12.5 MHz domain (SLOWCLK); the gearbox GBX crosses 64-bit @ 100 MHz to its stream rate.", fs=11)
    d.note("n2", 30, 508, 1000, 34,
           "Window and detect have NO block of their own — they are fused into the feeder and the "
           "unloader respectively,\nwhich is why the stage table reports 0 s for both: the work happens "
           "inside another kernel's existing DDR pass.", fs=11)
    return d.write(out / "fig-fabric.drawio.svg")


def fig_dataflow(out):
    """DDR buffer flow per frame + where the on-chip memory actually goes."""
    d = Diagram(1040, 620, "Data movement — DDR buffers and on-chip memory",
                draw_title=False)
    d.note("h1", 40, 34, 960, 20, "Every stage is a DDR-to-DDR streaming pass. The frame never fits on-chip.", fs=13)
    d.box("sig", 60, 70, 150, 60, "SIG\nraw signal", "mem", bold=True)
    d.box("scr", 300, 70, 150, 60, "SCRATCH", "mem", bold=True)
    d.box("sig2", 540, 70, 150, 60, "SIG\n(reused)", "mem")
    d.box("out", 800, 70, 170, 60, "OUT\nuint16 image", "mem", bold=True)

    d.box("p1", 60, 170, 150, 50, "resample\n+ CT#1", "fab")
    d.box("p2", 300, 170, 150, 50, "FFT-1", "ip")
    d.box("p3", 540, 170, 150, 50, "CT#2 + FFT-2\noverlapped", "fab")
    d.edge("sig", "p1"); d.edge("p1", "scr", "write")
    d.edge("scr", "p2"); d.edge("p2", "sig2", "write")
    d.edge("sig2", "p3"); d.edge("p3", "out", "write")

    d.box("warn", 60, 250, 910, 46,
          "ONE ELOD PER PIPE RUN — the internal corner-turn writes SIG, so a frame OVERWRITES ITS OWN INPUT. "
          "A second run without reloading silently processes the previous run's intermediate data.", "bad")

    d.note("h2", 40, 320, 960, 20, "On-chip memory: 412 of 812 LSRAM blocks (50.7%), 866 uSRAM", fs=13)
    bars = [("CT  corner-turn", 128), ("RES resample", 66), ("FEED x2", 108),
            ("COEFG x2", 64), ("FFT x2", 42), ("UNLD x2", 4)]
    y = 352
    for i, (name, blocks) in enumerate(bars):
        w = int(blocks * 5.2)
        d.note(f"lb{i}", 60, y, 150, 26, name, fs=12)
        d.box(f"bar{i}", 220, y, max(w, 26), 26, str(blocks), "fab" if i != 1 else "hls", fs=11)
        y += 32
    d.note("n3", 780, 352, 200, 190,
           "The hand-written\ncorner-turn is the\nlargest consumer at\n128 blocks — ~3x the\n"
           "SmartHLS kernel it\nreplaced.\n\nIt bought 6.71 s\nper frame.", fs=12)
    d.note("cap", 40, 552, 960, 56,
           "Why so much: the corner-turn double-buffers full-width tiles so FILL and DRAIN overlap. That is "
           "exactly what took\nits idle time from 41.5% to 2.0% — the memory is spent to keep the DDR port "
           "asking for data continuously.", fs=12)
    return d.write(out / "fig-dataflow.drawio.svg")


def fig_timing(out):
    """Where the frame time goes, and where it went."""
    d = Diagram(1000, 560, "Timing — 110.8 s to 18.45 s, every step measured on silicon",
                draw_title=False)
    d.note("h1", 40, 40, 920, 20, "Frame time, bit-exact at CRC 0x319037b2 throughout", fs=13)
    steps = [("110.8 s", 620, "first working pipeline", "bad"),
             ("37.72 s", 320, "fabric FFT + fusion", "hls"),
             ("25.16 s", 214, "multi-hart coeffs, 2nd chain, renorm epilogue", "gate"),
             ("18.45 s", 157, "hand-written corner-turn", "fab")]
    y = 76
    for i, (lab, w, note, st) in enumerate(steps):
        d.box(f"b{i}", 60, y, w, 42, lab, st, bold=(i == 3), fs=14)
        d.note(f"t{i}", 700, y, 280, 42, note, fs=12)
        y += 54
    d.note("h2", 40, 300, 920, 20, "Current stage split — no dominant stage remains", fs=13)
    st = [("resample  7.267 s", 300, "gather 5.212 + CT#1 2.064"),
          ("range-FFT 5.788 s", 239, "FFT-1 = the AZIMUTH transform"),
          ("azimuth-FFT 5.396 s", 223, "FFT-2 = the RANGE transform, CT#2 hidden inside")]
    y = 334
    for i, (lab, w, note) in enumerate(st):
        d.box(f"s{i}", 60, y, w, 40, lab, "ip", fs=13)
        d.note(f"sn{i}", 380, y, 600, 40, note, fs=12)
        y += 50
    d.note("clk", 40, 494, 920, 60,
           "Two clock domains: fabric 100 MHz (setup slack +0.182 ns on a ~9.82 ns path — essentially none "
           "left) and\nCoreFFT SLOWCLK 12.5 MHz (+67.8 ns). Raising the fabric clock needs path surgery "
           "first, not optimism.", fs=12)
    return d.write(out / "fig-timing.drawio.svg")


def fig_bug(out):
    """The re-arm bug: the deck's concrete example of why the gates are shaped this way."""
    d = Diagram(1000, 500, "One bug, and why every gate above silicon missed it",
                draw_title=False)
    d.box("rtl", 40, 70, 300, 130,
          "corner_turn_v.v\n\nbusy <= 1'b1;  fill_done <= 1'b0;\n...\nif (fill_done && ...) busy <= 1'b0;",
          "bad")
    d.note("expl", 370, 70, 600, 130,
           "Both assignments live in ONE always block. `fill_done <= 1'b0` is non-blocking, so the\n"
           "later line still reads the PREVIOUS run's 1 — and being later, its `busy <= 1'b0` wins.\n\n"
           "The kernel therefore works exactly ONCE per reset. Every start after the first\n"
           "reports 'done' immediately and the pipeline runs on untransposed data.", fs=12)
    y = 240
    checks = [("Model gate (bit-exact vs C)", "passed — it never runs the RTL", "gate"),
              ("Testbench, 3 cases, bit-exact", "passed — each case RESET before its single run", "gate"),
              ("Mutation battery", "passed — mutants were caught; the blind spot was structural", "gate"),
              ("Synthesis / place & route", "passed", "gate"),
              ("Timing, setup AND hold", "passed", "gate"),
              ("Silicon CRC", "FAILED — 0x1e8226cf, then a hang", "bad")]
    for i, (name, res, st) in enumerate(checks):
        d.box(f"c{i}", 40, y, 300, 34, name, st, fs=12)
        d.note(f"r{i}", 370, y, 600, 34, res, fs=12)
        y += 40
    d.note("fix", 40, 470, 930, 24,
           "Fix: one guard. Real lesson: the BENCH was the defect — it could not express 're-arm', so it could not fail.", fs=12)
    return d.write(out / "fig-bug.drawio.svg")


def fig_arch_pipeline(out):
    """ARCHITECTURE.md Figure 1. Lives in docs/img/, not the deck -- the architecture doc owns it.

    Replaces a hand-authored SVG that drifted a full generation behind its own caption (it showed
    37.72 s and the 62.5 MHz stage split while the caption said 18.45 s). Generated so the next
    baseline change is a one-line edit here rather than SVG surgery."""
    d = Diagram(1080, 380, "Figure 1 — SAR pipeline dataflow (18.45 s baseline, CRC 0x319037b2)",
                draw_title=False)
    d.box("sig", 30, 96, 120, 62, "SIG\nraw signal", "mem", bold=True)
    d.box("s1", 175, 96, 150, 62, "1. Resample\nrange gather\n5.212 s", "fab")
    d.box("ct1", 350, 96, 140, 62, "CT#1\ntranspose\n2.064 s", "fab")
    d.box("f1", 515, 96, 165, 62, "3. FFT-1  AZIMUTH\n+ gather + window\n5.788 s", "ip")
    d.box("ct2", 705, 96, 140, 62, "CT#2\n(hidden under\nFFT-2)", "fab", dashed=True)
    d.box("f2", 870, 96, 180, 62, "5. FFT-2  RANGE\n+ detect\n5.396 s", "ip")
    d.edge("sig", "s1"); d.edge("s1", "ct1", "SCRATCH")
    d.edge("ct1", "f1", "SIG"); d.edge("f1", "ct2", "SCRATCH")
    d.edge("ct2", "f2", "SIG")
    d.box("out", 870, 196, 180, 50, "OUT\nuint16 image", "mem", bold=True)
    d.edge("f2", "out")
    d.note("t", 30, 200, 800, 44,
           "resample 7.267 s  =  range gather 5.212 + CT#1 2.064        TOTAL 18.45 s\n"
           "Window is fused into the FFT-1 feeder and detect into the FFT-2 unloader: neither has a kernel.", fs=12)
    d.note("n", 30, 262, 1020, 96,
           "CT#2 is dashed because it has no wall-clock line of its own: with OVLMODE=1 it is "
           "strip-pipelined UNDER FFT-2\n(fft2_ct_overlap), so the stage timer attributes the merged time to "
           "FFT-2.\n\nNAMING TRAP: the code calls FFT-1 `rangeFFT` and FFT-2 `azFFT` — inverted. The labels "
           "above are the PHYSICAL axes.", fs=12)
    return d.write(out / "sar_pipeline.drawio.svg")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default="diagrams")
    ap.add_argument("--force", nargs="+", metavar="FIG", default=[],
                    help="overwrite ONLY these figures despite uncommitted local edits, by "
                         "basename (e.g. --force fig-orchestration). There is deliberately no "
                         "blanket form: a global override once clobbered an unrelated figure the "
                         "user had edited.")
    a = ap.parse_args()
    global FORCE
    FORCE = set(a.force)
    here = pathlib.Path(__file__).resolve().parent
    out = here / a.out
    out.mkdir(parents=True, exist_ok=True)
    for fn in (fig_loop, fig_orchestration, fig_gates, fig_pfa,
               fig_fabric, fig_dataflow, fig_timing, fig_bug):
        fn(out)
    # ARCHITECTURE.md Figure 1 lives with the doc that owns it, not with the deck
    img = (here / ".." / "img").resolve()
    img.mkdir(parents=True, exist_ok=True)
    fig_arch_pipeline(img)


if __name__ == "__main__":
    main()
