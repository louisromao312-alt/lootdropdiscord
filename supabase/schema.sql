-- =============================================================================
-- LootDrop – Vollständiges Supabase-Schema
-- =============================================================================
-- Ausführung: Supabase Dashboard → SQL Editor → New Query → Run
--
-- Enthält:
--   • Tabellen: players, vault, game_events, purchase_logs
--   • Indizes & Constraints
--   • Trigger (updated_at, Kauf-Protokoll)
--   • RPC-Funktionen (Link-Code, Kauf-Transaktion)
--   • Row Level Security (RLS)
--   • Demo-Daten zum sofortigen Testen des Discord-Bots
--
-- WICHTIG: Der Discord-Bot benötigt den SERVICE ROLE KEY (SUPABASE_KEY),
--          damit RLS umgangen wird und Schreiboperationen funktionieren.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ---------------------------------------------------------------------------
-- Hilfsfunktion: updated_at automatisch setzen
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- ---------------------------------------------------------------------------
-- Hilfsfunktion: Zufälligen Link-Code generieren (8 Zeichen, z.B. A3F9B2C1)
-- Wird vom Minecraft-Plugin beim Anlegen neuer Spieler genutzt.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.generate_link_code()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  chars  TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- ohne 0/O/1/I (Verwechslungsgefahr)
  result TEXT := '';
  i      INT;
BEGIN
  FOR i IN 1..8 LOOP
    result := result || substr(chars, floor(random() * length(chars) + 1)::INT, 1);
  END LOOP;
  RETURN result;
END;
$$;

-- ---------------------------------------------------------------------------
-- Tabelle: players
-- Zentrale Spieler-Daten: Minecraft-UUID, Discord-Verknüpfung, LootCoins
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.players (
  id                 UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  minecraft_uuid     UUID        NOT NULL UNIQUE,
  minecraft_username TEXT,
  discord_id         TEXT        UNIQUE,
  link_code          TEXT        UNIQUE,
  loot_coins         INTEGER     NOT NULL DEFAULT 0 CHECK (loot_coins >= 0),
  created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  -- Mindestens ein Identifikator muss vorhanden sein
  CONSTRAINT players_has_identity CHECK (
    discord_id IS NOT NULL OR link_code IS NOT NULL OR minecraft_uuid IS NOT NULL
  )
);

-- Migration: fehlende Spalten ergänzen falls players bereits existiert
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'players') THEN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'minecraft_uuid') THEN
      ALTER TABLE public.players ADD COLUMN minecraft_uuid UUID;
      UPDATE public.players SET minecraft_uuid = gen_random_uuid() WHERE minecraft_uuid IS NULL;
      ALTER TABLE public.players ALTER COLUMN minecraft_uuid SET NOT NULL;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'minecraft_username') THEN
      ALTER TABLE public.players ADD COLUMN minecraft_username TEXT;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'discord_id') THEN
      ALTER TABLE public.players ADD COLUMN discord_id TEXT UNIQUE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'link_code') THEN
      ALTER TABLE public.players ADD COLUMN link_code TEXT UNIQUE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'loot_coins') THEN
      ALTER TABLE public.players ADD COLUMN loot_coins INTEGER NOT NULL DEFAULT 0;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'created_at') THEN
      ALTER TABLE public.players ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'players' AND column_name = 'updated_at') THEN
      ALTER TABLE public.players ADD COLUMN updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
    END IF;
  END IF;
END $$;

COMMENT ON TABLE  public.players IS 'Spieler-Accounts: Minecraft ↔ Discord Verknüpfung & LootCoins-Kontostand';
COMMENT ON COLUMN public.players.minecraft_uuid IS 'Eindeutige Minecraft-UUID des Spielers';
COMMENT ON COLUMN public.players.discord_id  IS 'Discord Snowflake-ID (TEXT) nach /link';
COMMENT ON COLUMN public.players.link_code   IS 'Einmaliger Code aus dem Spiel; wird nach /link auf NULL gesetzt';
COMMENT ON COLUMN public.players.loot_coins  IS 'LootCoins-Guthaben (wird vom Plugin synchronisiert)';

CREATE INDEX IF NOT EXISTS idx_players_discord_id ON public.players (discord_id)
  WHERE discord_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_players_link_code ON public.players (link_code)
  WHERE link_code IS NOT NULL;

