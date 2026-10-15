ALTER TABLE workflow_runs RENAME TO runs;
ALTER TABLE runs RENAME COLUMN workflow_id TO owner_id;
ALTER TABLE runs ADD COLUMN kind TEXT NOT NULL DEFAULT 'workflow';
DROP INDEX IF EXISTS workflow_runs_status;
CREATE INDEX IF NOT EXISTS runs_status ON runs(status, updated_at);
CREATE INDEX IF NOT EXISTS runs_owner ON runs(kind, owner_id, updated_at);
