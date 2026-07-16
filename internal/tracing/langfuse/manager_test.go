package langfuse

import (
	"context"
	"strings"
	"testing"
	"time"
)

// TestManager_DisabledIsNoop verifies that when the manager is disabled the
// public API is safe to call and produces no side effects.
func TestManager_DisabledIsNoop(t *testing.T) {
	m, err := Init(Config{Enabled: false})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if m.Enabled() {
		t.Fatal("expected disabled")
	}
	ctx, trace := m.StartTrace(context.Background(), TraceOptions{Name: "x"})
	trace.Finish(nil, nil)

	_, gen := m.StartGeneration(ctx, GenerationOptions{Name: "g", Model: "m"})
	gen.Finish(nil, nil, nil)

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}
}

// TestManager_FullRoundTrip boots a fake OTLP endpoint, runs a trace +
// generation through the manager, and asserts the ingested OTLP payload
// contains a generation span carrying the model name and token usage, sharing
// the trace id of the root span.
func TestManager_FullRoundTrip(t *testing.T) {
	srv, drain := otlpTestServer(t)
	defer srv.Close()

	m, err := Init(Config{
		Enabled:        true,
		Host:           srv.URL,
		PublicKey:      "pk",
		SecretKey:      "sk",
		FlushAt:        16,
		FlushInterval:  1 * time.Second,
		QueueSize:      16,
		RequestTimeout: 2 * time.Second,
		SampleRate:     1.0,
	})
	if err != nil {
		t.Fatalf("init: %v", err)
	}

	ctx, trace := m.StartTrace(context.Background(), TraceOptions{
		Name:   "test.trace",
		UserID: "user-42",
	})
	_, gen := m.StartGeneration(ctx, GenerationOptions{
		Name:  "chat.completion",
		Model: "gpt-test",
		Input: []map[string]string{{"role": "user", "content": "hi"}},
	})
	gen.Finish("hello", &TokenUsage{Input: 10, Output: 20, Total: 30, Unit: "TOKENS"}, nil)
	trace.Finish("hello", nil)

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	spans := drain()
	wantTrace := traceIDHex(trace.ID)
	var sawGeneration bool
	for _, sp := range spans {
		if spanType(sp) != "generation" {
			continue
		}
		if sp["traceId"] != wantTrace {
			t.Errorf("generation trace id mismatch: got %s want %s", sp["traceId"], wantTrace)
		}
		if spanAttrStr(sp, "langfuse.observation.model.name") != "gpt-test" {
			t.Errorf("model mismatch: got %q", spanAttrStr(sp, "langfuse.observation.model.name"))
		}
		usage := spanAttrStr(sp, "langfuse.observation.usage_details")
		if !strings.Contains(usage, `"total":30`) {
			t.Errorf("expected usage_details to contain total:30, got %q", usage)
		}
		sawGeneration = true
	}
	if !sawGeneration {
		t.Fatalf("no generation span found in %d spans", len(spans))
	}
}
