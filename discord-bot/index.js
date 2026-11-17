import {
  AttachmentBuilder,
  Client,
  MessageFlags,
  GatewayIntentBits,
  REST,
  Routes,
  SlashCommandBuilder
} from 'discord.js';
import { createCanvas } from '@napi-rs/canvas';

const required = [
  'DISCORD_BOT_TOKEN',
  'DISCORD_APPLICATION_ID',
  'DISCORD_GUILD_ID',
  'DISCORD_RESULTS_CHANNEL_ID',
  'DISCORD_ADMIN_ROLE_IDS',
  'SUPABASE_URL',
  'SUPABASE_SERVICE_ROLE_KEY'
];
const missing = required.filter(name => !process.env[name]?.trim());
if (missing.length) {
  console.error('Variáveis obrigatórias ausentes:', missing.join(', '));
  process.exit(1);
}

const botToken = process.env.DISCORD_BOT_TOKEN.trim();
const appId = process.env.DISCORD_APPLICATION_ID.trim();
const guildId = process.env.DISCORD_GUILD_ID.trim();
const resultChannelId = process.env.DISCORD_RESULTS_CHANNEL_ID.trim();
const adminRoleIds = new Set(
  process.env.DISCORD_ADMIN_ROLE_IDS.split(',').map(value => value.trim()).filter(Boolean)
);
const supabaseUrl = process.env.SUPABASE_URL.replace(/\/+$/, '');
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY.trim();
const PAGE_SIZE = 1000;
const CANDIDATES_PER_IMAGE = 16;

const command = new SlashCommandBuilder()
  .setName('publicar-resultado')
  .setDescription('Publica a imagem da apuração final da eleição encerrada.');

function hasAdminRole(interaction) {
  const roleData = interaction.member?.roles;
  const roles = Array.isArray(roleData)
    ? roleData
    : roleData?.cache
      ? [...roleData.cache.keys()]
      : [];
  return roles.some(roleId => adminRoleIds.has(roleId));
}

function makeUrl(table, params) {
  const url = new URL(`${supabaseUrl}/rest/v1/${table}`);
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, String(value));
  }
  return url;
}

async function restRequest(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      ...(options.headers || {})
    }
  });

  if (!response.ok) {
    const detail = (await response.text()).slice(0, 500);
    console.error('Supabase REST error:', response.status, detail);
    throw new Error('Não foi possível consultar a apuração no Supabase.');
  }
  return response;
}

async function fetchRows(table, params) {
  const rows = [];
  for (let offset = 0; offset < 100000; offset += PAGE_SIZE) {
    const url = makeUrl(table, params);
    const response = await restRequest(url, {
      headers: {
        Range: `${offset}-${offset + PAGE_SIZE - 1}`,
        'Range-Unit': 'items'
      }
    });
    const page = await response.json();
    if (!Array.isArray(page)) throw new Error('Resposta inesperada do Supabase.');
    rows.push(...page);
    if (page.length < PAGE_SIZE) return rows;
  }
  throw new Error('A apuração excede o limite de leitura configurado.');
}

async function countRows(table, filters) {
  const url = makeUrl(table, { select: 'id', ...filters });
  const response = await restRequest(url, {
    method: 'HEAD',
    headers: {
      Range: '0-0',
      'Range-Unit': 'items',
      Prefer: 'count=exact'
    }
  });
  const contentRange = response.headers.get('content-range') || '';
  const match = contentRange.match(/\/(\d+|\*)$/);
  if (!match || match[1] === '*') throw new Error('Não foi possível contar os registros da eleição.');
  return Number(match[1]);
}

