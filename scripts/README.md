# Scripts

| Script | Purpose |
|---|---|
| [validate.py](validate.py) | End-to-end check (Docker): `generator check/build/synth`, then a throwaway PostgreSQL 16 container, DDL, sample load, a codelist-membership check for every lookup column, business-rule checks, the hard-delete block and audit-trail completeness. `--override F` validates a variant; `--keep` leaves the container running |
| [openclinica_odm_to_staging.py](openclinica_odm_to_staging.py) | OpenClinica ODM 1.3 export → staging CSVs (see [mapping/README.md](../mapping/README.md)) |
| [reverse_engineer.py](reverse_engineer.py) | Rebuilds `models/*.yaml` from a live database (`sql/catalog.sql` dump) plus SQL comments. It was used once to bootstrap the models from the original hand-written DDL. Afterwards, re-run it only to absorb manual DDL changes |
| [sql/catalog.sql](sql/catalog.sql) | Catalog query that produces the JSON input for `reverse_engineer.py` |
