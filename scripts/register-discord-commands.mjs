const applicationId = process.env.DISCORD_APPLICATION_ID
const token = process.env.DISCORD_BOT_TOKEN
const guildId = process.env.DISCORD_GUILD_ID

if (!applicationId || !token) throw new Error('DISCORD_APPLICATION_ID and DISCORD_BOT_TOKEN are required')
if (!/^\d{15,22}$/.test(applicationId) || (guildId && !/^\d{15,22}$/.test(guildId))) throw new Error('Discord IDs must be numeric snowflakes')

const command = {
  name: 'clearsplit',
  description: 'Create auditable ClearSplit public-fund drafts',
  options: [
    { type: 1, name: 'help', description: 'Show ClearSplit command help' },
    { type: 1, name: 'bind', description: 'Bind this channel to a ledger', options: [{ type: 3, name: 'code', description: 'One-time group bind code', required: true, min_length: 32, max_length: 32 }] },
    { type: 1, name: 'link', description: 'Link your Discord identity to a ledger member', options: [{ type: 3, name: 'code', description: 'One-time personal link code', required: true, min_length: 32, max_length: 32 }] },
    { type: 1, name: 'expense', description: 'Create a public-fund expense draft', options: [
      { type: 3, name: 'title', description: 'Expense title', required: true, max_length: 120 },
      { type: 4, name: 'amount', description: 'Positive whole-number amount', required: true, min_value: 1, max_value: 999999999 },
    ] },
  ],
}

const base = `https://discord.com/api/v10/applications/${applicationId}`
const endpoint = guildId ? `${base}/guilds/${guildId}/commands` : `${base}/commands`
const response = await fetch(endpoint, {
  method: 'POST',
  headers: { Authorization: `Bot ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify(command),
})
if (!response.ok) throw new Error(`Discord command registration failed (${response.status}): ${await response.text()}`)
const result = await response.json()
console.log(`Registered /${result.name} (${result.id})${guildId ? ' for guild ' + guildId : ' globally'}`)
