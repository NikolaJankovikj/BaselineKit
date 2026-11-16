import numpy as np
import torch

from fixtures import HORIZON, Fixtures, pack
from graph import CONTEXT, OBSERVED, ROWS, VALUE, Chronos2Export
from export import load_pipeline

# Float32 round-off between two orderings of the same arithmetic.
RESTATEMENT_TOLERANCE = 1e-3


def test_pack_left_pads_history_and_groups_rows_by_task():
    known = {"past": [0.0, 1.0, 0.0], "future": [1.0, np.nan]}
    task = {"target": [[5.0, np.nan, 7.0]], "past": [[1.0, 2.0, 3.0]], "known": [known]}
    packed = pack([task, {"target": [[9.0]]}])

    context = packed["context"]
    assert context[0, VALUE, -3:].tolist() == [5.0, 0.0, 7.0]
    assert context[0, OBSERVED, -3:].tolist() == [1.0, 0.0, 1.0]
    assert context[0, OBSERVED, :-3].sum() == 0
    assert packed["group_ids"][:5].tolist() == [0, 0, 0, 1, 4]
    assert packed["known_future"][2, VALUE, :2].tolist() == [1.0, 0.0]
    assert packed["known_future"][2, OBSERVED].sum() == 1
    assert packed["known_future"][[0, 1, 3]].sum() == 0


def test_export_graph_reproduces_stock_pipeline_on_every_fixture():
    pipeline = load_pipeline()
    fixtures = Fixtures.build(pipeline)
    export = Chronos2Export(pipeline.model.eval()).eval()
    with torch.no_grad():
        quantiles = export(*map(torch.from_numpy, fixtures.inputs.values())).numpy()

    assert quantiles.shape == (ROWS, len(fixtures.levels), HORIZON)
    assert fixtures.inputs["context"].shape == (ROWS, 2, CONTEXT)
    assert np.isfinite(quantiles).all()
    assert fixtures.band_errors(quantiles).max() < RESTATEMENT_TOLERANCE
