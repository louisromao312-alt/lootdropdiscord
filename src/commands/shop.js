const {
  SlashCommandBuilder,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
} = require('discord.js');
const supabase = require('../lib/supabase');
const { infoEmbed, errorEmbed } = require('../utils/embeds');

const MAX_BUTTONS = 25;

module.exports = {
  data: new SlashCommandBuilder()
    .setName('shop')
    .setDescription('Zeigt verfügbare Belohnungen aus dem Vault-Shop an.'),

  async execute(interaction) {
    await interaction.deferReply({ ephemeral: true });

    // Alle unbenutzten Belohnungen aus dem Vault laden
    const { data: rewards, error } = await supabase
      .from('vault')
      .select('id, cost')
      .eq('is_used', false)
      .order('cost', { ascending: true })
      .limit(MAX_BUTTONS);

    if (error) {
      console.error('[shop] Vault-Abfrage fehlgeschlagen:', error.message);
      return interaction.editReply({
        embeds: [errorEmbed('Fehler', 'Shop konnte nicht geladen werden.')],
      });
    }

    if (!rewards || rewards.length === 0) {
      return interaction.editReply({
        embeds: [infoEmbed('Vault-Shop', 'Aktuell sind keine Belohnungen verfügbar.')],
      });
    }

    const rewardList = rewards
      .map((r) => `**Belohnung #${r.id}** — ${r.cost.toLocaleString('de-DE')} LootCoins`)
      .join('\n\n');

    const embed = infoEmbed('Vault-Shop', rewardList).setFooter({
      text: 'Klicke auf einen Button, um eine Belohnung einzulösen.',
    });

    // Buttons in ActionRows (max. 5 Buttons pro Row)
    const rows = [];
    for (let i = 0; i < rewards.length; i += 5) {
      const chunk = rewards.slice(i, i + 5);
      const row = new ActionRowBuilder();

      for (const reward of chunk) {
        row.addComponents(
          new ButtonBuilder()
            .setCustomId(`buy_${reward.id}`)
            .setLabel(`#${reward.id} (${reward.cost} LC)`)
            .setStyle(ButtonStyle.Primary),
        );
      }

      rows.push(row);
    }

    return interaction.editReply({ embeds: [embed], components: rows });
  },
};
