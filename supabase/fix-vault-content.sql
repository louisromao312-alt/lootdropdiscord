-- Schnell-Fix: Spalte "content" auf bestehender vault-Tabelle ergänzen
-- Einmal im Supabase SQL Editor ausführen, wenn schema.sql bei INSERT fehlschlägt.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'content'
  ) THEN
    ALTER TABLE public.vault ADD COLUMN content TEXT;

    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'code') THEN
      UPDATE public.vault SET content = code::text WHERE content IS NULL;
    ELSIF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'vault' AND column_name = 'reward_code') THEN
      UPDATE public.vault SET content = reward_code::text WHERE content IS NULL;
    END IF;

    UPDATE public.vault SET content = 'UNSET-REWARD-' || id::text WHERE content IS NULL;
    ALTER TABLE public.vault ALTER COLUMN content SET NOT NULL;
  END IF;
END $$;
