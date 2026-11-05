"""Reverse-engineer models/*.yaml from a live PostgreSQL catalog dump + DDL comments.

Used once to bootstrap the YAML model from the hand-written, tested DDL; it can be
re-run to re-sync after DDL was changed by hand (models/ is otherwise the source of truth).

    python scripts/reverse_engineer.py <catalog.json> [--sql-dir sql] [--out models]

<catalog.json> is produced by: psql -d <db> -At -f scripts/sql/catalog.sql > catalog.json
"""
import argparse
import json
import re
from pathlib import Path

import yaml

STANDARD_COLUMNS = ["created_at", "created_by", "updated_at", "updated_by",
                    "is_deleted", "deleted_at", "deleted_by"]

SCHEMA_DESCRIPTIONS = {
    "ref": "Reference data: CDISC controlled terminology, coding dictionaries (MedDRA, WHODrug, LOINC), countries.",
    "security": "Application users, roles and study/site-scoped role assignments.",
    "org": "Organizations (sponsors, funders, institutions, depots, IRBs), grants and study funding.",
    "study": "Study design: study, protocol versions and amendments, arms, epochs, visit schedule, eligibility criteria.",
    "site": "Sites, investigators, study participation (study_site), PI/Sub-I roles and IRB approvals.",
    "subject": "Pseudonymized persons, study subjects, consent, eligibility, randomization, unblinding and visits.",
    "clinical": "CDISC findings and interventions: vital signs, labs, medical history, concomitant medications, exposure.",
    "safety": "Adverse events and serious adverse event details.",
    "supply": "Investigational product supply chain: products, lots, kits, shipments, dispensation.",
    "dq": "Data quality: protocol deviations, data queries and responses.",
    "audit": "Append-only audit trail (GCP / 21 CFR Part 11).",
}

CREATE_RE = re.compile(r"^CREATE TABLE (\w+)\.(\w+) \(")
COL_COMMENT_RE = re.compile(r"^\s+(\w+)\s+[^-]*?--\s*(.+?)\s*$")


def parse_sql_comments(sql_dir: Path):
    """Return {(schema, table): {"description": str, "columns": {col: comment}}}."""
    result = {}
    for path in sorted(sql_dir.glob("*.sql")):
        lines = path.read_text(encoding="utf-8").splitlines()
        current = None
        for i, line in enumerate(lines):
            m = CREATE_RE.match(line)
            if m:
                key = (m.group(1), m.group(2))
                desc = []
                j = i - 1
                while j >= 0 and lines[j].startswith("--") and not lines[j].startswith("-- ="):
                    text = lines[j].lstrip("- ").strip()
                    if not set(text) <= set("-"):
                        desc.insert(0, text)
                    j -= 1
                result[key] = {"description": " ".join(desc), "columns": {}}
                current = key
                continue
            if current is None:
                continue
            if line.startswith(")"):
                current = None
                continue
            cm = COL_COMMENT_RE.match(line)
            if cm and cm.group(1).upper() not in ("PRIMARY", "CONSTRAINT"):
                result[current]["columns"][cm.group(1)] = cm.group(2)
    return result


def seed_codelist_codes(sql_dir: Path):
    text = (sql_dir / "09_seed_ref.sql").read_text(encoding="utf-8")
    block = text.split("INSERT INTO ref.code_list ", 1)[1].split(";", 1)[0]
    return set(re.findall(r"^\s*\('(\w+)',", block, re.M))


FK_RE = re.compile(r"FOREIGN KEY \(([^)]*)\) REFERENCES (\w+)\.(\w+)\(([^)]*)\)")
IDX_RE = re.compile(r"CREATE (UNIQUE )?INDEX \w+ ON (?:ONLY )?[\w.]+ USING (\w+) \((.*?)\)(?: WHERE (.*))?$")


def split_cols(s):
    return [c.strip() for c in s.split(",")]


def detect_codelist(comment, codes):
    if not comment:
        return None
    first = re.split(r"[\s:(]", comment.strip(), 1)[0]
    return first if first in codes else None


