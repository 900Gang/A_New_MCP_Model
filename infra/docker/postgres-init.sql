-- PRD §4.4 — extensions the schema depends on. Created once, at container init,
-- because the runtime DB role is least-privilege and holds no DDL rights (TB-8).
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;      -- case-insensitive admin email
CREATE EXTENSION IF NOT EXISTS pg_trgm;     -- restaurant name fuzzy search (FR-8)
CREATE EXTENSION IF NOT EXISTS btree_gist;  -- EXCLUDE constraint on bookings (§7.2)

-- Timeouts are set per-connection by app/db/session.py in deployed environments;
-- these are the local-development backstops.
ALTER DATABASE bharat SET statement_timeout = '15s';
ALTER DATABASE bharat SET lock_timeout = '3s';
ALTER DATABASE bharat SET idle_in_transaction_session_timeout = '30s';
