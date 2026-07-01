const supabase = require('../lib/supabase');

/**
 * Führt einen atomischen Kauf-Vorgang durch (Coins abziehen + Vault-Item claimen).
 * Bei Fehlern wird ein Rollback versucht.
 *
 * @param {string} discordId - Discord-ID des Käufers
 * @param {number|string} vaultId - Primärschlüssel des Vault-Items
 * @returns {Promise<{ success: true, content: string } | { success: false, reason: string }>}
 */
async function purchaseReward(discordId, vaultId) {
  // Spieler anhand der Discord-ID laden (parametrisierte Abfrage)
  const { data: player, error: playerError } = await supabase
    .from('players')
    .select('discord_id, loot_coins')
    .eq('discord_id', discordId)
    .maybeSingle();

  if (playerError) {
    console.error('[purchase] Spieler-Abfrage fehlgeschlagen:', playerError.message);
    return { success: false, reason: 'Datenbankfehler beim Laden deines Kontos.' };
  }

  if (!player) {
    return { success: false, reason: 'Du bist noch nicht verknüpft. Nutze `/link` im Spiel.' };
  }

  // Verfügbares Vault-Item laden (nur unbenutzte Einträge)
  const { data: reward, error: rewardError } = await supabase
    .from('vault')
    .select('id, cost, content, is_used')
    .eq('id', vaultId)
    .eq('is_used', false)
    .maybeSingle();

  if (rewardError) {
    console.error('[purchase] Vault-Abfrage fehlgeschlagen:', rewardError.message);
    return { success: false, reason: 'Datenbankfehler beim Laden der Belohnung.' };
  }

  if (!reward) {
    return { success: false, reason: 'Diese Belohnung ist nicht mehr verfügbar.' };
  }

  if (player.loot_coins < reward.cost) {
    return { success: false, reason: 'Nicht genug LootCoins!' };
  }

  const previousBalance = player.loot_coins;
  const newBalance = previousBalance - reward.cost;

  // Schritt 1: LootCoins abziehen (Optimistic Lock via eq auf alten Kontostand)
  const { data: updatedPlayer, error: deductError } = await supabase
    .from('players')
    .update({ loot_coins: newBalance })
    .eq('discord_id', discordId)
    .eq('loot_coins', previousBalance)
    .select('loot_coins')
    .maybeSingle();

  if (deductError || !updatedPlayer) {
    console.error('[purchase] Coin-Abzug fehlgeschlagen:', deductError?.message);
    return { success: false, reason: 'Kauf konnte nicht abgeschlossen werden. Bitte erneut versuchen.' };
  }

  // Schritt 2: Vault-Item als eingelöst markieren
  const { data: claimedReward, error: claimError } = await supabase
    .from('vault')
    .update({ is_used: true, claimed_by: discordId })
    .eq('id', vaultId)
    .eq('is_used', false)
    .select('content')
    .maybeSingle();

  if (claimError || !claimedReward) {
    console.error('[purchase] Vault-Update fehlgeschlagen – Rollback wird durchgeführt:', claimError?.message);

    // Rollback: Coins zurückerstatten
    const { error: rollbackError } = await supabase
      .from('players')
      .update({ loot_coins: previousBalance })
      .eq('discord_id', discordId);

    if (rollbackError) {
      console.error('[purchase] KRITISCH – Rollback fehlgeschlagen:', rollbackError.message);
    }

    return { success: false, reason: 'Belohnung konnte nicht eingelöst werden. Deine LootCoins wurden nicht abgezogen.' };
  }

  return { success: true, content: claimedReward.content };
}

module.exports = { purchaseReward };
