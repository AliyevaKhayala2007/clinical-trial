-- =====================================================================
-- 20 - Audit trail functions, standard triggers on every table, DB roles (hand-written)
-- =====================================================================

-- audit.audit_log itself is generated from models/10_audit.yaml (sql/generated/).

-- Creates monthly partitions from the current month for p_months months.
-- Schedule monthly (pg_cron or an external job) to stay ahead.
CREATE OR REPLACE FUNCTION audit.create_audit_partitions(p_months integer DEFAULT 12) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    m date;
    part text;
BEGIN
    FOR i IN 0 .. p_months - 1 LOOP
        m := (date_trunc('month', current_date) + make_interval(months => i))::date;
        part := format('audit_log_%s', to_char(m, 'YYYYMM'));
        IF to_regclass('audit.' || part) IS NULL THEN
            EXECUTE format('CREATE TABLE audit.%I PARTITION OF audit.audit_log FOR VALUES FROM (%L) TO (%L)',
                           part, m, (m + interval '1 month')::date);
        END IF;
    END LOOP;
END $$;

SELECT audit.create_audit_partitions(12);

-- Row-level audit trigger. TG_ARGV[0] = primary-key column, TG_ARGV[1] = logical table name
-- (so rows written to partitions are logged under the parent table name).
CREATE OR REPLACE FUNCTION audit.log_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, audit AS $$
DECLARE
    v_old jsonb;
    v_new jsonb;
    v_cols text[];
BEGIN
    IF TG_OP IN ('UPDATE','DELETE') THEN v_old := to_jsonb(OLD); END IF;
    IF TG_OP IN ('INSERT','UPDATE') THEN v_new := to_jsonb(NEW); END IF;

    IF TG_OP = 'UPDATE' THEN
        SELECT array_agg(n.key) INTO v_cols
        FROM jsonb_each(v_new) n
        WHERE n.value IS DISTINCT FROM v_old -> n.key
          AND n.key NOT IN ('updated_at','updated_by');
        IF v_cols IS NULL THEN RETURN NEW; END IF;   -- nothing meaningful changed
    END IF;

    INSERT INTO audit.audit_log (operation, table_schema, table_name, record_id,
                                 old_values, new_values, changed_columns, reason_for_change)
    VALUES (left(TG_OP, 1), TG_TABLE_SCHEMA, COALESCE(TG_ARGV[1], TG_TABLE_NAME),
            COALESCE(v_new, v_old) ->> TG_ARGV[0],
            v_old, v_new, v_cols,
            NULLIF(current_setting('app.change_reason', true), ''));
    RETURN NULL;
END $$;

-- Attach the standard triggers to every business table (top-level tables only;
-- triggers on partitioned parents are inherited by partitions).
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS pk_col
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_index i     ON i.indrelid = c.oid AND i.indisprimary
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = i.indkey[0]
        WHERE n.nspname IN ('ref','security','org','study','site','subject','clinical','safety','supply','dq')
          AND c.relkind IN ('r','p')
          AND NOT c.relispartition
    LOOP
        EXECUTE format('CREATE TRIGGER trg_set_updated BEFORE UPDATE ON %I.%I
                        FOR EACH ROW EXECUTE FUNCTION audit.set_updated_columns()', r.sch, r.tbl);
        EXECUTE format('CREATE TRIGGER trg_no_hard_delete BEFORE DELETE ON %I.%I
                        FOR EACH ROW EXECUTE FUNCTION audit.prevent_hard_delete()', r.sch, r.tbl);
        EXECUTE format('CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON %I.%I
                        FOR EACH ROW EXECUTE FUNCTION audit.log_change(%L, %L)', r.sch, r.tbl, r.pk_col, r.tbl);
    END LOOP;
END $$;

-- The audit log itself is append-only.
CREATE OR REPLACE FUNCTION audit.block_audit_modification() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit.audit_log is append-only';
END $$;
CREATE TRIGGER trg_audit_append_only BEFORE UPDATE OR DELETE ON audit.audit_log
    FOR EACH ROW EXECUTE FUNCTION audit.block_audit_modification();

-- ---------- Database roles ----------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ct_readonly')  THEN CREATE ROLE ct_readonly  NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ct_app')       THEN CREATE ROLE ct_app       NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ct_unblinded') THEN CREATE ROLE ct_unblinded NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ct_auditor')   THEN CREATE ROLE ct_auditor   NOLOGIN; END IF;
END $$;

GRANT USAGE ON SCHEMA ref, security, org, study, site, subject, clinical, safety, supply, dq
    TO ct_readonly, ct_app, ct_unblinded;
GRANT SELECT ON ALL TABLES IN SCHEMA ref, org, study, site, subject, clinical, safety, supply, dq TO ct_readonly;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA ref, security, org, study, site, subject, clinical, safety, supply, dq TO ct_app;

-- Blinded data: only the unblinded role may read treatment assignment.
REVOKE ALL ON subject.randomization_list_entry, supply.investigational_product FROM ct_readonly, ct_app;
GRANT SELECT ON subject.randomization_list_entry, supply.investigational_product TO ct_unblinded;
GRANT INSERT, UPDATE ON subject.randomization_list_entry, supply.investigational_product TO ct_unblinded;

-- Column defaults call audit.current_app_user(), so writers need the schema + function.
GRANT USAGE ON SCHEMA audit TO ct_app, ct_unblinded, ct_auditor;
GRANT EXECUTE ON FUNCTION audit.current_app_user() TO ct_app, ct_unblinded;
GRANT SELECT ON audit.audit_log TO ct_auditor;
