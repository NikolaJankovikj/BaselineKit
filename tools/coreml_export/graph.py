"""Fixed-shape, NaN-free restatement of `Chronos2Model.forward` for Core ML tracing.

It shares the original weights and takes masks instead of NaNs:

    context       (ROWS, 2, CONTEXT)  channel VALUE and channel OBSERVED (1 = seen)
    known_future  (ROWS, 2, patch)    known-future covariate values, same channels
    group_ids     (ROWS,)             rows with the same id attend to each other
 -> quantiles     (ROWS, levels, patch)  in the units of each row

A shorter history is left-padded with OBSERVED = 0, which is exact: unobserved
patches are never attended to, RoPE is relative, and the time encoding counts
back from the forecast start.  An unused row is all-unobserved and alone in its
group.  Values where OBSERVED = 0 are ignored.
"""

from __future__ import annotations

import torch
from torch import nn

ROWS = 32
CONTEXT = 512
VALUE, OBSERVED = 0, 1
# Added to attention scores that must not be attended to.  The original adds
# float32 min; anything far below the unscaled scores gives the same softmax,
# and this value also survives a float16 graph.
MASKED = -1e4


class Chronos2Export(nn.Module):
    def __init__(self, model, context_length: int = CONTEXT):
        super().__init__()
        cfg = model.chronos_config
        assert context_length % cfg.input_patch_size == 0, (
            "context must be whole patches"
        )
        assert cfg.use_reg_token, "the export lays tokens out as context, [REG], future"
        assert cfg.use_arcsinh, "the export always applies arcsinh scaling"
        self.encoder = model.encoder
        self.embed_patch = model.input_patch_embedding
        self.project_quantiles = model.output_patch_embedding
        self.patch = cfg.input_patch_size
        self.n_quantiles = len(cfg.quantiles)
        self.n_heads = model.config.num_heads
        self.half_head = model.config.d_kv // 2
        self.eps = model.instance_norm.eps
        for name, table in _constant_tables(model, context_length).items():
            self.register_buffer(name, table)

    def forward(self, context, known_future, group_ids):
        loc_scale = self._location_and_scale(context)
        hidden = self._embed(context, known_future, loc_scale)
        time_mask, group_mask = _attention_masks(self._attendable(context), group_ids)
        for block in self.encoder.block:
            time, group, feed_forward = block.layer
            hidden = hidden + self._attend(
                time.self_attention, time.layer_norm(hidden), time_mask, self._rotate
            )
            across = hidden.transpose(0, 1)
            across = across + self._attend(
                group.self_attention, group.layer_norm(across), group_mask, _unrotated
            )
            hidden = feed_forward(across.transpose(0, 1))
        hidden = self.encoder.final_layer_norm(hidden)
        scaled = self.project_quantiles(hidden[:, -1, :])
        quantiles = torch.sinh(scaled.view(-1, self.n_quantiles, self.patch))
        loc, scale = loc_scale
        return quantiles * scale.unsqueeze(-1) + loc.unsqueeze(-1)

    def _location_and_scale(self, context):
        """Mean and std of the observed values, as `InstanceNorm` gets from nanmean."""
        values, observed = context[:, VALUE], context[:, OBSERVED]
        n_observed = observed.sum(-1, keepdim=True)
        count = n_observed.clamp(min=1.0)
        loc = (values * observed).sum(-1, keepdim=True) / count
        squared = (values - loc) ** 2 * observed
        scale = (squared.sum(-1, keepdim=True) / count).sqrt()
        scale = torch.where(n_observed > 0, scale, torch.ones_like(scale))
        scale = torch.where(scale == 0, torch.full_like(scale, self.eps), scale)
        return loc, scale

    def _embed(self, context, known_future, loc_scale):
        """Token embeddings (rows, seq, d_model): context patches, [REG], future patch."""
        context_patches = self._patch_features(context, self.context_time, loc_scale)
        future_patch = self._patch_features(known_future, self.future_time, loc_scale)
        context_tokens = self.embed_patch(context_patches)
        reg = self.reg_token.expand_as(context_tokens[:, :1])
        return torch.cat([context_tokens, reg, self.embed_patch(future_patch)], dim=1)

    def _patch_features(self, series, time_encoding, loc_scale):
        """(rows, 2, n·patch) → (rows, n, 3·patch): time, scaled value, observed."""
        loc, scale = loc_scale
        observed = series[:, OBSERVED]
        scaled = _arcsinh((series[:, VALUE] - loc) / scale) * observed
        scaled = self._patches(scaled)
        features = [time_encoding.expand_as(scaled), scaled, self._patches(observed)]
        return torch.cat(features, dim=-1)

    def _patches(self, series):
        """(rows, n·patch) → (rows, n, patch).  Shapes are never read back from a
        tensor: the converter cannot fold the integer casts that tracing them emits."""
        return series.unflatten(-1, (-1, self.patch))

    def _attendable(self, context):
        """(rows, seq) of 0/1.  A context patch needs one observed value; [REG] and
        the future patch can always be attended to."""
        observed = self._patches(context[:, OBSERVED])
        patch_observed = (observed.sum(-1) > 0).to(context.dtype)
        return torch.cat(
            [patch_observed, torch.ones_like(patch_observed[:, :2])], dim=1
        )

    def _attend(self, attention, states, mask, rotate):
        """Unscaled multi-head attention along dim 1 of (n, length, d_model)."""
        query = rotate(self._heads(attention.q(states)))
        key = rotate(self._heads(attention.k(states)))
        weights = torch.softmax(query @ key.transpose(-1, -2) + mask, dim=-1)
        mixed = (weights @ self._heads(attention.v(states))).transpose(1, 2)
        return attention.o(mixed.flatten(start_dim=2))

    def _heads(self, states):
        """(n, length, heads·d) → (n, heads, length, d)."""
        return states.unflatten(-1, (self.n_heads, -1)).transpose(1, 2)

    def _rotate(self, states):
        half = self.half_head
        rotated = torch.cat([-states[..., half:], states[..., :half]], dim=-1)
        return states * self.rope_cos + rotated * self.rope_sin


