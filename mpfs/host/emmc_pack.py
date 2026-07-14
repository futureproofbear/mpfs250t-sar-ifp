"""Pack serialize_inputs.py stage dir(s) into an eMMC INPUT-partition image.

Host-only, board-free. Consumes one or more ``jtag_stage/`` directories (each the
output of ``serialize_inputs.py`` for one CPHD scene) and produces a compact
image = the INPUT superblock ('SARI') + one self-describing blob per scene. The
provisioner writes this image starting at LBA ``EMMC_IN_LBA``; TOC entries carry
ABSOLUTE device LBAs so firmware can seek each blob directly.

Per the eMMC layout contract (ddr_layout.py):
  * JOB is NOT stored -- each TOC entry carries the job-semantic fields and the
    board rebuilds sar_job_t via job_from_in_entry().
  * A blob segment is tagged by ROLE, not by a DDR address -- firmware resolves
    role -> address at boot, so the DDR map can change without reprovisioning.

Usage:
    python emmc_pack.py --stage jtag_stage [--stage other_stage ...] \
                        --out emmc_input.img            # build + self-verify
    python emmc_pack.py --selftest                      # synthetic round-trip, no CPHD
"""
import sys
import json
import struct
import argparse
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ddr_layout as L  # noqa: E402

# role name -> stage filename, in role-id order (index == role id).
ROLE_FILES = [(name, f"{name}.bin") for name in
              ["sig", "f0", "df", "pr", "tans", "invorder",
               "krgrid", "kcgrid", "hamr", "hamc"]]


def read_stage(stage_dir):
    """Read a stage dir -> (ordered segs [(role_id, bytes)], layout dict)."""
    stage_dir = Path(stage_dir)
    layout = json.loads((stage_dir / "layout.json").read_text())
    segs = []
    for name, fn in ROLE_FILES:
        p = stage_dir / fn
        if not p.exists():
            raise FileNotFoundError(f"{p} missing (role '{name}')")
        segs.append((L.EMMC_ROLE[name], p.read_bytes()))
    # trust check: the SIG segment CRC must match what serialize_inputs recorded.
    sig_crc = L.crc32(segs[0][1])
    if sig_crc != layout["crc32"]["sig"]:
        raise ValueError(f"{stage_dir}: sig.bin CRC {sig_crc:#010x} != "
                         f"layout {layout['crc32']['sig']:#010x}")
    return segs, layout


def build_input_image(stage_dirs):
    """Build the INPUT-partition image from stage dirs.
    Returns (image_bytes, toc) where toc is a list of dicts (one per scene)."""
    scenes = [read_stage(d) for d in stage_dirs]

    # superblock occupies the first blocks of the INPUT region; blobs follow.
    super_bytes_probe = L.pack_in_super([b"\0" * 88] * len(scenes))
    lba = L.EMMC_IN_LBA + len(super_bytes_probe) // L.EMMC_BLK

    blobs, entries, toc = [], [], []
    for sid, (segs, layout) in enumerate(scenes):
        blob = L.pack_blob(segs)
        blobs.append(blob)
        byte_len = len(blob)
        blob_crc = L.crc32(blob)
        M, N = layout["dims"]["M"], layout["dims"]["N"]
        fft_r, fft_a = layout["fft_len"]["R"], layout["fft_len"]["A"]
        exp = layout["bfp_input"]["exp"]
        sig_len = layout["sizes"]["sig"]
        sig_crc = layout["crc32"]["sig"]
        name = layout["scene"]
        entries.append(L.pack_in_entry(sid, lba, byte_len, blob_crc, M, N,
                                       fft_r, fft_a, exp, sig_len, sig_crc, name))
        toc.append({"scene_id": sid, "name": name, "lba": lba,
                    "byte_len": byte_len, "blob_crc": blob_crc,
                    "M": M, "N": N, "fft_r": fft_r, "fft_a": fft_a,
                    "bfp_exp": exp, "sig_len": sig_len, "sig_crc": sig_crc})
        lba += byte_len // L.EMMC_BLK

    superblock = L.pack_in_super(entries)
    image = bytearray(superblock)
    for blob in blobs:
        image += blob
    # image maps 1:1 onto the device starting at EMMC_IN_LBA
    used = L.EMMC_IN_LBA + len(image) // L.EMMC_BLK
    if used > L.EMMC_IN_LBA + L.EMMC_IN_BLKS:
        raise ValueError("scenes overflow the INPUT partition; fewer scenes or bigger region")
    return bytes(image), toc


