# Embedder candidates: Qwen3-Embedding-0.6B (and EmbeddingGemma, not run)

Branch `final0.1-embedder-candidates`, on `main`. Follow-up to
`Docs/BE/Multilingual-Embedder-Handoff.md` §9: can a newer small multilingual embedder replace
`BAAI/bge-small-en-v1.5`, and in particular let a Vietnamese query retrieve from the English corpus
without the translation step?

## What changed

- `Pipeline/tools/compare_embedders.py` — prompts for `Qwen/Qwen3-Embedding-0.6B` (its
  `config_sentence_transformers.json` query instruction, empty document prompt) and
  `google/embeddinggemma-300m` (`task: search result | query: ` / `title: none | text: `), and
  `--candidates` to run the shipped model against both.
- `Docs/audits/embedder-candidates.json` — the run below.

## Result

`python -m tools.compare_embedders --models BAAI/bge-small-en-v1.5 Qwen/Qwen3-Embedding-0.6B --device cpu --batch-size 8`,
split corpus (1876 chunks, 39 docs), 209 English golden questions, 12 Vietnamese questions paired with
their English twins, laptop CPU.

| | bge-small-en-v1.5 (shipped) | Qwen3-Embedding-0.6B |
|---|---|---|
| Dimensions | 384 | 1024 |
| Parameters | ~33M | ~600M |
| Corpus embedding time (CPU) | 73 s | 681 s (9.3×) |
| EN recall@5 | **0.2632** | 0.2297 |
| EN doc-hit@5 | 0.7943 | **0.7990** |
| EN mrr | **0.1756** | 0.1695 |
| EN nDCG@5 | **0.1970** | 0.1843 |
| EN recall@10 | 0.3158 | **0.3206** |
| EN doc-hit@10 | **0.8708** | 0.8612 |
| VI→EN chunk overlap@5 | 0.000 | **0.450** |
| VI→EN same document@5 | 0.583 | **0.917** |
| cos(VI query, EN twin) | 0.403 | **0.694** |

Vector search only — no FTS, no fusion — so these are not the app's hybrid numbers; they compare
embedders like for like.

## Reading it

- **English: no gain.** Qwen3 is within noise of bge-small on doc-hit and below it on recall@5,
  mrr and nDCG@5. Swapping for English quality alone is not justified.
- **Cross-lingual: large gain.** A Vietnamese query finds the same document as its English twin
  11 times in 12 (bge-small: 7 in 12) and shares 45% of the top-5 chunks (bge-small: none — it is
  an English-only model). This is the only reason to consider the swap: it could let Vietnamese
  queries skip the VI→EN translation before retrieval.
- **12 Vietnamese questions is too few to decide on.** Treat the cross-lingual rows as a direction,
  not a result.
- **Cost on the device.** ~18× the parameters and 2.7× the vector size of the shipped model: a larger
  CoreML package, slower query embedding, and a `vec_chunks` index ~2.7× larger. It would need the
  full swap in the handoff doc §6 (converter, tokenizer — Qwen3 is BPE, not WordPiece — parity
  fixture, both indexes rebuilt).

## Not run

- **`google/embeddinggemma-300m`** — gated. This machine has no Hugging Face token. Accept the licence
  on its model page, `huggingface-cli login`, then `python -m tools.compare_embedders --candidates`.
- **Hybrid numbers** (the app's retriever with a Qwen3 index) and **a larger Vietnamese set** — both
  needed before any swap decision.

## Verdict

Keep `bge-small-en-v1.5`. Qwen3-Embedding-0.6B is only worth pursuing if the goal becomes dropping
the translation hop for Vietnamese, and then only after a bigger Vietnamese golden set and an
on-device latency check of the 0.6B query encoder.
