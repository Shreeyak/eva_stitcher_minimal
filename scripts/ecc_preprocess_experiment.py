"""
ECC Preprocessing Experiment — Histology WSI
=============================================
Evaluates which image preprocessing method gives the best ECC alignment
convergence for histology whole-slide images.

Preprocessing variants tested
------------------------------
Raw single-channel extractions:
  bgr_gray        — OpenCV standard grayscale (0.114B + 0.587G + 0.299R)
  channel_r       — Red channel only
  channel_g       — Green channel only
  channel_b       — Blue channel only
  ycrcb_y         — Y (luma) from YCrCb
  lab_l           — L* (lightness) from CIE L*a*b*
  hsv_v           — V (value) from HSV
  hls_l           — L (lightness) from HLS

Gradient-based transformations (applied on top of best single channels):
  sobel           — magnitude of Sobel x+y gradient (8-bit)
  laplacian       — absolute Laplacian
  canny           — Canny edge map (binary, soft-normalizes to 0/255)
  scharr          — Scharr gradient magnitude (more isotropic than Sobel)
  log             — Laplacian-of-Gaussian (LoG) blob/edge detector
  dog             — Difference-of-Gaussians (σ=1, σ=3)
  clahe           — CLAHE contrast-enhanced channel (no gradient, keeps texture)
  gamma_dark      — gamma-corrected (γ=0.5) to boost dark nuclear stain contrast

Composite / mixed:
  hessian_det     — Hessian determinant (blob-like structures)
  structure_eig   — smallest eigenvalue of structure tensor (corner energy)
  phase_congruency_approx — multi-scale Gabor-based local phase coherence proxy

Each variant is tested with ECC using MOTION_TRANSLATION, then
MOTION_EUCLIDEAN, with known ground-truth translations of 10–20 px.

Metrics collected per (variant, pair, warp_mode):
  - converged          (bool)
  - final_rho          (ECC correlation, 0–1)
  - tx_err, ty_err     (translation error vs GT, pixels)
  - te_px              (total translation error magnitude)
  - n_iters            (ECC iterations used)
  - elapsed_ms         (wall time)

Usage
-----
  python scripts/ecc_preprocess_experiment.py

Results are saved to:
  scripts/tmp_files/ecc_preprocess_results.csv
  scripts/tmp_files/ecc_preprocess_summary.txt
  scripts/tmp_files/ecc_preprocess_*.png  (visualisations)
"""

from __future__ import annotations

import csv
import random
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import cv2
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT = Path(__file__).resolve().parent.parent
DATA_DIR = REPO_ROOT / "data" / "wsi-large-extracts"
OUT_DIR = REPO_ROOT / "scripts" / "tmp_files"
OUT_DIR.mkdir(parents=True, exist_ok=True)

CROP_SIZE = 768  # pixels
GT_TRANSLATIONS = [  # (tx, ty) ground-truth shifts in pixels
    (4, 0),
    (0, 4),
    (5, 3),
    (-4, 6),
    (7, 2),
    (-3, 7),
]

ECC_MAX_ITERS = 100
ECC_EPS = 1e-5
RANDOM_SEED = 42

rng = random.Random(RANDOM_SEED)
np_rng = np.random.default_rng(RANDOM_SEED)


# ---------------------------------------------------------------------------
# Image loading helpers
# ---------------------------------------------------------------------------

# Only use full-resolution images: CMU L0 slides and WSI region extracts.
# Exclude L1 (downscaled), thumbnails, and manual crops — they are lower
# quality or too small to produce reliable 768 px crops.
_L0_PATTERNS = ("L0", "region")


def load_source_images() -> list[tuple[str, np.ndarray]]:
    """Load full-resolution WSI images from data/wsi-large-extracts."""
    images = []
    all_paths = sorted(DATA_DIR.glob("*.png")) + sorted(DATA_DIR.glob("*.jpg"))
    for p in all_paths:
        # Keep only L0 / region images; skip thumbnails, L1, manuals
        if not any(tag in p.name for tag in _L0_PATTERNS):
            continue
        img = cv2.imread(str(p))
        if img is None:
            continue
        h, w = img.shape[:2]
        if h < CROP_SIZE or w < CROP_SIZE:
            print(f"  [SKIP] {p.name} too small ({w}x{h})")
            continue
        images.append((p.name, img))
    if not images:
        raise FileNotFoundError(f"No suitable images found in {DATA_DIR}")
    print(f"Loaded {len(images)} source image(s): {[n for n, _ in images]}")
    return images


def extract_crop(img: np.ndarray, cx: int, cy: int, size: int) -> np.ndarray:
    """Extract a square crop centred at (cx, cy)."""
    h, w = img.shape[:2]
    x0 = cx - size // 2
    y0 = cy - size // 2
    x0 = max(0, min(x0, w - size))
    y0 = max(0, min(y0, h - size))
    return img[y0 : y0 + size, x0 : x0 + size].copy()


