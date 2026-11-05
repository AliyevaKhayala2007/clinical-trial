"""End-to-end validation in a throwaway PostgreSQL container (requires Docker).

    python scripts/validate.py [--override overrides/dev.yaml] [--image postgres:16] [--keep]

Steps: generator check -> build -> synth -> start container -> run DDL -> load samples ->
data checks (each lookup column holds values of its own codelist; business rules R3/R8;
soft-delete trigger; audit trail).
"""
import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from generator.model import load  # noqa: E402

CONTAINER = "ct-model-validate"


def run(cmd, **kw):
    print("$", " ".join(cmd))
    return subprocess.run(cmd, check=True, text=True, **kw)


def psql(sql_or_file, db="ct", file=False, workdir=None):
    cmd = ["docker", "exec"] + (["-w", workdir] if workdir else []) + [CONTAINER, "psql", "-U", "postgres", "-d", db,
                                                                       "-v", "ON_ERROR_STOP=1", "-At", "-q"]
    cmd += ["-f", sql_or_file] if file else ["-c", sql_or_file]
    return subprocess.run(cmd, check=True, text=True, capture_output=True).stdout.strip()


def codelist_checks(model):
    """One query per lookup column: count rows whose value belongs to another codelist."""
    checks = []
    for fq, t in model.tables.items():
        for c in t["columns"]:
            if c.get("codelist"):
                checks.append((f"{fq}.{c['name']} in {c['codelist']}",
                               f"SELECT count(*) FROM {fq} x JOIN ref.code_list_item i ON i.code_list_item_id = x.{c['name']} "
                               f"JOIN ref.code_list l USING (code_list_id) WHERE l.code_list_code <> '{c['codelist']}'"))
    return checks


RULE_CHECKS = [
    ("R3 SAE only for serious AE",
     "SELECT count(*) FROM safety.serious_adverse_event s JOIN safety.adverse_event a USING (adverse_event_id) WHERE NOT a.is_serious"),
    ("R8 subject study = study_site study",
     "SELECT count(*) FROM subject.study_subject s JOIN site.study_site ss USING (study_site_id) WHERE s.study_id <> ss.study_id"),
    ("randomization entries marked used",
     "SELECT count(*) FROM subject.subject_randomization r JOIN subject.randomization_list_entry e USING (randomization_list_entry_id) WHERE NOT e.is_used"),
    ("kit arm = subject arm",
     "SELECT count(*) FROM supply.dispensation d JOIN supply.kit k USING (kit_id) JOIN supply.product_lot l USING (product_lot_id) "
     "JOIN supply.investigational_product p USING (investigational_product_id) "
     "JOIN subject.subject_randomization r ON r.study_subject_id = d.study_subject_id "
     "JOIN subject.randomization_list_entry e USING (randomization_list_entry_id) WHERE p.study_arm_id <> e.study_arm_id"),
]


