"""Convert an OpenClinica CDISC ODM 1.3 export into staging CSVs for the OLTP model.

    python scripts/openclinica_odm_to_staging.py <export.xml> [--mapping mapping/openclinica/odm_to_oltp.yaml] [--out staging]

One CSV is written per target table (e.g. staging/clinical__vital_sign.csv). Rows carry
business keys instead of UUIDs:
    study_code, subject_number, site_number, visit_num   (visit_num empty for non-visit forms)
    <column>                 plain values
    <column>__code           codelist submission value for lookup columns (resolve via ref.code_list_item)
Items present in the export but missing from the mapping are reported, never silently dropped.
"""
import argparse
import csv
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from generator.model import load  # noqa: E402

NS = {"odm": "http://www.cdisc.org/ns/odm/v1.3",
      "OpenClinica": "http://www.openclinica.org/ns/odm_ext_v130/v3.1"}
KEY_COLS = ["study_code", "subject_number", "site_number", "visit_num"]


def attr(el, qname):
    if ":" in qname:
        prefix, local = qname.split(":", 1)
        return el.get(f"{{{NS[prefix]}}}{local}")
    return el.get(qname)


def validate_mapping(model, m):
    errors = []
    codes = {c["code"]: {i["value"] for i in c["items"]} for c in model.codelists["codelists"]}

    def col_ok(table, col):
        return model.column_exists(f"{table}.{col}")

    for oid, g in m["item_groups"].items():
        t = g["target"]
        if t not in model.tables:
            errors.append(f"{oid}: unknown target table {t}")
            continue
        if g["layout"] == "one_row_per_item":
            for col in (g["date_column"], g["test_column"], g["result_column"], g["unit_column"]):
                if not col_ok(t, col):
                    errors.append(f"{oid}: {t}.{col} does not exist")
            for item, spec in g["items"].items():
                if spec["test"] not in codes.get(g["test_codelist"], ()):
                    errors.append(f"{oid}.{item}: {spec['test']} not in codelist {g['test_codelist']}")
                if spec.get("unit") and spec["unit"] not in codes.get(g["unit_codelist"], ()):
                    errors.append(f"{oid}.{item}: unit {spec['unit']} not in codelist {g['unit_codelist']}")
        else:
            if not col_ok(t, g["sequence_column"]):
                errors.append(f"{oid}: {t}.{g['sequence_column']} does not exist")
            for item, spec in g["items"].items():
                if not col_ok(t, spec["column"]):
                    errors.append(f"{oid}.{item}: {t}.{spec['column']} does not exist")
                cl = spec.get("codelist")
                if cl:
                    if cl not in codes:
                        errors.append(f"{oid}.{item}: unknown codelist {cl}")
                    for v in (spec.get("values") or {}).values():
                        if v not in codes.get(cl, ()):
                            errors.append(f"{oid}.{item}: {v} not in codelist {cl}")
    if errors:
        raise SystemExit("Mapping validation failed:\n" + "\n".join(errors))


def convert(xml_path, m):
    root = ET.parse(xml_path).getroot()
    rows = {}            # target table -> list of dict
    unmapped = Counter()
    for cd in root.findall("odm:ClinicalData", NS):
        if cd.get("StudyOID") != m["study"]["study_oid"]:
            continue
        for sd in cd.findall("odm:SubjectData", NS):
            keys = {"study_code": m["study"]["study_code"],
                    "subject_number": attr(sd, m["subject"]["key"]) or sd.get("SubjectKey"),
                    "site_number": m["subject"].get("sites", {}).get(attr(sd, m["subject"].get("site_attribute", "")) or "", "")}
            for ev in sd.findall("odm:StudyEventData", NS):
                visit = m["events"].get(ev.get("StudyEventOID"))
                if visit is None:
                    unmapped[f"event {ev.get('StudyEventOID')}"] += 1
                for form in ev.findall("odm:FormData", NS):
                    for ig in form.findall("odm:ItemGroupData", NS):
                        g = m["item_groups"].get(ig.get("ItemGroupOID"))
                        items = {it.get("ItemOID"): it.get("Value") for it in ig.findall("odm:ItemData", NS)}
                        if g is None:
                            unmapped[f"item group {ig.get('ItemGroupOID')}"] += 1
                            continue
                        base = {**keys, "visit_num": visit if visit is not None else ""}
                        out = rows.setdefault(g["target"], [])
                        if g["layout"] == "one_row_per_item":
                            when = items.get(g["date_item"], "")
                            for oid, value in items.items():
                                if oid == g["date_item"]:
                                    continue
                                spec = g["items"].get(oid)
                                if spec is None:
                                    unmapped[f"item {oid}"] += 1
                                    continue
                                if value in (None, ""):
                                    continue
                                out.append({**base, g["date_column"]: when, f"{g['test_column']}__code": spec["test"],
                                            g["result_column"]: value, f"{g['unit_column']}__code": spec.get("unit", "")})
                        else:
                            row = {**base, g["sequence_column"]: ig.get("ItemGroupRepeatKey") or "1"}
                            for oid, value in items.items():
                                spec = g["items"].get(oid)
                                if spec is None:
                                    unmapped[f"item {oid}"] += 1
                                    continue
                                value = (spec.get("values") or {}).get(value, value)
                                name = f"{spec['column']}__code" if spec.get("codelist") else spec["column"]
                                row[name] = value
                            out.append(row)
    return rows, unmapped


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("xml")
    ap.add_argument("--mapping", default="mapping/openclinica/odm_to_oltp.yaml")
    ap.add_argument("--out", default="staging")
    args = ap.parse_args()
    m = yaml.safe_load(Path(args.mapping).read_text(encoding="utf-8"))
    validate_mapping(load(), m)
    rows, unmapped = convert(args.xml, m)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for table, data in rows.items():
        cols = KEY_COLS + sorted({k for r in data for k in r} - set(KEY_COLS))
        path = out / f"{table.replace('.', '__')}.csv"
        with path.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=cols)
            w.writeheader()
            w.writerows(data)
        print(f"wrote {path} ({len(data)} rows)")
    for what, n in sorted(unmapped.items()):
        print(f"WARNING unmapped {what} ({n}x)", file=sys.stderr)


if __name__ == "__main__":
    main()
