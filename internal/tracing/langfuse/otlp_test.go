package langfuse

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// decodeOTLPSpans unmarshals an OTLP/JSON body into the flat list of spans.
func decodeOTLPSpans(t *testing.T, body []byte) []map[string]interface{} {
	t.Helper()
	var req map[string]interface{}
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatalf("unmarshal OTLP: %v", err)
	}
	var spans []map[string]interface{}
	for _, rs := range asSlice(req["resourceSpans"]) {
		for _, ss := range asSlice(rs.(map[string]interface{})["scopeSpans"]) {
			for _, sp := range asSlice(ss.(map[string]interface{})["spans"]) {
				spans = append(spans, sp.(map[string]interface{}))
			}
		}
	}
	return spans
}

func mkEvent(typ string, body interface{}) ingestionEvent {
	return ingestionEvent{ID: newID(), Timestamp: isoTime(time.Now()), Type: typ, Body: body}
}

// TestClient_OTLPGateHeaders asserts the HTTP request carries the headers
// LiteFuse / Langfuse v3 require on /api/public/otel/v1/traces: Basic auth,
// the x-langfuse-ingestion-version: 4 gate opt-in, and the SDK markers.
// This guards against a future refactor silently dropping the gate header
// (which would resurface the 400 "requires Python SDK >= 4.0.0" failure).
func TestClient_OTLPGateHeaders(t *testing.T) {
	var gotHeaders http.Header
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotHeaders = r.Header.Clone()
		gotPath = r.URL.Path
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m, err := Init(Config{
		Enabled: true, Host: srv.URL, PublicKey: "pk", SecretKey: "sk",
		FlushAt: 16, FlushInterval: 1 * time.Second, QueueSize: 16,
		RequestTimeout: 2 * time.Second, SampleRate: 1.0,
	})
	if err != nil {
		t.Fatalf("init: %v", err)
	}

	_, trace := m.StartTrace(context.Background(), TraceOptions{Name: "h"})
	trace.Finish(nil, nil)

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	if gotPath != "/api/public/otel/v1/traces" {
		t.Errorf("path = %q, want /api/public/otel/v1/traces", gotPath)
	}
	if v := gotHeaders.Get("x-langfuse-ingestion-version"); v != "4" {
		t.Errorf("x-langfuse-ingestion-version = %q, want 4", v)
	}
	if v := gotHeaders.Get("x-langfuse-sdk-name"); v != "python" {
		t.Errorf("x-langfuse-sdk-name = %q, want python", v)
	}
	if v := gotHeaders.Get("x-langfuse-sdk-version"); v != "4.0.0" {
		t.Errorf("x-langfuse-sdk-version = %q, want 4.0.0", v)
	}
	if auth := gotHeaders.Get("Authorization"); !strings.HasPrefix(auth, "Basic ") {
		t.Errorf("Authorization = %q, want Basic ...", auth)
	}
	if v := gotHeaders.Get("Content-Type"); v != "application/json" {
		t.Errorf("Content-Type = %q, want application/json", v)
	}
	// Exact Basic-auth value, not just the prefix — guards against a future
	// change to the credential layout (e.g. secret:key reorder) silently
	// sending the wrong identity and getting 401s from the gate.
	wantAuth := "Basic " + base64.StdEncoding.EncodeToString([]byte("pk:sk"))
	if got := gotHeaders.Get("Authorization"); got != wantAuth {
		t.Errorf("Authorization = %q, want %q", got, wantAuth)
	}
}

// TestBuildOTLPRequest_MergesCreateAndUpdate verifies that a create event
// followed by an update event for the same observation id fold into a single
// OTel span carrying the create's model + the update's usage.
func TestBuildOTLPRequest_MergesCreateAndUpdate(t *testing.T) {
	traceID := "550e8400-e29b-41d4-a716-446655440000"
	obsID := "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
	events := []ingestionEvent{
		mkEvent("trace-create", traceBody{ID: traceID, Name: "root"}),
		mkEvent("generation-create", observationBody{
			ID: obsID, TraceID: traceID, Type: "GENERATION", Name: "llm", Model: "gpt-test",
			StartTime: isoTime(time.Now()), Input: "hi",
		}),
		mkEvent("generation-update", observationBody{
			ID: obsID, TraceID: traceID, Type: "GENERATION",
			EndTime: isoTime(time.Now()), Output: "hello",
			Usage: &TokenUsage{Input: 10, Output: 20, Total: 30, Unit: "TOKENS"},
		}),
	}
	body, err := buildOTLPRequest(events, Config{PublicKey: "pk"})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	spans := decodeOTLPSpans(t, body)

	var gen map[string]interface{}
	for _, sp := range spans {
		if spanType(sp) == "generation" {
			gen = sp
		}
	}
	if gen == nil {
		t.Fatalf("no generation span in %d spans", len(spans))
	}
	if spanAttrStr(gen, "langfuse.observation.model.name") != "gpt-test" {
		t.Errorf("model lost in merge: %q", spanAttrStr(gen, "langfuse.observation.model.name"))
	}
	usage := spanAttrStr(gen, "langfuse.observation.usage_details")
	if !strings.Contains(usage, `"total":30`) {
		t.Errorf("usage lost in merge: %q", usage)
	}
	if spanAttrStr(gen, "langfuse.observation.output") == "" {
		t.Errorf("output lost in merge")
	}
}

