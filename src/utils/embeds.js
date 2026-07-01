const { EmbedBuilder } = require('discord.js');

const BRAND_COLOR = 0x57f287;
const ERROR_COLOR = 0xed4245;
const INFO_COLOR = 0x5865f2;

function successEmbed(title, description) {
  return new EmbedBuilder()
    .setColor(BRAND_COLOR)
    .setTitle(title)
    .setDescription(description)
    .setTimestamp();
}

function errorEmbed(title, description) {
  return new EmbedBuilder()
    .setColor(ERROR_COLOR)
    .setTitle(title)
    .setDescription(description)
    .setTimestamp();
}

function infoEmbed(title, description) {
  return new EmbedBuilder()
    .setColor(INFO_COLOR)
    .setTitle(title)
    .setDescription(description)
    .setTimestamp();
}

module.exports = { successEmbed, errorEmbed, infoEmbed };
