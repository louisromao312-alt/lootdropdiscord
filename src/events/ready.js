const { REST, Routes } = require('discord.js');

module.exports = {
  name: 'clientReady',
  once: true,
  async execute(client) {
    const commands = [...client.commands.values()].map((cmd) => cmd.data.toJSON());

    const rest = new REST({ version: '10' }).setToken(process.env.DISCORD_TOKEN);

    try {
      console.log(`Registriere ${commands.length} Slash-Command(s)...`);

      await rest.put(Routes.applicationCommands(process.env.DISCORD_CLIENT_ID), {
        body: commands,
      });

      console.log('Slash-Commands erfolgreich registriert.');
    } catch (error) {
      console.error('Slash-Command-Registrierung fehlgeschlagen:', error);
    }

    console.log(`LootDrop-Bot online als ${client.user.tag}`);
  },
};
