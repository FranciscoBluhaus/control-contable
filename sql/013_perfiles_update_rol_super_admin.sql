-- ============================================================================
-- Permite que un super_admin cambie el rol de cualquier usuario (perfiles.rol)
-- desde "Gestionar acceso". La tabla `perfiles` es anterior al historial de
-- migraciones de este proyecto (no sabemos qué políticas de UPDATE tiene ya
-- configuradas), así que esta política es puramente ADITIVA — en Postgres,
-- las políticas RLS para un mismo comando se combinan con OR, así que esto
-- amplía el acceso sin tocar ni reemplazar nada que ya exista en `perfiles`.
--
-- Correr esto siempre es seguro, exista o no ya un permiso equivalente.
-- ============================================================================

drop policy if exists perfiles_update_super_admin on perfiles;
create policy perfiles_update_super_admin on perfiles
for update using (is_super_admin())
with check (is_super_admin());