def translate_crop(
    img_bgr: np.ndarray, tx: float, ty: float
) -> tuple[np.ndarray, np.ndarray]:
    """
    Create a (reference, shifted) pair.
    Reference = centre crop.  Shifted = crop from position offset by (tx, ty),
    so ECC should find the INVERSE shift (-tx, -ty) when aligning shifted→reference.
    """
    h, w = img_bgr.shape[:2]
    # reference centre
    cx, cy = w // 2, h // 2
    ref = extract_crop(img_bgr, cx, cy, CROP_SIZE)
    # shifted source (camera moved by (tx,ty))
    src = extract_crop(img_bgr, cx + int(round(tx)), cy + int(round(ty)), CROP_SIZE)
    return ref, src


# ---------------------------------------------------------------------------
# Preprocessing variants
# ---------------------------------------------------------------------------


def to_uint8(arr: np.ndarray) -> np.ndarray:
    """Normalise float/signed array to uint8 [0,255]."""
    arr = arr.astype(np.float32)
    mn, mx = arr.min(), arr.max()
    if mx == mn:
        return np.zeros_like(arr, dtype=np.uint8)
    return ((arr - mn) / (mx - mn) * 255).astype(np.uint8)


def apply_clahe(gray: np.ndarray, clip: float = 2.0, tile: int = 8) -> np.ndarray:
    clahe = cv2.createCLAHE(clipLimit=clip, tileGridSize=(tile, tile))
    return clahe.apply(gray)


def sobel_magnitude(gray: np.ndarray) -> np.ndarray:
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    return to_uint8(np.sqrt(gx**2 + gy**2))


def scharr_magnitude(gray: np.ndarray) -> np.ndarray:
    gx = cv2.Scharr(gray, cv2.CV_32F, 1, 0)
    gy = cv2.Scharr(gray, cv2.CV_32F, 0, 1)
    return to_uint8(np.sqrt(gx**2 + gy**2))


def laplacian_abs(gray: np.ndarray) -> np.ndarray:
    lap = cv2.Laplacian(gray, cv2.CV_32F, ksize=3)
    return to_uint8(np.abs(lap))


def canny_map(gray: np.ndarray, lo: int = 20, hi: int = 80) -> np.ndarray:
    """ECC needs continuous gradients; blur Canny to soften binary edges."""
    edges = cv2.Canny(gray, lo, hi)
    return cv2.GaussianBlur(edges, (3, 3), 0)


def log_filter(gray: np.ndarray, sigma: float = 1.5) -> np.ndarray:
    """Laplacian-of-Gaussian."""
    k = max(3, int(6 * sigma + 1) | 1)  # odd kernel
    blurred = cv2.GaussianBlur(gray.astype(np.float32), (k, k), sigma)
    lap = cv2.Laplacian(blurred, cv2.CV_32F, ksize=3)
    return to_uint8(np.abs(lap))


def dog_filter(
    gray: np.ndarray, sigma1: float = 1.0, sigma2: float = 3.0
) -> np.ndarray:
    """Difference of Gaussians."""

    def gblur(g, s):
        k = max(3, int(6 * s + 1) | 1)
        return cv2.GaussianBlur(g.astype(np.float32), (k, k), s)

    return to_uint8(np.abs(gblur(gray, sigma1) - gblur(gray, sigma2)))


def gamma_dark(gray: np.ndarray, gamma: float = 0.5) -> np.ndarray:
    lut = np.array([((i / 255.0) ** gamma) * 255 for i in range(256)], dtype=np.uint8)
    return cv2.LUT(gray, lut)


