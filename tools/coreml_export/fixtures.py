"""Golden forecasting tasks: the inputs the app sends and what stock Chronos-2 answers.

A task is a dict: "target" (list of histories, forecast jointly), optional "past"
(past-only covariate histories) and optional "known" (covariates with a "past"
history and a "future" of up to HORIZON known values).  NaN marks a missing value.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from graph import CONTEXT, OBSERVED, ROWS, VALUE

HORIZON = 16
LOWER, UPPER = 0.1, 0.9
DEGENERATE_BAND = 1e-3
SEED = 7
DAYS = 120
DAYS_PER_WEEK = 7
SATURDAY = 5
MISSING_SHARE = 0.25


def task_rows(task: dict) -> list[tuple]:
    """(history, known future or None) for each model row of a task, targets first."""
    forecast_only = [*task["target"], *task.get("past", [])]
    known = [(k["past"], k["future"]) for k in task.get("known", [])]
    return [(history, None) for history in forecast_only] + known


def pack(tasks: list[dict], rows: int = ROWS) -> dict[str, np.ndarray]:
    """Lay tasks out as inputs of the exported graph, one group per task."""
    packed = {
        "context": np.zeros((rows, 2, CONTEXT), dtype=np.float32),
        "known_future": np.zeros((rows, 2, HORIZON), dtype=np.float32),
        # A row no task uses keeps its own index, which no task has as group.
        "group_ids": np.arange(rows, dtype=np.int32),
    }
    row = 0
    for group, task in enumerate(tasks):
        for history, future in task_rows(task):
            recent = _recent(history)
            packed["context"][row] = _masked(recent, CONTEXT, CONTEXT - len(recent))
            if future is not None:
                packed["known_future"][row] = _masked(_floats(future), HORIZON, 0)
            packed["group_ids"][row] = group
            row += 1
    return packed


def _masked(values: np.ndarray, length: int, start: int) -> np.ndarray:
    """(2, length): the values from `start` with 0 for NaN, and their observed flags."""
    out = np.zeros((2, length), dtype=np.float32)
    observed = ~np.isnan(values)
    out[VALUE, start : start + len(values)] = np.where(observed, values, 0.0)
    out[OBSERVED, start : start + len(values)] = observed
    return out


def _floats(values) -> np.ndarray:
    return np.asarray(values, dtype=np.float32)


def _recent(history) -> np.ndarray:
    return _floats(history)[..., -CONTEXT:]


def fixture_tasks() -> list[dict]:
    """Daily-health-shaped tasks covering the cases the app relies on."""
    rng = np.random.default_rng(SEED)
    return [*_single_series_tasks(rng), *_joint_tasks(rng)]


def _single_series_tasks(rng) -> list[dict]:
    steps = _noisy(rng, 700, level=9000, noise=2500) + _weekly(700, 1500)
    gappy = _noisy(rng, 200, level=14.5, noise=0.6)
    gappy[rng.random(200) < MISSING_SHARE] = np.nan
    gappy[40:70] = np.nan
    return [
        {"name": "cold_start_9_days", "target": [_noisy(rng, 9, level=61, noise=2.5)]},
        {"name": "longer_than_context", "target": [steps]},
        {"name": "missing_values", "target": [gappy]},
        {"name": "constant_series", "target": [np.full(30, 36.6)]},
    ]


def _joint_tasks(rng) -> list[dict]:
    resting_hr = _noisy(rng, DAYS, level=58, noise=2.0) + _weekly(DAYS, 1.0)
    hrv = _noisy(rng, DAYS, level=62, noise=8.0) - _weekly(DAYS, 3.0)
    load = np.abs(_noisy(rng, DAYS, level=450, noise=150))
    weekday = np.arange(DAYS + HORIZON) % DAYS_PER_WEEK
    weekend = (weekday >= SATURDAY).astype(float)
    known_weekend = {"past": weekend[:DAYS], "future": weekend[DAYS:]}
    both = [resting_hr, hrv]
    return [
        {"name": "joint_two_targets", "target": both},
        {
            "name": "joint_with_covariates",
            "target": both,
            "past": [load],
            "known": [known_weekend],
        },
    ]


def _noisy(rng, n: int, *, level: float, noise: float) -> np.ndarray:
    return level + noise * rng.standard_normal(n)


def _weekly(n: int, amplitude: float) -> np.ndarray:
    return amplitude * np.sin(2 * np.pi * np.arange(n) / DAYS_PER_WEEK)


def reference_quantiles(pipeline, task: dict) -> np.ndarray:
    """Forecast one task with the stock pipeline: (n_targets, n_quantiles, HORIZON)."""
    known = task.get("known", [])
    past = {f"past{i}": _recent(s) for i, s in enumerate(task.get("past", []))}
    past |= {f"known{i}": _recent(k["past"]) for i, k in enumerate(known)}
    inputs: dict = {"target": _recent(task["target"])}
    if past:
        inputs["past_covariates"] = past
    if known:
        future = {f"known{i}": _floats(k["future"]) for i, k in enumerate(known)}
        inputs["future_covariates"] = future
    return pipeline.predict([inputs], prediction_length=HORIZON)[0].numpy()


@dataclass
class Fixtures:
    tasks: list[dict]
    inputs: dict[str, np.ndarray]
    reference: list[np.ndarray]
    levels: list[float]

    @classmethod
    def build(cls, pipeline) -> Fixtures:
        tasks = fixture_tasks()
        reference = [reference_quantiles(pipeline, task) for task in tasks]
        levels = [round(float(level), 2) for level in pipeline.quantiles]
        return cls(tasks, pack(tasks), reference, levels)

    @property
    def band_levels(self) -> slice:
        """The quantile levels from LOWER to UPPER, the ones the app reads."""
        return slice(self.levels.index(LOWER), self.levels.index(UPPER) + 1)

    def band_errors(self, quantiles: np.ndarray) -> np.ndarray:
        """|model − reference| as a fraction of the reference LOWER–UPPER width,
        shaped (target rows, levels, HORIZON).  `quantiles` is the graph output
        for `self.inputs`."""
        band = self.band_levels
        errors, row = [], 0
        for task, ref in zip(self.tasks, self.reference, strict=True):
            width = ref[:, band.stop - 1] - ref[:, band.start]
            # A constant series has no band to measure against; use its level.
            width = np.maximum(width, DEGENERATE_BAND * (1 + np.abs(ref).mean(axis=1)))
            errors.append(
                np.abs(quantiles[row : row + len(ref)] - ref) / width[:, None]
            )
            row += len(task_rows(task))
        return np.concatenate(errors)
