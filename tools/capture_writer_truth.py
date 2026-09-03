"""
Capture the writer's ground truth for the Swift port to be checked against.

Greedy, so it is reproducible: same prompt, same ids, every time. The Swift
side has to produce exactly this text from exactly this prompt, or the port is
wrong somewhere no amount of reading the output would reveal — a KV cache fed
back a position out gives fluent, plausible, different prose.

    python3 tools/capture_writer_truth.py

Writes MimicKit/Tests/Fixtures/writer-truth.json. Needs the writer model in
~/.mimic/model (writer.onnx, writer_tokenizer.json) and onnxruntime + tokenizers.
"""
import json
import pathlib
import sys

import numpy as np
import onnxruntime as ort
from tokenizers import Tokenizer

MODEL = pathlib.Path("~/.mimic/model").expanduser()
OUT = pathlib.Path(__file__).resolve().parent.parent / "MimicKit/Tests/Fixtures/writer-truth.json"

SYSTEM = "You write short pieces of text to be read aloud."
USER = "a limerick about a cat who is late"
EOS = {151645, 151643}


def prompt(system: str, user: str) -> str:
    return (f"<|im_start|>system\n{system}<|im_end|>\n"
            f"<|im_start|>user\n{user}<|im_end|>\n"
            f"<|im_start|>assistant\n")


def main() -> int:
    if not (MODEL / "writer.onnx").is_file():
        print(f"no writer model in {MODEL} — download it in the app first", file=sys.stderr)
        return 1

    config = json.loads((MODEL / "writer_config.json").read_text())
    layers = config["num_hidden_layers"]
    kv_heads = config["num_key_value_heads"]
    head_dim = config.get("head_dim", config["hidden_size"] // config["num_attention_heads"])

    tokenizer = Tokenizer.from_file(str(MODEL / "writer_tokenizer.json"))
    session = ort.InferenceSession(str(MODEL / "writer.onnx"),
                                   providers=["CPUExecutionProvider"])

    ids = tokenizer.encode(prompt(SYSTEM, USER), add_special_tokens=False).ids
    past = {f"past_key_values.{i}.{kind}":
            np.zeros((1, kv_heads, 0, head_dim), dtype=np.float32)
            for i in range(layers) for kind in ("key", "value")}

    produced, position, step = [], 0, ids
    for _ in range(40):
        n = len(step)
        outputs = session.run(None, {
            "input_ids": np.array([step], dtype=np.int64),
            "attention_mask": np.ones((1, position + n), dtype=np.int64),
            "position_ids": np.arange(position, position + n, dtype=np.int64)[None, :],
            **past,
        })
        token = int(np.argmax(outputs[0][0, -1]))     # greedy: no seed to disagree on
        if token in EOS:
            break
        produced.append(token)
        position += n
        for i in range(layers):
            past[f"past_key_values.{i}.key"] = outputs[1 + 2 * i]
            past[f"past_key_values.{i}.value"] = outputs[2 + 2 * i]
        step = [token]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps({
        "system": SYSTEM,
        "user": USER,
        "prompt_ids_head": ids[:12],
        "prompt_token_count": len(ids),
        "greedy_ids": produced,
        "text": tokenizer.decode(produced),
    }, indent=2) + "\n")
    print(f"wrote {OUT.relative_to(OUT.parent.parent.parent)} — {len(produced)} tokens")
    return 0


if __name__ == "__main__":
    sys.exit(main())