def verify_image(image, toc):
    """Re-parse the image and confirm every blob/segment CRC and that each TOC
    entry reconstructs a JOB. Raises on any mismatch; returns nothing."""
    magic, version, count, _ = struct.unpack_from(L.EMMC_SUPER_HDR_FMT, image, 0)
    assert magic == L.EMMC_IN_MAGIC, "bad superblock magic"
    assert version == L.EMMC_VERSION, f"superblock version {version} != {L.EMMC_VERSION}"
    assert count == len(toc), "superblock count mismatch"
    esz = struct.calcsize(L.EMMC_IN_ENTRY_FMT)
    hdr = struct.calcsize(L.EMMC_SUPER_HDR_FMT)
    for i, t in enumerate(toc):
        ent = struct.unpack_from(L.EMMC_IN_ENTRY_FMT, image, hdr + i * esz)
        # reconstruct the JOB from the persisted TOC entry (the whole point)
        job = L.job_from_in_entry(ent, L.OUT_DTYPE_UINT16)
        assert len(job) == L.JOB_BYTES, "reconstructed JOB wrong size"
        # locate the blob in the image (image offset = (lba - IN_LBA) * blk)
        boff = (t["lba"] - L.EMMC_IN_LBA) * L.EMMC_BLK
        blob = image[boff:boff + t["byte_len"]]
        assert L.crc32(blob) == t["blob_crc"], f"scene {i} blob CRC mismatch"
        bmagic, bver, seg_count, total = struct.unpack_from(L.EMMC_BLOB_HDR_FMT, blob, 0)
        assert bmagic == L.EMMC_BLOB_MAGIC and total == len(blob), "bad blob header"
        segoff = struct.calcsize(L.EMMC_BLOB_HDR_FMT)
        sig_seg_crc = None
        for s in range(seg_count):
            role, off, ln, crc = struct.unpack_from(L.EMMC_SEG_FMT, blob, segoff + s * 16)
            assert L.crc32(blob[off:off + ln]) == crc, f"scene {i} seg {role} CRC mismatch"
            assert off % L.EMMC_BLK == 0, "segment not block-aligned"
            if role == L.EMMC_ROLE["sig"]:
                sig_seg_crc = crc
        # the SIG segment CRC must equal the JOB/TOC sig_crc (loopback check)
        assert sig_seg_crc == t["sig_crc"], f"scene {i} SIG seg CRC != TOC sig_crc"


def _selftest():
    """Synthetic round-trip with two fake scenes -- proves pack/parse/reconstruct
    without needing a CPHD, sarpy, or a board."""
    import numpy as np
    L.assert_emmc_fits(8 * 1024**3)

    def fake_stage(tmp, name, M, N):
        d = Path(tmp) / name
        d.mkdir(parents=True, exist_ok=True)
        Mp = Np = L.GRID_MAX
        sig = (np.arange(M * N * 2, dtype=np.int16)).tobytes()
        bins = {
            "sig": sig,
            "f0": np.zeros(M, np.float32).tobytes(),
            "df": np.ones(M, np.float32).tobytes(),
            "pr": np.zeros(M, np.float32).tobytes(),
            "tans": np.linspace(0, 1, M, dtype=np.float32).tobytes(),
            "invorder": np.arange(M, dtype=np.int32).tobytes(),
            "krgrid": np.zeros(Np, np.float32).tobytes(),
            "kcgrid": np.zeros(Mp, np.float32).tobytes(),
            "hamr": np.zeros(Np, np.int16).tobytes(),
            "hamc": np.zeros(Mp, np.int16).tobytes(),
        }
        for nm, b in bins.items():
            (d / f"{nm}.bin").write_bytes(b)
        layout = {"scene": name, "dims": {"M": M, "N": N},
                  "fft_len": {"R": Np, "A": Mp}, "deci": {"pulse": 1, "sample": 1},
                  "bfp_input": {"lsb": 0.015625, "exp": -6},
                  "sizes": {"sig": len(sig)},
                  "crc32": {"sig": L.crc32(sig)}}
        (d / "layout.json").write_text(json.dumps(layout))
        return str(d)

    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        dirs = [fake_stage(tmp, "sceneA", 5634, 4319),
                fake_stage(tmp, "sceneB", 8167, 6273)]
        image, toc = build_input_image(dirs)
        verify_image(image, toc)
    print("selftest OK:")
    for t in toc:
        print(f"  scene {t['scene_id']} '{t['name']}': LBA {t['lba']:#x} "
              f"({t['byte_len']/1e6:.1f} MB blob)  M={t['M']} N={t['N']} "
              f"fft={t['fft_a']}x{t['fft_r']} sig_crc={t['sig_crc']:#010x}")
    print(f"  image = {len(image)/1e6:.1f} MB, superblock + {len(toc)} blobs, "
          f"all blob/segment CRCs verified, JOB reconstructs from every TOC entry")


def main():
    ap = argparse.ArgumentParser(description="Pack stage dirs -> eMMC INPUT image")
    ap.add_argument("--stage", action="append", default=[],
                    help="a serialize_inputs.py output dir (repeatable)")
    ap.add_argument("--out", help="output image path")
    ap.add_argument("--selftest", action="store_true",
                    help="synthetic round-trip, no CPHD/board needed")
    a = ap.parse_args()
    if a.selftest:
        _selftest()
        return
    if not a.stage or not a.out:
        ap.error("need --stage and --out (or --selftest)")
    image, toc = build_input_image(a.stage)
    verify_image(image, toc)
    Path(a.out).write_bytes(image)
    print(f"wrote {a.out}  ({len(image)/1e6:.1f} MB, {len(toc)} scene(s))")
    for t in toc:
        print(f"  scene {t['scene_id']} '{t['name']}': device LBA {t['lba']:#x}"
              f" ({t['byte_len']/1e6:.1f} MB)")
    print("verified: all blob/segment CRCs, JOB reconstructs from every TOC entry")


if __name__ == "__main__":
    main()
