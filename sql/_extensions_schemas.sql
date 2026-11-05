-- =====================================================================
-- 00 - Extensions, schemas and shared helper functions
-- Target: PostgreSQL 15+
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

CREATE SCHEMA IF NOT EXISTS ref;        -- reference / controlled terminology & coding dictionaries
CREATE SCHEMA IF NOT EXISTS security;   -- application users, roles, access scope
CREATE SCHEMA IF NOT EXISTS org;        -- organizations, grants, funding
CREATE SCHEMA IF NOT EXISTS study;      -- study, protocol, arms, epochs, schedule
CREATE SCHEMA IF NOT EXISTS site;       -- sites, investigators, study participation, IRB
CREATE SCHEMA IF NOT EXISTS subject;    -- person, study subject, consent, randomization, visits
CREATE SCHEMA IF NOT EXISTS clinical;   -- CDISC findings/interventions: VS, LB, MH, CM, EX
CREATE SCHEMA IF NOT EXISTS safety;     -- AE / SAE
CREATE SCHEMA IF NOT EXISTS supply;     -- investigational product, lots, kits, shipments
CREATE SCHEMA IF NOT EXISTS dq;         -- protocol deviations, data queries
CREATE SCHEMA IF NOT EXISTS audit;      -- audit trail

-- Current application user (set by the application per session/transaction:
--   SET LOCAL app.username = 'jdoe';)  Falls back to the DB login role.
CREATE OR REPLACE FUNCTION audit.current_app_user() RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(NULLIF(current_setting('app.username', true), ''), current_user::text)
$$;

-- Maintains updated_at / updated_by on every UPDATE.
CREATE OR REPLACE FUNCTION audit.set_updated_columns() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    NEW.updated_by := audit.current_app_user();
    IF NEW.is_deleted AND NOT OLD.is_deleted THEN
        NEW.deleted_at := now();
        NEW.deleted_by := audit.current_app_user();
    END IF;
    RETURN NEW;
END $$;

-- Hard deletes are forbidden on business tables (GCP data retention); use soft delete.
CREATE OR REPLACE FUNCTION audit.prevent_hard_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Hard delete is not allowed on %.%; set is_deleted = true instead',
        TG_TABLE_SCHEMA, TG_TABLE_NAME;
END $$;

/*
Standard columns appended to every business table (written out in each CREATE TABLE):
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  text        NOT NULL DEFAULT audit.current_app_user(),
    updated_at  timestamptz,
    updated_by  text,
    is_deleted  boolean     NOT NULL DEFAULT false,
    deleted_at  timestamptz,
    deleted_by  text
*/
