package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestBuildAndPostRequests(t *testing.T) {
	dataRoot := t.TempDir()
	for _, name := range []string{"folder_a", "folder_b"} {
		if err := os.Mkdir(filepath.Join(dataRoot, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	timestamp := time.Date(2026, 9, 23, 12, 30, 0, 0, time.UTC)
	jobID := "30a3e7d2-f886-47b6-b9d6-11c54d37fc4d"
	requests, err := buildRequests(
		dataRoot,
		[]string{"folder_a:folder_b"},
		"client-production",
		jobID,
		timestamp,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(requests) != 1 {
		t.Fatalf("expected one request, got %d", len(requests))
	}
	request := requests[0]
	if request.JobID != jobID || request.Timestamp != timestamp || request.TotalExpectedPairs != 1 || request.CallbackID != "client-production" {
		t.Fatalf("unexpected request: %+v", request)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("unexpected request method or authorization header")
		}
		var received comparisonRequest
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Error(err)
		}
		if received.JobID != request.JobID || received.SourceFolder != request.SourceFolder || received.DestinationFolder != request.DestinationFolder {
			t.Errorf("received unexpected request: %+v", received)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	if err := postJob(context.Background(), server.Client(), server.URL, "test-token", request); err != nil {
		t.Fatal(err)
	}
}

func TestBuildRequestsRejectsMissingOrEscapingFolders(t *testing.T) {
	dataRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(dataRoot, "folder_a"), 0o755); err != nil {
		t.Fatal(err)
	}

	for _, pair := range []string{"folder_a:missing", "../folder_a:folder_a", "folder_a"} {
		if _, err := buildRequests(dataRoot, []string{pair}, "client-production", "job-id", time.Now()); err == nil {
			t.Errorf("expected %q to fail", pair)
		}
	}
	if _, err := buildRequests(
		dataRoot,
		[]string{"folder_a:folder_a", "folder_a:folder_a"},
		"client-production",
		"job-id",
		time.Now(),
	); err == nil {
		t.Error("expected duplicate pair to fail")
	}
}