async function loadFinalResults() {
  const configRows = await fetchRows('election_config', {
    select: 'status,election_display_date,quorum_pct,majority_rule,runoff_enabled',
    id: 'eq.1',
    limit: '1'
  });
  const config = configRows[0];
  if (!config) throw new Error('Configuração da eleição não encontrada.');
  if (config.status !== 'closed') {
    throw new Error('A apuração só pode ser publicada depois que a eleição for encerrada.');
  }

  const [offices, eligibleVoters] = await Promise.all([
    fetchRows('election_offices', {
      select: 'id,name,sort_order,round',
      active: 'eq.true',
      order: 'sort_order.asc,name.asc'
    }),
    countRows('voters', { eligible: 'eq.true' })
  ]);
  if (!offices.length) throw new Error('Não há cargos ativos para publicar.');

  const officeFilter = `in.(${offices.map(office => office.id).join(',')})`;
  const [candidates, ballots, participations] = await Promise.all([
    fetchRows('candidates', {
      select: 'id,office_id,number,name,party,active,runoff_eligible',
      office_id: officeFilter,
      active: 'eq.true',
      order: 'number.asc'
    }),
    fetchRows('ballots', {
      select: 'office_id,round,kind,candidate_id',
      office_id: officeFilter
    }),
    Promise.all(offices.map(async office => ({
      officeId: office.id,
      round: office.round,
      count: await countRows('participation', {
        office_id: `eq.${office.id}`,
        round: `eq.${office.round}`
      })
    })))
  ]);

  const participationByOffice = new Map(
    participations.map(item => [`${item.officeId}:${item.round}`, item.count])
  );

  const reports = offices.map(office => {
    const officeBallots = ballots.filter(ballot =>
      ballot.office_id === office.id && ballot.round === office.round
    );
    const valid = officeBallots.filter(ballot => ballot.kind === 'candidate').length;
    const blank = officeBallots.filter(ballot => ballot.kind === 'blank').length;
    const nullVotes = officeBallots.filter(ballot => ballot.kind === 'null').length;
    const participants = participationByOffice.get(`${office.id}:${office.round}`) || 0;

    const officeCandidates = candidates
      .filter(candidate =>
        candidate.office_id === office.id &&
        (office.round === 1 || candidate.runoff_eligible)
      )
      .map(candidate => {
        const votes = officeBallots.filter(ballot =>
          ballot.kind === 'candidate' && ballot.candidate_id === candidate.id
        ).length;
        return {
          ...candidate,
          votes,
          pct: valid === 0 ? 0 : (100 * votes) / valid
        };
      })
      .sort((a, b) => b.votes - a.votes || a.number.localeCompare(b.number, 'pt-BR', { numeric: true }));

    const first = officeCandidates[0];
    const secondVotes = officeCandidates[1]?.votes || 0;
    const quorumOk = participants * 100 >= Number(config.quorum_pct || 0) * eligibleVoters;
    let majorityWon = false;
    if (first?.votes > 0) {
      if (config.majority_rule === 'plurality') majorityWon = first.votes > secondVotes;
      else if (config.majority_rule === 'absolute_valid') majorityWon = first.votes * 2 > valid;
      else majorityWon = first.votes * 2 > eligibleVoters;
    }
    const winner = quorumOk && majorityWon ? first : null;
    const needsRunoff = !winner && quorumOk &&
      Boolean(config.runoff_enabled) && office.round === 1 &&
      officeCandidates.length >= 2;

    let outcome = 'Sem vencedor pela regra de maioria configurada.';
    if (!quorumOk) outcome = 'Quórum não atingido.';
    else if (winner) outcome = `Vencedor: ${winner.name}`;
    else if (needsRunoff) outcome = 'Segundo turno necessário.';

    return {
      ...office,
      participants,
      total: officeBallots.length,
      valid,
      blank,
      nullVotes,
      candidates: officeCandidates,
      quorumOk,
      winner,
      needsRunoff,
      outcome
    };
  });

  // Revalida após as contagens para não publicar se um administrador reabrir a eleição durante a consulta.
  const finalCheck = await fetchRows('election_config', {
    select: 'status',
    id: 'eq.1',
    limit: '1'
  });
  if (finalCheck[0]?.status !== 'closed') {
    throw new Error('A eleição foi reaberta durante a consulta. Nenhum resultado foi publicado.');
  }

  return { config, eligibleVoters, reports };
}

