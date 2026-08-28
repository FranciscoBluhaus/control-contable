// ============================================================
// Edge Function: admin-delete-user
// Elimina COMPLETAMENTE el acceso de un usuario: borra su cuenta de
// Supabase Auth (auth.users), su fila en `perfiles` y sus filas en
// `asignaciones_clientes`. SOLO puede ejecutarla un usuario con rol
// 'super_admin', y nunca puede borrarse a sí mismo — así, después de
// cualquier borrado, siempre queda al menos ese mismo super_admin con
// acceso (imposible quedar sin ninguno por esta vía).
//
// Importante: esto tiene que borrar la cuenta de Auth de verdad, no solo
// la fila de `perfiles`. Si solo se borrara el perfil, la persona podría
// seguir iniciando sesión con su clave de siempre, y bootstrapPerfil() en
// el frontend trataría eso como un login "sin perfil" — el mismo camino
// que usa el primer arranque de la app, que intenta crear un perfil
// super_admin automáticamente. Un borrado "suave" no revocaría el acceso,
// lo reescalaría.
//
// body: { user_id: string }
// ============================================================
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Falta token de autorización' }), { status: 401, headers: corsHeaders });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

    // Cliente "normal" con el token de quien llama, solo para verificar quién es
    const callerClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } }
    });
    const { data: userData, error: userErr } = await callerClient.auth.getUser();
    if (userErr || !userData?.user) {
      return new Response(JSON.stringify({ error: 'Token inválido' }), { status: 401, headers: corsHeaders });
    }

    const { data: perfil, error: perfilErr } = await callerClient
      .from('perfiles')
      .select('rol')
      .eq('user_id', userData.user.id)
      .maybeSingle();

    if (perfilErr || !perfil || perfil.rol !== 'super_admin') {
      return new Response(JSON.stringify({ error: 'Solo el super administrador puede eliminar usuarios' }), { status: 403, headers: corsHeaders });
    }

    const body = await req.json();
    const userId = (body.user_id || '').trim();
    if (!userId) {
      return new Response(JSON.stringify({ error: 'Falta user_id' }), { status: 400, headers: corsHeaders });
    }

    if (userId === userData.user.id) {
      return new Response(JSON.stringify({ error: 'No puedes eliminar tu propia cuenta' }), { status: 400, headers: corsHeaders });
    }

    // Cliente con permisos de administrador — SOLO existe aquí, nunca en el navegador
    const adminClient = createClient(supabaseUrl, serviceRoleKey);

    // Se borra la cuenta de Auth PRIMERO. Si esto falla, no se toca nada
    // más — mejor dejar todo como estaba que dejar un perfil borrado con
    // la cuenta de Auth todavía viva (ver nota arriba).
    const { error: deleteAuthErr } = await adminClient.auth.admin.deleteUser(userId);
    if (deleteAuthErr) {
      return new Response(JSON.stringify({ error: 'No se pudo eliminar la cuenta: ' + deleteAuthErr.message }), { status: 400, headers: corsHeaders });
    }

    // Limpieza defensiva — por si `asignaciones_clientes`/`perfiles` no
    // tienen ON DELETE CASCADE configurado hacia auth.users. Si ya se
    // borraron solas por cascada, este delete simplemente no encuentra
    // filas y no es un error.
    await adminClient.from('asignaciones_clientes').delete().eq('usuario_id', userId);
    await adminClient.from('perfiles').delete().eq('user_id', userId);

    return new Response(JSON.stringify({ ok: true }), { status: 200, headers: corsHeaders });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message || 'Error desconocido' }), { status: 500, headers: corsHeaders });
  }
});
