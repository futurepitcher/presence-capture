/**
 * TypeScript bindings for the capture schema.
 *
 * Generated-by-hand for v0.1.0-draft. Once the spec freezes these move to
 * generation from a single source alongside the Python models.
 */

export type PrivacyLevel = 'standard' | 'sensitive' | 'excluded' | 'sacred_mode';

/** Privacy levels a grant may name. `sacred_mode` is absent by design. */
export type GrantablePrivacyLevel = Exclude<PrivacyLevel, 'sacred_mode'>;

export type CaptureType =
  | 'screen_frame'
  | 'screen_text'
  | 'audio_segment'
  | 'audio_transcript'
  | 'audio_alignment'
  | 'activity';

export type Extraction = 'accessibility' | 'ocr' | 'asr' | 'none';

export type RevocationScopeKind = 'capture' | 'time_range' | 'source' | 'privacy_level';

export type ProjectionKind = 'index' | 'vector' | 'summary';

export interface CapturePayload {
  payloadHash: string;
  byteCount: number;
  mediaType: string;
  storageUri: string;
  createdAt: string;
}

export interface CaptureEvent {
  captureId: string;
  /** Monotonic. The replay ordering (R4). */
  sequence: number;
  capturedAt: string;
  captureType: CaptureType;
  source: string;
  sourceApp: string | null;
  /** `null` when the daemon could not establish it. Never guessed. */
  sourceUrl: string | null;
  privacyLevel: PrivacyLevel;
  /** Opaque to the schema. Any taxonomy fits (R6). */
  classification: string | null;
  payloadHash: string | null;
  contentText: string | null;
  extraction: Extraction | null;
  /** Set on derived artifacts: a transcript points at its audio (R10). */
  derivedFrom: string | null;
  dedupeKey: string | null;
}

export interface Revocation {
  revocationId: string;
  sequence: number;
  revokedAt: string;
  scopeKind: RevocationScopeKind;
  scopeValue: string;
  reason: string | null;
}

export interface Grant {
  grantId: string;
  clientId: string;
  issuedAt: string;
  /** Required. A grant with no expiry is not issuable (ADR 0001 §4.1). */
  expiresAt: string;
  domains: string[];
  timeFrom: string | null;
  timeTo: string | null;
  privacyLevels: GrantablePrivacyLevel[];
  captureTypes: Array<CaptureType | '*'>;
  sources: string[];
  maxRowsPerQuery: number;
  revokedAt: string | null;
}

export interface EgressRecord {
  egressId: number;
  servedAt: string;
  clientId: string;
  grantId: string;
  tool: string;
  /** Hash of the query, not the query text. */
  queryFingerprint: string;
  captureIds: string[];
  privacyLevelsServed: PrivacyLevel[];
  rowCount: number;
  byteCount: number;
  prevHash: string;
  recordHash: string;
}

/** The only shape in which capture content crosses an MCP boundary. */
export interface UntrustedEnvelope {
  presence_capture_untrusted: {
    envelope_version: '1';
    /** Populated from capture metadata, never derived from content. */
    provenance: {
      capture_id: string;
      captured_at: string;
      source_app: string | null;
      source_url: string | null;
      capture_type: CaptureType;
      privacy_level: PrivacyLevel;
      extraction: Extraction | null;
    };
    /** Attacker-controlled. Data, never instructions. */
    content: string | null;
  };
}

export interface VectorStore {
  upsert(entry: { captureId: string; entryRef: string; vector: number[] }): void;
  /** Must actually remove. R3 is mandatory regardless of backend. */
  deleteByCaptureIds(captureIds: string[]): number;
  entryRefsFor(captureId: string): string[];
  size(): number;
}