// TestBuildOTLPRequest_EmptyParentRootsUnderTrace verifies an observation
// with no explicit parent observation is parented to the root trace span
// (OTLP has no implicit parent — otherwise it'd become a disconnected root).
func TestBuildOTLPRequest_EmptyParentRootsUnderTrace(t *testing.T) {
	traceID := "550e8400-e29b-41d4-a716-446655440000"
	obsID := "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
	events := []ingestionEvent{
		mkEvent("trace-create", traceBody{ID: traceID, Name: "root"}),
		mkEvent("span-create", observationBody{
			ID: obsID, TraceID: traceID, Type: "SPAN", Name: "orphan", StartTime: isoTime(time.Now()),
		}),
	}
	body, err := buildOTLPRequest(events, Config{PublicKey: "pk"})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	spans := decodeOTLPSpans(t, body)

	var span map[string]interface{}
	for _, sp := range spans {
		if spanType(sp) == "span" {
			span = sp
		}
	}
	if span == nil {
		t.Fatalf("no span observation")
	}
	if span["parentSpanId"] != spanIDHex(traceID) {
		t.Errorf("empty-parent span parentSpanId = %v, want %q (root)", span["parentSpanId"], spanIDHex(traceID))
	}
}

// TestBuildOTLPRequest_ObservationsWithoutTraceCreate covers the ResumeTrace
// path: a batch with observations but no trace-create event (the HTTP parent
// owns the root). Spans still emit, parented to their trace id.
func TestBuildOTLPRequest_ObservationsWithoutTraceCreate(t *testing.T) {
	traceID := "550e8400-e29b-41d4-a716-446655440000"
	obsID := "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
	events := []ingestionEvent{
		mkEvent("span-create", observationBody{
			ID: obsID, TraceID: traceID, Type: "SPAN", Name: "child", StartTime: isoTime(time.Now()),
		}),
	}
	body, err := buildOTLPRequest(events, Config{PublicKey: "pk"})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	spans := decodeOTLPSpans(t, body)
	if len(spans) != 1 {
		t.Fatalf("expected 1 span (no root), got %d", len(spans))
	}
	if spans[0]["traceId"] != traceIDHex(traceID) {
		t.Errorf("traceId = %v, want %q", spans[0]["traceId"], traceIDHex(traceID))
	}
	if spans[0]["parentSpanId"] != spanIDHex(traceID) {
		t.Errorf("parentSpanId = %v, want %q (root)", spans[0]["parentSpanId"], spanIDHex(traceID))
	}
}

// TestPadHex_ShortID verifies non-UUID short ids still produce valid (zero-
// padded) OTel trace/span ids — so ResumeTrace with an externally-supplied
// non-hex trace id never yields a malformed OTLP request.
func TestPadHex_ShortID(t *testing.T) {
	if got := traceIDHex("abc"); len(got) != 32 || !strings.HasSuffix(got, "abc") {
		t.Errorf("traceIDHex(abc) = %q (len %d), want 32-char zero-padded suffix abc", got, len(got))
	}
	if got := spanIDHex("abc"); len(got) != 16 || !strings.HasSuffix(got, "abc") {
		t.Errorf("spanIDHex(abc) = %q (len %d), want 16-char zero-padded suffix abc", got, len(got))
	}
	// Non-hex chars are dropped, not copied — OTel ids must be hex.
	if got := traceIDHex("upstream-trace"); !strings.HasPrefix(got, strings.Repeat("0", 26)) {
		t.Errorf("traceIDHex(upstream-trace) = %q, expected heavy zero-padding after dropping non-hex", got)
	}
}

// TestBuildOTLPRequest_BodyAsMapFallback verifies the translator tolerates an
// event body that arrives as a map[string]interface{} (e.g. a future caller
// that round-trips events through JSON) instead of the typed struct.
func TestBuildOTLPRequest_BodyAsMapFallback(t *testing.T) {
	traceID := "550e8400e29b41d4a716446655440000"
	obsMap := map[string]interface{}{
		"id":        "6ba7b8109dad11d180b400c04fd430c8",
		"traceId":   traceID,
		"type":      "SPAN",
		"name":      "mapped",
		"startTime": isoTime(time.Now()),
	}
	events := []ingestionEvent{mkEvent("span-create", obsMap)}
	body, err := buildOTLPRequest(events, Config{PublicKey: "pk"})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	spans := decodeOTLPSpans(t, body)
	if len(spans) != 1 {
		t.Fatalf("expected 1 span from map body, got %d", len(spans))
	}
	if spanType(spans[0]) != "span" {
		t.Errorf("type = %q, want span", spanType(spans[0]))
	}
}
