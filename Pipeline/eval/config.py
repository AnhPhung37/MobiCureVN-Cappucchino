from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class EmbedConfig:
    model_name: str
    embed_dim: int
    batch_size: int
    normalize: bool = True


@dataclass(frozen=True)
class EvaluationConfig:
    queries_path: Path
    qrels_path: Path
    top_k: int
    seed: int


@dataclass(frozen=True)
class ExperimentConfig:
    name: str
    source_chunks_dir: Path
    enriched_output_dir: Path
    index_db_path: Path


@dataclass(frozen=True)
class ProjectConfig:
    registry_path: Path
    embed: EmbedConfig
    evaluation: EvaluationConfig
    experiments: list[ExperimentConfig]