function formatDate(value) {
  if (!value) return 'Data não informada';
  const date = new Date(`${String(value).slice(0, 10)}T00:00:00Z`);
  return new Intl.DateTimeFormat('pt-BR', { dateStyle: 'long', timeZone: 'UTC' }).format(date);
}

function fitText(context, text, maxWidth) {
  let value = String(text ?? '');
  if (context.measureText(value).width <= maxWidth) return value;
  while (value.length > 1 && context.measureText(`${value}…`).width > maxWidth) {
    value = value.slice(0, -1);
  }
  return `${value}…`;
}

function renderOfficePage(report, config, eligibleVoters, pageIndex, pageCount) {
  const width = 1200;
  const start = pageIndex * CANDIDATES_PER_IMAGE;
  const pageCandidates = report.candidates.slice(start, start + CANDIDATES_PER_IMAGE);
  const rowHeight = 74;
  const height = 610 + Math.max(pageCandidates.length, 1) * rowHeight;
  const canvas = createCanvas(width, height);
  const context = canvas.getContext('2d');

  context.fillStyle = '#f1f4f9';
  context.fillRect(0, 0, width, height);
  context.fillStyle = '#173b73';
  context.fillRect(0, 0, width, 190);

  context.fillStyle = '#ffffff';
  context.font = 'bold 42px Arial';
  context.fillText('APURAÇÃO FINAL', 58, 72);
  context.font = '24px Arial';
  context.fillText(formatDate(config.election_display_date), 60, 118);
  context.font = 'bold 32px Arial';
  context.fillText(fitText(context, report.name, 1080), 60, 166);

  context.fillStyle = '#ffffff';
  context.fillRect(50, 215, 1100, 150);
  context.fillStyle = '#17202d';
  context.font = 'bold 26px Arial';
  context.fillText(`${report.round}º turno`, 76, 258);
  context.font = '20px Arial';
  context.fillText(`Votos: ${report.total}   Válidos: ${report.valid}   Brancos: ${report.blank}   Nulos: ${report.nullVotes}`, 76, 300);
  context.fillText(`Participação: ${report.participants} de ${eligibleVoters}`, 76, 336);

  context.fillStyle = report.winner ? '#e7f5eb' : '#fff4d6';
  context.fillRect(50, 382, 1100, 66);
  context.fillStyle = '#17202d';
  context.font = 'bold 23px Arial';
  context.fillText(fitText(context, report.outcome, 1040), 76, 423);

  context.fillStyle = '#17202d';
  context.font = 'bold 22px Arial';
  const pageText = pageCount > 1 ? `CANDIDATOS · PÁGINA ${pageIndex + 1}/${pageCount}` : 'CANDIDATOS';
  context.fillText(pageText, 60, 495);

  let y = 520;
  if (!pageCandidates.length) {
    context.font = '22px Arial';
    context.fillText('Nenhuma candidatura ativa para este cargo.', 60, y + 36);
  }
  for (const candidate of pageCandidates) {
    context.fillStyle = '#ffffff';
    context.fillRect(50, y, 1100, 64);
    context.fillStyle = '#173b73';
    context.font = 'bold 21px Arial';
    context.fillText(fitText(context, `${candidate.number} · ${candidate.name}`, 750), 72, y + 27);
    context.fillStyle = '#596273';
    context.font = '18px Arial';
    context.fillText(fitText(context, candidate.party || 'Sem partido informado', 720), 72, y + 52);
    context.fillStyle = '#17202d';
    context.font = 'bold 20px Arial';
    context.textAlign = 'right';
    context.fillText(`${candidate.votes} voto(s) · ${candidate.pct.toFixed(2)}%`, 1125, y + 38);
    context.textAlign = 'left';

    const barX = 785;
    const barY = y + 48;
    const barWidth = 300;
    context.fillStyle = '#e0e6ef';
    context.fillRect(barX, barY, barWidth, 7);
    context.fillStyle = '#27a844';
    context.fillRect(barX, barY, Math.max(0, barWidth * candidate.pct / 100), 7);
    y += rowHeight;
  }

  context.fillStyle = '#596273';
  context.font = '16px Arial';
  const footerY = height - 24;
  context.fillText('Urna Eletrônica · Resultado agregado após o encerramento', 60, footerY);
  if (pageCount > 1) {
    context.textAlign = 'right';
    context.fillText(`Continuação · candidatos ${start + 1}–${start + pageCandidates.length}`, 1140, footerY);
    context.textAlign = 'left';
  }

  return canvas.toBuffer('image/png');
}

