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


def fig_python(out):
    """The host-side Python layer: a ladder of models, each closer to the silicon.

    This is what 'verification' actually means on this project -- not an agent, but a chain of
    references where each rung can reject the one below it."""
    d = Diagram(1060, 470, "Python-level implementation", draw_title=False)
    d.box("cphd", 30, 92, 130, 66, "CPHD\nphase history\n(Umbra open data)", "host", bold=True)

    d.box("f1", 200, 60, 165, 60, "form_image_pfa\nfloat PFA\nreference", "host")
    d.box("f2", 200, 148, 165, 60, "form_image_pfa_fixed\n+ fixedpoint\nBFP emulation", "gate")
    d.box("cmp", 400, 104, 130, 60, "compare_\nfloat_fixed\nGeoTIFF diff", "gate")
    d.edge("cphd", "f1"); d.edge("cphd", "f2")
    d.edge("f1", "cmp"); d.edge("f2", "cmp")

    d.box("emu", 570, 104, 165, 60, "silicon_emulator\nBIT-ACCURATE\nmirror of the board", "fab", bold=True)
    d.edge("f2", "emu")

    d.box("ser", 200, 250, 165, 58, "serialize_inputs\nCPHD -> staged\nDDR binaries", "host")
    d.edge("cphd", "ser")
    d.box("pipe", 400, 250, 130, 58, "sar_pipeline\nhost-side\norchestration", "host")
    d.box("acc", 570, 250, 165, 58, "accel  backend.focus()\nnumpy  <->  board", "mss", bold=True)
    d.edge("ser", "pipe"); d.edge("pipe", "acc")

    d.box("board", 800, 176, 175, 62, "the board\nOUT image\n+ crop CRC", "bad", bold=True)
    d.edge("acc", "board"); d.edge("emu", "board", "predicts", dashed=True, double=True)

    d.note("n1", 30, 340, 1000, 46,
           "Each rung can REJECT the one below it. float vs fixed answers 'did quantisation break the "
           "algorithm?';\nemulator vs board answers 'does the silicon do what we modelled?' -- and it is "
           "bit-accurate, so the answer is yes/no, not a correlation.", fs=12)
    d.note("n2", 30, 398, 1000, 46,
           "accel.py is the seam: the SAME call runs on numpy or on the fabric, so the board is A/B-able "
           "against its own model.\nThat is why a wrong image is traceable to a stage rather than to "
           "'somewhere in the pipeline'.", fs=12)
    return d.write(out / "fig-python.drawio.svg")


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


# ---------------------------------------------------------------------------------------------
# Figures for docs/slides/sar-processor-design.md. Kept in this generator rather than authored as
# loose SVG so the rendered picture and the embedded draw.io XML can never disagree.
# ---------------------------------------------------------------------------------------------
def fig_sar_python(out):
    """Part 2 -- the Python reference pipeline, with the mathematics of each stage."""
    d = Diagram(1180, 470, "Python reference pipeline (PFA) -- stage mathematics",
                draw_title=False)
    d.box("cphd", 24, 150, 140, 78, "CPHD\nphase history\nM x N complex", "host")
    d.box("geo", 24, 262, 140, 68, "geometry\nf0, df, pr, tan_s", "host")
    d.box("r1", 196, 150, 180, 78,
          "1. range resample\nkr = 2pr/c (f0 + j df)\nt = (KR - x0)/dx", "fab")
    d.box("r2", 408, 150, 180, 78,
          "2. azimuth resample\nu = KC / kr\nmerge scan on tan_s", "fab")
    d.box("w", 620, 150, 150, 78,
          "3. window\nw[r,c] = wr[r] wc[c]\nHamming", "fab", dashed=True)
    d.box("f", 802, 150, 150, 78, "4. 2-D FFT\nseparable:\ntwo 1-D passes", "ip")
    d.box("det", 984, 150, 160, 78, "5. detect\n|z| = sqrt(Re^2 + Im^2)", "fab", dashed=True)
    d.box("img", 984, 268, 160, 62, "detected image\n8192 x 8192", "host", bold=True)
    for a, b in [("cphd", "r1"), ("r1", "r2"), ("r2", "w"), ("w", "f"), ("f", "det")]:
        d.edge(a, b)
    d.edge("det", "img")
    d.edge("geo", "r1", dashed=True)
    d.note("n1", 196, 262, 392, 74,
           "Both resamples share ONE 2-tap kernel:  out = (1-mu) in[k] + mu in[k+1].\n"
           "Range: the source grid is UNIFORM in j, so k and mu are closed form -- no search.\n"
           "Azimuth: the source (tan_s) is NON-uniform, so k comes from a monotone merge scan.", fs=11)
    d.note("n2", 620, 262, 332, 74,
           "The 2-D FFT is SEPARABLE. That is the whole reason the\n"
           "hardware can do two 1-D passes with a transpose between\n"
           "them, instead of a 2-D transform it has no memory for.", fs=11)
    d.note("n3", 24, 42, 1120, 54,
           "Dashed = fused on hardware, no pass of its own. This is the CORRECTNESS reference: the "
           "fabric build is trusted\nby matching these values sample by sample, not by matching the "
           "Python code structure.", fs=12)
    return d.write(out / "fig-sar-python.drawio.svg")


