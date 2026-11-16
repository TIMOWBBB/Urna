-- Lista eleitores sem participação e permite selecioná-los pelo nome no painel.
-- Os códigos de votação não são recuperáveis: voters.code_hash armazena somente o hash.
CREATE OR REPLACE FUNCTION public.admin_voter_delete_options()
RETURNS TABLE(voter_id uuid, display_name text, discord_id text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  RETURN QUERY
  SELECT v.id, v.display_name, v.discord_id
  FROM public.voters AS v
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.participation AS p
    WHERE p.voter_id = v.id
  )
  ORDER BY v.display_name, v.id;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_voter_by_id(
  p_voter_id uuid,
  p_confirm text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_voter_id uuid;
  v_display_name text;
  v_discord_id text;
  v_deleted integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  IF p_voter_id IS NULL THEN
    RAISE EXCEPTION 'eleitor_nao_encontrado';
  END IF;

  IF COALESCE(p_confirm, '') <> 'APAGAR ELEITOR' THEN
    RAISE EXCEPTION 'confirmacao_invalida';
  END IF;

  BEGIN
    SELECT v.id, v.display_name, v.discord_id
      INTO STRICT v_voter_id, v_display_name, v_discord_id
    FROM public.voters AS v
    WHERE v.id = p_voter_id
    FOR UPDATE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE EXCEPTION 'eleitor_nao_encontrado';
    WHEN TOO_MANY_ROWS THEN
      RAISE EXCEPTION 'eleitor_id_ambiguo';
  END;

  IF EXISTS (
    SELECT 1
    FROM public.participation AS p
    WHERE p.voter_id = v_voter_id
  ) THEN
    RAISE EXCEPTION 'eleitor_ja_votou';
  END IF;

  PERFORM set_config('app.allow_voter_delete', 'on', true);

  DELETE FROM public.voters AS v
  WHERE v.id = v_voter_id
    AND NOT EXISTS (
      SELECT 1
      FROM public.participation AS p
      WHERE p.voter_id = v.id
    );
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  IF v_deleted <> 1 THEN
    RAISE EXCEPTION 'eleitor_ja_votou';
  END IF;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (
    auth.uid(),
    'voter_deleted',
    jsonb_build_object(
      'voter_id', v_voter_id,
      'display_name', v_display_name,
      'discord_id', v_discord_id,
      'voters_deleted', v_deleted
    )
  );

  RETURN jsonb_build_object(
    'voters_deleted', v_deleted,
    'display_name', v_display_name
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_voter_delete_options() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_voter_delete_options() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_delete_voter_by_id(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_voter_by_id(uuid, text) TO authenticated;