DROP TRIGGER IF EXISTS trg_players_updated_at ON public.players;
CREATE TRIGGER trg_players_updated_at
  BEFORE UPDATE ON public.players
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Tabelle: profiles
-- B2B-Mandant / Server-Profil – vault.profile_id verweist hierauf
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.profiles (
  id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT        NOT NULL DEFAULT 'LootDrop Server',
  slug       TEXT        UNIQUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.profiles IS 'B2B-Mandantenprofile – jeder Vault-Eintrag gehört zu einem Profil';

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Demo-Profil sicherstellen (kompatibel mit verschiedenen profiles-Schemas)
CREATE OR REPLACE FUNCTION public.ensure_demo_profile()
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_id   UUID;
  v_user UUID;
BEGIN
  SELECT id INTO v_id FROM public.profiles ORDER BY created_at NULLS LAST LIMIT 1;
  IF v_id IS NOT NULL THEN
    RETURN v_id;
  END IF;

  -- Variante 1: DEFAULT VALUES (wenn alle Pflichtfelder Defaults haben)
  BEGIN
    INSERT INTO public.profiles DEFAULT VALUES RETURNING id INTO v_id;
    RETURN v_id;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Variante 2: Minimales LootDrop-Schema
  BEGIN
    INSERT INTO public.profiles (id, name, slug)
    VALUES (gen_random_uuid(), 'LootDrop Demo Server', 'lootdrop-demo')
    RETURNING id INTO v_id;
    RETURN v_id;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  BEGIN
    INSERT INTO public.profiles (id, name)
    VALUES (gen_random_uuid(), 'LootDrop Demo Server')
    RETURNING id INTO v_id;
    RETURN v_id;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;

  -- Variante 3: Supabase-typisch (id = auth.users.id)
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'auth' AND table_name = 'users'
  ) THEN
    SELECT u.id INTO v_user FROM auth.users u ORDER BY u.created_at NULLS LAST LIMIT 1;

    IF v_user IS NOT NULL THEN
      BEGIN
        INSERT INTO public.profiles (id) VALUES (v_user) RETURNING id INTO v_id;
        RETURN v_id;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;

      BEGIN
        INSERT INTO public.profiles (id, full_name)
        VALUES (v_user, 'LootDrop Demo Server')
        RETURNING id INTO v_id;
        RETURN v_id;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;

      BEGIN
        INSERT INTO public.profiles (id, username)
        VALUES (v_user, 'lootdrop-demo')
        RETURNING id INTO v_id;
        RETURN v_id;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;

      BEGIN
        INSERT INTO public.profiles (user_id, name)
        VALUES (v_user, 'LootDrop Demo Server')
        RETURNING id INTO v_id;
        RETURN v_id;
      EXCEPTION WHEN OTHERS THEN
        NULL;
      END;
    END IF;
  END IF;

  RETURN NULL;
END;
$$;

DO $$
DECLARE
  v_profile_id UUID;
