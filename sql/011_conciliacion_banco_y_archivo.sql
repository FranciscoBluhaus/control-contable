-- ============================================================================
-- Conciliación bancaria: identificar cada lote subido.
--
-- Con varios estados de cuenta subidos, el selector de lotes no tenía forma
-- de distinguirlos (solo mostraba el período, que puede repetirse o no venir
-- bien leído). Se agregan dos columnas, denormalizadas igual que
-- periodo_inicio/periodo_fin (mismo valor repetido en cada fila del lote,
-- para no necesitar una tabla aparte de "lotes"):
--   - banco: nombre del banco leído por la IA del propio PDF (best-effort,
--     puede venir vacío si el documento no lo deja claro).
--   - nombre_archivo_original: el nombre del archivo tal como lo subió el
--     usuario (ej. "estado-cuenta-enero.pdf") — se guarda porque
--     archivo_estado_cuenta solo tiene la ruta interna del storage
--     (<cliente_id>/<uuid>.pdf), donde el nombre original ya se perdió.
-- El frontend usa banco si vino, si no cae a nombre_archivo_original, como
-- respaldo para identificar el lote en el selector.
-- ============================================================================

alter table conciliacion_movimientos
  add column if not exists banco text,
  add column if not exists nombre_archivo_original text;
