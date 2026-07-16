package langfuse

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Tencent/WeKnora/internal/types"
	"github.com/hibiken/asynq"
)

// dummyPayload is a minimal payload that embeds TracingContext, mirroring
// how real asynq payloads opt into trace propagation.
type dummyPayload struct {
	types.TracingContext
	KnowledgeID string `json:"knowledge_id"`
}

// TestInjectTracing_DisabledIsZero verifies InjectTracing is a no-op when
// Langfuse is disabled: no panics, no trace fields written.
func TestInjectTracing_DisabledIsZero(t *testing.T) {
	// Explicitly install a disabled manager to shadow any globally-enabled
	// one from a previous test in the same package.
	_, _ = Init(Config{Enabled: false})

	p := &dummyPayload{KnowledgeID: "k1"}
	InjectTracing(context.Background(), p)
	if p.LangfuseTraceID != "" || p.LangfuseParentObservationID != "" {
		t.Fatalf("expected no tracing fields on disabled manager, got %+v", p.TracingContext)
	}
}

// TestInjectTracing_PopulatesFromContext checks that when a trace is active
// on the context, its id is copied onto the payload and a subsequent
// peekTracingContext round-trips it correctly.
func TestInjectTracing_PopulatesFromContext(t *testing.T) {
	// Stand up a fake ingestion endpoint — Init starts a real flush worker
	// and we don't want it to panic on connection refused during the test.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(200)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	m, err := Init(Config{
		Enabled:        true,
		Host:           srv.URL,
		PublicKey:      "pk",
		SecretKey:      "sk",
		FlushAt:        16,
		FlushInterval:  50 * time.Millisecond,
		QueueSize:      16,
		RequestTimeout: 2 * time.Second,
		SampleRate:     1.0,
	})
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	defer func() { _ = m.Shutdown(context.Background()) }()

	ctx, trace := m.StartTrace(context.Background(), TraceOptions{Name: "parent"})
	ctx, span := m.StartSpan(ctx, SpanOptions{Name: "wrap"})
	if span == nil || span.ID == "" {
		t.Fatalf("expected a span with id, got %+v", span)
	}

	p := &dummyPayload{KnowledgeID: "k1"}
	InjectTracing(ctx, p)

	if p.LangfuseTraceID != trace.ID {
		t.Errorf("trace id mismatch: got %q want %q", p.LangfuseTraceID, trace.ID)
	}
	if p.LangfuseParentObservationID != span.ID {
		t.Errorf("parent observation id mismatch: got %q want %q", p.LangfuseParentObservationID, span.ID)
	}

	// Round-trip the payload through JSON, which is what asynq does on the
	// wire, and make sure peekTracingContext recovers the ids.
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	got := peekTracingContext(b)
	if got.LangfuseTraceID != trace.ID || got.LangfuseParentObservationID != span.ID {
		t.Errorf("peek round-trip lost ids: %+v", got)
	}
}

