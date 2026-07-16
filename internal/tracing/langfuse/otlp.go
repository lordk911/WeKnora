package langfuse

import (
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Langfuse / OpenTelemetry semantic-convention attribute keys mirrored from
// the official langfuse-python v4 SDK (_client/attributes.py). These are sent
// as span attributes on the OTLP wire; LiteFuse (and Langfuse v3+) index
// traces/generations off them.
const (
	attrObsType            = "langfuse.observation.type"
	attrObsInput           = "langfuse.observation.input"
	attrObsOutput          = "langfuse.observation.output"
	attrObsMetadata        = "langfuse.observation.metadata"
	attrObsLevel           = "langfuse.observation.level"
	attrObsStatusMessage   = "langfuse.observation.status_message"
	attrObsModel           = "langfuse.observation.model.name"
	attrObsModelParams     = "langfuse.observation.model.parameters"
	attrObsUsageDetails    = "langfuse.observation.usage_details"
	attrObsCompletionStart = "langfuse.observation.completion_start_time"
	attrTraceName          = "langfuse.trace.name"
	attrTraceInput         = "langfuse.trace.input"
	attrTraceOutput        = "langfuse.trace.output"
	attrTraceMetadata      = "langfuse.trace.metadata"
	attrTraceTags          = "langfuse.trace.tags"
	attrUserID             = "user.id"
	attrSessionID          = "session.id"
	attrEnvironment        = "langfuse.environment"
	attrRelease            = "langfuse.release"
	attrLangfusePubKey     = "langfuse.public.key"

	// The LiteFuse/Langfuse v3 OTel gate keys the "events_full" direct-write
	// path on the instrumentation scope name. langfuse-python v4 uses
	// "langfuse-sdk"; LiteFuse's getSdkInfoFromResourceSpans only requires the
	// scope name to contain "langfuse" for server-side SDK classification.
	langfuseScopeName    = "langfuse-sdk"
	langfuseScopeVersion = "4.0.0"
)

// buildOTLPRequest translates an internal ingestion-event batch into an
// OTLP/HTTP JSON ExportTraceServiceRequest that LiteFuse (and Langfuse v3+)
// accept on POST /api/public/otel/v1/traces.
//
// The legacy ingestion protocol emits separate create/update events per
// observation and separate open/finish events per trace — the Langfuse
// server merged them by id. OTLP has no such server-side merge: each span
// is a single object, so the translator folds create+update into one span
// keyed by observation id and trace open/finish into one root span keyed by
// trace id.
//
// Langfuse observation ids are UUIDv4 (32 hex chars once hyphens are
// stripped), which map cleanly onto OTel trace ids (128-bit) and — truncated
// to the first 16 hex — onto OTel span ids (64-bit). Parent linking is
// preserved by deriving each span's parentSpanId from its
// parentObservationId.
func buildOTLPRequest(events []ingestionEvent, cfg Config) ([]byte, error) {
	type obsState struct {
		body   observationBody
		trace  string
		parent string
	}
	type traceState struct {
		body  traceBody
		start string // event timestamp of the open (first trace-create)
		end   string // event timestamp of the latest trace-create update
	}

	traces := map[string]*traceState{}
	traceOrder := []string{} // first-seen order for stable output
	obs := map[string]*obsState{}

	addTrace := func(tb traceBody, evTS string) {
		if s, ok := traces[tb.ID]; ok {
			mergeTraceBody(&s.body, tb)
			s.end = evTS
			return
		}
		traces[tb.ID] = &traceState{body: tb, start: evTS}
		traceOrder = append(traceOrder, tb.ID)
	}
	addObs := func(ob observationBody) {
		if s, ok := obs[ob.ID]; ok {
			mergeObsBody(&s.body, ob)
			return
		}
		obs[ob.ID] = &obsState{body: ob, trace: ob.TraceID, parent: ob.ParentObservationID}
	}

	for _, ev := range events {
		switch ev.Type {
		case "trace-create":
			if tb, ok := ev.Body.(traceBody); ok {
				addTrace(tb, ev.Timestamp)
			} else if tb, ok := bodyAs[traceBody](ev.Body); ok {
				addTrace(tb, ev.Timestamp)
			}
		case "span-create", "generation-create", "span-update", "generation-update":
			if ob, ok := ev.Body.(observationBody); ok {
				addObs(ob)
			} else if ob, ok := bodyAs[observationBody](ev.Body); ok {
				addObs(ob)
			}
		}
	}

	spans := []map[string]interface{}{}

	// Root span per trace.
	for _, tid := range traceOrder {
		ts := traces[tid]
		startN := isoToUnixNanoStr(ts.start)
		endN := isoToUnixNanoStr(ts.end)
		if endN == "" {
			endN = startN
		}
		spans = append(spans, map[string]interface{}{
			"traceId":           traceIDHex(tid),
			"spanId":            spanIDHex(tid),
			"name":              firstNonEmpty(ts.body.Name, tid),
			"kind":              "SPAN_KIND_INTERNAL",
			"startTimeUnixNano": startN,
			"endTimeUnixNano":   endN,
			"attributes":        traceAttrs(ts.body),
		})
	}

	// One span per observation, sorted by id for deterministic output.
	obsOrder := make([]string, 0, len(obs))
	for id := range obs {
		obsOrder = append(obsOrder, id)
	}
	sort.Strings(obsOrder)
	for _, oid := range obsOrder {
		s := obs[oid]
		ob := s.body
		tid := firstNonEmpty(s.trace, ob.TraceID)
		startN := isoToUnixNanoStr(ob.StartTime)
		endN := isoToUnixNanoStr(ob.EndTime)
		if endN == "" {
			endN = isoToUnixNanoStr(ob.StartTime)
		}
		span := map[string]interface{}{
			"traceId":           traceIDHex(tid),
			"spanId":            spanIDHex(oid),
			"name":              firstNonEmpty(ob.Name, ob.ID),
			"kind":              "SPAN_KIND_INTERNAL",
			"startTimeUnixNano": startN,
			"endTimeUnixNano":   endN,
			"attributes":        obsAttrs(ob),
		}
		// An observation with no explicit parent observation sits directly
		// under the trace root (the legacy ingestion protocol left
		// parentObservationId empty in that case and Langfuse implicit-parented
		// to the trace). OTLP has no implicit parent: a span without
		// parentSpanId is its own root, so we parent it to the root trace span
		// to keep the tree intact.
		parent := firstNonEmpty(s.parent, ob.ParentObservationID)
		if parent == "" {
			parent = tid
		}
		span["parentSpanId"] = spanIDHex(parent)
		if st := statusFor(ob); st != nil {
			span["status"] = st
		}
		spans = append(spans, span)
	}

	// Resource attributes carry the project public key (auth is via Basic
	// header on the HTTP request, but LiteFuse also surfaces this on the
	// trace for project correlation) + environment/release.
	resAttrs := []map[string]interface{}{strAttr(attrLangfusePubKey, cfg.PublicKey)}
	if cfg.Environment != "" {
		resAttrs = append(resAttrs, strAttr(attrEnvironment, cfg.Environment))
	}
	if cfg.Release != "" {
		resAttrs = append(resAttrs, strAttr(attrRelease, cfg.Release))
	}

	req := map[string]interface{}{
		"resourceSpans": []map[string]interface{}{{
			"resource": map[string]interface{}{"attributes": resAttrs},
			"scopeSpans": []map[string]interface{}{{
				"scope": map[string]interface{}{"name": langfuseScopeName, "version": langfuseScopeVersion},
				"spans": spans,
			}},
		}},
	}
	return json.Marshal(req)
}

// bodyAs is a fallback for the (rare) case where an event body arrives as a
// map[string]interface{} rather than the typed struct — e.g. if a future
// caller constructs events via JSON round-trip. It performs a marshal +
// unmarshal to the target type.
func bodyAs[T any](v interface{}) (T, bool) {
	var z T
	b, err := json.Marshal(v)
	if err != nil {
		return z, false
	}
	if err := json.Unmarshal(b, &z); err != nil {
		return z, false
	}
	return z, true
}

// mergeTraceBody overlays non-zero fields from src onto dst (the finish
// update carries Output/Metadata; the open carried Name/Input/etc).
func mergeTraceBody(dst *traceBody, src traceBody) {
	if src.Name != "" {
		dst.Name = src.Name
	}
	if src.UserID != "" {
		dst.UserID = src.UserID
	}
	if src.SessionID != "" {
		dst.SessionID = src.SessionID
	}
	if src.Release != "" {
		dst.Release = src.Release
	}
	if src.Environment != "" {
		dst.Environment = src.Environment
	}
	if src.Input != nil {
		dst.Input = src.Input
	}
	if src.Output != nil {
		dst.Output = src.Output
	}
	if src.Metadata != nil {
		dst.Metadata = src.Metadata
	}
	if len(src.Tags) > 0 {
		dst.Tags = src.Tags
	}
	if src.Public {
		dst.Public = src.Public
	}
}

// mergeObsBody overlays non-zero fields from src onto dst (update carries
// EndTime/Output/Usage/Level/StatusMessage/CompletionStart; create carried
// the rest).
func mergeObsBody(dst *observationBody, src observationBody) {
	if src.StartTime != "" {
		dst.StartTime = src.StartTime
	}
	if src.EndTime != "" {
		dst.EndTime = src.EndTime
	}
	if src.Name != "" {
		dst.Name = src.Name
	}
	if src.Input != nil {
		dst.Input = src.Input
	}
	if src.Output != nil {
		dst.Output = src.Output
	}
	if src.Metadata != nil {
		dst.Metadata = src.Metadata
	}
	if src.Model != "" {
		dst.Model = src.Model
	}
	if src.ModelParameters != nil {
		dst.ModelParameters = src.ModelParameters
	}
	if src.Usage != nil {
		dst.Usage = src.Usage
	}
	if src.Level != "" {
		dst.Level = src.Level
	}
	if src.StatusMessage != "" {
		dst.StatusMessage = src.StatusMessage
	}
	if src.CompletionStart != "" {
		dst.CompletionStart = src.CompletionStart
	}
}

// traceIDHex maps a Langfuse trace id (UUID) to a 32-hex OTel trace id by
// stripping hyphens. UUIDv4 is already 32 hex chars; arbitrary short ids are
// zero-padded to 32 so the result is always a valid OTel trace id.
func traceIDHex(id string) string {
	return padHex(strings.ReplaceAll(id, "-", ""), 32)
}

// spanIDHex maps a Langfuse observation id (UUID) to a 16-hex OTel span id
// by stripping hyphens and taking the first 16 hex chars. Padded/truncated
// to exactly 16.
func spanIDHex(id string) string {
	return padHex(strings.ReplaceAll(id, "-", ""), 16)
}

// padHex left-trims to maxLen hex chars (after filtering non-hex) and
// zero-pads on the left to reach maxLen. OTel requires trace ids to be
// exactly 16 bytes (32 hex) and span ids exactly 8 bytes (16 hex).
func padHex(s string, maxLen int) string {
	var b strings.Builder
	b.Grow(maxLen)
	for _, r := range s {
		if isHexRune(r) {
			b.WriteRune(r)
			if b.Len() >= maxLen {
				break
			}
		}
	}
	out := b.String()
	if len(out) < maxLen {
		out = strings.Repeat("0", maxLen-len(out)) + out
	}
	return out[:maxLen]
}

func isHexRune(r rune) bool {
	switch {
	case r >= '0' && r <= '9':
		return true
	case r >= 'a' && r <= 'f':
		return true
	case r >= 'A' && r <= 'F':
		return true
	}
	return false
}

// isoToUnixNanoStr parses an isoTime() string ("2006-01-02T15:04:05.000Z")
// into a decimal string of Unix nanoseconds, as required by the OTLP/JSON
// startTimeUnixNano / endTimeUnixNano fields. Empty input → "".
func isoToUnixNanoStr(iso string) string {
	if iso == "" {
		return ""
	}
	t, err := time.Parse("2006-01-02T15:04:05.000Z", iso)
	if err != nil {
		return ""
	}
	return strconv.FormatInt(t.UnixNano(), 10)
}

func strAttr(key, value string) map[string]interface{} {
	return map[string]interface{}{
		"key": key,
		"value": map[string]interface{}{
			"stringValue": value,
		},
	}
}

// jsonAttr serializes v to a compact JSON string and wraps it as a string
// OTLP attribute — matching how langfuse-python stores structured fields
// (input/output/metadata/usage) on spans.
func jsonAttr(key string, v interface{}) (map[string]interface{}, bool) {
	if v == nil {
		return nil, false
	}
	b, err := json.Marshal(v)
	if err != nil {
		return nil, false
	}
	if len(b) == 0 || string(b) == "null" {
		return nil, false
	}
	return map[string]interface{}{
		"key": key,
		"value": map[string]interface{}{
			"stringValue": string(b),
		},
	}, true
}

// traceAttrs builds the span attributes for a root (trace) span.
func traceAttrs(tb traceBody) []map[string]interface{} {
	attrs := []map[string]interface{}{strAttr(attrObsType, "trace")}
	if tb.Name != "" {
		attrs = append(attrs, strAttr(attrTraceName, tb.Name))
	}
	if a, ok := jsonAttr(attrTraceInput, tb.Input); ok {
		attrs = append(attrs, a)
	}
	if a, ok := jsonAttr(attrTraceOutput, tb.Output); ok {
		attrs = append(attrs, a)
	}
	if a, ok := jsonAttr(attrTraceMetadata, tb.Metadata); ok {
		attrs = append(attrs, a)
	}
	if len(tb.Tags) > 0 {
		if a, ok := jsonAttr(attrTraceTags, tb.Tags); ok {
			attrs = append(attrs, a)
		}
	}
	if tb.UserID != "" {
		attrs = append(attrs, strAttr(attrUserID, tb.UserID))
	}
	if tb.SessionID != "" {
		attrs = append(attrs, strAttr(attrSessionID, tb.SessionID))
	}
	if tb.Environment != "" {
		attrs = append(attrs, strAttr(attrEnvironment, tb.Environment))
	}
	if tb.Release != "" {
		attrs = append(attrs, strAttr(attrRelease, tb.Release))
	}
	return attrs
}

// obsAttrs builds the span attributes for a span/generation observation.
func obsAttrs(ob observationBody) []map[string]interface{} {
	attrs := []map[string]interface{}{strAttr(attrObsType, strings.ToLower(ob.Type))}
	if a, ok := jsonAttr(attrObsInput, ob.Input); ok {
		attrs = append(attrs, a)
	}
	if a, ok := jsonAttr(attrObsOutput, ob.Output); ok {
		attrs = append(attrs, a)
	}
	if a, ok := jsonAttr(attrObsMetadata, ob.Metadata); ok {
		attrs = append(attrs, a)
	}
	if ob.Model != "" {
		attrs = append(attrs, strAttr(attrObsModel, ob.Model))
	}
	if a, ok := jsonAttr(attrObsModelParams, ob.ModelParameters); ok {
		attrs = append(attrs, a)
	}
	if ob.Usage != nil {
		if a, ok := jsonAttr(attrObsUsageDetails, ob.Usage); ok {
			attrs = append(attrs, a)
		}
	}
	if ob.CompletionStart != "" {
		attrs = append(attrs, strAttr(attrObsCompletionStart, ob.CompletionStart))
	}
	if ob.Level != "" && ob.Level != "DEFAULT" {
		attrs = append(attrs, strAttr(attrObsLevel, ob.Level))
	}
	if ob.StatusMessage != "" {
		attrs = append(attrs, strAttr(attrObsStatusMessage, ob.StatusMessage))
	}
	return attrs
}

// statusFor maps the legacy ERROR level onto an OTel span status so failures
// surface as red observations in Langfuse. Non-error observations get no
// status (unset).
func statusFor(ob observationBody) map[string]interface{} {
	if ob.Level != "ERROR" {
		return nil
	}
	st := map[string]interface{}{
		"code":    "STATUS_CODE_ERROR",
		"message": ob.StatusMessage,
	}
	return st
}
