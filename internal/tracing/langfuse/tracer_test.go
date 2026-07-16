package langfuse

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// otlpTestServer spins up a fake OTLP /api/public/otel/v1/traces endpoint
// and returns a drain func yielding every decoded span across all flushes.
func otlpTestServer(t *testing.T) (*httptest.Server, func() []map[string]interface{}) {
	t.Helper()
	var mu sync.Mutex
	var spans []map[string]interface{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		var req map[string]interface{}
		_ = json.Unmarshal(body, &req)
		mu.Lock()
		defer mu.Unlock()
		for _, rs := range asSlice(req["resourceSpans"]) {
			for _, ss := range asSlice(rs.(map[string]interface{})["scopeSpans"]) {
				for _, sp := range asSlice(ss.(map[string]interface{})["spans"]) {
					spans = append(spans, sp.(map[string]interface{}))
				}
			}
		}
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{}`))
	}))
	drain := func() []map[string]interface{} {
		mu.Lock()
		defer mu.Unlock()
		out := make([]map[string]interface{}, len(spans))
		copy(out, spans)
		return out
	}
	return srv, drain
}

func asSlice(v interface{}) []interface{} {
	if s, ok := v.([]interface{}); ok {
		return s
	}
	return nil
}

func newTestManager(t *testing.T, host string) *Manager {
	t.Helper()
	m, err := Init(Config{
		Enabled:        true,
		Host:           host,
		PublicKey:      "pk",
		SecretKey:      "sk",
		FlushAt:        16,
		FlushInterval:  1 * time.Second,
		QueueSize:      32,
		RequestTimeout: 2 * time.Second,
		SampleRate:     1.0,
	})
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	return m
}

// spanAttrStr returns the stringValue of a span attribute, or "" if absent.
func spanAttrStr(sp map[string]interface{}, key string) string {
	for _, a := range asSlice(sp["attributes"]) {
		am, _ := a.(map[string]interface{})
		if am["key"] != key {
			continue
		}
		if v, ok := am["value"].(map[string]interface{}); ok {
			if s, ok := v["stringValue"].(string); ok {
				return s
			}
		}
	}
	return ""
}

// spanType returns the langfuse.observation.type of a span.
func spanType(sp map[string]interface{}) string {
	return spanAttrStr(sp, "langfuse.observation.type")
}

func spanStatus(sp map[string]interface{}) (code, message string) {
	st, ok := sp["status"].(map[string]interface{})
	if !ok {
		return "", ""
	}
	if c, ok := st["code"].(string); ok {
		code = c
	}
	if m, ok := st["message"].(string); ok {
		message = m
	}
	return
}

// TestSpan_NestedHierarchy verifies that nested StartSpan calls produce a
// trace → span₁ → span₂ → generation tree, with parentSpanId pointing to
// the direct ancestor at each level (derived from the parent observation id).
func TestSpan_NestedHierarchy(t *testing.T) {
	srv, drain := otlpTestServer(t)
	defer srv.Close()
	m := newTestManager(t, srv.URL)

	ctx, trace := m.StartTrace(context.Background(), TraceOptions{Name: "root"})
	ctx, outer := m.StartSpan(ctx, SpanOptions{Name: "outer"})
	ctx, inner := m.StartSpan(ctx, SpanOptions{Name: "inner"})
	_, gen := m.StartGeneration(ctx, GenerationOptions{Name: "llm", Model: "m"})

	gen.Finish("out", &TokenUsage{Input: 1, Output: 2, Total: 3}, nil)
	inner.Finish("inner-out", nil, nil)
	outer.Finish("outer-out", nil, nil)
	trace.Finish("root-out", nil)

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	spans := drain()
	wantTrace := traceIDHex(trace.ID)
	bySpanID := map[string]map[string]interface{}{}
	for _, sp := range spans {
		bySpanID[sp["spanId"].(string)] = sp
		if sp["traceId"] != wantTrace {
			t.Errorf("span %q has traceId %q want %q", sp["name"], sp["traceId"], wantTrace)
		}
	}

	rootID := spanIDHex(trace.ID)
	outerSp := bySpanID[spanIDHex(outer.ID)]
	if outerSp == nil {
		t.Fatalf("missing outer span %q", spanIDHex(outer.ID))
	}
	if outerSp["parentSpanId"] != rootID {
		t.Errorf("outer parentSpanId = %v want %q", outerSp["parentSpanId"], rootID)
	}
	if spanType(outerSp) != "span" {
		t.Errorf("outer type = %q want span", spanType(outerSp))
	}

	innerSp := bySpanID[spanIDHex(inner.ID)]
	if innerSp == nil {
		t.Fatalf("missing inner span")
	}
	if innerSp["parentSpanId"] != spanIDHex(outer.ID) {
		t.Errorf("inner parentSpanId = %v want %q", innerSp["parentSpanId"], spanIDHex(outer.ID))
	}
	if spanType(innerSp) != "span" {
		t.Errorf("inner type = %q want span", spanType(innerSp))
	}

	genSp := bySpanID[spanIDHex(gen.ID)]
	if genSp == nil {
		t.Fatalf("missing generation span")
	}
	if genSp["parentSpanId"] != spanIDHex(inner.ID) {
		t.Errorf("generation parentSpanId = %v want %q", genSp["parentSpanId"], spanIDHex(inner.ID))
	}
	if spanType(genSp) != "generation" {
		t.Errorf("generation type = %q want generation", spanType(genSp))
	}
}

// TestSpan_FinishWithError records an error status on the span so failures in
// asynq handlers surface as red observations in Langfuse.
func TestSpan_FinishWithError(t *testing.T) {
	srv, drain := otlpTestServer(t)
	defer srv.Close()
	m := newTestManager(t, srv.URL)

	ctx, _ := m.StartTrace(context.Background(), TraceOptions{Name: "root"})
	_, span := m.StartSpan(ctx, SpanOptions{Name: "boom"})
	span.Finish(nil, nil, errors.New("kaboom"))

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	var sawError bool
	for _, sp := range drain() {
		if spanAttrStr(sp, "langfuse.observation.status_message") != "kaboom" {
			continue
		}
		if code, _ := spanStatus(sp); code == "STATUS_CODE_ERROR" {
			sawError = true
		}
	}
	if !sawError {
		t.Fatal("expected a span with ERROR status and status_message=kaboom")
	}
}

// TestResumeTrace_NoTraceCreateEvent verifies that ResumeTrace does NOT emit
// a root trace span — the originating HTTP handler already did, and a
// duplicate would register as an orphan root in the Langfuse UI.
func TestResumeTrace_NoTraceCreateEvent(t *testing.T) {
	srv, drain := otlpTestServer(t)
	defer srv.Close()
	m := newTestManager(t, srv.URL)

	ctx, trace := m.ResumeTrace(context.Background(), "upstream-trace", "upstream-span")
	if trace == nil || trace.ID != "upstream-trace" {
		t.Fatalf("expected resumed trace with id upstream-trace, got %+v", trace)
	}
	if pid, ok := parentObservationFromCtx(ctx); !ok || pid != "upstream-span" {
		t.Errorf("expected parent observation upstream-span on ctx, got %q (ok=%v)", pid, ok)
	}

	// Emit one child so there's something to flush, proving only child
	// observations reach the wire — not a root trace span for the resume.
	_, span := m.StartSpan(ctx, SpanOptions{Name: "child"})
	span.Finish(nil, nil, nil)

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	for _, sp := range drain() {
		if spanType(sp) == "trace" {
			t.Fatalf("ResumeTrace must not emit a root trace span, got %v", sp["name"])
		}
	}
}

// TestResumeTrace_DisabledIsSafe guards against nil deref when Langfuse is
// off: ResumeTrace should return a nil *Trace and the original ctx unchanged.
func TestResumeTrace_DisabledIsSafe(t *testing.T) {
	m, err := Init(Config{Enabled: false})
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	ctx, trace := m.ResumeTrace(context.Background(), "x", "y")
	if trace != nil {
		t.Errorf("expected nil trace when disabled, got %+v", trace)
	}
	if _, ok := parentObservationFromCtx(ctx); ok {
		t.Error("disabled ResumeTrace should not attach parent observation")
	}
}
