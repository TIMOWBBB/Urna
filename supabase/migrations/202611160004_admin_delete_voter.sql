-- Exclusão administrativa segura de eleitores sem participação registrada.
-- Eleitores que já votaram em qualquer turno devem ser preservados para manter a integridade eleitoral.
CREATE OR REPLACE FUNCTION public.block_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_TABLE_NAME = 'ballots'
     AND TG_OP = 'DELETE'
     AND current_setting('app.allow_ballot_reset', true) = 'on' THEN
    RETURN OLD;
  END IF;

  IF TG_TABLE_NAME = 'voters'
     AND TG_OP = 'DELETE'
     AND current_setting('app.allow_voter_delete', true) = 'on' THEN
    RETURN OLD;
  END IF;

  RAISE EXCEPTION 'registro imutável';
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_voter(
  p_discord_id text,
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
  v_discord_id text := btrim(COALESCE(p_discord_id, ''));
  v_deleted integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  IF v_discord_id = '' THEN
    RAISE EXCEPTION 'discord_id_obrigatorio';
  END IF;

  IF COALESCE(p_confirm, '') <> 'APAGAR ELEITOR' THEN
    RAISE EXCEPTION 'confirmacao_invalida';
  END IF;

  BEGIN
    SELECT v.id, v.display_name
      INTO STRICT v_voter_id, v_display_name
    FROM public.voters AS v
    WHERE v.discord_id = v_discord_id
    FOR UPDATE;
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RAISE EXCEPTION 'eleitor_nao_encontrado';
    WHEN TOO_MANY_ROWS THEN
      RAISE EXCEPTION 'discord_id_ambiguo';
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

REVOKE ALL ON FUNCTION public.admin_delete_voter(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_voter(text, text) TO authenticated;