def fig_sar_fabric(out):
    """Part 3 -- how the pipeline maps onto MPFS250T: compute domains and the DDR bridge."""
    d = Diagram(1180, 560, "MPFS250T mapping -- domains, kernels and the DDR bridge",
                draw_title=False)
    d.box("mss", 24, 60, 250, 120,
          "MSS -- 4 x U54 @ 600 MHz\norchestration, geometry,\nblock-exponent bookkeeping", "mss")
    d.box("cic", 24, 210, 250, 56, "CIC  AXI4-Lite, 9 targets\narm / status / tables", "ip")
    d.box("fic", 318, 120, 150, 96,
          "FIC_0\n64-bit @ 100 MHz\n~ 800 MB/s\nTHE BOTTLENECK", "ip", bold=True)
    d.box("res", 520, 40, 170, 62, "RES\nresample gather\n+ coeff generation", "fab")
    d.box("ct", 520, 118, 170, 62, "CT\ncorner-turn\ntiled transpose", "fab")
    d.box("fft", 520, 196, 170, 78,
          "FEED -> CoreFFT -> UNLD\nx2 chains\nSLOWCLK 12.5 MHz", "ip")
    d.box("cg", 520, 290, 170, 56, "COEFG\nazimuth coefficients", "fab")
    d.box("ddr", 780, 40, 370, 306,
          "DDR (LPDDR4)\n\n"
          "SIG       0x8800_0000   256 MB\n"
          "SCRATCH   0x9800_0000   256 MB\n"
          "OUT       0xA800_0000   128 MB\n"
          "geometry  0xB000_0000    ~1 MB\n"
          "knobs     0xB005_9xxx    words", "mem")
    d.edge("mss", "fic")
    d.edge("cic", "fic", dashed=True)
    for k in ("res", "ct", "fft", "cg"):
        d.edge("fic", k, double=True)
        d.edge(k, "ddr", double=True)
    d.note("n1", 24, 300, 470, 92,
           "WHY BUFFERS SIT 256 MB APART. An in-place FFT stalls on silicon: the DMA is\n"
           "still flushing transform t while the feeder pulls t+1 over the shared\n"
           "interconnect, CoreFFT drops BUF_READY and the pipeline locks. Ping-ponging\n"
           "SCRATCH <-> SIG keeps read and write on SEPARATE 256 MB pages.", fs=11)
    d.note("n2", 24, 410, 1126, 74,
           "An 8192 x 8192 complex frame is 256 MB, so no stage fits on chip and every stage streams "
           "through FIC_0. The design\nis therefore BANDWIDTH-bound, not compute-bound -- MACC "
           "utilisation is 74 of 784 (9%). Deleting a DDR pass is worth\nmore than any arithmetic "
           "optimisation.", fs=12)
    return d.write(out / "fig-sar-fabric.drawio.svg")