// TestAsynqMiddleware_ResumeTrace asserts the middleware grafts a resumed
// trace onto the child handler's context, and that the OTLP endpoint
// receives a worker span whose traceId/parentSpanId derive from the
// payload-stamped upstream ids — without emitting a duplicate root trace
// span (which would split the Langfuse UI tree into two disconnected roots).
func TestAsynqMiddleware_ResumeTrace(t *testing.T) {
	srv, drain := otlpTestServer(t)
	defer srv.Close()

	m, err := Init(Config{
		Enabled:        true,
		Host:           srv.URL,
		PublicKey:      "pk",
		SecretKey:      "sk",
		FlushAt:        1,
		FlushInterval:  5 * time.Millisecond,
		QueueSize:      32,
		RequestTimeout: 2 * time.Second,
		SampleRate:     1.0,
	})
	if err != nil {
		t.Fatalf("init: %v", err)
	}

	// Build a payload that already carries an upstream trace id (as if the
	// HTTP layer injected one at enqueue time). Use real UUID-shaped hex so
	// the OTel trace/span id derivation is faithful to production.
	upstreamTrace := newID()
	upstreamParent := newID()
	payload := &dummyPayload{KnowledgeID: "k1"}
	payload.LangfuseTraceID = upstreamTrace
	payload.LangfuseParentObservationID = upstreamParent
	raw, _ := json.Marshal(payload)

	var receivedTraceID, receivedParentID string
	var sawTrace bool
	handler := asynq.HandlerFunc(func(ctx context.Context, _ *asynq.Task) error {
		if tr, ok := TraceFromContext(ctx); ok && tr != nil {
			sawTrace = true
			receivedTraceID = tr.ID
		}
		if pid, ok := parentObservationFromCtx(ctx); ok {
			receivedParentID = pid
		}
		return nil
	})

	mw := AsynqMiddleware()
	wrapped := mw(handler)

	task := asynq.NewTask("test:type", raw)
	if err := wrapped.ProcessTask(context.Background(), task); err != nil {
		t.Fatalf("handler err: %v", err)
	}

	if !sawTrace {
		t.Fatal("expected handler ctx to carry a resumed trace")
	}
	if receivedTraceID != upstreamTrace {
		t.Errorf("trace id mismatch: got %q want %q", receivedTraceID, upstreamTrace)
	}
	if receivedParentID == "" {
		t.Error("expected parent observation to be set to the wrapper span id")
	}

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	wantTrace := traceIDHex(upstreamTrace)
	wantParent := spanIDHex(upstreamParent)
	var sawWorkerSpan, sawRootTrace bool
	for _, sp := range drain() {
		if spanType(sp) == "trace" {
			sawRootTrace = true
		}
		if sp["traceId"] != wantTrace {
			continue
		}
		// The worker's wrapper span attaches to the upstream parent.
		if sp["parentSpanId"] == wantParent {
			sawWorkerSpan = true
		}
	}
	if !sawWorkerSpan {
		t.Error("missing worker span stamped with upstream trace+parent ids")
	}
	if sawRootTrace {
		t.Error("resumed trace should not emit a root trace span (HTTP parent owns it)")
	}
}

// TestAsynqMiddleware_StandaloneTrace asserts that when the payload carries
// NO upstream trace id (e.g. a scheduled job), the middleware opens a
// standalone trace tagged with the task type, so the worker-side work
// still shows up in Langfuse.
func TestAsynqMiddleware_StandaloneTrace(t *testing.T) {
	srv, drain := otlpTestServer(t)
	defer srv.Close()

	m, err := Init(Config{
		Enabled: true, Host: srv.URL, PublicKey: "pk", SecretKey: "sk",
		FlushAt: 1, FlushInterval: 5 * time.Millisecond, QueueSize: 32,
		RequestTimeout: 2 * time.Second, SampleRate: 1.0,
	})
	if err != nil {
		t.Fatalf("init: %v", err)
	}

	payload := &dummyPayload{KnowledgeID: "kX"}
	raw, _ := json.Marshal(payload)

	handler := asynq.HandlerFunc(func(context.Context, *asynq.Task) error { return nil })
	wrapped := AsynqMiddleware()(handler)
	if err := wrapped.ProcessTask(context.Background(), asynq.NewTask("scheduled:ping", raw)); err != nil {
		t.Fatalf("handler err: %v", err)
	}

	if err := m.Shutdown(context.Background()); err != nil {
		t.Fatalf("shutdown: %v", err)
	}

	var sawNamedRoot bool
	for _, sp := range drain() {
		if spanType(sp) != "trace" {
			continue
		}
		if sp["name"] == "asynq.scheduled:ping" {
			sawNamedRoot = true
		}
	}
	if !sawNamedRoot {
		t.Error("standalone run should emit a root trace span named asynq.scheduled:ping")
	}
}
