const { SlashCommandBuilder } = require('discord.js');
const supabase = require('../lib/supabase');
const { successEmbed, errorEmbed } = require('../utils/embeds');

module.exports = {
  data: new SlashCommandBuilder()
    .setName('link')
    .setDescription('Verknüpft deinen Discord-Account mit deinem Minecraft-Account.')
    .addStringOption((option) =>
      option
        .setName('code')
        .setDescription('Den Link-Code aus dem Spiel.')
        .setRequired(true)
        .setMinLength(4)
        .setMaxLength(32),
    ),

  async execute(interaction) {
    const code = interaction.options.getString('code', true).trim();
    const discordId = interaction.user.id;

    await interaction.deferReply({ ephemeral: true });

    // Prüfen, ob der User bereits verknüpft ist
    const { data: existingPlayer, error: existingError } = await supabase
      .from('players')
      .select('discord_id')
      .eq('discord_id', discordId)
      .maybeSingle();

    if (existingError) {
      console.error('[link] Bestehende Verknüpfung prüfen fehlgeschlagen:', existingError.message);
      return interaction.editReply({
        embeds: [errorEmbed('Fehler', 'Datenbankfehler. Bitte später erneut versuchen.')],
      });
    }

    if (existingPlayer) {
      return interaction.editReply({
        embeds: [errorEmbed('Bereits verknüpft', 'Dein Discord-Account ist bereits mit einem Spieler verknüpft.')],
      });
    }

    // Spieler anhand des Link-Codes suchen (parametrisierte Abfrage)
    const { data: player, error: lookupError } = await supabase
      .from('players')
      .select('id, link_code')
      .eq('link_code', code)
      .maybeSingle();

    if (lookupError) {
      console.error('[link] Code-Suche fehlgeschlagen:', lookupError.message);
      return interaction.editReply({
        embeds: [errorEmbed('Fehler', 'Datenbankfehler. Bitte später erneut versuchen.')],
      });
    }

    if (!player) {
      return interaction.editReply({
        embeds: [errorEmbed('Ungültiger Code', 'Dieser Link-Code existiert nicht oder ist abgelaufen.')],
      });
    }

    // Verknüpfung speichern: discord_id setzen, link_code entfernen
    const { error: updateError } = await supabase
      .from('players')
      .update({ discord_id: discordId, link_code: null })
      .eq('id', player.id)
      .eq('link_code', code);

    if (updateError) {
      console.error('[link] Verknüpfung speichern fehlgeschlagen:', updateError.message);
      return interaction.editReply({
        embeds: [errorEmbed('Fehler', 'Verknüpfung konnte nicht gespeichert werden.')],
      });
    }

    return interaction.editReply({
      embeds: [
        successEmbed(
          'Account verknüpft!',
          `Dein Discord-Account wurde erfolgreich mit deinem Minecraft-Account verbunden.\n\nNutze \`/points\`, um deinen Kontostand zu sehen, oder \`/shop\`, um Belohnungen einzulösen.`,
        ),
      ],
    });
  },
};