def hessian_det(gray: np.ndarray) -> np.ndarray:
    """Hessian determinant — large for blob-like structures."""
    f = gray.astype(np.float32)
    # Second-order derivatives via two first-order Sobel passes
    gx = cv2.Sobel(f, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(f, cv2.CV_32F, 0, 1, ksize=3)
    Lxx = cv2.Sobel(gx, cv2.CV_32F, 1, 0, ksize=3)
    Lyy = cv2.Sobel(gy, cv2.CV_32F, 0, 1, ksize=3)
    Lxy = cv2.Sobel(gx, cv2.CV_32F, 0, 1, ksize=3)
    det = Lxx * Lyy - Lxy**2
    return to_uint8(det)


def structure_tensor_eig(gray: np.ndarray, sigma: float = 1.5) -> np.ndarray:
    """
    Smallest eigenvalue of the structure tensor (Harris-like corner energy).
    Strong at both edges and corners — good angular diversity for ECC.
    """
    f = gray.astype(np.float32)
    gx = cv2.Sobel(f, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(f, cv2.CV_32F, 0, 1, ksize=3)
    k = max(3, int(6 * sigma + 1) | 1)
    Ixx = cv2.GaussianBlur(gx * gx, (k, k), sigma)
    Ixy = cv2.GaussianBlur(gx * gy, (k, k), sigma)
    Iyy = cv2.GaussianBlur(gy * gy, (k, k), sigma)
    trace = Ixx + Iyy
    det = Ixx * Iyy - Ixy**2
    # smaller eigenvalue: (trace - sqrt(trace²-4det)) / 2
    disc = np.sqrt(np.maximum(trace**2 - 4 * det, 0))
    lam_min = (trace - disc) / 2.0
    return to_uint8(lam_min)


def phase_congruency_approx(gray: np.ndarray) -> np.ndarray:
    """
    Approximate phase congruency using multi-scale Gabor magnitude sum.
    Phase congruency is illumination-invariant and fires at all feature types.
    """
    f = gray.astype(np.float32)
    response = np.zeros_like(f)
    for ksize in [7, 11, 17]:
        for theta in np.linspace(0, np.pi, 4, endpoint=False):
            kern = cv2.getGaborKernel(
                (ksize, ksize),
                sigma=ksize / 5,
                theta=theta,
                lambd=ksize / 3,
                gamma=0.5,
                psi=0,
                ktype=cv2.CV_32F,
            )
            r = cv2.filter2D(f, cv2.CV_32F, kern)
            response += np.abs(r)
    return to_uint8(response)


def build_variants() -> dict[str, Callable[[np.ndarray], np.ndarray]]:
    """
    Returns dict of variant_name → function(bgr_img) → uint8 gray.
    """

    def ch_r(bgr):
        return bgr[:, :, 2]

    def ch_g(bgr):
        return bgr[:, :, 1]

    def ch_b(bgr):
        return bgr[:, :, 0]

    def bgr_gray(bgr):
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)

    def ycrcb_y(bgr):
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2YCrCb)[:, :, 0]

    def lab_l(bgr):
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2Lab)[:, :, 0]

    def hsv_v(bgr):
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2HSV)[:, :, 2]

    def hls_l(bgr):
        return cv2.cvtColor(bgr, cv2.COLOR_BGR2HLS)[:, :, 1]

    raw = {
        "bgr_gray": bgr_gray,
        "channel_r": ch_r,
        "channel_g": ch_g,
        "channel_b": ch_b,
        "ycrcb_y": ycrcb_y,
        "lab_l": lab_l,
        "hsv_v": hsv_v,
        "hls_l": hls_l,
    }

    # additional: CLAHE on each raw variant
    clahe_variants = {
        f"clahe_{name}": (lambda bgr, fn=fn: apply_clahe(fn(bgr)))
        for name, fn in raw.items()
    }

    # Gradient variants on top of G channel and Lab-L (likely best)
    def make_grad(base_fn, grad_fn, name):
        def f(bgr):
            return grad_fn(base_fn(bgr))

        f.__name__ = name
        return f

    grad_bases = {
        "g_sobel": make_grad(ch_g, sobel_magnitude, "g_sobel"),
        "g_scharr": make_grad(ch_g, scharr_magnitude, "g_scharr"),
        "g_laplacian": make_grad(ch_g, laplacian_abs, "g_laplacian"),
        "g_canny": make_grad(ch_g, canny_map, "g_canny"),
        "g_log": make_grad(ch_g, log_filter, "g_log"),
        "g_dog": make_grad(ch_g, dog_filter, "g_dog"),
        "g_gamma": make_grad(ch_g, gamma_dark, "g_gamma"),
        "g_clahe_sobel": make_grad(
            lambda bgr: apply_clahe(ch_g(bgr)), sobel_magnitude, "g_clahe_sobel"
        ),
        "g_hessian": make_grad(ch_g, hessian_det, "g_hessian"),
        "g_struct_eig": make_grad(ch_g, structure_tensor_eig, "g_struct_eig"),
        "g_phase_cong": make_grad(ch_g, phase_congruency_approx, "g_phase_cong"),
        "l_sobel": make_grad(lab_l, sobel_magnitude, "l_sobel"),
        "l_scharr": make_grad(lab_l, scharr_magnitude, "l_scharr"),
        "l_laplacian": make_grad(lab_l, laplacian_abs, "l_laplacian"),
        "l_canny": make_grad(lab_l, canny_map, "l_canny"),
        "l_log": make_grad(lab_l, log_filter, "l_log"),
        "l_dog": make_grad(lab_l, dog_filter, "l_dog"),
        "l_clahe_sobel": make_grad(
            lambda bgr: apply_clahe(lab_l(bgr)), sobel_magnitude, "l_clahe_sobel"
        ),
        "l_struct_eig": make_grad(lab_l, structure_tensor_eig, "l_struct_eig"),
        "l_phase_cong": make_grad(lab_l, phase_congruency_approx, "l_phase_cong"),
    }

    return {**raw, **clahe_variants, **grad_bases}


# ---------------------------------------------------------------------------
# ECC alignment
# ---------------------------------------------------------------------------


@dataclass
class ECCResult:
    variant: str
    warp_mode_name: str
    img_name: str
    gt_tx: float
    gt_ty: float
    converged: bool
    final_rho: float
    tx_err: float
    ty_err: float
    te_px: float
    n_iters: int
    elapsed_ms: float
    note: str = ""


WARP_MODES = {
    "translation": cv2.MOTION_TRANSLATION,
    # "euclidean":   cv2.MOTION_EUCLIDEAN,  # enable to also test rotation
}


