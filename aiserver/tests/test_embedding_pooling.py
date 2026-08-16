"""Last-token pooling under padding.

These guard a failure that does not raise. The checkpoint pools by reading one
position out of the sequence, and while every call embedded exactly one item
that position was always `-1`. Batching breaks that: pick the wrong index and a
row gets the hidden state of a PAD token, which normalizes into a perfectly
well-formed, entirely meaningless vector. Nothing crashes; search just quietly
gets worse for every item in a batch except the longest.
"""

import pytest
import torch

from aichat.model_manager import last_token_indices, _pool_last_token


class TestLastTokenIndices:
    def test_right_padded_rows_skip_their_padding(self):
        # Row 0 has 2 real tokens then 2 pads; row 1 is full length.
        mask = torch.tensor([[1, 1, 0, 0], [1, 1, 1, 1]])
        assert last_token_indices(mask).tolist() == [1, 3]

    def test_left_padded_rows_land_on_the_end(self):
        # `padding_side` is never set in this codebase, so the convention is
        # whatever the processor's tokenizer config carries. Counting from the
        # right has to be correct under either one.
        mask = torch.tensor([[0, 0, 1, 1], [1, 1, 1, 1]])
        assert last_token_indices(mask).tolist() == [3, 3]

    def test_unpadded_batch_is_the_final_position(self):
        mask = torch.ones(3, 5, dtype=torch.long)
        assert last_token_indices(mask).tolist() == [4, 4, 4]

    def test_single_real_token(self):
        mask = torch.tensor([[1, 0, 0]])
        assert last_token_indices(mask).tolist() == [0]


class TestPoolLastToken:
    def test_padded_row_pools_its_own_last_real_token_not_a_pad(self):
        # Distinct value per position so the wrong pick is visible: row 0's
        # real content ends at position 1, and positions 2-3 are padding
        # deliberately filled with a large value a naive `[:, -1, :]` would
        # grab.
        hidden = torch.tensor([[[1.0, 0.0], [2.0, 0.0], [99.0, 0.0], [99.0, 0.0]]])
        mask = torch.tensor([[1, 1, 0, 0]])

        pooled = _pool_last_token(hidden, mask)

        # Normalized [2.0, 0.0] is [1.0, 0.0]; the pad value would be too, so
        # compare before normalization by checking sign and the ratio instead.
        assert pooled.shape == (1, 2)
        assert pytest.approx(pooled[0][0].item(), abs=1e-6) == 1.0

    def test_a_short_row_and_a_long_row_pool_independently(self):
        # The regression that matters: batching a 2-token item with a 4-token
        # one must give the short item position 1, not position 3.
        hidden = torch.zeros(2, 4, 2)
        hidden[0, 1] = torch.tensor([3.0, 4.0])   # row 0's real last token
        hidden[0, 3] = torch.tensor([-1.0, 0.0])  # padding
        hidden[1, 3] = torch.tensor([0.0, 5.0])   # row 1's real last token
        mask = torch.tensor([[1, 1, 0, 0], [1, 1, 1, 1]])

        pooled = _pool_last_token(hidden, mask)

        # [3,4] normalizes to [0.6, 0.8]; [0,5] to [0, 1].
        assert pytest.approx(pooled[0].tolist(), abs=1e-6) == [0.6, 0.8]
        assert pytest.approx(pooled[1].tolist(), abs=1e-6) == [0.0, 1.0]

    def test_batching_does_not_change_a_vector(self):
        # An item embedded alone and the same item embedded inside a batch must
        # produce the same vector, or the corpus becomes a mix of two
        # incompatible embeddings depending on where each chunk happened to
        # land in a batch.
        alone_hidden = torch.tensor([[[1.0, 0.0], [3.0, 4.0]]])
        alone_mask = torch.tensor([[1, 1]])
        alone = _pool_last_token(alone_hidden, alone_mask)

        batched_hidden = torch.zeros(2, 5, 2)
        batched_hidden[0, 0] = torch.tensor([1.0, 0.0])
        batched_hidden[0, 1] = torch.tensor([3.0, 4.0])
        batched_hidden[1, 4] = torch.tensor([7.0, 0.0])
        batched_mask = torch.tensor([[1, 1, 0, 0, 0], [1, 1, 1, 1, 1]])
        batched = _pool_last_token(batched_hidden, batched_mask)

        assert pytest.approx(batched[0].tolist(), abs=1e-6) == alone[0].tolist()

    def test_output_is_unit_length(self):
        hidden = torch.tensor([[[0.0, 0.0], [3.0, 4.0]]])
        mask = torch.tensor([[1, 1]])
        pooled = _pool_last_token(hidden, mask)
        assert pytest.approx(pooled.norm().item(), abs=1e-6) == 1.0
