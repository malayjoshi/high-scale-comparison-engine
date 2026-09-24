package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type comparisonRequest struct {
	JobID              string    `json:"job_id"`
	SourceFolder       string    `json:"source_folder"`
	DestinationFolder  string    `json:"destination_folder"`
	TotalExpectedPairs int       `json:"total_expected_pairs"`
	Timestamp          time.Time `json:"timestamp"`
	CallbackID         string    `json:"callback_id"`
}

var callbackIDPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)
var jobIDPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$`)

type pairFlags []string

func (p *pairFlags) String() string { return strings.Join(*p, ",") }
func (p *pairFlags) Set(value string) error {
	*p = append(*p, value)
	return nil
}

func main() {
	var pairs pairFlags
	apiURL := flag.String("api-url", os.Getenv("COMPARISON_ENGINE_API_URL"), "API Gateway /jobs URL")
	callbackID := flag.String("callback-id", os.Getenv("COMPARISON_ENGINE_CALLBACK_ID"), "registered callback identifier")
	jobID := flag.String("job-id", "", "existing job UUID when retrying a partially submitted job")
	dataRoot := flag.String("data-root", envOrDefault("COMPARISON_ENGINE_DATA_ROOT", "dummy_data"), "local dummy-data directory")
	timeout := flag.Duration("timeout", 30*time.Second, "request timeout")
	flag.Var(&pairs, "pair", "folder pair as source:destination; repeat for multiple pairs")
	flag.Parse()

	if *apiURL == "" {
		log.Fatal("API URL is required through -api-url or COMPARISON_ENGINE_API_URL")
	}
	token := strings.TrimSpace(os.Getenv("COMPARISON_ENGINE_TOKEN"))
	if token == "" {
		log.Fatal("COMPARISON_ENGINE_TOKEN is required")
	}

	if *jobID == "" {
		var err error
		*jobID, err = newUUID()
		if err != nil {
			log.Fatalf("generate job ID: %v", err)
		}
	} else if !jobIDPattern.MatchString(*jobID) {
		log.Fatal("job ID must be a valid UUID")
	}

	requests, err := buildRequests(*dataRoot, pairs, *callbackID, *jobID, time.Now().UTC())
	if err != nil {
		log.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	fmt.Println(*jobID)
	for index, request := range requests {
		if err := postJob(ctx, http.DefaultClient, *apiURL, token, request); err != nil {
			log.Fatalf(
				"job %s: submit pair %d/%d (%s:%s): %v",
				*jobID,
				index+1,
				len(requests),
				request.SourceFolder,
				request.DestinationFolder,
				err,
			)
		}
	}
}

func buildRequests(dataRoot string, rawPairs []string, callbackID, jobID string, timestamp time.Time) ([]comparisonRequest, error) {
	if len(rawPairs) == 0 {
		return nil, errors.New("at least one -pair source:destination is required")
	}
	if len(rawPairs) > 100 {
		return nil, errors.New("at most 100 folder pairs are allowed per job")
	}
	if !callbackIDPattern.MatchString(callbackID) {
		return nil, errors.New("callback ID must contain 1-100 letters, numbers, dots, underscores, or hyphens")
	}

	requests := make([]comparisonRequest, 0, len(rawPairs))
	seen := make(map[string]struct{}, len(rawPairs))
	for _, raw := range rawPairs {
		source, destination, found := strings.Cut(raw, ":")
		if !found || source == "" || destination == "" {
			return nil, fmt.Errorf("invalid pair %q: expected source:destination", raw)
		}
		if err := validateFolder(dataRoot, source); err != nil {
			return nil, fmt.Errorf("source folder %q: %w", source, err)
		}
		if err := validateFolder(dataRoot, destination); err != nil {
			return nil, fmt.Errorf("destination folder %q: %w", destination, err)
		}
		pairKey := source + "\x00" + destination
		if _, exists := seen[pairKey]; exists {
			return nil, fmt.Errorf("duplicate pair %q", raw)
		}
		seen[pairKey] = struct{}{}
		requests = append(requests, comparisonRequest{
			JobID:              jobID,
			SourceFolder:       source,
			DestinationFolder:  destination,
			TotalExpectedPairs: len(rawPairs),
			Timestamp:          timestamp.UTC(),
			CallbackID:         callbackID,
		})
	}
	return requests, nil
}

func validateFolder(dataRoot, name string) error {
	if name == "" || name == "." || filepath.IsAbs(name) || filepath.Base(name) != name {
		return errors.New("must be a direct child of the dummy-data directory")
	}
	info, err := os.Stat(filepath.Join(dataRoot, name))
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return errors.New("is not a directory")
	}
	return nil
}

func newUUID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", err
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16]), nil
}

func postJob(ctx context.Context, client *http.Client, apiURL, token string, request comparisonRequest) error {
	body, err := json.Marshal(request)
	if err != nil {
		return fmt.Errorf("encode job: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	response, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("send job: %w", err)
	}
	defer response.Body.Close()
	responseBody, err := io.ReadAll(io.LimitReader(response.Body, 64<<10))
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("API returned %s: %s", response.Status, strings.TrimSpace(string(responseBody)))
	}
	return nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}