def run_ecc(
    ref_f32: np.ndarray, src_f32: np.ndarray, warp_mode: int, max_iters: int, eps: float
) -> tuple[bool, np.ndarray, float, int]:
    """
    Run ECC alignment. Returns (converged, warp_matrix, final_rho, n_iters).
    warp_matrix aligns src → ref.
    """
    if warp_mode == cv2.MOTION_TRANSLATION:
        warp = np.eye(2, 3, dtype=np.float32)
    else:
        warp = np.eye(2, 3, dtype=np.float32)

    criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, max_iters, eps)
    try:
        rho, warp_out = cv2.findTransformECC(
            ref_f32, src_f32, warp, warp_mode, criteria, inputMask=None, gaussFiltSize=5
        )
        return True, warp_out, float(rho), max_iters  # cv2 doesn't return iter count
    except cv2.error as e:
        if "diverged" in str(e) or "ECC algorithm" in str(e) or "iterations" in str(e):
            return False, warp, 0.0, max_iters
        raise


def align_and_evaluate(
    variant_name: str,
    preprocess_fn: Callable[[np.ndarray], np.ndarray],
    ref_bgr: np.ndarray,
    src_bgr: np.ndarray,
    gt_tx: float,
    gt_ty: float,
    img_name: str,
) -> list[ECCResult]:
    results = []

    ref_proc = preprocess_fn(ref_bgr).astype(np.float32)
    src_proc = preprocess_fn(src_bgr).astype(np.float32)

    for mode_name, warp_mode in WARP_MODES.items():
        t0 = time.perf_counter()
        converged, warp_mat, rho, n_iters = run_ecc(
            ref_proc, src_proc, warp_mode, ECC_MAX_ITERS, ECC_EPS
        )
        elapsed_ms = (time.perf_counter() - t0) * 1000

        if converged:
            # warp_mat maps src → ref; translation is in column 2
            est_tx = warp_mat[0, 2]
            est_ty = warp_mat[1, 2]
            # ECC aligns src into ref: the warp should recover -gt_tx, -gt_ty
            tx_err = abs(est_tx - (-gt_tx))
            ty_err = abs(est_ty - (-gt_ty))
            te_px = np.sqrt(tx_err**2 + ty_err**2)
        else:
            est_tx = est_ty = 0.0
            tx_err = abs(gt_tx)
            ty_err = abs(gt_ty)
            te_px = np.sqrt(gt_tx**2 + gt_ty**2)

        results.append(
            ECCResult(
                variant=variant_name,
                warp_mode_name=mode_name,
                img_name=img_name,
                gt_tx=gt_tx,
                gt_ty=gt_ty,
                converged=converged,
                final_rho=rho,
                tx_err=tx_err,
                ty_err=ty_err,
                te_px=te_px,
                n_iters=n_iters,
                elapsed_ms=elapsed_ms,
            )
        )

    return results


# ---------------------------------------------------------------------------
# Gradient strength diagnostics
# ---------------------------------------------------------------------------


def gradient_energy(gray: np.ndarray) -> float:
    """Mean gradient magnitude — proxy for how informative the image is for ECC."""
    gx = cv2.Sobel(gray.astype(np.float32), cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray.astype(np.float32), cv2.CV_32F, 0, 1, ksize=3)
    return float(np.mean(np.sqrt(gx**2 + gy**2)))


# ---------------------------------------------------------------------------
# Visualization
# ---------------------------------------------------------------------------


def save_sample_variants(bgr_img: np.ndarray, variants: dict, img_name: str):
    """Save a montage of preprocessed images for visual inspection."""
    names = sorted(variants.keys())
    n = len(names)
    cols = 8
    rows = (n + cols - 1) // cols

    fig, axes = plt.subplots(rows, cols, figsize=(cols * 2.2, rows * 2.2))
    axes = np.array(axes).ravel()

    for ax, name in zip(axes, names):
        proc = variants[name](bgr_img)
        ax.imshow(proc, cmap="gray", vmin=0, vmax=255)
        ax.set_title(name, fontsize=6)
        ax.axis("off")

    for ax in axes[n:]:
        ax.axis("off")

    plt.suptitle(f"Preprocessed variants — {img_name}", fontsize=9)
    plt.tight_layout()
    out_path = OUT_DIR / f"ecc_variants_{img_name.replace('.', '_')}.png"
    plt.savefig(out_path, dpi=120, bbox_inches="tight")
    plt.close()
    print(f"  Saved variant montage → {out_path.name}")


