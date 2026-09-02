package main

import (
	"context"
	"net/http"
	"time"
)

// Result is what one fetch of a site produced.
type Result struct {
	OK         bool   `json:"ok"`
	StatusCode *int   `json:"status_code"`
	LatencyMs  int    `json:"latency_ms"`
	Error      string `json:"error,omitempty"`
	CheckedAt  string `json:"checked_at"`
}

// check fetches url once and reports whether it answered with a non-error status.
// Any transport failure (dns, refused, timeout) is a down result, not a crash.
func check(ctx context.Context, client *http.Client, url string) Result {
	start := time.Now()
	res := Result{CheckedAt: start.UTC().Format(time.RFC3339)}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		res.Error = err.Error()
		res.LatencyMs = int(time.Since(start).Milliseconds())
		return res
	}
	req.Header.Set("User-Agent", "uptime-checker/0.1")

	resp, err := client.Do(req)
	res.LatencyMs = int(time.Since(start).Milliseconds())
	if err != nil {
		res.Error = err.Error()
		return res
	}
	defer resp.Body.Close()

	code := resp.StatusCode
	res.StatusCode = &code
	res.OK = code < 400
	if !res.OK {
		res.Error = "http " + resp.Status
	}
	return res
}
