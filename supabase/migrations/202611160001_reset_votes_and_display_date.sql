-- Migração: reset seguro de votos e data pública do cabeçalho.
-- Execute uma única vez no Supabase SQL Editor.

ALTER TABLE public.election_config
  ADD COLUMN IF NOT EXISTS election_display_date date
  NOT NULL DEFAULT DATE '2027-02-01';

-- Permite exclusão de ballots somente durante a função de reset.
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
  RAISE EXCEPTION 'registro imutável';
END;
$$;

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
  FROM public.election_config WHERE id = 1 FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'configuracao_inexistente';
  END IF;
  IF v_status NOT IN ('paused', 'closed') THEN
    RAISE EXCEPTION 'reset_exige_votacao_suspensa_ou_encerrada';
  END IF;

  PERFORM set_config('app.allow_ballot_reset', 'on', true);
  DELETE FROM public.ballots;
  GET DIAGNOSTICS v_ballots = ROW_COUNT;

  DELETE FROM public.participation;
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

CREATE OR REPLACE FUNCTION public.admin_set_election_display_date(p_date date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'data_invalida';
  END IF;

  UPDATE public.election_config
    SET election_display_date = p_date
    WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'configuracao_inexistente';
  END IF;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (auth.uid(), 'election_display_date_changed',
    jsonb_build_object('election_display_date', p_date));
END;
$$;

REVOKE ALL ON FUNCTION public.admin_reset_votes(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_reset_votes(text) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_set_election_display_date(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_election_display_date(date) TO authenticated;