def plot_summary(summary: dict[str, dict], mode_name: str):
    """Bar chart: mean TE error and convergence rate per variant (sorted by TE)."""
    records = [
        (name, d["mean_te"], d["conv_rate"], d["mean_rho"], d["mean_ms"])
        for name, d in summary.items()
    ]
    records.sort(key=lambda x: (-(x[2]), x[1]))  # sort by conv_rate desc, then TE asc

    names = [r[0] for r in records]
    means = [r[1] for r in records]
    cr = [r[2] * 100 for r in records]  # percent
    rhos = [r[3] for r in records]

    x = np.arange(len(names))

    fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(max(12, len(names) * 0.35), 12))

    colors = ["green" if c >= 90 else "orange" if c >= 60 else "red" for c in cr]
    ax1.bar(x, means, color=colors)
    ax1.set_xticks(x)
    ax1.set_xticklabels(names, rotation=75, ha="right", fontsize=7)
    ax1.set_ylabel("Mean Translation Error (px)")
    ax1.set_title(
        f"ECC Alignment Error by Preprocessing Variant [{mode_name}]\n"
        f"(green=≥90% converged, orange=≥60%, red=<60%)"
    )
    ax1.axhline(
        1.0, color="gray", linestyle="--", linewidth=0.8, label="1 px threshold"
    )
    ax1.legend(fontsize=8)

    ax2.bar(x, cr, color=colors)
    ax2.set_xticks(x)
    ax2.set_xticklabels(names, rotation=75, ha="right", fontsize=7)
    ax2.set_ylabel("Convergence Rate (%)")
    ax2.set_ylim(0, 105)
    ax2.axhline(90, color="gray", linestyle="--", linewidth=0.8)

    ax3.bar(x, rhos, color=colors)
    ax3.set_xticks(x)
    ax3.set_xticklabels(names, rotation=75, ha="right", fontsize=7)
    ax3.set_ylabel("Mean ECC Rho (correlation)")
    ax3.set_ylim(0, 1.05)

    plt.tight_layout()
    out_path = OUT_DIR / f"ecc_summary_{mode_name}.png"
    plt.savefig(out_path, dpi=130, bbox_inches="tight")
    plt.close()
    print(f"  Saved summary plot → {out_path.name}")


def plot_gradient_energy(energy_table: dict[str, float]):
    """Bar chart of gradient energy per variant."""
    items = sorted(energy_table.items(), key=lambda x: -x[1])
    names = [i[0] for i in items]
    vals = [i[1] for i in items]
    x = np.arange(len(names))

    fig, ax = plt.subplots(figsize=(max(12, len(names) * 0.35), 5))
    ax.bar(x, vals, color="steelblue")
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=75, ha="right", fontsize=7)
    ax.set_ylabel("Mean Gradient Energy")
    ax.set_title("Gradient Energy by Preprocessing Variant")
    plt.tight_layout()
    out_path = OUT_DIR / "ecc_gradient_energy.png"
    plt.savefig(out_path, dpi=120, bbox_inches="tight")
    plt.close()
    print(f"  Saved gradient energy plot → {out_path.name}")


# ---------------------------------------------------------------------------
# Top-10 visual inspection
# ---------------------------------------------------------------------------

_INSPECT_SAMPLES = 3  # number of (image, shift) pairs to visualise per variant


def _warp_src_onto_ref(
    src_bgr: np.ndarray, warp_mat: np.ndarray, warp_mode: int
) -> np.ndarray:
    """Apply the ECC warp matrix to src and return the result, same size as src."""
    h, w = src_bgr.shape[:2]
    flags = cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP
    return cv2.warpAffine(
        src_bgr, warp_mat, (w, h), flags=flags, borderMode=cv2.BORDER_REPLICATE
    )


def _diff_overlay(ref: np.ndarray, aligned: np.ndarray) -> np.ndarray:
    """
    Visualise alignment error as a colour overlay.
    Green channel = reference, magenta channel = aligned source.
    Perfect alignment → gray. Residual error → colour tinge.
    """
    ref_f = ref.astype(np.float32) / 255.0
    aln_f = aligned.astype(np.float32) / 255.0

    # Convert both to grayscale for the overlay
    def to_gray_f(bgr_f):
        return 0.299 * bgr_f[:, :, 2] + 0.587 * bgr_f[:, :, 1] + 0.114 * bgr_f[:, :, 0]

    rg = to_gray_f(ref_f)
    ag = to_gray_f(aln_f)
    out = np.stack([ag, (rg + ag) * 0.5, rg], axis=-1)  # B=aligned, G=avg, R=ref
    return (np.clip(out, 0, 1) * 255).astype(np.uint8)


