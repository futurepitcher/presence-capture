"""Python bindings for the capture schema (v0.1.0-draft).

Mirrors src/types.d.ts. Hand-written for the draft; both move to generation
from a single source once the spec freezes.
"""

from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field

PrivacyLevel = Literal["standard", "sensitive", "excluded", "sacred_mode"]
GrantablePrivacyLevel = Literal["standard", "sensitive", "excluded"]
CaptureType = Literal[
    "screen_frame",
    "screen_text",
    "audio_segment",
    "audio_transcript",
    "audio_alignment",
    "activity",
]
Extraction = Literal["accessibility", "ocr", "asr", "none"]
RevocationScopeKind = Literal["capture", "time_range", "source", "privacy_level"]
ProjectionKind = Literal["index", "vector", "summary"]


class CapturePayload(BaseModel):
    payload_hash: str
    byte_count: int
    media_type: str
    storage_uri: str
    created_at: str


class CaptureEvent(BaseModel):
    capture_id: str
    sequence: int
    captured_at: str
    capture_type: CaptureType
    source: str
    source_app: Optional[str] = None
    source_url: Optional[str] = None
    privacy_level: PrivacyLevel
    classification: Optional[str] = None
    payload_hash: Optional[str] = None
    content_text: Optional[str] = None
    extraction: Optional[Extraction] = None
    derived_from: Optional[str] = None
    dedupe_key: Optional[str] = None


class Revocation(BaseModel):
    revocation_id: str
    sequence: int
    revoked_at: str
    scope_kind: RevocationScopeKind
    scope_value: str
    reason: Optional[str] = None


class Grant(BaseModel):
    grant_id: str
    client_id: str
    issued_at: str
    expires_at: str
    domains: list[str] = Field(default_factory=lambda: ["*"])
    time_from: Optional[str] = None
    time_to: Optional[str] = None
    privacy_levels: list[GrantablePrivacyLevel] = Field(default_factory=lambda: ["standard"])
    capture_types: list[str] = Field(default_factory=lambda: ["*"])
    sources: list[str] = Field(default_factory=lambda: ["*"])
    max_rows_per_query: int = 100
    revoked_at: Optional[str] = None


class EgressRecord(BaseModel):
    egress_id: int
    served_at: str
    client_id: str
    grant_id: str
    tool: str
    query_fingerprint: str
    capture_ids: list[str]
    privacy_levels_served: list[PrivacyLevel]
    row_count: int
    byte_count: int
    prev_hash: str
    record_hash: str


class EnvelopeProvenance(BaseModel):
    capture_id: str
    captured_at: str
    source_app: Optional[str]
    source_url: Optional[str]
    capture_type: CaptureType
    privacy_level: PrivacyLevel
    extraction: Optional[Extraction]


class UntrustedPayload(BaseModel):
    envelope_version: Literal["1"]
    provenance: EnvelopeProvenance
    content: Optional[str]


class UntrustedEnvelope(BaseModel):
    presence_capture_untrusted: UntrustedPayload
