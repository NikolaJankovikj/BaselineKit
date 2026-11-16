"""Export Chronos-2-small to Core ML for the app.

Run from this directory:
    uv run python export.py

Writes into the app repo:
    BaselineKit/Sources/Forecasting/Resources/Chronos2Small.mlpackage   the model
    BaselineKit/Tests/ForecastingTests/Fixtures/chronos2_golden.json    parity fixtures
    docs/coreml_parity.md                                                size, latency, error

Every weight-compression variant is converted and measured against the stock
PyTorch pipeline on the golden fixtures; SHIPPED is the one the app gets.
"""

from __future__ import annotations

import json
import logging
import platform
import shutil
import time
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import torch

from fixtures import HORIZON, Fixtures
from graph import CONTEXT, ROWS, Chronos2Export

log = logging.getLogger("export_coreml")

DEFAULT_MODEL = "autogluon/chronos-2-small"
HERE = Path(__file__).resolve().parent
APP = HERE.parents[1]
WORK = HERE / "build"
MODEL_PATH = "BaselineKit/Sources/Forecasting/Resources/Chronos2Small.mlpackage"
FIXTURES_PATH = "BaselineKit/Tests/ForecastingTests/Fixtures/chronos2_golden.json"
REPORT_PATH = "docs/coreml_parity.md"

COMPRESSION = {
    "int8": (
        cto.linear_quantize_weights,
        cto.OpLinearQuantizerConfig(
            mode="linear_symmetric", dtype="int8", granularity="per_channel"
        ),
    ),
    "palette6": (cto.palettize_weights, cto.OpPalettizerConfig(mode="kmeans", nbits=6)),
    "palette4": (cto.palettize_weights, cto.OpPalettizerConfig(mode="kmeans", nbits=4)),
}
VARIANTS = ("float32", *COMPRESSION)
SHIPPED = "int8"
# Largest |Core ML − PyTorch| the app's parity test accepts at any quantile level
# from q10 to q90 of any fixture, as a fraction of that forecast's q10–q90 width.
PARITY_TOLERANCE = 0.05
LATENCY_REPEATS = 20


def convert(export: Chronos2Export, inputs: dict[str, np.ndarray]):
    """Trace the export graph and convert it to an ML Program."""
    example = tuple(torch.from_numpy(value) for value in inputs.values())
    with torch.no_grad():
        traced = torch.jit.trace(export, example)
    input_types = [
        ct.TensorType(name=name, shape=value.shape, dtype=value.dtype.type)
        for name, value in inputs.items()
    ]
    return ct.convert(
        traced,
        inputs=input_types,
        outputs=[ct.TensorType(name="quantiles")],
        convert_to="mlprogram",
        # Instance normalisation squares raw values, and a day's step count
        # squared overflows float16.
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS18,
    )


def compress(mlmodel, variant: str):
    if variant not in COMPRESSION:
        return mlmodel
    apply, op_config = COMPRESSION[variant]
    return apply(mlmodel, cto.OptimizationConfig(global_config=op_config))


def set_metadata(mlmodel, levels: list[float]) -> None:
    mlmodel.short_description = f"{DEFAULT_MODEL}, zero-shot quantile forecaster"
    mlmodel.license = "Apache-2.0"
    # The app finds q10 / q50 / q90 in the output by these levels.
    mlmodel.user_defined_metadata["quantile_levels"] = ",".join(map(str, levels))


def measure(mlmodel, package: Path, fixtures: Fixtures) -> dict[str, float]:
    """Save a variant and measure it as the app runs it: from disk, on the CPU."""
    mlmodel.save(str(package))
    loaded = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_ONLY)
    errors = fixtures.band_errors(loaded.predict(fixtures.inputs)["quantiles"])
    band = errors[:, fixtures.band_levels]
    files = (f for f in package.rglob("*") if f.is_file())
    return {
        "size_mb": sum(f.stat().st_size for f in files) / 1e6,
        "latency_ms": _median_latency_ms(loaded, fixtures.inputs),
        "max_error": float(band.max()),
        "mean_error": float(band.mean()),
        "max_tail_error": float(errors.max()),
    }


def _median_latency_ms(mlmodel, inputs: dict[str, np.ndarray]) -> float:
    times = []
    for _ in range(LATENCY_REPEATS):
        start = time.perf_counter()
        mlmodel.predict(inputs)
        times.append((time.perf_counter() - start) * 1e3)
    return float(np.median(times))