def save_top10_visual_inspection(
    top10_names: list[str],
    variants: dict[str, any],
    source_images: list[tuple[str, np.ndarray]],
) -> None:
    """
    For each of the top-10 preprocessing variants, produce a multi-panel
    figure showing _INSPECT_SAMPLES representative (image, shift) pairs.

    Each row covers one sample:
      Col 0: Reference crop (BGR)
      Col 1: Shifted source crop (BGR)
      Col 2: Preprocessed reference (gray)
      Col 3: Preprocessed source (gray)
      Col 4: Source warped onto reference (BGR)
      Col 5: Diff overlay (green=ref, magenta=aligned)

    Files saved to:  scripts/tmp_files/top10_visual/
    """
    vis_dir = OUT_DIR / "top10_visual"
    vis_dir.mkdir(exist_ok=True)

    # Pick representative samples: spread across images and shifts
    # Use first 2 images and 3 shifts for diversity
    sample_combos: list[tuple[str, np.ndarray, int, int]] = []
    shifts_for_sample = [(4, 0), (5, 3), (-3, 7)]
    for img_name, bgr_img in source_images[:3]:
        for gt_tx, gt_ty in shifts_for_sample:
            sample_combos.append((img_name, bgr_img, gt_tx, gt_ty))
            if len(sample_combos) >= _INSPECT_SAMPLES * 3:
                break
        if len(sample_combos) >= _INSPECT_SAMPLES * 3:
            break
    # truncate to desired number
    sample_combos = sample_combos[:_INSPECT_SAMPLES]

    n_rows = len(sample_combos)
    n_cols = 6
    col_labels = [
        "Reference",
        "Shifted Source",
        "Preproc Ref",
        "Preproc Src",
        "Aligned (src→ref)",
        "Diff Overlay",
    ]

    warp_mode = cv2.MOTION_TRANSLATION

    for rank, vname in enumerate(top10_names, 1):
        fn = variants[vname]
        fig, axes = plt.subplots(n_rows, n_cols, figsize=(n_cols * 3, n_rows * 3.2))
        if n_rows == 1:
            axes = axes[np.newaxis, :]

        for row_idx, (img_name, bgr_img, gt_tx, gt_ty) in enumerate(sample_combos):
            ref_bgr, src_bgr = translate_crop(bgr_img, gt_tx, gt_ty)

            # Preprocess
            try:
                ref_proc = fn(ref_bgr).astype(np.float32)
                src_proc = fn(src_bgr).astype(np.float32)
            except Exception as e:
                for c in range(n_cols):
                    axes[row_idx, c].set_facecolor("black")
                    axes[row_idx, c].axis("off")
                axes[row_idx, 0].set_title(f"[ERROR] {e}", fontsize=6, color="red")
                continue

            # Run ECC
            warp = np.eye(2, 3, dtype=np.float32)
            criteria = (
                cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT,
                ECC_MAX_ITERS,
                ECC_EPS,
            )
            converged = False
            rho = 0.0
            try:
                rho, warp = cv2.findTransformECC(
                    ref_proc, src_proc, warp, warp_mode, criteria, gaussFiltSize=5
                )
                converged = True
            except cv2.error:
                pass

            # Warp source BGR onto reference
            aligned_bgr = _warp_src_onto_ref(src_bgr, warp, warp_mode)
            diff_vis = _diff_overlay(ref_bgr, aligned_bgr)

            # Stats
            est_tx = warp[0, 2]
            est_ty = warp[1, 2]
            te = np.sqrt((est_tx - (-gt_tx)) ** 2 + (est_ty - (-gt_ty)) ** 2)
            status = "OK" if converged else "FAIL"
            border_color = "#00c853" if converged else "#d50000"

            label_top = f"{img_name[:18]}  GT({gt_tx},{gt_ty})"
            label_stats = (
                f"{status} rho={rho:.4f}\nest({est_tx:.1f},{est_ty:.1f})  TE={te:.2f}px"
            )

            panels = [
                cv2.cvtColor(ref_bgr, cv2.COLOR_BGR2RGB),
                cv2.cvtColor(src_bgr, cv2.COLOR_BGR2RGB),
                ref_proc.astype(np.uint8),
                src_proc.astype(np.uint8),
                cv2.cvtColor(aligned_bgr, cv2.COLOR_BGR2RGB),
                cv2.cvtColor(diff_vis, cv2.COLOR_BGR2RGB),
            ]
            cmaps = [None, None, "gray", "gray", None, None]

            for col_idx, (panel, cmap) in enumerate(zip(panels, cmaps)):
                ax = axes[row_idx, col_idx]
                ax.imshow(panel, cmap=cmap, vmin=0, vmax=255)
                ax.axis("off")
                if row_idx == 0:
                    ax.set_title(col_labels[col_idx], fontsize=8, fontweight="bold")
                if col_idx == 0:
                    ax.set_ylabel(label_top, fontsize=7, labelpad=4)
                if col_idx == 5:
                    ax.set_xlabel(
                        label_stats, fontsize=7, color="green" if converged else "red"
                    )
                # coloured border on diff column to flag convergence
                for spine in ax.spines.values():
                    spine.set_edgecolor(border_color)
                    spine.set_linewidth(2.5 if col_idx == 5 else 0.5)

        fig.suptitle(f"#{rank:02d} {vname}", fontsize=11, fontweight="bold", y=1.005)
        plt.tight_layout()
        out_path = vis_dir / f"{rank:02d}_{vname}.png"
        plt.savefig(out_path, dpi=130, bbox_inches="tight")
        plt.close()
        print(f"  Saved visual panel → top10_visual/{out_path.name}")

    # --- Combined overview strip: one row per top-10 variant, diff col only ---
    print("  Generating combined diff overview strip...")
    strip_sample = sample_combos[0]  # use first sample for the strip
    img_name_s, bgr_img_s, gt_tx_s, gt_ty_s = strip_sample
    ref_bgr_s, src_bgr_s = translate_crop(bgr_img_s, gt_tx_s, gt_ty_s)

    n = len(top10_names)
    fig2, axes2 = plt.subplots(2, n, figsize=(n * 2.5, 5.5))
    for col_idx, vname in enumerate(top10_names):
        fn = variants[vname]
        ref_proc = fn(ref_bgr_s).astype(np.float32)
        src_proc = fn(src_bgr_s).astype(np.float32)
        warp = np.eye(2, 3, dtype=np.float32)
        criteria = (
            cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT,
            ECC_MAX_ITERS,
            ECC_EPS,
        )
        converged = False
        rho_s = 0.0
        try:
            rho_s, warp = cv2.findTransformECC(
                ref_proc, src_proc, warp, warp_mode, criteria, gaussFiltSize=5
            )
            converged = True
        except cv2.error:
            pass
        aligned_s = _warp_src_onto_ref(src_bgr_s, warp, warp_mode)
        diff_s = _diff_overlay(ref_bgr_s, aligned_s)
        rank = col_idx + 1
        color = "green" if converged else "red"
        te_s = np.sqrt((warp[0, 2] - (-gt_tx_s)) ** 2 + (warp[1, 2] - (-gt_ty_s)) ** 2)
        axes2[0, col_idx].imshow(fn(ref_bgr_s), cmap="gray", vmin=0, vmax=255)
        axes2[0, col_idx].axis("off")
        axes2[0, col_idx].set_title(
            f"#{rank} {vname}", fontsize=6.5, color=color, fontweight="bold"
        )
        axes2[1, col_idx].imshow(cv2.cvtColor(diff_s, cv2.COLOR_BGR2RGB))
        axes2[1, col_idx].axis("off")
        axes2[1, col_idx].set_xlabel(
            f"TE={te_s:.2f}px\nrho={rho_s:.4f}", fontsize=6.5, color=color
        )
    axes2[0, 0].set_ylabel("Preproc (ref)", fontsize=8)
    axes2[1, 0].set_ylabel("Diff overlay", fontsize=8)
    fig2.suptitle(
        f"Top-10 Variants — Diff Overlay Overview\n"
        f"Sample: {img_name_s}  GT=({gt_tx_s},{gt_ty_s})px",
        fontsize=9,
    )
    plt.tight_layout()
    strip_path = vis_dir / "00_top10_overview.png"
    plt.savefig(strip_path, dpi=140, bbox_inches="tight")
    plt.close()
    print("  Saved overview strip → top10_visual/00_top10_overview.png")


