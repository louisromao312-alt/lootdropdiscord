const { SlashCommandBuilder } = require('discord.js');
const supabase = require('../lib/supabase');
const { infoEmbed, errorEmbed } = require('../utils/embeds');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('points')
    .setDescription('Zeigt deinen aktuellen LootCoins-Kontostand an.'),

  async execute(interaction) {
    const discordId = interaction.user.id;

    await interaction.deferReply({ ephemeral: true });

    // Spieler anhand der Discord-ID laden
    const { data: player, error } = await supabase
      .from('players')
      .select('loot_coins')
      .eq('discord_id', discordId)
      .maybeSingle();

    if (error) {
      console.error('[points] Abfrage fehlgeschlagen:', error.message);
      return interaction.editReply({
        embeds: [errorEmbed('Fehler', 'Kontostand konnte nicht geladen werden.')],
      });
    }

    if (!player) {
      return interaction.editReply({
        embeds: [
          errorEmbed(
            'Nicht verknüpft',
            'Dein Discord-Account ist noch nicht verknüpft.\nNutze `/link <code>` mit dem Code aus dem Spiel.',
          ),
        ],
      });
    }

    return interaction.editReply({
      embeds: [
        infoEmbed(
          'Dein LootCoins-Kontostand',
          `Du hast **${player.loot_coins.toLocaleString('de-DE')}** LootCoins.`,
        ),
      ],
    });
  },
};
