CREATE TABLE IF NOT EXISTS threads (
    id TEXT PRIMARY KEY,
    resource TEXT,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
    id INTEGER PRIMARY KEY,
    thread_id TEXT NOT NULL,
    seq INTEGER NOT NULL,
    role TEXT NOT NULL,
    content_json TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS messages_thread_seq ON messages(thread_id, seq);
CREATE TABLE IF NOT EXISTS working_memory (
    resource TEXT NOT NULL,
    agent_id TEXT NOT NULL,
    value_json TEXT NOT NULL,
    fingerprint INTEGER NOT NULL,
    updated_at INTEGER NOT NULL,
    PRIMARY KEY (resource, agent_id)
);
CREATE TABLE IF NOT EXISTS workflow_runs (
    run_id TEXT PRIMARY KEY,
    workflow_id TEXT NOT NULL,
    fingerprint INTEGER NOT NULL,
    status TEXT NOT NULL,
    suspended_at TEXT,
    state_json TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS workflow_runs_status ON workflow_runs(status, updated_at);