def fig_sar_dataflow(out):
    """Part 3 -- one frame end to end: passes over DDR, what is fused, where the time goes."""
    d = Diagram(1180, 520, "One frame -- DDR passes, fusion and elapsed time", draw_title=False)
    d.box("sig1", 24, 96, 130, 58, "SIG\nphase history", "mem")
    d.box("g", 194, 96, 190, 58, "range gather\n5634 lines", "fab")
    d.box("scr1", 424, 96, 130, 58, "SCRATCH", "mem")
    d.box("ct1", 594, 96, 150, 58, "corner-turn", "fab")
    d.box("sig2", 784, 96, 130, 58, "SIG", "mem")
    d.box("f1", 194, 214, 190, 74,
          "FFT-1\n+ azimuth gather\n+ window   (FUSED)", "ip", bold=True)
    d.box("scr2", 424, 214, 130, 58, "SCRATCH", "mem")
    d.box("ct2", 594, 214, 150, 58, "corner-turn #2\n(OVERLAPPED)", "fab", dashed=True)
    d.box("sig3", 784, 214, 130, 58, "SIG", "mem")
    d.box("f2", 194, 332, 190, 74, "FFT-2\n+ detect   (FUSED)", "ip", bold=True)
    d.box("out", 424, 332, 130, 58, "OUT\n8192 x 8192", "mem", bold=True)
    d.edge("sig1", "g", label="3.74 s")
    d.edge("g", "scr1")
    d.edge("scr1", "ct1")
    d.edge("ct1", "sig2")
    d.edge("sig2", "f1", label="5.42 s")
    d.edge("f1", "scr2")
    d.edge("scr2", "ct2")
    d.edge("ct2", "sig3")
    d.edge("sig3", "f2", label="5.77 s")
    d.edge("f2", "out")
    d.note("n1", 784, 318, 366, 90,
           "TOTAL 14.92 s   (budget 15 s)\n\n"
           "3 passes over 256 MB, not 7.\nThe budget is met by moving less\n"
           "data, not by computing faster.", fs=12)
    d.note("n2", 24, 424, 1126, 74,
           "WHY THE FUSIONS ARE EXACT, not merely convenient:  window -- F{w.s}, a pointwise scale "
           "commutes with the read;\nazimuth gather -- the feeder already chooses which sample to "
           "present;  detect -- |z| is pointwise on the FFT output;\ncorner-turn #2 -- strip-pipelined "
           "against FFT-2, legal because the 1-D transforms of distinct rows are INDEPENDENT.", fs=12)
    return d.write(out / "fig-sar-dataflow.drawio.svg")


