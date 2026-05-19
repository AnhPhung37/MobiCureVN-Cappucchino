from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol

import httpx


class Answerer(Protocol):
    def answer(self, question: str, context: str) -> str: ...


@dataclass(frozen=True)
class OpenAICompatibleConfig:
    base_url: str
    model: str
    api_key: str | None = None
    timeout_s: int = 120


@dataclass(frozen=True)
class OllamaConfig:
    base_url: str
    model: str
    timeout_s: int = 120


class OpenAICompatibleAnswerer:
    def __init__(self, cfg: OpenAICompatibleConfig) -> None:
        self._cfg = cfg

    def answer(self, question: str, context: str) -> str:
        headers = {"Content-Type": "application/json"}
        if self._cfg.api_key:
            headers["Authorization"] = f"Bearer {self._cfg.api_key}"

        payload = {
            "model": self._cfg.model,
            "messages": [
                {
                    "role": "system",
                    "content": "You are a medical assistant. Answer only using the provided context.",
                },
                {
                    "role": "user",
                    "content": f"Question: {question}\n\nContext:\n{context}\n\nAnswer:",
                },
            ],
            "temperature": 0.0,
        }

        with httpx.Client(timeout=self._cfg.timeout_s) as client:
            resp = client.post(
                f"{self._cfg.base_url.rstrip('/')}/v1/chat/completions",
                headers=headers,
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        return data["choices"][0]["message"]["content"].strip()


class OllamaAnswerer:
    def __init__(self, cfg: OllamaConfig) -> None:
        self._cfg = cfg

    def answer(self, question: str, context: str) -> str:
        payload = {
            "model": self._cfg.model,
            "prompt": (
                "You are a medical assistant. Answer only using the provided context.\n\n"
                f"Question: {question}\n\nContext:\n{context}\n\nAnswer:"
            ),
            "options": {"temperature": 0.0},
            "stream": False,
        }

        with httpx.Client(timeout=self._cfg.timeout_s) as client:
            resp = client.post(
                f"{self._cfg.base_url.rstrip('/')}/api/generate",
                json=payload,
            )
            resp.raise_for_status()
            data = resp.json()

        return data.get("response", "").strip()
