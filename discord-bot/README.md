# Bot de resultados da Urna

Este serviço registra o comando `/publicar-resultado` no servidor configurado. Um administrador autorizado pode usá-lo para publicar imagens da apuração no canal definido.

## Regras de segurança

- O comando só publica quando `election_config.status = 'closed'`.
- Apenas membros com um dos cargos configurados em `DISCORD_ADMIN_ROLE_IDS` podem publicar.
- O bot consulta somente os cargos ativos, os candidatos ativos, os votos agregados por cargo e a contagem de participações. Não consulta nomes, códigos ou IDs de eleitores.
- O resultado é publicado apenas em `DISCORD_RESULTS_CHANNEL_ID`.
- O segredo `SUPABASE_SERVICE_ROLE_KEY` e o token do bot são lidos apenas do ambiente. Nunca os coloque no GitHub ou em mensagens do Discord.

## Criar o bot no Discord

1. No Discord Developer Portal, crie uma aplicação e adicione um bot.
2. Copie o token do bot e o Application ID.
3. Convide o bot ao servidor com os escopos `bot` e `applications.commands`. Dê permissões de visualizar o canal de resultados, enviar mensagens e anexar arquivos.
4. Copie o ID do servidor, o ID do canal de resultados e o ID de um cargo que identifique os administradores que podem publicar.

## Implantar no Railway

Crie um **serviço separado** apontando para este mesmo repositório e configure o diretório raiz como `/discord-bot`. O comando de inicialização é `npm start`.

Adicione estas variáveis privadas no Railway:

| Variável | Valor |
| --- | --- |
| `DISCORD_BOT_TOKEN` | Token do bot |
| `DISCORD_APPLICATION_ID` | Application ID do Discord |
| `DISCORD_GUILD_ID` | ID do servidor Discord |
| `DISCORD_RESULTS_CHANNEL_ID` | ID do canal onde a imagem será publicada |
| `DISCORD_ADMIN_ROLE_IDS` | ID(s) do(s) cargo(s) administrador, separados por vírgulas |
| `SUPABASE_URL` | URL do projeto Supabase |
| `SUPABASE_SERVICE_ROLE_KEY` | Chave service_role do Supabase |

O serviço registra o comando de servidor ao iniciar. Comandos de servidor ficam disponíveis imediatamente.

## Executar localmente

Use Node.js 22 ou superior. Copie `.env.example` para `.env`, preencha as variáveis e execute:

```sh
npm install
node --env-file=.env index.js
```

Não compartilhe o arquivo `.env`; mantenha-o fora de commits.
