-- Catalog dump used by scripts/reverse_engineer.py:  psql -At -f scripts/sql/catalog.sql > catalog.json
SELECT json_agg(t ORDER BY t.ord, t.name) FROM (
 SELECT n.nspname AS schema, c.relname AS name,
  array_position(ARRAY['ref','security','org','study','site','subject','clinical','safety','supply','dq','audit'], n.nspname::text) AS ord,
  c.oid::bigint AS oid,
  CASE WHEN c.relkind='p' THEN pg_get_partkeydef(c.oid) END AS partition_by,
  (SELECT json_agg(json_build_object('name',pc.relname,'bound',pg_get_expr(pc.relpartbound,pc.oid)) ORDER BY pc.relname)
     FROM pg_inherits i JOIN pg_class pc ON pc.oid=i.inhrelid WHERE i.inhparent=c.oid) AS partitions,
  (SELECT json_agg(json_build_object('name',a.attname,'type',format_type(a.atttypid,a.atttypmod),
      'not_null',a.attnotnull,'default',pg_get_expr(d.adbin,d.adrelid),'identity',NULLIF(a.attidentity,'')) ORDER BY a.attnum)
     FROM pg_attribute a LEFT JOIN pg_attrdef d ON d.adrelid=a.attrelid AND d.adnum=a.attnum
     WHERE a.attrelid=c.oid AND a.attnum>0 AND NOT a.attisdropped) AS columns,
  (SELECT json_agg(json_build_object('name',co.conname,'type',co.contype,'def',pg_get_constraintdef(co.oid),
      'columns',(SELECT json_agg(at.attname ORDER BY k.ord) FROM unnest(co.conkey) WITH ORDINALITY k(n,ord) JOIN pg_attribute at ON at.attrelid=co.conrelid AND at.attnum=k.n)) ORDER BY co.contype, co.conname)
     FROM pg_constraint co WHERE co.conrelid=c.oid AND co.contype IN ('p','u','f','c') AND co.conparentid=0) AS constraints,
  (SELECT json_agg(json_build_object('name',ic.relname,'def',pg_get_indexdef(ix.indexrelid)) ORDER BY ic.relname)
     FROM pg_index ix JOIN pg_class ic ON ic.oid=ix.indexrelid
     WHERE ix.indrelid=c.oid AND NOT EXISTS (SELECT 1 FROM pg_constraint co WHERE co.conindid=ix.indexrelid AND co.conrelid=c.oid)) AS indexes
 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname IN ('ref','security','org','study','site','subject','clinical','safety','supply','dq','audit')
   AND c.relkind IN ('r','p') AND NOT c.relispartition) t;
