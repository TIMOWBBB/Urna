BEGIN;

CREATE OR REPLACE FUNCTION public.admin_delete_election_office(p_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_name text;
  v_active boolean;
  v_status text;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'sem_permissao';
  END IF;

  SELECT status INTO v_status
  FROM public.election_config
  WHERE id = 1
  FOR UPDATE;

  IF v_status IS NULL THEN
    RAISE EXCEPTION 'configuracao_inexistente';
  END IF;
  IF v_status NOT IN ('draft', 'paused') THEN
    RAISE EXCEPTION 'cargos_bloqueados';
  END IF;
  IF EXISTS (SELECT 1 FROM public.ballots)
     OR EXISTS (SELECT 1 FROM public.participation) THEN
    RAISE EXCEPTION 'cargos_bloqueados_com_votos';
  END IF;

  SELECT name, active
    INTO v_name, v_active
  FROM public.election_offices
  WHERE id = p_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'cargo_nao_encontrado';
  END IF;

  IF v_active AND NOT EXISTS (
    SELECT 1
    FROM public.election_offices
    WHERE active AND id <> p_id
  ) THEN
    RAISE EXCEPTION 'cargo_ativo_obrigatorio';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.candidates
    WHERE office_id = p_id
  ) THEN
    RAISE EXCEPTION 'cargo_possui_candidatos';
  END IF;

  DELETE FROM public.election_offices
  WHERE id = p_id;

  INSERT INTO public.audit_log(actor, action, details)
  VALUES (
    auth.uid(),
    'election_office_deleted',
    jsonb_build_object('office_id', p_id, 'name', v_name, 'active', v_active)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_delete_election_office(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_election_office(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
