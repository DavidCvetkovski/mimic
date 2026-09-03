"""
Capture the speech engine's ground truth for the Swift port to be checked
against.

A reimplementation of an autoregressive loop is wrong in ways unit tests
written from the same misunderstanding will not catch — so the Swift side is
compared against what the reference implementation actually produces: the same
tokeniser output, the same prompt grid, the same alignment of the reference
codes under the semantic row.

    python3 tools/capture_speech_truth.py

Writes MimicKit/Tests/Fixtures/speech-truth.json. Needs the model in
~/.mimic/model and a voice named David in ~/.mimic/voices.
"""
import json
import pathlib
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

HOME = pathlib.Path("~/.mimic").expanduser()
MODEL, VOICES = HOME / "model", HOME / "voices"
OUT = pathlib.Path(__file__).resolve().parent.parent / "MimicKit/Tests/Fixtures/speech-truth.json"

VOICE = "David"
TEXT = "The quick brown fox jumps over the lazy dog."


def main() -> int:
    from core.vendor.arktts.prompt import PromptBuilder

    manifest_path = MODEL / "runtime_manifest.json"
    if not manifest_path.is_file():
        print(f"no model in {MODEL}", file=sys.stderr)
        return 1
    meta_path = VOICES / VOICE / "meta.json"
    if not meta_path.is_file():
        print(f"no voice named {VOICE} in {VOICES}", file=sys.stderr)
        return 1

    manifest = json.loads(manifest_path.read_text())
    meta = json.loads(meta_path.read_text())
    codes = np.load(VOICES / VOICE / "codes.npy").astype(np.int64)

    builder = PromptBuilder(MODEL / "tokenizer",
                            manifest["semantic_begin_id"], manifest["num_codebooks"])
    # build returns [1, codebooks + 1, tokens]; the leading axis is the batch,
    # and the grid the Swift side compares against is what is inside it.
    grid = builder.build(TEXT, meta["reference_text"], codes)[0]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "text": TEXT,
        "reference_text": meta["reference_text"],
        "shape": list(grid.shape),
        "row0_head": grid[0][:24].tolist(),
        "row0_tail": grid[0][-24:].tolist(),
        "row0_sum": int(grid[0].sum()),
        "row1_sum": int(grid[1].sum()),
        # The first thing that can silently differ: a different BPE
        # implementation gives plausible-looking but wrong ids.
        "encode_probe": builder.encode_text("<|im_start|>system\n"),
    }, indent=2) + "\n")
    print(f"wrote {OUT.name} — prompt {grid.shape}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
