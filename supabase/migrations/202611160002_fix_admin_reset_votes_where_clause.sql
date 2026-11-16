-- Corrige o reset para satisfazer a proteção contra DELETE sem WHERE.
-- Este sistema mantém uma única eleição, identificada por election_config.id = 1.
-- A condição impede qualquer exclusão se a configuração da eleição não existir.
CREATE OR REPLACE FUNCTION public.admin_reset_votes(p_confirm text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_status text;
  v_ballots integer := 0;
  v_participation integer := 0;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;
  IF COALESCE(p_confirm, '') <> 'RESETAR VOTOS' THEN
    RAISE EXCEPTION 'confirmacao_invalida';
  END IF;

  SELECT status INTO v_status
  FROM public.election_config
  WHERE id = 1
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'configuracao_inexistente';
  END IF;
  IF v_status NOT IN ('paused', 'closed') THEN
    RAISE EXCEPTION 'reset_exige_votacao_suspensa_ou_encerrada';
  END IF;

  PERFORM set_config('app.allow_ballot_reset', 'on', true);

  DELETE FROM public.ballots
  WHERE EXISTS (
    SELECT 1
    FROM public.election_config
    WHERE id = 1
  );
  GET DIAGNOSTICS v_ballots = ROW_COUNT;

  DELETE FROM public.participation
  WHERE EXISTS (
    SELECT 1
    FROM public.election_config
    WHERE id = 1
  );
  GET DIAGNOSTICS v_participation = ROW_COUNT;

  UPDATE public.candidates SET runoff_eligible = false;
  UPDATE public.election_config
    SET status = 'paused', round = 1
    WHERE id = 1;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (auth.uid(), 'election_votes_reset',
    jsonb_build_object(
      'previous_status', v_status,
      'new_status', 'paused',
      'round_reset_to', 1,
      'ballots_deleted', v_ballots,
      'participation_deleted', v_participation
    ));

  RETURN jsonb_build_object(
    'ballots_deleted', v_ballots,
    'participation_deleted', v_participation,
    'status', 'paused',
    'round', 1
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_votes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_votes(text) TO authenticated;