# ---------------------------------------------------------------------------
# Main experiment loop
# ---------------------------------------------------------------------------


def main():
    print("=" * 70)
    print("ECC Preprocessing Experiment — Histology WSI")
    print("=" * 70)

    source_images = load_source_images()
    variants = build_variants()
    print(f"Testing {len(variants)} preprocessing variants")
    print(f"GT translations: {GT_TRANSLATIONS}")
    print()

    # Save visual montage of variants on first image
    first_img_name, first_img = source_images[0]
    cx, cy = first_img.shape[1] // 2, first_img.shape[0] // 2
    sample_crop = extract_crop(first_img, cx, cy, CROP_SIZE)
    print("Generating variant montage...")
    save_sample_variants(sample_crop, variants, first_img_name)

    # --- Gradient energy table ---
    print("\nComputing gradient energy on sample crop...")
    energy_table: dict[str, float] = {}
    for vname, fn in variants.items():
        try:
            proc = fn(sample_crop)
            energy_table[vname] = gradient_energy(proc)
        except Exception as e:
            energy_table[vname] = 0.0
            print(f"  [WARN] gradient energy failed for {vname}: {e}")
    plot_gradient_energy(energy_table)

    # --- ECC alignment experiment ---
    all_results: list[ECCResult] = []
    total_runs = len(source_images) * len(GT_TRANSLATIONS) * len(variants)
    done = 0

    # Open CSV incrementally so partial results survive interruption
    csv_path = OUT_DIR / "ecc_preprocess_results.csv"
    fieldnames = [f.name for f in ECCResult.__dataclass_fields__.values()]
    csv_fh = open(csv_path, "w", newline="")
    csv_writer = csv.DictWriter(csv_fh, fieldnames=fieldnames)
    csv_writer.writeheader()

    try:
        for img_name, bgr_img in source_images:
            img_batch: list[ECCResult] = []

            for gt_tx, gt_ty in GT_TRANSLATIONS:
                ref_bgr, src_bgr = translate_crop(bgr_img, gt_tx, gt_ty)

                for vname, fn in variants.items():
                    try:
                        results = align_and_evaluate(
                            vname, fn, ref_bgr, src_bgr, gt_tx, gt_ty, img_name
                        )
                        img_batch.extend(results)
                    except Exception as e:
                        print(f"  [ERROR] {vname} on {img_name} ({gt_tx},{gt_ty}): {e}")

                    done += 1
                    if done % 50 == 0 or done == total_runs:
                        print(
                            f"  Progress: {done}/{total_runs} variant×image×shift combos"
                        )

            # Flush this image's results to CSV immediately
            for r in img_batch:
                csv_writer.writerow({f: getattr(r, f) for f in fieldnames})
            csv_fh.flush()
            all_results.extend(img_batch)
            print(f"  Saved {len(img_batch)} rows for {img_name} → {csv_path.name}")

    finally:
        csv_fh.close()

    print(f"\nTotal saved: {len(all_results)} result rows → {csv_path.name}")

    # --- Aggregate statistics ---
    from collections import defaultdict

    def default_agg():
        return {"te": [], "rho": [], "converged": [], "ms": []}

    agg: dict[str, dict[str, list]] = defaultdict(lambda: defaultdict(list))

    for r in all_results:
        key = (r.variant, r.warp_mode_name)
        agg[key]["te"].append(r.te_px)
        agg[key]["rho"].append(r.final_rho)
        agg[key]["converged"].append(int(r.converged))
        agg[key]["ms"].append(r.elapsed_ms)

    # Build summary per mode
    for mode_name in WARP_MODES:
        summary: dict[str, dict] = {}
        for vname in variants:
            key = (vname, mode_name)
            d = agg.get(key, None)
            if not d:
                continue
            summary[vname] = {
                "mean_te": float(np.mean(d["te"])),
                "median_te": float(np.median(d["te"])),
                "mean_rho": float(np.mean(d["rho"])),
                "conv_rate": float(np.mean(d["converged"])),
                "mean_ms": float(np.mean(d["ms"])),
                "grad_energy": energy_table.get(vname, 0.0),
            }
        plot_summary(summary, mode_name)

    # --- Human-readable summary report ---
    summary_path = OUT_DIR / "ecc_preprocess_summary.txt"
    with open(summary_path, "w") as fh:

        def w(s=""):
            print(s)
            fh.write(s + "\n")

        w("=" * 80)
        w("ECC PREPROCESSING EXPERIMENT — RESULTS SUMMARY")
        w(f"Date: {time.strftime('%Y-%m-%d %H:%M')}")
        w(f"Images: {[n for n, _ in source_images]}")
        w(f"Crop size: {CROP_SIZE}x{CROP_SIZE}  |  GT shifts: {GT_TRANSLATIONS}")
        w(f"ECC: max_iters={ECC_MAX_ITERS}, eps={ECC_EPS}")
        w("=" * 80)

        for mode_name in WARP_MODES:
            summary = {}
            for vname in variants:
                key = (vname, mode_name)
                d = agg.get(key, None)
                if not d:
                    continue
                summary[vname] = {
                    "mean_te": float(np.mean(d["te"])),
                    "median_te": float(np.median(d["te"])),
                    "mean_rho": float(np.mean(d["rho"])),
                    "conv_rate": float(np.mean(d["converged"])),
                    "mean_ms": float(np.mean(d["ms"])),
                }

            ranked = sorted(
                summary.items(), key=lambda x: (-(x[1]["conv_rate"]), x[1]["mean_te"])
            )

            w(f"\n{'─' * 80}")
            w(f"  Warp mode: {mode_name.upper()}")
            w(f"{'─' * 80}")
            w(
                f"  {'Rank':<4} {'Variant':<26} {'Conv%':>6} {'MeanTE':>8} "
                f"{'MedTE':>8} {'MeanRho':>8} {'ms':>7}"
            )
            w(
                f"  {'-' * 4} {'-' * 26} {'-' * 6} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 7}"
            )
            for rank, (vname, s) in enumerate(ranked, 1):
                w(
                    f"  {rank:<4} {vname:<26} "
                    f"{s['conv_rate'] * 100:>5.1f}% "
                    f"{s['mean_te']:>8.3f} "
                    f"{s['median_te']:>8.3f} "
                    f"{s['mean_rho']:>8.4f} "
                    f"{s['mean_ms']:>7.1f}"
                )

        w("\n" + "=" * 80)
        w("TOP 10 VARIANTS (by convergence rate, then mean TE) — TRANSLATION MODE")
        w("=" * 80)
        mode_name = "translation"
        summary = {}
        for vname in variants:
            key = (vname, mode_name)
            d = agg.get(key, None)
            if not d:
                continue
            summary[vname] = {
                "mean_te": float(np.mean(d["te"])),
                "conv_rate": float(np.mean(d["converged"])),
                "mean_rho": float(np.mean(d["rho"])),
                "mean_ms": float(np.mean(d["ms"])),
                "grad_e": energy_table.get(vname, 0.0),
            }
        top10 = sorted(
            summary.items(), key=lambda x: (-(x[1]["conv_rate"]), x[1]["mean_te"])
        )[:10]
        for rank, (vname, s) in enumerate(top10, 1):
            w(
                f"  #{rank:2d}  {vname:<28}  "
                f"conv={s['conv_rate'] * 100:.0f}%  "
                f"TE={s['mean_te']:.3f}px  "
                f"rho={s['mean_rho']:.4f}  "
                f"GradE={s['grad_e']:.2f}  "
                f"{s['mean_ms']:.1f}ms"
            )

    print(f"\nFull summary → {summary_path.name}")

    # --- Top-10 visual inspection panels ---
    print("\nGenerating visual inspection panels for top 10 variants...")
    top10_names = [vname for vname, _ in top10]
    save_top10_visual_inspection(top10_names, variants, source_images)

    print("Done.")


if __name__ == "__main__":
    main()