def fig_sar_range_resamp(out):
    """Range resample, drawn: one pulse's own grid, the common grid, and where a sample comes from."""
    d = Diagram(1160, 470, "Range resample -- what the interpolation actually does",
                draw_title=False)
    d.note("t1", 24, 24, 1112, 30,
           "Pulse i is sampled on ITS OWN range-frequency grid kr[i,j] = x0_i + j dx_i. Every pulse "
           "has a different x0 and dx, so the\ngrid SHIFTS AND STRETCHES pulse to pulse. The FFT "
           "needs one COMMON grid, so each pulse is resampled onto KR[q].", fs=12)

    # source grid (pulse i), evenly spaced
    d.box("slab", 24, 120, 120, 34, "pulse i\nown grid", "host", fs=12)
    for j in range(9):
        d.box("s%d" % j, 176 + j * 104, 120, 22, 34, "", "mem")
    d.note("sx", 176, 160, 940, 22,
           "x0_i            +dx            +2dx           +3dx           +4dx           "
           "+5dx           +6dx           +7dx", fs=10)

    # the two taps that matter, and the query between them
    d.box("k0", 488, 120, 22, 34, "", "fab", bold=True)
    d.box("k1", 592, 120, 22, 34, "", "fab", bold=True)
    d.note("kl", 452, 86, 200, 24, "in[k]                  in[k+1]", fs=11)

    # query grid (common), offset so a query lands BETWEEN two source samples
    d.box("qlab", 24, 300, 120, 34, "common grid\nKR[q]", "ip", fs=12)
    for q in range(9):
        d.box("q%d" % q, 210 + q * 104, 300, 22, 34, "", "mem")
    d.box("qt", 522, 300, 22, 34, "", "ip", bold=True)
    d.note("ql", 470, 340, 260, 24, "KR[q]  --  the output sample", fs=11)

    d.edge("k0", "qt", dashed=True)
    d.edge("k1", "qt", dashed=True)

    d.note("m", 660, 236, 476, 116,
           "t = (KR[q] - x0_i) / dx_i        k = floor(t)      mu = t - k\n\n"
           "out[q] = (1-mu) in[k] + mu in[k+1]        (2-tap, baseline)\n"
           "out[q] = SUM c_t(mu) in[k-15+t]           (32-tap sinc, variant)\n\n"
           "The grid is UNIFORM in j, so k and mu are closed form -- no search,\n"
           "which is what lets the fabric generate them from 3 scalars per line.", fs=11)
    d.note("m2", 24, 380, 600, 60,
           "mu is the FRACTIONAL position of the query between two source samples. The whole\n"
           "interpolation question is how well a kernel estimates the signal AT that fractional\n"
           "point -- which is why tap count and scalloping matter.", fs=11)
    return d.write(out / "fig-sar-range-resamp.drawio.svg")


def fig_sar_azimuth_resamp(out):
    """Azimuth resample: same 2-tap kernel, but a NON-uniform source abscissa."""
    d = Diagram(1160, 470, "Azimuth resample -- same kernel, non-uniform source",
                draw_title=False)
    d.note("t1", 24, 24, 1112, 30,
           "After the corner-turn each RANGE BIN is a row of pulses. The source abscissa is "
           "tan(phi) of each pulse -- and the\nplatform does not fly at constant angular rate, so "
           "these are NOT evenly spaced. That is the one structural difference from range.", fs=12)

    d.box("slab", 24, 120, 120, 34, "sorted pulses\ntan(phi)_s", "host", fs=12)
    # deliberately UNEVEN spacing
    xs = [176, 262, 372, 450, 566, 700, 792, 918, 1050]
    for j, x in enumerate(xs):
        d.box("s%d" % j, x, 120, 22, 34, "", "mem")
    d.note("sx", 176, 160, 940, 22,
           "unevenly spaced -- the gaps differ, so the bracket cannot be computed by division", fs=10)

    d.box("k0", 566, 120, 22, 34, "", "fab", bold=True)
    d.box("k1", 700, 120, 22, 34, "", "fab", bold=True)
    d.note("kl", 530, 86, 240, 24, "tan_s[k]                   tan_s[k+1]", fs=11)

    d.box("qlab", 24, 300, 120, 34, "uniform grid\nKC[q]/kr", "ip", fs=12)
    for q in range(9):
        d.box("q%d" % q, 210 + q * 104, 300, 22, 34, "", "mem")
    d.box("qt", 626, 300, 22, 34, "", "ip", bold=True)
    d.note("ql", 566, 340, 260, 24, "u = KC[q]/kr  --  the output sample", fs=11)

    d.edge("k0", "qt", dashed=True)
    d.edge("k1", "qt", dashed=True)

    d.note("m", 700, 236, 436, 116,
           "k = max{ m : tan_s[m] <= u }\n"
           "mu = (u - tan_s[k]) / (tan_s[k+1] - tan_s[k])\n\n"
           "Found by a MONOTONE MERGE SCAN: one pointer walks forward\n"
           "as q advances, O(M + Mp) per line rather than O(Mp log M).\n"
           "Both sequences are sorted, so the pointer never goes back.", fs=11)
    d.note("m2", 24, 380, 640, 60,
           "The KERNEL is identical to range -- same 2-tap blend, same 32-tap sinc variant. Only "
           "the way\nk and mu are FOUND differs. That is why one gather core can serve both passes, "
           "and why the\ninterpolator upgrade applies to both.", fs=11)
    return d.write(out / "fig-sar-azimuth-resamp.drawio.svg")


