const { purchaseReward } = require('../utils/purchase');
const { successEmbed, errorEmbed } = require('../utils/embeds');

module.exports = {
  name: 'interactionCreate',
  async execute(interaction, client) {
    // Slash-Commands
    if (interaction.isChatInputCommand()) {
      const command = client.commands.get(interaction.commandName);
      if (!command) return;

      try {
        await command.execute(interaction);
      } catch (error) {
        console.error(`[command:${interaction.commandName}]`, error);
        const payload = {
          embeds: [errorEmbed('Fehler', 'Bei der Ausführung ist ein unerwarteter Fehler aufgetreten.')],
          ephemeral: true,
        };

        if (interaction.deferred || interaction.replied) {
          await interaction.editReply(payload).catch(() => {});
        } else {
          await interaction.reply(payload).catch(() => {});
        }
      }
      return;
    }

    // Button-Klicks: buy_<vault_id>
    if (interaction.isButton() && interaction.customId.startsWith('buy_')) {
      await interaction.deferReply({ ephemeral: true });

      const vaultId = interaction.customId.slice('buy_'.length);
      if (!vaultId) {
        return interaction.editReply({
          embeds: [errorEmbed('Fehler', 'Ungültige Button-ID.')],
        });
      }

      const result = await purchaseReward(interaction.user.id, vaultId);

      if (!result.success) {
        return interaction.editReply({
          content: result.reason === 'Nicht genug LootCoins!' ? result.reason : undefined,
          embeds: result.reason !== 'Nicht genug LootCoins!'
            ? [errorEmbed('Kauf fehlgeschlagen', result.reason)]
            : undefined,
        });
      }

      return interaction.editReply({
        embeds: [
          successEmbed(
            'Belohnung eingelöst!',
            `Hier ist dein Reward:\n\n\`\`\`\n${result.content}\n\`\`\``,
          ),
        ],
      });
    }
  },
};