function makeFileName(name, pageIndex) {
  const slug = name.normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '') || 'cargo';
  return `resultado-${slug}-${pageIndex + 1}.png`;
}

function renderReports(reports, config, eligibleVoters) {
  return reports.flatMap(report => {
    const pageCount = Math.max(1, Math.ceil(report.candidates.length / CANDIDATES_PER_IMAGE));
    return Array.from({ length: pageCount }, (_, pageIndex) => ({
      officeName: report.name,
      pageIndex,
      buffer: renderOfficePage(report, config, eligibleVoters, pageIndex, pageCount),
      filename: makeFileName(report.name, pageIndex)
    }));
  });
}

async function publish(interaction) {
  await interaction.deferReply({ flags: MessageFlags.Ephemeral });

  if (interaction.guildId !== guildId) {
    return interaction.editReply('Este comando só está disponível no servidor configurado.');
  }
  if (!hasAdminRole(interaction)) {
    return interaction.editReply('Você não tem permissão para publicar a apuração.');
  }

  const channel = await interaction.client.channels.fetch(resultChannelId);
  if (!channel?.isTextBased() || typeof channel.send !== 'function') {
    return interaction.editReply('O canal de resultados configurado não está disponível.');
  }

  const { config, eligibleVoters, reports } = await loadFinalResults();
  const files = renderReports(reports, config, eligibleVoters);
  const firstName = reports[0]?.name || 'eleição';
  const attachmentGroups = [];
  for (let index = 0; index < files.length; index += 10) {
    attachmentGroups.push(files.slice(index, index + 10));
  }

  for (const [index, group] of attachmentGroups.entries()) {
    const discordFiles = group.map(file =>
      new AttachmentBuilder(file.buffer, { name: file.filename })
    );
    await channel.send({
      content: index === 0
        ? `📊 **Apuração final da eleição** · ${firstName}${reports.length > 1 ? ` e mais ${reports.length - 1} cargo(s)` : ''}`
        : 'Continuação da apuração final:',
      files: discordFiles
    });
  }

  return interaction.editReply(`Resultado publicado em <#${resultChannelId}>.`);
}

const client = new Client({ intents: [GatewayIntentBits.Guilds] });
client.once('ready', () => {
  console.log(`Bot conectado como ${client.user.tag}.`);
});

client.on('interactionCreate', async interaction => {
  if (!interaction.isChatInputCommand() || interaction.commandName !== 'publicar-resultado') return;
  try {
    await publish(interaction);
  } catch (error) {
    console.error('Falha ao publicar a apuração:', error);
    const message = error instanceof Error ? error.message : 'Erro inesperado.';
    if (interaction.deferred || interaction.replied) {
      await interaction.editReply(message).catch(() => {});
    } else {
      await interaction.reply({ content: message, flags: MessageFlags.Ephemeral }).catch(() => {});
    }
  }
});

async function start() {
  const rest = new REST({ version: '10' }).setToken(botToken);
  await rest.put(Routes.applicationGuildCommands(appId, guildId), {
    body: [command.toJSON()]
  });
  console.log('Comando /publicar-resultado registrado no servidor.');
  await client.login(botToken);
}

start().catch(error => {
  console.error('Não foi possível iniciar o bot:', error);
  process.exit(1);
});