def fixtures_document(fixtures: Fixtures) -> dict:
    tasks = [
        {**_jsonable(task), "quantiles": _jsonable(reference)}
        for task, reference in zip(fixtures.tasks, fixtures.reference, strict=True)
    ]
    return {
        "model": DEFAULT_MODEL,
        "quantile_levels": fixtures.levels,
        "tolerance": PARITY_TOLERANCE,
        "tasks": tasks,
    }


def _jsonable(value):
    """Plain JSON data, with None for NaN, which JSON cannot hold."""
    if isinstance(value, dict):
        return {key: _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, np.ndarray)):
        return [_jsonable(item) for item in value]
    if isinstance(value, str):
        return value
    return None if np.isnan(value) else float(value)


def report(measurements: dict[str, dict[str, float]], n_levels: int) -> str:
    rows = [
        f"| {name}{' **(shipped)**' if name == SHIPPED else ''} | {m['size_mb']:.1f} "
        f"| {m['latency_ms']:.0f} | {m['max_error']:.4f} | {m['mean_error']:.4f} "
        f"| {m['max_tail_error']:.4f} |"
        for name, m in measurements.items()
    ]
    return REPORT_TEMPLATE.format(
        model=DEFAULT_MODEL,
        rows=ROWS,
        context=CONTEXT,
        horizon=HORIZON,
        levels=n_levels,
        table="\n".join(rows),
        tolerance=PARITY_TOLERANCE,
        machine=f"{platform.processor()} {platform.machine()}, macOS {platform.mac_ver()[0]}",
        versions=f"coremltools {ct.__version__}, torch {torch.__version__}",
    )


REPORT_TEMPLATE = """\
# Core ML export of {model}

Generated by `tools/coreml_export/export.py`; do not edit by hand.

One fixed-shape ML Program: {rows} rows × {context} context steps in,
{levels} quantile levels × {horizon} steps out. Float32 compute, CPU.

| Weights | Size (MB) | Latency (ms / {rows}-row call) | Max error, q10–q90 \
| Mean error, q10–q90 | Max error, all {levels} levels |
|---|---|---|---|---|---|
{table}

- **Error** is |Core ML − PyTorch `Chronos2Pipeline.predict`| at every step of
  every golden fixture target, as a fraction of that forecast's q10–q90 width.
  The fixtures cover cold start, a history longer than the context, missing
  values, a constant series, joint targets, and past plus known-future covariates.
- The app reads q10, q50 and q90, so the **tolerance** for the shipped model is
  max error < {tolerance} over the levels q10–q90. The Swift parity test
  (`ForecastingTests`) asserts it against the same fixtures. Weight compression
  costs most at the extreme levels (q01, q99), which the app does not use.
- **Latency** is the median single call on the machine that ran the export
  ({machine}), not on an iPhone. The app logs on-device latency itself.
- Built with {versions}.
"""


def load_pipeline():
    from chronos import BaseChronosPipeline

    return BaseChronosPipeline.from_pretrained(DEFAULT_MODEL, device_map="cpu")


def install(fixtures: Fixtures, measurements: dict) -> None:
    model = APP / MODEL_PATH
    shutil.rmtree(model, ignore_errors=True)
    shutil.copytree(WORK / f"{SHIPPED}.mlpackage", model)
    for path, text in (
        (APP / FIXTURES_PATH, json.dumps(fixtures_document(fixtures))),
        (APP / REPORT_PATH, report(measurements, len(fixtures.levels))),
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    pipeline = load_pipeline()
    fixtures = Fixtures.build(pipeline)
    base = convert(Chronos2Export(pipeline.model.eval()).eval(), fixtures.inputs)
    measurements = measure_variants(base, fixtures)
    shipped_error = measurements[SHIPPED]["max_error"]
    assert shipped_error < PARITY_TOLERANCE, f"{SHIPPED} is off by {shipped_error}"
    install(fixtures, measurements)


def measure_variants(base, fixtures: Fixtures) -> dict[str, dict[str, float]]:
    WORK.mkdir(parents=True, exist_ok=True)
    measurements = {}
    for variant in VARIANTS:
        mlmodel = compress(base, variant)
        set_metadata(mlmodel, fixtures.levels)
        package = WORK / f"{variant}.mlpackage"
        measurements[variant] = measure(mlmodel, package, fixtures)
        log.info("%s: %s", variant, measurements[variant])
    return measurements


if __name__ == "__main__":
    main()
