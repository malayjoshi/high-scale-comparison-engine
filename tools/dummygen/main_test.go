package main

import (
	"encoding/csv"
	"os"
	"path/filepath"
	"testing"
)

func TestGeneratePair(t *testing.T) {
	if folderLabel(0) != "a" || folderLabel(25) != "z" || folderLabel(26) != "aa" {
		t.Fatal("folder labels are not spreadsheet-style")
	}

	root := filepath.Join(t.TempDir(), "dummy_data")
	cfg := config{
		pairs: 1, output: root,
		minFiles: 3, maxFiles: 3,
		minRows: 4, maxRows: 4,
		overlapRate: 0.67, workers: 2, seed: 42,
	}
	if err := generate(cfg); err != nil {
		t.Fatal(err)
	}

	leftFiles := filenames(t, filepath.Join(root, "folder_a"))
	rightFiles := filenames(t, filepath.Join(root, "folder_b"))
	if len(leftFiles) != 3 || len(rightFiles) != 3 {
		t.Fatalf("expected three files per folder, got %d and %d", len(leftFiles), len(rightFiles))
	}

	common := filepath.Join(root, "folder_a", "dataset_0001.random")
	leftRows := readCSV(t, common)
	rightRows := readCSV(t, filepath.Join(root, "folder_b", "dataset_0001.random"))
	if leftRows[0][0] != "id" || rightRows[0][0] != "id" {
		t.Fatal("id must be the first column")
	}
	if len(leftRows[0]) < 4 || len(leftRows[0]) > 7 || len(rightRows[0]) < 4 || len(rightRows[0]) > 7 {
		t.Fatal("matched schemas must contain between four and seven columns")
	}
	if len(leftRows) != 5 || len(rightRows) != 5 {
		t.Fatal("expected a header and four data rows")
	}
	for row := 1; row < len(leftRows); row++ {
		if leftRows[row][0] != rightRows[row][0] {
			t.Fatalf("primary keys differ on row %d", row)
		}
	}
}

func filenames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	result := make([]string, len(entries))
	for index, entry := range entries {
		result[index] = entry.Name()
	}
	return result
}

func readCSV(t *testing.T, path string) [][]string {
	t.Helper()
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	records, err := csv.NewReader(file).ReadAll()
	if err != nil {
		t.Fatal(err)
	}
	return records
}