def _arcsinh(x):
    """`torch.asinh` from ops Core ML has.  Taking the log of |x| + √(x² + 1) and
    restoring the sign avoids the cancellation that x + √(x² + 1) has for x < 0."""
    return torch.sign(x) * torch.log(torch.abs(x) + torch.sqrt(x * x + 1.0))


def _unrotated(states):
    """Rows of a group have no order, so group attention carries no position."""
    return states


def _attention_masks(attendable, group_ids):
    """Additive masks: time (rows, 1, 1, seq) and group (seq, 1, rows, rows)."""
    time_mask = (1.0 - attendable)[:, None, None, :] * MASKED
    same_group = (group_ids[:, None] == group_ids[None, :]).to(attendable.dtype)
    # [t, query row, key row]: the key row is in the query's group and attendable at t
    visible = same_group[None] * attendable.transpose(0, 1)[:, None, :]
    return time_mask, (1.0 - visible)[:, None] * MASKED


def _constant_tables(model, context_length: int) -> dict[str, torch.Tensor]:
    """What a fixed shape lets the export precompute instead of trace."""
    cfg = model.chronos_config
    context_time, future_time = _time_encodings(cfg, context_length)
    seq_len = context_length // cfg.input_patch_size + 2  # + [REG] and the future patch
    cos, sin = _rope_tables(model, seq_len)
    reg_token = model.shared.weight[model.config.reg_token_id]
    return {
        "reg_token": reg_token.detach().view(1, 1, -1),
        "context_time": context_time,
        "future_time": future_time,
        "rope_cos": cos,
        "rope_sin": sin,
    }


def _time_encodings(cfg, context_length: int):
    """Step index / scale, patched: the context counts back from 0, the future forward."""
    patch, scale = cfg.input_patch_size, cfg.time_encoding_scale
    context = torch.arange(-context_length, 0, dtype=torch.float32) / scale
    future = torch.arange(0, patch, dtype=torch.float32) / scale
    return context.view(1, -1, patch), future.view(1, 1, patch)


def _rope_tables(model, seq_len: int):
    """cos and sin of the rotary angles, (1, 1, seq_len, d_head)."""
    time_layer = model.encoder.block[0].layer[0]
    rope = time_layer.self_attention.rope_embed
    positions = torch.arange(seq_len, dtype=torch.float32)
    angles = torch.outer(positions, rope.inv_freq.float())
    angles = torch.cat([angles, angles], dim=-1)[None, None]
    return angles.cos(), angles.sin()