BEGIN
  v_profile_id := public.ensure_demo_profile();

  IF v_profile_id IS NULL THEN
    RAISE NOTICE 'Kein Profil angelegt – vault-Demo-Daten werden übersprungen. Siehe supabase/create-demo-profile.sql';
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- Tabelle: vault
-- Belohnungen (Codes, Links, Keys) die gegen LootCoins eingelöst werden
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.vault (
  id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id  UUID        NOT NULL REFERENCES public.profiles (id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  description TEXT,
  content     TEXT        NOT NULL,
  cost        INTEGER     NOT NULL CHECK (cost > 0),
  is_used     BOOLEAN     NOT NULL DEFAULT FALSE,
  claimed_by  TEXT,
  claimed_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  CONSTRAINT vault_claimed_consistency CHECK (
    (is_used = FALSE AND claimed_by IS NULL AND claimed_at IS NULL)
    OR
    (is_used = TRUE  AND claimed_by IS NOT NULL AND claimed_at IS NOT NULL)
  )
);

-- Migration: fehlende Spalten ergänzen falls vault bereits existiert (älteres Schema)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'vault') THEN
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'name') THEN
    ALTER TABLE public.vault ADD COLUMN name TEXT;
    UPDATE public.vault SET name = 'Belohnung #' || id::text WHERE name IS NULL;
    ALTER TABLE public.vault ALTER COLUMN name SET NOT NULL;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'description') THEN
    ALTER TABLE public.vault ADD COLUMN description TEXT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'content') THEN
    ALTER TABLE public.vault ADD COLUMN content TEXT;

    -- Bestehende Spalten übernehmen (falls unter anderem Namen angelegt)
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'code') THEN
      UPDATE public.vault SET content = code::text WHERE content IS NULL;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'reward_code') THEN
      UPDATE public.vault SET content = reward_code::text WHERE content IS NULL;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'reward_content') THEN
      UPDATE public.vault SET content = reward_content::text WHERE content IS NULL;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'value') THEN
      UPDATE public.vault SET content = value::text WHERE content IS NULL;
    END IF;

    UPDATE public.vault SET content = 'UNSET-REWARD-' || id::text WHERE content IS NULL;
    ALTER TABLE public.vault ALTER COLUMN content SET NOT NULL;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'cost') THEN
    ALTER TABLE public.vault ADD COLUMN cost INTEGER NOT NULL DEFAULT 100;
    ALTER TABLE public.vault ALTER COLUMN cost DROP DEFAULT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'is_used') THEN
    ALTER TABLE public.vault ADD COLUMN is_used BOOLEAN NOT NULL DEFAULT FALSE;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'claimed_by') THEN
    ALTER TABLE public.vault ADD COLUMN claimed_by TEXT;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'claimed_at') THEN
    ALTER TABLE public.vault ADD COLUMN claimed_at TIMESTAMPTZ;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'created_at') THEN
    ALTER TABLE public.vault ADD COLUMN created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
  END IF;

  -- profile_id: Pflichtfeld in bestehenden LootDrop-Installationen
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'profile_id') THEN
    ALTER TABLE public.vault ADD COLUMN profile_id UUID;

    UPDATE public.vault v
    SET profile_id = (
      SELECT p.id FROM public.profiles p ORDER BY p.created_at NULLS LAST LIMIT 1
    )
    WHERE v.profile_id IS NULL;

    UPDATE public.vault v
    SET profile_id = 'aaaaaaaa-bbbb-cccc-dddd-000000000001'
    WHERE v.profile_id IS NULL;

    ALTER TABLE public.vault ALTER COLUMN profile_id SET NOT NULL;

    IF NOT EXISTS (
      SELECT 1 FROM information_schema.table_constraints
      WHERE constraint_schema = 'public'
        AND table_name = 'vault'
        AND constraint_name = 'vault_profile_id_fkey'
    ) THEN
      ALTER TABLE public.vault
        ADD CONSTRAINT vault_profile_id_fkey
        FOREIGN KEY (profile_id) REFERENCES public.profiles (id) ON DELETE CASCADE;
    END IF;
  END IF;
END $$;

COMMENT ON TABLE  public.vault IS 'Belohnungs-Vault: einlösbare Rewards für Discord-Bot & Web-Frontend';
COMMENT ON COLUMN public.vault.profile_id IS 'B2B-Mandant, dem diese Belohnung gehört';
COMMENT ON COLUMN public.vault.content    IS 'Geheimer Reward-Inhalt (Code, Link, Key) – nur nach Kauf sichtbar';
COMMENT ON COLUMN public.vault.is_used    IS 'FALSE = im Shop verfügbar';
COMMENT ON COLUMN public.vault.claimed_by IS 'Discord-ID des Käufers';

CREATE INDEX IF NOT EXISTS idx_vault_profile_id ON public.vault (profile_id);

CREATE INDEX IF NOT EXISTS idx_vault_available ON public.vault (cost ASC)
  WHERE is_used = FALSE;

CREATE INDEX IF NOT EXISTS idx_vault_claimed_by ON public.vault (claimed_by)
  WHERE claimed_by IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Tabelle: game_events