def fig_sar_kspace(out):
    """The PFA geometry in THREE states: polar collection, after range resample, after azimuth.

    Standard polar-format geometry (cf. Doerry, Sandia, 'Basics of Polar Format algorithm for
    processing SAR images', which shows the collected annulus and the post-range-interpolation
    state as separate figures). Drawn FROM THE GEOMETRY -- the paper is not in this repo, so this
    is the same construction rather than a traced reproduction of a specific figure."""
    d = Diagram(1180, 560, "PFA: polar collection -> range resample -> azimuth resample",
                draw_title=False)
    d.note("t", 24, 18, 1130, 46,
           "A SAR collection samples k-space on a POLAR grid. The 2-D FFT needs a uniform "
           "RECTANGULAR one. Stages 1-2 get from\nthe left picture to the right, and the MIDDLE "
           "picture is what the range interpolation alone produces.", fs=12)

    d.note("l1",  60, 84, 300, 22, "1  COLLECTED  --  polar", fs=13)
    d.note("l2", 470, 84, 300, 22, "2  after RANGE resample", fs=13)
    d.note("l3", 840, 84, 300, 22, "3  after AZIMUTH resample", fs=13)
    d.box("a0", 73.2, 193.7, 7, 7, "", "mem")
    d.box("a1", 65.4, 175.3, 7, 7, "", "mem")
    d.box("a2", 57.6, 156.8, 7, 7, "", "mem")
    d.box("a3", 49.8, 138.4, 7, 7, "", "mem")
    d.box("a4", 42.0, 120.0, 7, 7, "", "mem")
    d.box("a5", 34.2, 101.6, 7, 7, "", "mem")
    d.box("a6", 101.3, 183.4, 7, 7, "", "mem")
    d.box("a7", 95.4, 164.3, 7, 7, "", "mem")
    d.box("a8", 89.5, 145.2, 7, 7, "", "mem")
    d.box("a9", 83.6, 126.1, 7, 7, "", "mem")
    d.box("a10", 77.7, 107.0, 7, 7, "", "mem")
    d.box("a11", 71.8, 87.9, 7, 7, "", "mem")
    d.box("a12", 130.4, 176.0, 7, 7, "", "mem")
    d.box("a13", 126.4, 156.4, 7, 7, "", "mem")
    d.box("a14", 122.5, 136.8, 7, 7, "", "mem")
    d.box("a15", 118.5, 117.2, 7, 7, "", "mem")
    d.box("a16", 114.5, 97.6, 7, 7, "", "mem")
    d.box("a17", 110.5, 78.0, 7, 7, "", "mem")
    d.box("a18", 160.0, 171.5, 7, 7, "", "mem")
    d.box("a19", 158.1, 151.6, 7, 7, "", "mem")
    d.box("a20", 156.1, 131.7, 7, 7, "", "mem")
    d.box("a21", 154.1, 111.8, 7, 7, "", "mem")
    d.box("a22", 152.1, 91.9, 7, 7, "", "mem")
    d.box("a23", 150.1, 72.0, 7, 7, "", "mem")
    d.box("a24", 190.0, 170.0, 7, 7, "", "mem")
    d.box("a25", 190.0, 150.0, 7, 7, "", "mem")
    d.box("a26", 190.0, 130.0, 7, 7, "", "mem")
    d.box("a27", 190.0, 110.0, 7, 7, "", "mem")
    d.box("a28", 190.0, 90.0, 7, 7, "", "mem")
    d.box("a29", 190.0, 70.0, 7, 7, "", "mem")
    d.box("a30", 220.0, 171.5, 7, 7, "", "mem")
    d.box("a31", 221.9, 151.6, 7, 7, "", "mem")
    d.box("a32", 223.9, 131.7, 7, 7, "", "mem")
    d.box("a33", 225.9, 111.8, 7, 7, "", "mem")
    d.box("a34", 227.9, 91.9, 7, 7, "", "mem")
    d.box("a35", 229.9, 72.0, 7, 7, "", "mem")
    d.box("a36", 249.6, 176.0, 7, 7, "", "mem")
    d.box("a37", 253.6, 156.4, 7, 7, "", "mem")
    d.box("a38", 257.5, 136.8, 7, 7, "", "mem")
    d.box("a39", 261.5, 117.2, 7, 7, "", "mem")
    d.box("a40", 265.5, 97.6, 7, 7, "", "mem")
    d.box("a41", 269.5, 78.0, 7, 7, "", "mem")
    d.box("a42", 278.7, 183.4, 7, 7, "", "mem")
    d.box("a43", 284.6, 164.3, 7, 7, "", "mem")
    d.box("a44", 290.5, 145.2, 7, 7, "", "mem")
    d.box("a45", 296.4, 126.1, 7, 7, "", "mem")
    d.box("a46", 302.3, 107.0, 7, 7, "", "mem")
    d.box("a47", 308.2, 87.9, 7, 7, "", "mem")
    d.box("a48", 306.8, 193.7, 7, 7, "", "mem")
    d.box("a49", 314.6, 175.3, 7, 7, "", "mem")
    d.box("a50", 322.4, 156.8, 7, 7, "", "mem")
    d.box("a51", 330.2, 138.4, 7, 7, "", "mem")
    d.box("a52", 338.0, 120.0, 7, 7, "", "mem")
    d.box("a53", 345.8, 101.6, 7, 7, "", "mem")
    d.box("b0", 470.0, 103.2, 7, 7, "", "fab")
    d.box("b1", 470.0, 150.3, 7, 7, "", "fab")
    d.box("b2", 470.0, 197.5, 7, 7, "", "fab")
    d.box("b3", 470.0, 244.7, 7, 7, "", "fab")
    d.box("b4", 470.0, 291.9, 7, 7, "", "fab")
    d.box("b5", 470.0, 339.0, 7, 7, "", "fab")
    d.box("b6", 500.0, 95.0, 7, 7, "", "fab")
    d.box("b7", 500.0, 142.6, 7, 7, "", "fab")
    d.box("b8", 500.0, 190.3, 7, 7, "", "fab")
    d.box("b9", 500.0, 237.9, 7, 7, "", "fab")
    d.box("b10", 500.0, 285.6, 7, 7, "", "fab")
    d.box("b11", 500.0, 333.3, 7, 7, "", "fab")
    d.box("b12", 530.0, 89.0, 7, 7, "", "fab")
    d.box("b13", 530.0, 137.0, 7, 7, "", "fab")
    d.box("b14", 530.0, 185.1, 7, 7, "", "fab")
    d.box("b15", 530.0, 233.1, 7, 7, "", "fab")
    d.box("b16", 530.0, 281.1, 7, 7, "", "fab")
    d.box("b17", 530.0, 329.1, 7, 7, "", "fab")
    d.box("b18", 560.0, 85.4, 7, 7, "", "fab")
    d.box("b19", 560.0, 133.7, 7, 7, "", "fab")
    d.box("b20", 560.0, 181.9, 7, 7, "", "fab")
    d.box("b21", 560.0, 230.1, 7, 7, "", "fab")
    d.box("b22", 560.0, 278.4, 7, 7, "", "fab")
    d.box("b23", 560.0, 326.6, 7, 7, "", "fab")
    d.box("b24", 590.0, 84.2, 7, 7, "", "fab")
    d.box("b25", 590.0, 132.6, 7, 7, "", "fab")
    d.box("b26", 590.0, 180.8, 7, 7, "", "fab")
    d.box("b27", 590.0, 229.2, 7, 7, "", "fab")
    d.box("b28", 590.0, 277.4, 7, 7, "", "fab")
    d.box("b29", 590.0, 325.8, 7, 7, "", "fab")
    d.box("b30", 620.0, 85.4, 7, 7, "", "fab")
    d.box("b31", 620.0, 133.7, 7, 7, "", "fab")
    d.box("b32", 620.0, 181.9, 7, 7, "", "fab")
    d.box("b33", 620.0, 230.1, 7, 7, "", "fab")
    d.box("b34", 620.0, 278.4, 7, 7, "", "fab")
    d.box("b35", 620.0, 326.6, 7, 7, "", "fab")
    d.box("b36", 650.0, 89.0, 7, 7, "", "fab")
    d.box("b37", 650.0, 137.0, 7, 7, "", "fab")
    d.box("b38", 650.0, 185.1, 7, 7, "", "fab")
    d.box("b39", 650.0, 233.1, 7, 7, "", "fab")
    d.box("b40", 650.0, 281.1, 7, 7, "", "fab")
    d.box("b41", 650.0, 329.1, 7, 7, "", "fab")
    d.box("b42", 680.0, 95.0, 7, 7, "", "fab")
    d.box("b43", 680.0, 142.6, 7, 7, "", "fab")
    d.box("b44", 680.0, 190.3, 7, 7, "", "fab")
    d.box("b45", 680.0, 237.9, 7, 7, "", "fab")
    d.box("b46", 680.0, 285.6, 7, 7, "", "fab")
    d.box("b47", 680.0, 333.3, 7, 7, "", "fab")
    d.box("b48", 710.0, 103.2, 7, 7, "", "fab")
    d.box("b49", 710.0, 150.3, 7, 7, "", "fab")
    d.box("b50", 710.0, 197.5, 7, 7, "", "fab")
    d.box("b51", 710.0, 244.7, 7, 7, "", "fab")
    d.box("b52", 710.0, 291.9, 7, 7, "", "fab")
    d.box("b53", 710.0, 339.0, 7, 7, "", "fab")
    d.box("c0", 840.0, 130.0, 7, 7, "", "ip")
    d.box("c1", 840.0, 164.0, 7, 7, "", "ip")
    d.box("c2", 840.0, 198.0, 7, 7, "", "ip")
    d.box("c3", 840.0, 232.0, 7, 7, "", "ip")
    d.box("c4", 840.0, 266.0, 7, 7, "", "ip")
    d.box("c5", 840.0, 300.0, 7, 7, "", "ip")
    d.box("c6", 870.0, 130.0, 7, 7, "", "ip")
    d.box("c7", 870.0, 164.0, 7, 7, "", "ip")
    d.box("c8", 870.0, 198.0, 7, 7, "", "ip")
    d.box("c9", 870.0, 232.0, 7, 7, "", "ip")
    d.box("c10", 870.0, 266.0, 7, 7, "", "ip")
    d.box("c11", 870.0, 300.0, 7, 7, "", "ip")
    d.box("c12", 900.0, 130.0, 7, 7, "", "ip")
    d.box("c13", 900.0, 164.0, 7, 7, "", "ip")
    d.box("c14", 900.0, 198.0, 7, 7, "", "ip")
    d.box("c15", 900.0, 232.0, 7, 7, "", "ip")
    d.box("c16", 900.0, 266.0, 7, 7, "", "ip")
    d.box("c17", 900.0, 300.0, 7, 7, "", "ip")
    d.box("c18", 930.0, 130.0, 7, 7, "", "ip")
    d.box("c19", 930.0, 164.0, 7, 7, "", "ip")
    d.box("c20", 930.0, 198.0, 7, 7, "", "ip")
    d.box("c21", 930.0, 232.0, 7, 7, "", "ip")
    d.box("c22", 930.0, 266.0, 7, 7, "", "ip")
    d.box("c23", 930.0, 300.0, 7, 7, "", "ip")
    d.box("c24", 960.0, 130.0, 7, 7, "", "ip")
    d.box("c25", 960.0, 164.0, 7, 7, "", "ip")
    d.box("c26", 960.0, 198.0, 7, 7, "", "ip")
    d.box("c27", 960.0, 232.0, 7, 7, "", "ip")
    d.box("c28", 960.0, 266.0, 7, 7, "", "ip")
    d.box("c29", 960.0, 300.0, 7, 7, "", "ip")
    d.box("c30", 990.0, 130.0, 7, 7, "", "ip")
    d.box("c31", 990.0, 164.0, 7, 7, "", "ip")
    d.box("c32", 990.0, 198.0, 7, 7, "", "ip")
    d.box("c33", 990.0, 232.0, 7, 7, "", "ip")
    d.box("c34", 990.0, 266.0, 7, 7, "", "ip")
    d.box("c35", 990.0, 300.0, 7, 7, "", "ip")
    d.box("c36", 1020.0, 130.0, 7, 7, "", "ip")
    d.box("c37", 1020.0, 164.0, 7, 7, "", "ip")
    d.box("c38", 1020.0, 198.0, 7, 7, "", "ip")
    d.box("c39", 1020.0, 232.0, 7, 7, "", "ip")
    d.box("c40", 1020.0, 266.0, 7, 7, "", "ip")
    d.box("c41", 1020.0, 300.0, 7, 7, "", "ip")
    d.box("c42", 1050.0, 130.0, 7, 7, "", "ip")
    d.box("c43", 1050.0, 164.0, 7, 7, "", "ip")
    d.box("c44", 1050.0, 198.0, 7, 7, "", "ip")
    d.box("c45", 1050.0, 232.0, 7, 7, "", "ip")
    d.box("c46", 1050.0, 266.0, 7, 7, "", "ip")
    d.box("c47", 1050.0, 300.0, 7, 7, "", "ip")
    d.box("c48", 1080.0, 130.0, 7, 7, "", "ip")
    d.box("c49", 1080.0, 164.0, 7, 7, "", "ip")
    d.box("c50", 1080.0, 198.0, 7, 7, "", "ip")
    d.box("c51", 1080.0, 232.0, 7, 7, "", "ip")
    d.box("c52", 1080.0, 266.0, 7, 7, "", "ip")
    d.box("c53", 1080.0, 300.0, 7, 7, "", "ip")
    d.note("m1", 40, 300, 380, 96,
           "kr[i,j] = 2 pr[i]/c (f0[i] + j df[i])\n\n"
           "Each pulse i is an arc at its own aspect\nangle; j steps outward in range frequency.\n"
           "x0 and dx differ pulse to pulse, so the arcs\nare neither concentric in index nor "
           "evenly spaced.", fs=11)
    d.note("m2", 440, 330, 370, 96,
           "t = (KR[q] - x0_i)/dx_i,  k = floor(t),  mu = t-k\n\n"
           "COLUMNS now line up: every pulse has been\nresampled onto the SAME kx grid. Rows do "
           "not,\nbecause each pulse was only made uniform along\nits OWN radial. Hence a second "
           "resample.", fs=11)
    d.note("m3", 830, 330, 320, 96,
           "u = KC[q]/kr,  k from a merge scan on tan(phi)\n\n"
           "Uniform in BOTH axes, so a separable 2-D FFT\napplies and the hardware runs two 1-D "
           "passes with\na transpose between. That transpose is the\ncorner-turn.", fs=11)
    return d.write(out / "fig-sar-kspace.drawio.svg")


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
    for fn in (fig_loop, fig_orchestration, fig_gates, fig_pfa, fig_python,
               fig_fabric, fig_dataflow, fig_timing, fig_bug,
               fig_sar_python, fig_sar_fabric, fig_sar_dataflow,
               fig_sar_range_resamp, fig_sar_azimuth_resamp, fig_sar_kspace):
        fn(out)
    # ARCHITECTURE.md Figure 1 lives with the doc that owns it, not with the deck
    img = (here / ".." / "img").resolve()
    img.mkdir(parents=True, exist_ok=True)
    fig_arch_pipeline(img)


if __name__ == "__main__":
    main()
