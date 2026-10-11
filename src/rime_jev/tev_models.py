"""Explicit local Tev choices, pinned to official runner-specific manifests."""

from typing import Literal, TypedDict


class TevModel(TypedDict):
    tag: str
    digest: str
    bytes: int
    label: str
    runner: Literal["llamacpp", "mlx"]


TEV_MODELS: dict[str, TevModel] = {
    "tev-0.8b": {
        "tag": "tev1:0.8b",
        "digest": "d6e7bb9bfe0feda2548249c5fe9dde6113cf62d4a7eb0f95f5612573c2f2146e",
        "bytes": 796578327,
        "label": "Tev 0.8B",
        "runner": "mlx",
    },
    "tev-4b": {
        "tag": "tev1:4b",
        "digest": "4d24c6f6d61a48d9b72902f4805c5f1da53010736b834b0372377fb4bb7e53d3",
        "bytes": 4361568088,
        "label": "Tev 4B",
        "runner": "mlx",
    },
}

__all__ = ["TEV_MODELS", "TevModel"]