-- Event-Log vom Minecraft-Plugin (Punkte-Tracking, Audit)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.game_events (
  id               BIGSERIAL   PRIMARY KEY,
  player_id        UUID        NOT NULL REFERENCES public.players (id) ON DELETE CASCADE,
  event_type       TEXT        NOT NULL,
  loot_coins_delta INTEGER     NOT NULL DEFAULT 0,
  metadata         JSONB       NOT NULL DEFAULT '{}',
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.game_events IS 'Vom Minecraft-Plugin gesendete Events (z.B. kill, quest, login)';

CREATE INDEX IF NOT EXISTS idx_game_events_player_id ON public.game_events (player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_game_events_type      ON public.game_events (event_type);

-- ---------------------------------------------------------------------------
-- Tabelle: purchase_logs
-- Unveränderliches Audit-Log für Vault-Käufe
-- vault_id = UUID (muss mit vault.id übereinstimmen)
-- ---------------------------------------------------------------------------

-- Fehlerhafte purchase_logs-Tabelle entfernen (z.B. vault_id war BIGINT statt UUID)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'purchase_logs'
      AND column_name = 'vault_id'
      AND data_type = 'bigint'
  ) THEN
    DROP TABLE public.purchase_logs CASCADE;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.purchase_logs (
  id         BIGSERIAL   PRIMARY KEY,
  player_id  UUID        NOT NULL REFERENCES public.players (id) ON DELETE RESTRICT,
  vault_id   UUID        NOT NULL REFERENCES public.vault (id) ON DELETE RESTRICT,
  discord_id TEXT        NOT NULL,
  cost       INTEGER     NOT NULL CHECK (cost > 0),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.purchase_logs IS 'Audit-Trail: jede Vault-Einlösung wird protokolliert';

CREATE INDEX IF NOT EXISTS idx_purchase_logs_player ON public.purchase_logs (player_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_purchase_logs_discord ON public.purchase_logs (discord_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Trigger: Kauf in purchase_logs protokollieren
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.log_vault_purchase()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_player_id UUID;
  v_cost      INTEGER;
BEGIN
  IF OLD.is_used = FALSE AND NEW.is_used = TRUE THEN
    SELECT id INTO v_player_id
    FROM public.players
    WHERE discord_id = NEW.claimed_by
    LIMIT 1;

    SELECT cost INTO v_cost FROM public.vault WHERE id = NEW.id;

    IF v_player_id IS NOT NULL THEN
      INSERT INTO public.purchase_logs (player_id, vault_id, discord_id, cost)
      VALUES (v_player_id, NEW.id, NEW.claimed_by, v_cost);
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vault_purchase_log ON public.vault;
CREATE TRIGGER trg_vault_purchase_log
  AFTER UPDATE ON public.vault
  FOR EACH ROW EXECUTE FUNCTION public.log_vault_purchase();

-- ---------------------------------------------------------------------------
-- RPC: Spieler aus Minecraft-Plugin anlegen / aktualisieren (Upsert)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_player_from_minecraft(
  p_minecraft_uuid     UUID,
  p_minecraft_username TEXT DEFAULT NULL,
  p_loot_coins         INTEGER DEFAULT NULL
)
RETURNS TABLE (
  player_id   UUID,
  link_code   TEXT,
  loot_coins  INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_link_code TEXT;
  v_coins     INTEGER;
BEGIN
  SELECT p.link_code, p.loot_coins
  INTO v_link_code, v_coins
  FROM public.players p
  WHERE p.minecraft_uuid = p_minecraft_uuid;

  IF NOT FOUND THEN
    v_link_code := public.generate_link_code();

    -- Kollisionen vermeiden (extrem selten)
    WHILE EXISTS (SELECT 1 FROM public.players WHERE players.link_code = v_link_code) LOOP
      v_link_code := public.generate_link_code();
    END LOOP;

    INSERT INTO public.players (minecraft_uuid, minecraft_username, link_code, loot_coins)
    VALUES (
      p_minecraft_uuid,
      p_minecraft_username,
      v_link_code,
      COALESCE(p_loot_coins, 0)
    )
    RETURNING id, players.link_code, players.loot_coins
    INTO player_id, link_code, loot_coins;

    RETURN NEXT;
    RETURN;
  END IF;

  UPDATE public.players p
  SET
    minecraft_username = COALESCE(p_minecraft_username, p.minecraft_username),
    loot_coins         = COALESCE(p_loot_coins, p.loot_coins),
    updated_at         = NOW()
  WHERE p.minecraft_uuid = p_minecraft_uuid
  RETURNING p.id, p.link_code, p.loot_coins
  INTO player_id, link_code, loot_coins;

  RETURN NEXT;
END;
$$;

COMMENT ON FUNCTION public.upsert_player_from_minecraft IS
  'Minecraft-Plugin: Spieler anlegen oder LootCoins/Username synchronisieren';

-- ---------------------------------------------------------------------------
-- RPC: Atomischer Vault-Kauf (optional – Bot nutzt App-Logik mit Rollback)
-- Kann vom Web-Frontend für echte DB-Transaktionen verwendet werden.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.purchase_vault_item(TEXT, BIGINT);

CREATE OR REPLACE FUNCTION public.purchase_vault_item(
  p_discord_id TEXT,
  p_vault_id   UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_player_id      UUID;
  v_balance        INTEGER;
  v_cost           INTEGER;
  v_content        TEXT;
  v_rows_vault     INTEGER;
BEGIN
  -- Spieler sperren (verhindert Race Conditions)
  SELECT id, loot_coins
  INTO v_player_id, v_balance
  FROM public.players
  WHERE discord_id = p_discord_id
  FOR UPDATE;

  IF v_player_id IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_linked');
  END IF;

  -- Vault-Item sperren
  SELECT cost, content
  INTO v_cost, v_content
  FROM public.vault
  WHERE id = p_vault_id AND is_used = FALSE
  FOR UPDATE;

  IF v_cost IS NULL THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'not_available');
  END IF;

  IF v_balance < v_cost THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'insufficient_coins');
  END IF;

  -- Coins abziehen
  UPDATE public.players
  SET loot_coins = loot_coins - v_cost
  WHERE id = v_player_id AND loot_coins = v_balance;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', FALSE, 'reason', 'concurrent_update');
  END IF;

  -- Vault als eingelöst markieren
  UPDATE public.vault
  SET
    is_used    = TRUE,
    claimed_by = p_discord_id,
    claimed_at = NOW()
  WHERE id = p_vault_id AND is_used = FALSE;

  GET DIAGNOSTICS v_rows_vault = ROW_COUNT;

  IF v_rows_vault = 0 THEN
    -- Rollback Coins
    UPDATE public.players SET loot_coins = v_balance WHERE id = v_player_id;
    RETURN jsonb_build_object('success', FALSE, 'reason', 'claim_failed');
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'content', v_content,
    'new_balance', v_balance - v_cost
  );
END;
$$;

COMMENT ON FUNCTION public.purchase_vault_item IS
  'Atomischer Kauf: LootCoins abziehen + Vault-Item claimen in einer Transaktion';

-- Trigger: claimed_at automatisch setzen wenn is_used = true
CREATE OR REPLACE FUNCTION public.set_vault_claimed_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.is_used = TRUE AND OLD.is_used = FALSE THEN
    NEW.claimed_at := COALESCE(NEW.claimed_at, NOW());
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_vault_claimed_at ON public.vault;
CREATE TRIGGER trg_vault_claimed_at
  BEFORE UPDATE ON public.vault
  FOR EACH ROW EXECUTE FUNCTION public.set_vault_claimed_at();

-- ---------------------------------------------------------------------------
-- Row Level Security (RLS)
-- Service Role Key des Bots umgeht RLS automatisch.
-- Policies schützen direkten Zugriff über Anon/Authenticated Keys (Web).
-- ---------------------------------------------------------------------------
ALTER TABLE public.players       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profiles      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.vault         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.game_events   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_logs ENABLE ROW LEVEL SECURITY;

-- Bestehende Policies entfernen (idempotent bei Re-Run)
DROP POLICY IF EXISTS "players_service_full_access"   ON public.players;
DROP POLICY IF EXISTS "profiles_service_full_access"  ON public.profiles;
DROP POLICY IF EXISTS "vault_service_full_access"     ON public.vault;
DROP POLICY IF EXISTS "game_events_service_full_access" ON public.game_events;
DROP POLICY IF EXISTS "purchase_logs_service_full_access" ON public.purchase_logs;
DROP POLICY IF EXISTS "vault_public_read_available"   ON public.vault;
DROP POLICY IF EXISTS "players_read_own_by_discord"   ON public.players;

-- Service-Role / Backend: voller Zugriff (explizit für authenticated backend calls)
CREATE POLICY "players_service_full_access" ON public.players
  FOR ALL TO authenticated, service_role
  USING (TRUE) WITH CHECK (TRUE);

CREATE POLICY "profiles_service_full_access" ON public.profiles
  FOR ALL TO authenticated, service_role
  USING (TRUE) WITH CHECK (TRUE);

CREATE POLICY "vault_service_full_access" ON public.vault
  FOR ALL TO authenticated, service_role
  USING (TRUE) WITH CHECK (TRUE);

CREATE POLICY "game_events_service_full_access" ON public.game_events
  FOR ALL TO authenticated, service_role
  USING (TRUE) WITH CHECK (TRUE);

CREATE POLICY "purchase_logs_service_full_access" ON public.purchase_logs
  FOR ALL TO authenticated, service_role
  USING (TRUE) WITH CHECK (TRUE);

-- Web-Frontend: verfügbare Vault-Items lesen (ohne content – nur Metadaten)
-- Hinweis: content bleibt für anon gesperrt; Frontend sollte nur id/name/cost/is_used laden
CREATE POLICY "vault_public_read_available" ON public.vault
  FOR SELECT TO anon, authenticated
  USING (is_used = FALSE);

-- Grants für Supabase API-Rollen
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.players       TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.profiles      TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.vault         TO authenticated, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.game_events   TO authenticated, service_role;
GRANT SELECT                         ON public.purchase_logs TO authenticated, service_role;

-- Anon/Web: nur Shop-Metadaten, NIEMALS den geheimen Reward-Inhalt (content)
GRANT SELECT (id, name, description, cost, is_used, created_at) ON public.vault TO anon;

GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.ensure_demo_profile() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.generate_link_code()              TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.upsert_player_from_minecraft(UUID, TEXT, INTEGER) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.purchase_vault_item(TEXT, UUID) TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Demo-Daten – Discord-Bot sofort testbar
-- ---------------------------------------------------------------------------

-- Demo-Spieler (noch nicht mit Discord verknüpft)
-- Link-Code: DEMO1234  →  /link DEMO1234 im Discord
INSERT INTO public.players (minecraft_uuid, minecraft_username, link_code, loot_coins)
VALUES (
  '550e8400-e29b-41d4-a716-446655440000',
  'DemoSpieler',
  'DEMO1234',
  5000
)
ON CONFLICT (minecraft_uuid) DO UPDATE
SET
  link_code  = EXCLUDED.link_code,
  loot_coins = EXCLUDED.loot_coins,
  updated_at = NOW()
WHERE public.players.discord_id IS NULL;

-- Zweiter Demo-Spieler mit mehr Coins (bereits verknüpft simuliert – optional)
INSERT INTO public.players (minecraft_uuid, minecraft_username, link_code, loot_coins)
VALUES (
  '550e8400-e29b-41d4-a716-446655440001',
  'ReicherSpieler',
  'RICH5678',
  50000
)
ON CONFLICT (minecraft_uuid) DO UPDATE
SET
  link_code  = EXCLUDED.link_code,
  loot_coins = EXCLUDED.loot_coins,
  updated_at = NOW()
WHERE public.players.discord_id IS NULL;

-- Demo-Belohnungen im Vault (optional – nur wenn ein Profil existiert)
DO $$
DECLARE
  v_profile_id UUID;
BEGIN
  v_profile_id := public.ensure_demo_profile();

  IF v_profile_id IS NULL THEN
    RAISE NOTICE 'Vault-Demo-Daten übersprungen: Kein Eintrag in public.profiles. Bot funktioniert trotzdem – Belohnungen manuell anlegen oder create-demo-profile.sql ausführen.';
    RETURN;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'Amazon Gutschein 5€') THEN
    INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
    VALUES (v_profile_id, 'Amazon Gutschein 5€', 'Digitaler Gutscheincode für Amazon.de', 'AMZN-DEMO-XXXX-YYYY-ZZZZ', 500, FALSE);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'Steam Key – Indie Bundle') THEN
    INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
    VALUES (v_profile_id, 'Steam Key – Indie Bundle', 'Einlösbar auf store.steampowered.com', 'STEAM-DEMO-ABCD-EFGH-IJKL', 1200, FALSE);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'Discord Nitro 1 Monat') THEN
    INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
    VALUES (v_profile_id, 'Discord Nitro 1 Monat', 'Promo-Link für Discord Nitro Basic', 'https://discord.gift/demo-nitro-link', 2500, FALSE);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'Premium Crate Key') THEN
    INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
    VALUES (v_profile_id, 'Premium Crate Key', 'Ingame-Schlüssel für Premium-Kiste', 'CRATE-KEY-DEMO-9999', 800, FALSE);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.vault WHERE name = 'LootDrop VIP Badge') THEN
    INSERT INTO public.vault (profile_id, name, description, content, cost, is_used)
    VALUES (v_profile_id, 'LootDrop VIP Badge', 'Exklusives VIP-Abzeichen auf dem Server', 'VIP-BADGE-UNLOCK-DEMO', 10000, FALSE);
  END IF;

  RAISE NOTICE 'Demo-Vault-Einträge für Profil % angelegt.', v_profile_id;
END $$;

-- ---------------------------------------------------------------------------
-- Schnelltest-Checkliste (nach Ausführung dieses Scripts):
-- ---------------------------------------------------------------------------
-- 1. Discord-Bot starten (SUPABASE_KEY = Service Role Key!)
-- 2. /link DEMO1234        → Account verknüpfen
-- 3. /points               → 5.000 LootCoins anzeigen
-- 4. /shop                 → 5 Belohnungen mit Kauf-Buttons
-- 5. Button klicken        → Reward-Content als ephemeral Nachricht
-- =============================================================================
