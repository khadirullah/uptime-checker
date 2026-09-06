// The worker has two jobs.
//
// Scheduler: once per interval, push every site id onto the redis queue.
// Only one worker replica does this per tick, guarded by a redis lock,
// so scaling the worker out does not multiply the checks.
//
// Consumer: pop site ids from the queue, fetch the site, write the result
// to postgres for history and to redis for the "current status" the api shows.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

const (
	startupWait = 60 * time.Second
	queueKey    = "checks:queue"
	lockKey     = "scheduler:lock"
)

func statusKey(siteID int64) string {
	return fmt.Sprintf("site:%d:status", siteID)
}

type config struct {
	databaseURL string
	redisURL    string
	interval    time.Duration
	httpTimeout time.Duration
}

func loadConfig() config {
	return config{
		databaseURL: envOr("DATABASE_URL", "postgresql://uptime:uptime@localhost:5432/uptime"),
		redisURL:    envOr("REDIS_URL", "redis://localhost:6379/0"),
		interval:    time.Duration(envInt("CHECK_INTERVAL_SECONDS", 60)) * time.Second,
		httpTimeout: time.Duration(envInt("HTTP_TIMEOUT_SECONDS", 10)) * time.Second,
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func envInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		log.Printf("ignoring %s=%q, using %d", key, v, fallback)
		return fallback
	}
	return n
}

type worker struct {
	cfg  config
	db   *pgxpool.Pool
	rdb  *redis.Client
	http *http.Client
}

// waitFor retries ping until it succeeds or the deadline passes. On a fresh cluster the
// worker can start before dns knows the postgres service or before the migrate job has run,
// and crashing into a restart loop for that is noise. Anything longer than a minute is real.
func waitFor(ctx context.Context, name string, ping func() error) error {
	deadline := time.Now().Add(startupWait)
	for {
		err := ping()
		if err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return err
		}
		log.Printf("waiting for %s: %v", name, err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

func main() {
	cfg := loadConfig()
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	db, err := pgxpool.New(ctx, cfg.databaseURL)
	if err != nil {
		log.Fatalf("postgres config: %v", err)
	}
	defer db.Close()
	if err := waitFor(ctx, "postgres", func() error { return db.Ping(ctx) }); err != nil {
		log.Fatalf("postgres ping: %v", err)
	}

	opts, err := redis.ParseURL(cfg.redisURL)
	if err != nil {
		log.Fatalf("redis config: %v", err)
	}
	rdb := redis.NewClient(opts)
	defer rdb.Close()
	if err := waitFor(ctx, "redis", func() error { return rdb.Ping(ctx).Err() }); err != nil {
		log.Fatalf("redis ping: %v", err)
	}

	w := &worker{cfg: cfg, db: db, rdb: rdb, http: &http.Client{Timeout: cfg.httpTimeout}}
	log.Printf("worker up: interval=%s timeout=%s", cfg.interval, cfg.httpTimeout)

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); w.runScheduler(ctx) }()
	go func() { defer wg.Done(); w.runConsumer(ctx) }()
	wg.Wait()
	log.Print("worker stopped")
}

// runScheduler enqueues every site once per interval. The lock has a ttl a bit
// shorter than the interval so exactly one replica wins each tick.
func (w *worker) runScheduler(ctx context.Context) {
	w.scheduleOnce(ctx)
	t := time.NewTicker(w.cfg.interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.scheduleOnce(ctx)
		}
	}
}

func (w *worker) scheduleOnce(ctx context.Context) {
	ttl := w.cfg.interval - 5*time.Second
	if ttl < time.Second {
		ttl = time.Second
	}
	won, err := w.rdb.SetNX(ctx, lockKey, "1", ttl).Result()
	if err != nil {
		log.Printf("scheduler: lock: %v", err)
		return
	}
	if !won {
		return
	}

	rows, err := w.db.Query(ctx, "SELECT id FROM sites ORDER BY id")
	if err != nil {
		log.Printf("scheduler: list sites: %v", err)
		return
	}
	defer rows.Close()

	var ids []any
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			log.Printf("scheduler: scan: %v", err)
			return
		}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return
	}
	if err := w.rdb.LPush(ctx, queueKey, ids...).Err(); err != nil {
		log.Printf("scheduler: enqueue: %v", err)
		return
	}
	log.Printf("scheduler: queued %d sites", len(ids))
}

// runConsumer blocks on the queue and checks one site at a time.
func (w *worker) runConsumer(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}
		item, err := w.rdb.BRPop(ctx, 5*time.Second, queueKey).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) || ctx.Err() != nil {
				continue
			}
			log.Printf("consumer: pop: %v", err)
			time.Sleep(time.Second)
			continue
		}
		siteID, err := strconv.ParseInt(item[1], 10, 64)
		if err != nil {
			log.Printf("consumer: bad queue item %q", item[1])
			continue
		}
		w.checkSite(ctx, siteID)
	}
}

func (w *worker) checkSite(ctx context.Context, siteID int64) {
	var url string
	err := w.db.QueryRow(ctx, "SELECT url FROM sites WHERE id = $1", siteID).Scan(&url)
	if err != nil {
		// the site was deleted after it was queued. nothing to do.
		log.Printf("consumer: site %d: %v", siteID, err)
		return
	}

	res := check(ctx, w.http, url)

	_, err = w.db.Exec(ctx,
		`INSERT INTO checks (site_id, ok, status_code, latency_ms, error)
		 VALUES ($1, $2, $3, $4, NULLIF($5, ''))`,
		siteID, res.OK, res.StatusCode, res.LatencyMs, res.Error)
	if err != nil {
		log.Printf("consumer: site %d: insert: %v", siteID, err)
	}

	payload, _ := json.Marshal(res)
	if err := w.rdb.Set(ctx, statusKey(siteID), payload, 0).Err(); err != nil {
		log.Printf("consumer: site %d: cache: %v", siteID, err)
	}

	state := "up"
	if !res.OK {
		state = "down"
	}
	log.Printf("check site=%d url=%s %s latency=%dms", siteID, url, state, res.LatencyMs)
}