# Writes the database must reject: (name, SQL, expected error text). Each runs in its own
# transaction, so deferred constraint triggers fire at its COMMIT.
REJECT_CHECKS = [
    ("codelist: lookup value from another codelist",
     "UPDATE study.study SET phase_id = (SELECT code_list_item_id FROM ref.code_list_item i JOIN ref.code_list l "
     "USING (code_list_id) WHERE l.code_list_code = 'SEX' LIMIT 1) WHERE study_id = (SELECT min(study_id::text)::uuid FROM study.study)",
     "is not an active item of codelist TPHASE"),
    ("codelist: inactive item",
     "BEGIN; UPDATE ref.code_list_item SET is_active = false WHERE code_list_item_id = "
     "(SELECT severity_id FROM safety.adverse_event WHERE severity_id IS NOT NULL LIMIT 1); "
     "INSERT INTO safety.adverse_event (study_subject_id, sequence_no, verbatim_term, start_date_text, is_serious, severity_id) "
     "SELECT study_subject_id, 9999, 'x', '2024', false, severity_id FROM safety.adverse_event WHERE severity_id IS NOT NULL LIMIT 1; COMMIT;",
     "is not an active item of codelist AESEV"),
    ("BR01 SAE on non-serious AE",
     "UPDATE safety.adverse_event SET is_serious = false WHERE adverse_event_id = "
     "(SELECT adverse_event_id FROM safety.serious_adverse_event LIMIT 1)",
     "BR01 violated"),
    ("BR03 consent on another study's protocol",
     "UPDATE subject.informed_consent c SET protocol_version_id = (SELECT pv.protocol_version_id FROM study.protocol_version pv "
     "JOIN subject.study_subject s ON s.study_subject_id = c.study_subject_id WHERE pv.study_id <> s.study_id LIMIT 1) "
     "WHERE informed_consent_id = (SELECT informed_consent_id FROM subject.informed_consent LIMIT 1)",
     "BR03 violated"),
    ("BR09 kit of the other arm",
     "UPDATE supply.dispensation d SET kit_id = (SELECT k.kit_id FROM supply.kit k JOIN supply.product_lot USING (product_lot_id) "
     "JOIN supply.investigational_product p USING (investigational_product_id) "
     "WHERE p.study_arm_id IS NOT NULL AND p.study_arm_id <> (SELECT e.study_arm_id FROM subject.subject_randomization r "
     "JOIN subject.randomization_list_entry e USING (randomization_list_entry_id) WHERE r.study_subject_id = d.study_subject_id) "
     "AND NOT EXISTS (SELECT 1 FROM supply.dispensation x WHERE x.kit_id = k.kit_id) LIMIT 1) "
     "WHERE dispensation_id = (SELECT min(dispensation_id::text)::uuid FROM supply.dispensation)",
     "BR09 violated"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--override")
    ap.add_argument("--image", default="postgres:16")
    ap.add_argument("--keep", action="store_true", help="leave the container running")
    args = ap.parse_args()

    py = sys.executable
    ov = ["--override", args.override] if args.override else []
    run([py, "-m", "generator", "check", *ov], cwd=ROOT)
    run([py, "-m", "generator", "build", *ov], cwd=ROOT, stdout=subprocess.DEVNULL)
    run([py, "-m", "generator", "synth", *ov], cwd=ROOT, stdout=subprocess.DEVNULL)
    model = load(ROOT, args.override)
    base = ROOT if not args.override else ROOT / "build" / model.override_name
    samples = base / "samples"

    subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)
    run(["docker", "run", "-d", "--name", CONTAINER, "-e", "POSTGRES_PASSWORD=validate", args.image], stdout=subprocess.DEVNULL)
    failures = 0
    try:
        # The image runs a temporary server during init and then restarts it, so a bare
        # "select 1" can succeed too early. Wait for the init-complete log line first.
        for _ in range(120):
            logs = subprocess.run(["docker", "logs", CONTAINER], capture_output=True, text=True)
            if "PostgreSQL init process complete" in logs.stdout + logs.stderr and subprocess.run(
                    ["docker", "exec", CONTAINER, "pg_isready", "-U", "postgres", "-h", "127.0.0.1"],
                    capture_output=True).returncode == 0:
                break
            time.sleep(1)
        run(["docker", "exec", CONTAINER, "psql", "-U", "postgres", "-q", "-c", "CREATE DATABASE ct"], stdout=subprocess.DEVNULL)
        run(["docker", "cp", str(base / "sql"), f"{CONTAINER}:/sql"])
        run(["docker", "cp", str(samples), f"{CONTAINER}:/samples"])
        psql("/sql/run_all.sql", file=True)
        print("DDL applied")
        psql("load_samples.sql", file=True, workdir="/samples")
        print("samples loaded")

        for name, sql in codelist_checks(model) + RULE_CHECKS:
            bad = int(psql(sql))
            if bad:
                failures += 1
                print(f"FAIL {name}: {bad} rows")
        print(f"{len(codelist_checks(model)) + len(RULE_CHECKS)} data checks run, {failures} failed")

        for name, sql, expected in REJECT_CHECKS:
            try:
                psql(sql)
                failures += 1
                print(f"FAIL {name}: write was accepted")
            except subprocess.CalledProcessError as e:
                if expected in e.stderr:
                    print(f"rejected as expected: {name}")
                else:
                    failures += 1
                    print(f"FAIL {name}: unexpected error: {e.stderr.strip()}")

        try:
            psql("DELETE FROM safety.adverse_event")
            failures += 1
            print("FAIL hard delete was allowed")
        except subprocess.CalledProcessError as e:
            ok = "Hard delete is not allowed" in e.stderr
            failures += 0 if ok else 1
            print("hard delete blocked" if ok else f"FAIL unexpected error: {e.stderr}")
        audited = int(psql("SELECT count(*) FROM audit.audit_log WHERE changed_by = 'synthetic_loader'"))
        loaded = sum(1 for f in samples.glob("*.csv") for _ in f.open(encoding="utf-8")) - len(list(samples.glob("*.csv")))
        print(f"audit rows {audited}, sample rows {loaded}")
        if audited != loaded:
            failures += 1
            print("FAIL audit row count differs from loaded row count")
    finally:
        if not args.keep:
            subprocess.run(["docker", "rm", "-f", CONTAINER], capture_output=True)
    print("VALIDATION " + ("PASSED" if not failures else f"FAILED ({failures})"))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
