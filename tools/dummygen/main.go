// Command dummygen creates reproducible folder pairs with realistic schema,
// filename, and cell-level differences for comparison-engine testing.
package main

import (
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	defaultMinFiles = 200
	defaultMaxFiles = 300
	defaultMinRows  = 100
	defaultMaxRows  = 200
	valueMatchRate  = 0.80
)

var columns = []string{
	"customer_name", "category", "amount", "quantity", "status", "region",
	"event_date", "score", "active", "reference", "currency", "source",
	"priority", "department", "country", "version",
}

type config struct {
	pairs       int
	output      string
	minFiles    int
	maxFiles    int
	minRows     int
	maxRows     int
	overlapRate float64
	workers     int
	seed        int64
}

type fileJob struct {
	leftPath    string
	rightPath   string
	leftSchema  []string
	rightSchema []string
	rows        int
	seed        int64
}

func main() {
	cfg := parseFlags()
	if err := generate(cfg); err != nil {
		fmt.Fprintln(os.Stderr, "dummygen:", err)
		os.Exit(1)
	}

	fmt.Printf("generated %d folder pairs (%d folders) under %s using seed %d\n",
		cfg.pairs, cfg.pairs*2, cfg.output, cfg.seed)
}

func parseFlags() config {
	var cfg config
	flag.IntVar(&cfg.pairs, "pairs", 1, "number of folder pairs; 100 creates 200 folders")
	flag.StringVar(&cfg.output, "out", "dummy_data", "output directory")
	flag.IntVar(&cfg.minFiles, "min-files", defaultMinFiles, "minimum files per folder")
	flag.IntVar(&cfg.maxFiles, "max-files", defaultMaxFiles, "maximum files per folder")
	flag.IntVar(&cfg.minRows, "min-rows", defaultMinRows, "minimum rows per file")
	flag.IntVar(&cfg.maxRows, "max-rows", defaultMaxRows, "maximum rows per file")
	flag.Float64Var(&cfg.overlapRate, "filename-overlap", 0.75, "fraction of filenames shared within each pair")
	flag.IntVar(&cfg.workers, "workers", runtime.NumCPU(), "concurrent file writers")
	flag.Int64Var(&cfg.seed, "seed", time.Now().UnixNano(), "random seed for reproducible output")
	flag.Parse()
	return cfg
}

func generate(cfg config) error {
	if err := validate(cfg); err != nil {
		return err
	}
	if err := os.MkdirAll(cfg.output, 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}

	jobs := make(chan fileJob, cfg.workers*2)
	var workers sync.WaitGroup
	var firstErr error
	var errOnce sync.Once

	for range cfg.workers {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for job := range jobs {
				var err error
				if job.rightPath == "" {
					err = writeSingleFile(job.leftPath, job.leftSchema, job.rows, job.seed)
				} else {
					err = writeMatchedFiles(job)
				}
				if err != nil {
					errOnce.Do(func() { firstErr = err })
				}
			}
		}()
	}

	rng := rand.New(rand.NewSource(cfg.seed))
	for pair := 0; pair < cfg.pairs; pair++ {
		leftName := "folder_" + folderLabel(pair*2)
		rightName := "folder_" + folderLabel(pair*2+1)
		leftDir := filepath.Join(cfg.output, leftName)
		rightDir := filepath.Join(cfg.output, rightName)

		if err := os.Mkdir(leftDir, 0o755); err != nil {
			close(jobs)
			workers.Wait()
			return fmt.Errorf("create %s: %w", leftDir, err)
		}
		if err := os.Mkdir(rightDir, 0o755); err != nil {
			close(jobs)
			workers.Wait()
			return fmt.Errorf("create %s: %w", rightDir, err)
		}

		leftFiles := between(rng, cfg.minFiles, cfg.maxFiles)
		rightFiles := between(rng, cfg.minFiles, cfg.maxFiles)
		commonFiles := int(float64(min(leftFiles, rightFiles)) * cfg.overlapRate)
		if cfg.overlapRate > 0 && commonFiles == 0 {
			commonFiles = 1
		}

		for fileNumber := 1; fileNumber <= commonFiles; fileNumber++ {
			leftSchema, rightSchema := matchedSchemas(rng)
			name := fmt.Sprintf("dataset_%04d.random", fileNumber)
			jobs <- fileJob{
				leftPath:    filepath.Join(leftDir, name),
				rightPath:   filepath.Join(rightDir, name),
				leftSchema:  leftSchema,
				rightSchema: rightSchema,
				rows:        between(rng, cfg.minRows, cfg.maxRows),
				seed:        rng.Int63(),
			}
		}

		for fileNumber := 1; fileNumber <= leftFiles-commonFiles; fileNumber++ {
			jobs <- singleJob(leftDir, leftName, fileNumber, cfg, rng)
		}
		for fileNumber := 1; fileNumber <= rightFiles-commonFiles; fileNumber++ {
			jobs <- singleJob(rightDir, rightName, fileNumber, cfg, rng)
		}
	}

	close(jobs)
	workers.Wait()
	return firstErr
}

