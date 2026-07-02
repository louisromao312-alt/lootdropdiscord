-- =============================================================================
-- LootDrop: Profil anlegen + Demo-Vault (wenn schema.sql ohne Demo-Daten lief)
-- =============================================================================
-- Schritt 1: Spalten deiner profiles-Tabelle anzeigen
SELECT
  column_name,
  data_type,
  is_nullable,
  column_default
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'profiles'
ORDER BY ordinal_position;

-- Schritt 2: Automatisch Demo-Profil versuchen
SELECT public.ensure_demo_profile() AS profile_id;

-- Schritt 3: Falls Schritt 2 NULL zurückgibt → manuell anpassen:
-- Ersetze die Spalten unten durch die Pflichtfelder aus Schritt 1!
--
-- Beispiel A (einfaches Schema):
-- INSERT INTO public.profiles (id, name)
-- VALUES (gen_random_uuid(), 'Mein LootDrop Server');
--
-- Beispiel B (Supabase Auth verknüpft):
-- INSERT INTO public.profiles (id, full_name)
-- SELECT id, 'Mein LootDrop Server' FROM auth.users LIMIT 1;

-- Schritt 4: Demo-Belohnungen anlegen (nachdem profile_id existiert)
DO $$
DECLARE
  v_profile_id UUID;
BEGIN
  SELECT id INTO v_profile_id FROM public.profiles LIMIT 1;

  IF v_profile_id IS NULL THEN
    RAISE EXCEPTION 'Noch kein Profil vorhanden. Bitte Schritt 2 oder 3 ausführen.';
  END IF;

  INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
  SELECT v_profile_id, 'Amazon Gutschein 5€', 'Digitaler Gutscheincode', 'AMZN-DEMO-XXXX', 500, FALSE
  WHERE NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'Amazon Gutschein 5€');

  INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
  SELECT v_profile_id, 'Steam Key Demo', 'Steam-Einlösung', 'STEAM-DEMO-KEY', 1200, FALSE
  WHERE NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'Steam Key Demo');

  RAISE NOTICE 'Demo-Vault für Profil % angelegt.', v_profile_id;
END $$;

-- Schritt 5: Prüfen
SELECT id, name FROM public.profiles;
SELECT id, profile_id, name, cost, is_used FROM public.vault;
