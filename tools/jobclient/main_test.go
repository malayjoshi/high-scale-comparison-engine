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

func TestBuildAndPostJob(t *testing.T) {
	dataRoot := t.TempDir()
	for _, name := range []string{"folder_a", "folder_b"} {
		if err := os.Mkdir(filepath.Join(dataRoot, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	timestamp := time.Date(2026, 9, 23, 12, 30, 0, 0, time.UTC)
	job, err := buildJob(dataRoot, []string{"folder_a:folder_b"}, timestamp)
	if err != nil {
		t.Fatal(err)
	}
	if len(job.JobID) != 36 || job.Timestamp != timestamp || len(job.Folder) != 1 {
		t.Fatalf("unexpected job: %+v", job)
	}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("unexpected request method or authorization header")
		}
		var received comparisonJob
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Error(err)
		}
		if received.JobID != job.JobID || received.Folder[0] != job.Folder[0] {
			t.Errorf("received unexpected job: %+v", received)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	if err := postJob(context.Background(), server.Client(), server.URL, "test-token", job); err != nil {
		t.Fatal(err)
	}
}

func TestBuildJobRejectsMissingOrEscapingFolders(t *testing.T) {
	dataRoot := t.TempDir()
	if err := os.Mkdir(filepath.Join(dataRoot, "folder_a"), 0o755); err != nil {
		t.Fatal(err)
	}

	for _, pair := range []string{"folder_a:missing", "../folder_a:folder_a", "folder_a"} {
		if _, err := buildJob(dataRoot, []string{pair}, time.Now()); err == nil {
			t.Errorf("expected %q to fail", pair)
		}
	}
}