func validate(cfg config) error {
	switch {
	case cfg.pairs < 1:
		return errors.New("pairs must be at least 1")
	case cfg.minFiles < 1 || cfg.maxFiles < cfg.minFiles:
		return errors.New("file range is invalid")
	case cfg.minRows < 1 || cfg.maxRows < cfg.minRows:
		return errors.New("row range is invalid")
	case cfg.overlapRate < 0 || cfg.overlapRate > 1:
		return errors.New("filename-overlap must be between 0 and 1")
	case cfg.workers < 1:
		return errors.New("workers must be at least 1")
	case strings.TrimSpace(cfg.output) == "":
		return errors.New("output directory cannot be empty")
	default:
		return nil
	}
}

func singleJob(dir, folder string, fileNumber int, cfg config, rng *rand.Rand) fileJob {
	return fileJob{
		leftPath:   filepath.Join(dir, fmt.Sprintf("only_%s_%04d.random", folder, fileNumber)),
		leftSchema: randomSchema(rng),
		rows:       between(rng, cfg.minRows, cfg.maxRows),
		seed:       rng.Int63(),
	}
}

func writeMatchedFiles(job fileJob) error {
	leftFile, leftCSV, err := newCSVFile(job.leftPath)
	if err != nil {
		return err
	}
	defer leftFile.Close()

	rightFile, rightCSV, err := newCSVFile(job.rightPath)
	if err != nil {
		return err
	}
	defer rightFile.Close()

	if err := leftCSV.Write(job.leftSchema); err != nil {
		return err
	}
	if err := rightCSV.Write(job.rightSchema); err != nil {
		return err
	}

	rng := rand.New(rand.NewSource(job.seed))
	leftColumns := make(map[string]struct{}, len(job.leftSchema))
	for _, column := range job.leftSchema {
		leftColumns[column] = struct{}{}
	}

	for rowNumber := 1; rowNumber <= job.rows; rowNumber++ {
		id := fmt.Sprintf("%08d", rowNumber)
		leftValues := map[string]string{"id": id}
		leftRow := make([]string, len(job.leftSchema))
		for index, column := range job.leftSchema {
			if column == "id" {
				leftRow[index] = id
				continue
			}
			leftValues[column] = randomValue(column, rowNumber, rng)
			leftRow[index] = leftValues[column]
		}

		rightRow := make([]string, len(job.rightSchema))
		for index, column := range job.rightSchema {
			if column == "id" {
				rightRow[index] = id
				continue
			}
			if _, shared := leftColumns[column]; shared {
				if rng.Float64() < valueMatchRate {
					rightRow[index] = leftValues[column]
				} else {
					rightRow[index] = differentValue(column, leftValues[column], rowNumber, rng)
				}
			} else {
				rightRow[index] = randomValue(column, rowNumber, rng)
			}
		}

		if err := leftCSV.Write(leftRow); err != nil {
			return err
		}
		if err := rightCSV.Write(rightRow); err != nil {
			return err
		}
	}

	return finishCSV(leftCSV, rightCSV)
}

func writeSingleFile(path string, schema []string, rows int, seed int64) error {
	file, writer, err := newCSVFile(path)
	if err != nil {
		return err
	}
	defer file.Close()

	if err := writer.Write(schema); err != nil {
		return err
	}
	rng := rand.New(rand.NewSource(seed))
	for rowNumber := 1; rowNumber <= rows; rowNumber++ {
		row := make([]string, len(schema))
		for index, column := range schema {
			if column == "id" {
				row[index] = fmt.Sprintf("%08d", rowNumber)
			} else {
				row[index] = randomValue(column, rowNumber, rng)
			}
		}
		if err := writer.Write(row); err != nil {
			return err
		}
	}
	return finishCSV(writer)
}

