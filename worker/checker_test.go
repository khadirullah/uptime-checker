package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestCheckUp(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	res := check(context.Background(), srv.Client(), srv.URL)
	if !res.OK {
		t.Fatalf("expected ok, got %+v", res)
	}
	if res.StatusCode == nil || *res.StatusCode != 200 {
		t.Fatalf("expected status 200, got %+v", res.StatusCode)
	}
	if res.Error != "" {
		t.Fatalf("expected no error, got %q", res.Error)
	}
}

func TestCheckServerError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer srv.Close()

	res := check(context.Background(), srv.Client(), srv.URL)
	if res.OK {
		t.Fatalf("expected down for 502, got %+v", res)
	}
	if res.StatusCode == nil || *res.StatusCode != 502 {
		t.Fatalf("expected status 502, got %+v", res.StatusCode)
	}
}

func TestCheckUnreachable(t *testing.T) {
	// a server we start and immediately stop gives a reliably refused port
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()

	client := &http.Client{Timeout: 2 * time.Second}
	res := check(context.Background(), client, url)
	if res.OK {
		t.Fatalf("expected down, got %+v", res)
	}
	if res.StatusCode != nil {
		t.Fatalf("expected no status code, got %d", *res.StatusCode)
	}
	if res.Error == "" {
		t.Fatal("expected a transport error message")
	}
}
