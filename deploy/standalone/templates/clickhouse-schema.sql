-- ClusterEye per-query metric store — ClickHouse schema.
-- Mirrors clustereye-api/clickhouse/init/001_schema.sql (kept in sync by hand).
-- 8 tables under the `clustereye` database, 30-day TTL, partitioned by day.

CREATE DATABASE IF NOT EXISTS clustereye;

CREATE TABLE IF NOT EXISTS clustereye.mssql_top_queries
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), host LowCardinality(String),
  database LowCardinality(String), query_hash String, plan_handle String, query_plan_hash String,
  query_type LowCardinality(String), schema_name String, object_name String, query_text String,
  collection_method LowCardinality(String), is_new UInt8 DEFAULT 0, execution_count UInt64 DEFAULT 0,
  avg_duration_ms Float64 DEFAULT 0, total_duration_ms Float64 DEFAULT 0, avg_cpu_time_ms Float64 DEFAULT 0,
  total_cpu_time_ms Float64 DEFAULT 0, avg_logical_reads Float64 DEFAULT 0, total_logical_reads UInt64 DEFAULT 0,
  avg_physical_reads Float64 DEFAULT 0, total_physical_reads UInt64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.mssql_query_workload
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), query_hash String,
  wait_category LowCardinality(String), wait_ms Float64 DEFAULT 0, samples Float64 DEFAULT 0,
  blocked_samples Float64 DEFAULT 0, blocking_samples Float64 DEFAULT 0, active_sessions Float64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.mssql_query_waits
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), query_hash String,
  wait_category LowCardinality(String), wait_ms Float64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.mssql_query_text_catalog
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), database LowCardinality(String),
  query_hash String, query_text String, schema_name String, object_name String )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.postgresql_query
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), host LowCardinality(String),
  database LowCardinality(String), query_hash String, query_id String, query_type LowCardinality(String),
  username LowCardinality(String), application_name LowCardinality(String), state LowCardinality(String),
  query_text String, execution_count UInt64 DEFAULT 0, avg_duration_ms Float64 DEFAULT 0,
  total_duration_ms Float64 DEFAULT 0, total_io_read_bytes Float64 DEFAULT 0,
  total_io_write_bytes Float64 DEFAULT 0, total_rows_returned Float64 DEFAULT 0, avg_rows_returned Float64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.postgresql_query_workload
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), query_hash String,
  wait_category LowCardinality(String), wait_ms Float64 DEFAULT 0, samples Float64 DEFAULT 0,
  blocked_samples Float64 DEFAULT 0, blocking_samples Float64 DEFAULT 0, active_sessions Float64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.oracle_top_sql
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), sql_id String,
  parsing_schema LowCardinality(String), rank_dim LowCardinality(String), plan_hash_value Int64 DEFAULT 0,
  module String, action String, sql_text String, executions Int64 DEFAULT 0, elapsed_time_us Int64 DEFAULT 0,
  cpu_time_us Int64 DEFAULT 0, buffer_gets Int64 DEFAULT 0, disk_reads Int64 DEFAULT 0, rows_processed Int64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,sql_id,rank_dim) TTL toDateTime(time)+INTERVAL 30 DAY;

CREATE TABLE IF NOT EXISTS clustereye.mongodb_queries
( time DateTime64(3,'UTC'), agent_id LowCardinality(String), host LowCardinality(String),
  replica_set LowCardinality(String), database LowCardinality(String), collection LowCardinality(String),
  query_hash String, query_text String, query_text_raw String, execution_count UInt64 DEFAULT 0,
  avg_duration_ms Float64 DEFAULT 0, p95_duration_ms Float64 DEFAULT 0, avg_docs_returned Float64 DEFAULT 0,
  avg_docs_examined Float64 DEFAULT 0, avg_keys_examined Float64 DEFAULT 0, scan_efficiency Float64 DEFAULT 0 )
ENGINE=MergeTree PARTITION BY toYYYYMMDD(time) ORDER BY (agent_id,time,query_hash) TTL toDateTime(time)+INTERVAL 30 DAY;