func newCSVFile(path string) (*os.File, *csv.Writer, error) {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if err != nil {
		return nil, nil, fmt.Errorf("create %s: %w", path, err)
	}
	return file, csv.NewWriter(file), nil
}

func finishCSV(writers ...*csv.Writer) error {
	for _, writer := range writers {
		writer.Flush()
		if err := writer.Error(); err != nil {
			return err
		}
	}
	return nil
}

func matchedSchemas(rng *rand.Rand) ([]string, []string) {
	pool := shuffledColumns(rng)
	sharedCount := between(rng, 2, 4)
	leftTotal := between(rng, max(4, sharedCount+2), 7)
	rightTotal := between(rng, max(4, sharedCount+2), 7)
	leftExtra := leftTotal - sharedCount - 1
	rightExtra := rightTotal - sharedCount - 1

	shared := pool[:sharedCount]
	leftOnly := pool[sharedCount : sharedCount+leftExtra]
	rightOnly := pool[sharedCount+leftExtra : sharedCount+leftExtra+rightExtra]

	left := append(append([]string{}, shared...), leftOnly...)
	right := append(append([]string{}, shared...), rightOnly...)
	rng.Shuffle(len(left), func(i, j int) { left[i], left[j] = left[j], left[i] })
	rng.Shuffle(len(right), func(i, j int) { right[i], right[j] = right[j], right[i] })
	return append([]string{"id"}, left...), append([]string{"id"}, right...)
}

func randomSchema(rng *rand.Rand) []string {
	columnCount := between(rng, 3, 6)
	return append([]string{"id"}, shuffledColumns(rng)[:columnCount]...)
}

func shuffledColumns(rng *rand.Rand) []string {
	result := append([]string{}, columns...)
	rng.Shuffle(len(result), func(i, j int) { result[i], result[j] = result[j], result[i] })
	return result
}

func randomValue(column string, rowNumber int, rng *rand.Rand) string {
	switch column {
	case "customer_name":
		return []string{"Aarav", "Diya", "Ishaan", "Meera", "Rohan", "Sara"}[rng.Intn(6)]
	case "category":
		return []string{"alpha", "beta", "gamma", "delta"}[rng.Intn(4)]
	case "amount":
		return fmt.Sprintf("%.2f", 10+rng.Float64()*9990)
	case "quantity":
		return strconv.Itoa(1 + rng.Intn(500))
	case "status":
		return []string{"new", "active", "pending", "closed"}[rng.Intn(4)]
	case "region":
		return []string{"north", "south", "east", "west"}[rng.Intn(4)]
	case "event_date":
		return time.Date(2020, 1, 1, 0, 0, 0, 0, time.UTC).AddDate(0, 0, rng.Intn(3650)).Format("2006-01-02")
	case "score":
		return strconv.Itoa(rng.Intn(101))
	case "active":
		return strconv.FormatBool(rng.Intn(2) == 1)
	case "reference":
		return fmt.Sprintf("REF-%06d", rng.Intn(1_000_000))
	case "currency":
		return []string{"INR", "USD", "EUR", "GBP"}[rng.Intn(4)]
	case "source":
		return []string{"api", "batch", "manual", "partner"}[rng.Intn(4)]
	case "priority":
		return []string{"low", "medium", "high"}[rng.Intn(3)]
	case "department":
		return []string{"engineering", "finance", "operations", "sales"}[rng.Intn(4)]
	case "country":
		return []string{"IN", "US", "GB", "DE", "SG"}[rng.Intn(5)]
	case "version":
		return fmt.Sprintf("v%d.%d", 1+rng.Intn(5), rng.Intn(10))
	default:
		return fmt.Sprintf("value-%d-%d", rowNumber, rng.Intn(1_000_000))
	}
}

func differentValue(column, current string, rowNumber int, rng *rand.Rand) string {
	for range 20 {
		candidate := randomValue(column, rowNumber, rng)
		if candidate != current {
			return candidate
		}
	}
	return current + "-changed"
}

func folderLabel(index int) string {
	label := ""
	for index >= 0 {
		label = string(rune('a'+index%26)) + label
		index = index/26 - 1
	}
	return label
}

func between(rng *rand.Rand, minimum, maximum int) int {
	return minimum + rng.Intn(maximum-minimum+1)
}
