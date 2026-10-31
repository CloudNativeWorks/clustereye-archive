-- ClusterEye per-query metrics — ClickHouse schema (Faz 0).
--
-- These tables hold the HIGH-cardinality per-query data that was
-- previously stored as InfluxDB series (one series per query plan),
-- which OOM-swapped single-node InfluxDB on large fleets. In ClickHouse
-- query_hash / query_text / plan_handle are plain columns — cardinality
-- is a non-issue.
--
-- Low-cardinality system metrics + the *_performance_summary aggregates
-- stay in InfluxDB; they are NOT migrated here.
--
-- Engine notes:
--   * MergeTree, PARTITION BY day so retention TTL drops whole parts.
--   * ORDER BY (agent_id, time, query_hash): favours the hot path
--     (list / top-N / aggregate over a time window for an agent).
--     Per-query drill-downs still prune by partition + agent_id prefix.
--   * LowCardinality(String) for bounded dimensions (agent ids, db
--     names, categories) — dictionary-encoded, cheap.

CREATE DATABASE IF NOT EXISTS clustereye;

-- ---------------------------------------------------------------
-- MSSQL — top queries (sys.dm_exec_query_stats snapshots)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.mssql_top_queries
(
    time                  DateTime64(3, 'UTC'),
    agent_id              LowCardinality(String),
    host                  LowCardinality(String),
    database              LowCardinality(String),
    query_hash            String,
    plan_handle           String,
    query_plan_hash       String,
    query_type            LowCardinality(String),
    schema_name           String,
    object_name           String,
    query_text            String,
    collection_method     LowCardinality(String),
    is_new                UInt8 DEFAULT 0,
    execution_count       UInt64 DEFAULT 0,
    avg_duration_ms       Float64 DEFAULT 0,
    total_duration_ms     Float64 DEFAULT 0,
    avg_cpu_time_ms       Float64 DEFAULT 0,
    total_cpu_time_ms     Float64 DEFAULT 0,
    avg_logical_reads     Float64 DEFAULT 0,
    total_logical_reads   UInt64 DEFAULT 0,
    avg_physical_reads    Float64 DEFAULT 0,
    total_physical_reads  UInt64 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- MSSQL — Active Session Sampler workload attribution
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.mssql_query_workload
(
    time              DateTime64(3, 'UTC'),
    agent_id          LowCardinality(String),
    query_hash        String,
    wait_category     LowCardinality(String),
    wait_ms           Float64 DEFAULT 0,
    samples           Float64 DEFAULT 0,
    blocked_samples   Float64 DEFAULT 0,
    blocking_samples  Float64 DEFAULT 0,
    active_sessions   Float64 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- MSSQL — per-query wait correlation (Query Store wait_stats)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.mssql_query_waits
(
    time           DateTime64(3, 'UTC'),
    agent_id       LowCardinality(String),
    query_hash     String,
    wait_category  LowCardinality(String),
    wait_ms        Float64 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- MSSQL — query text catalog (sampler one-shot fingerprints)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.mssql_query_text_catalog
(
    time         DateTime64(3, 'UTC'),
    agent_id     LowCardinality(String),
    database     LowCardinality(String),
    query_hash   String,
    query_text   String,
    schema_name  String,
    object_name  String
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- PostgreSQL — pg_stat_statements query metrics
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.postgresql_query
(
    time                  DateTime64(3, 'UTC'),
    agent_id              LowCardinality(String),
    host                  LowCardinality(String),
    database              LowCardinality(String),
    query_hash            String,
    query_id              String,
    query_type            LowCardinality(String),
    username              LowCardinality(String),
    application_name      LowCardinality(String),
    state                 LowCardinality(String),
    query_text            String,
    execution_count       UInt64 DEFAULT 0,
    avg_duration_ms       Float64 DEFAULT 0,
    total_duration_ms     Float64 DEFAULT 0,
    total_io_read_bytes   Float64 DEFAULT 0,
    total_io_write_bytes  Float64 DEFAULT 0,
    total_rows_returned   Float64 DEFAULT 0,
    avg_rows_returned     Float64 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- PostgreSQL — workload attribution (Active Session Sampler)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.postgresql_query_workload
(
    time              DateTime64(3, 'UTC'),
    agent_id          LowCardinality(String),
    query_hash        String,
    wait_category     LowCardinality(String),
    wait_ms           Float64 DEFAULT 0,
    samples           Float64 DEFAULT 0,
    blocked_samples   Float64 DEFAULT 0,
    blocking_samples  Float64 DEFAULT 0,
    active_sessions   Float64 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- Oracle — top SQL (V$SQLSTATS snapshots)
-- ---------------------------------------------------------------
-- Oracle keys per-query data by sql_id (high cardinality). The same
-- sql_id can appear under several rank dimensions in one snapshot
-- (elapsed / cpu / buffer_gets / disk_reads / executions), so the
-- natural row key is (agent_id, time, sql_id, rank_dim).
CREATE TABLE IF NOT EXISTS clustereye.oracle_top_sql
(
    time             DateTime64(3, 'UTC'),
    agent_id         LowCardinality(String),
    sql_id           String,
    parsing_schema   LowCardinality(String),
    rank_dim         LowCardinality(String),
    plan_hash_value  Int64   DEFAULT 0,
    module           String,
    action           String,
    sql_text         String,
    executions       Int64   DEFAULT 0,
    elapsed_time_us  Int64   DEFAULT 0,
    cpu_time_us      Int64   DEFAULT 0,
    buffer_gets      Int64   DEFAULT 0,
    disk_reads       Int64   DEFAULT 0,
    rows_processed   Int64   DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, sql_id, rank_dim)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- MongoDB — query metrics (from system.profile aggregation)
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS clustereye.mongodb_queries
(
    time               DateTime64(3, 'UTC'),
    agent_id           LowCardinality(String),
    host               LowCardinality(String),
    replica_set        LowCardinality(String),
    database           LowCardinality(String),
    collection         LowCardinality(String),
    query_hash         String,
    query_text         String,
    query_text_raw     String,
    execution_count    UInt64  DEFAULT 0,
    avg_duration_ms    Float64 DEFAULT 0,
    p95_duration_ms    Float64 DEFAULT 0,
    avg_docs_returned  Float64 DEFAULT 0,
    avg_docs_examined  Float64 DEFAULT 0,
    avg_keys_examined  Float64 DEFAULT 0,
    scan_efficiency    Float64 DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, query_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;

-- ---------------------------------------------------------------
-- MySQL — top queries (Phase 5, performance_schema digest analytics)
-- ---------------------------------------------------------------
-- One row per (agent_id, time tick, digest_hash). digest_hash is
-- MySQL's own DIGEST value (64-char hex, stable across nodes for the
-- same normalised SQL). normalized_query_hash is the agent's own
-- SHA-256-derived 16-char hash of the lowercased digest text — used
-- for cross-engine joins (an MSSQL query and a MySQL query with the
-- same normalised shape will share a normalized_query_hash even
-- though their engine-specific DIGEST values diverge).
--
-- All numeric fields are per-window deltas, not lifetime cumulative
-- counters. The agent's DigestCollector tracks the previous snapshot
-- per (schema, digest) and emits (current - previous) every tick.
-- That way "execution_count = 250" means "this digest ran 250 times
-- in the last tick window", which is what dashboards and alerting
-- actually want to chart.
--
-- query_text holds MySQL's already-normalised DIGEST_TEXT (literals
-- replaced with ?). Per the Phase 5 spec we never store literal-heavy
-- raw SQL. _others_ rows aggregate any digests that fell out of the
-- top-N cardinality cap.
CREATE TABLE IF NOT EXISTS clustereye.mysql_top_queries
(
    time                          DateTime64(3, 'UTC'),
    agent_id                      LowCardinality(String),
    host                          LowCardinality(String),
    cluster                       LowCardinality(String),
    schema_name                   LowCardinality(String),
    digest_hash                   String,
    normalized_query_hash         String,
    query_type                    LowCardinality(String),
    query_text                    String,
    execution_count               UInt64  DEFAULT 0,
    total_latency_ms              Float64 DEFAULT 0,
    avg_latency_ms                Float64 DEFAULT 0,
    max_latency_ms                Float64 DEFAULT 0,
    rows_examined                 UInt64  DEFAULT 0,
    rows_sent                     UInt64  DEFAULT 0,
    rows_examined_per_row_sent    Float64 DEFAULT 0,
    tmp_tables                    UInt64  DEFAULT 0,
    tmp_disk_tables               UInt64  DEFAULT 0,
    full_joins                    UInt64  DEFAULT 0,
    full_scans                    UInt64  DEFAULT 0,
    sort_merge_passes             UInt64  DEFAULT 0
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(time)
ORDER BY (agent_id, time, digest_hash)
TTL toDateTime(time) + INTERVAL 30 DAY;