def build_table(t, comments, codes, pk_map):
    info = comments.get((t["schema"], t["name"]), {"description": "", "columns": {}})
    cols = t["columns"] or []
    names = [c["name"] for c in cols]
    standard = all(s in names for s in STANDARD_COLUMNS)

    table = {"name": t["name"], "description": info["description"] or None}
    if standard:
        table["standard_columns"] = True
    if t["partition_by"]:
        table["partition"] = {
            "by": t["partition_by"],
            "partitions": [{"name": p["name"], "bound": p["bound"]} for p in (t["partitions"] or [])],
        }

    # Single-column constraints that carry PostgreSQL's default name are folded into the
    # column definition (pk / unique / references / check); everything else stays table-level.
    tn = t["name"]
    col_attrs = {}
    pk, uniques, foreign_keys, checks = None, [], [], []
    for con in t["constraints"] or []:
        ccols = con["columns"] or []
        single = ccols[0] if len(ccols) == 1 else None
        if con["type"] == "p":
            if single and con["name"] == f"{tn}_pkey":
                col_attrs.setdefault(single, {})["pk"] = True
            else:
                pk = {"name": con["name"], "columns": ccols}
        elif con["type"] == "u":
            if single and con["name"] == f"{tn}_{single}_key":
                col_attrs.setdefault(single, {})["unique"] = True
            else:
                uniques.append({"name": con["name"], "columns": ccols})
        elif con["type"] == "f":
            m = FK_RE.search(con["def"])
            target = f"{m.group(2)}.{m.group(3)}"
            ref_cols = split_cols(m.group(4))
            if single and con["name"] == f"{tn}_{single}_fkey" and ref_cols == pk_map.get(target):
                col_attrs.setdefault(single, {})["references"] = target
            else:
                foreign_keys.append({"name": con["name"], "columns": split_cols(m.group(1)),
                                     "references": target, "ref_columns": ref_cols})
        elif con["type"] == "c":
            expr = con["def"][len("CHECK "):]
            named_col = next((c["name"] for c in cols if con["name"] == f"{tn}_{c['name']}_check"), None)
            if named_col:
                col_attrs.setdefault(named_col, {})["check"] = expr
            else:
                checks.append({"name": con["name"], "expression": expr})

    columns = []
    for c in cols:
        if standard and c["name"] in STANDARD_COLUMNS:
            continue
        comment = info["columns"].get(c["name"])
        attrs = col_attrs.get(c["name"], {})
        col = {"name": c["name"], "type": c["type"]}
        if attrs.get("pk"):
            col["pk"] = True
        elif c["not_null"]:
            col["nullable"] = False
        if c["identity"]:
            col["identity"] = "ALWAYS" if c["identity"] == "a" else "BY DEFAULT"
        elif c["default"] is not None:
            col["default"] = c["default"]
        for k in ("unique", "references", "check"):
            if k in attrs:
                col[k] = attrs[k]
        is_codelist_fk = attrs.get("references") == "ref.code_list_item"
        if is_codelist_fk:
            cl = detect_codelist(comment, codes)
            if cl:
                col["codelist"] = cl
                rest = comment.strip()[len(cl):].lstrip(" :").strip()
                comment = rest or None
        if comment:
            col["description"] = comment
        columns.append(col)

    table["columns"] = columns
    if pk:
        table["primary_key"] = pk
    if uniques:
        table["unique"] = uniques
    if foreign_keys:
        table["foreign_keys"] = foreign_keys
    if checks:
        table["checks"] = checks
    indexes = []
    for ix in t["indexes"] or []:
        m = IDX_RE.match(ix["def"])
        idx = {"name": ix["name"], "columns": split_cols(m.group(3))}
        if m.group(1):
            idx["unique"] = True
        if m.group(2) != "btree":
            idx["method"] = m.group(2)
        if m.group(4):
            w = m.group(4)
            idx["where"] = w[1:-1] if w.startswith("(") and w.endswith(")") else w
        indexes.append(idx)
    if indexes:
        table["indexes"] = indexes
    if table["description"] is None:
        del table["description"]
    return table


class Dumper(yaml.SafeDumper):
    pass


def _str(dumper, data):
    style = '"' if any(ch in data for ch in ":#{}[],&*?|<>=!%@`'\"") or data != data.strip() else None
    return dumper.represent_scalar("tag:yaml.org,2002:str", data, style=style)


Dumper.add_representer(str, _str)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("catalog")
    ap.add_argument("--sql-dir", default="sql")
    ap.add_argument("--out", default="models")
    args = ap.parse_args()

    catalog = json.loads(Path(args.catalog).read_text(encoding="utf-8"))
    sql_dir = Path(args.sql_dir)
    comments = parse_sql_comments(sql_dir)
    codes = seed_codelist_codes(sql_dir)

    pk_map = {f"{t['schema']}.{t['name']}": next(c["columns"] for c in t["constraints"] if c["type"] == "p")
              for t in catalog}
    by_schema = {}
    # keep original creation order (oid) within each schema
    for t in sorted(catalog, key=lambda t: (t["ord"], t["oid"])):
        by_schema.setdefault(t["schema"], []).append(build_table(t, comments, codes, pk_map))

    out = Path(args.out)
    out.mkdir(exist_ok=True)
    for order, (schema, tables) in enumerate(by_schema.items()):
        doc = {"schema": schema, "order": order, "description": SCHEMA_DESCRIPTIONS.get(schema), "tables": tables}
        path = out / f"{order:02d}_{schema}.yaml"
        path.write_text(yaml.dump(doc, Dumper=Dumper, sort_keys=False, allow_unicode=True, width=120), encoding="utf-8")
        print(f"wrote {path} ({len(tables)} tables)")


if __name__ == "__main__":
    main()
