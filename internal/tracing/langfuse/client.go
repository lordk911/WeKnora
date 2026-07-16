package langfuse

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// client is a thin HTTP client for the Langfuse/LiteFuse OTLP ingestion
// endpoint. It posts OTLP/HTTP JSON (ExportTraceServiceRequest) to
// /api/public/otel/v1/traces — the protocol Langfuse v3+ and the LiteFuse
// fork accept; the legacy /api/public/ingestion batch API is rejected by
// LiteFuse and deprecated upstream.
type client struct {
	host       string
	auth       string // pre-computed "Basic <base64>"
	httpClient *http.Client
	debug      bool
	cfg        Config
}

func newClient(cfg Config) *client {
	credentials := cfg.PublicKey + ":" + cfg.SecretKey
	return &client{
		host: strings.TrimRight(cfg.Host, "/"),
		auth: "Basic " + base64.StdEncoding.EncodeToString([]byte(credentials)),
		httpClient: &http.Client{
			Timeout: cfg.RequestTimeout,
		},
		debug: cfg.Debug,
		cfg:   cfg,
	}
}

// ingest translates an internal event batch into OTLP/JSON and posts it to
// the OTLP traces endpoint. LiteFuse's /api/public/otel/v1/traces gate
// requires a modern-SDK marker: we send x-langfuse-ingestion-version=4
// (the custom OTel-exporter opt-in the gate accepts regardless of SDK
// language) plus the langfuse-python SDK name/version for good measure.
// Failures are surfaced to the caller; the manager only logs them when
// Debug is enabled so observability never blocks the request path.
func (c *client) ingest(ctx context.Context, events []ingestionEvent) error {
	if len(events) == 0 {
		return nil
	}

	body, err := buildOTLPRequest(events, c.cfg)
	if err != nil {
		return fmt.Errorf("langfuse: build OTLP request: %w", err)
	}

	endpoint := c.host + "/api/public/otel/v1/traces"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("langfuse: build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", c.auth)
	req.Header.Set("x-langfuse-ingestion-version", "4")
	req.Header.Set("x-langfuse-sdk-name", "python")
	req.Header.Set("x-langfuse-sdk-version", "4.0.0")
	req.Header.Set("User-Agent", "weknora-langfuse/1.0")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("langfuse: ingest request failed: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 200 && resp.StatusCode < 300 {
		return nil
	}
	return fmt.Errorf("langfuse: ingest failed with status %d: %s", resp.StatusCode, truncate(string(respBody), 512))
}

func truncate(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen] + "..."
}
