# clinical-trial
# Clinical Trials — OLTP Data Model

This is the operational (OLTP) data model for **investigator-initiated clinical trials** run by an academic research group. It is built on **PostgreSQL** and follows **CDISC CDASH/SDTM** naming and controlled terminology.

The YAML files in `models/` are the **single source of truth**. A Python generator turns them into the DDL, documentation, dictionary, mappings, DBML, `model.json` and synthetic sample data.

## Repository layout

| Folder / file | Hand-written or generated | Content |
|---|---|---|
| [docs/](docs/) | hand-written + `generated/` | [Conceptual](docs/01-conceptual-model.md), [logical](docs/02-logical-model.md) and [physical](docs/03-physical-model.md) models. `generated/` holds the [data dictionary](docs/generated/data-dictionary.md) and [per-schema ERDs](docs/generated/erd.md) |
| [models/](models/) | **hand-written (source of truth)** | One YAML per schema: tables, columns, keys, checks, indexes, partitions, descriptions |
| [dictionary/](dictionary/) | hand-written + 1 generated | Code lists (CDISC CT and local), reference data, business glossary; generated `data_dictionary.csv` |
| [mapping/](mapping/) | hand-written + 1 generated | OLTP → SDTM, OpenClinica ODM → OLTP; generated logical → physical CSV |
| [overrides/](overrides/) | hand-written | Per-environment or per-study changes that are merged on top of the model |
| [generator/](generator/) | code | `python -m generator check \| build \| synth` |
| [scripts/](scripts/) | code | End-to-end validation, OpenClinica converter, reverse engineering |
| [sql/](sql/) | hand-written + `generated/` | Runnable PostgreSQL DDL and seed data |
| [diagram/](diagram/) | generated | DBML schema ([dbdiagram.io](https://dbdiagram.io)) |
| [samples/](samples/) | generated | Synthetic CSV data + `load_samples.sql` |
| [model.json](model.json) | generated | The whole model in one machine-readable file |

## Workflow

```bash
python -m venv .venv && .venv/Scripts/pip install -r requirements.txt   # Windows; on Linux/macOS use .venv/bin/

python -m generator check        # validate models, code lists, mappings, glossary
python -m generator build        # regenerate sql/generated, docs/generated, dictionary, mapping, diagram, model.json
python -m generator synth        # regenerate samples/
python scripts/validate.py       # build + run in a throwaway PostgreSQL container (Docker) + data checks

python -m generator build --override overrides/dev.yaml   # a variant, written to build/dev/
```

To change the model:

1. Edit `models/*.yaml`, `dictionary/codelists.yaml` or the mappings.
2. Run `python -m generator build`.
3. Run `python scripts/validate.py`.
4. Commit the source files and the generated output together.

## Install the database only

```bash
createdb clinical_trials
psql -d clinical_trials -v ON_ERROR_STOP=1 -f sql/run_all.sql
cd samples && psql -d clinical_trials -f load_samples.sql    # optional sample data
```

Requires PostgreSQL 15 or later. Tested on PostgreSQL 16.
