-- ============================================================================
-- Permite que perfiles.rol acepte también 'cliente'.
-- Antes solo aceptaba 'super_admin' / 'usuario' (perfiles_rol_check).
-- ============================================================================

alter table perfiles drop constraint perfiles_rol_check;

alter table perfiles add constraint perfiles_rol_check
  check (rol = any (array['super_admin'::text, 'usuario'::text, 'cliente'::text]));
