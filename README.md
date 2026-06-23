# Photo Workflow

MVP barato para sincronizar ensaios do Google Agenda com Trello.

Fluxo:

1. GitHub Actions roda duas vezes por dia, as 09:17 e 21:17 UTC.
2. O script busca eventos futuros do Google Agenda.
3. Eventos futuros viram cards no Trello, exceto os que baterem no filtro de exclusao.
4. O arquivo `data/calendar_event_syncs.json` guarda `google_event_id` e `trello_card_id`.
5. Se o evento for editado, o card existente e atualizado em vez de duplicado.
6. Se um evento futuro sair da agenda, o card correspondente e arquivado no Trello.
7. Um workflow separado pode enviar lembretes internos por e-mail para cards em listas de galeria/edicao.

## Configuracao

A configuracao operacional fica em `config/settings.json`: IDs de listas, filtros, prazos, assunto dos e-mails, timeouts, webhook e templates.

Use `.env` apenas para secrets e dados locais sensiveis. O arquivo `.env` ainda pode sobrescrever qualquer chave do JSON quando voce precisar ajustar algo sem commitar.

```bash
cp config/sample.env .env
```

Se quiser usar outro arquivo de configuracao, rode com:

```bash
PHOTO_WORKFLOW_CONFIG=config/settings.local.json ruby bin/sync_calendar_to_trello
```

## Secrets

Configure estes secrets no repositorio do GitHub:

```text
GOOGLE_CALENDAR_ID
GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET
GOOGLE_REFRESH_TOKEN
TRELLO_KEY
TRELLO_TOKEN
```

Secrets opcionais para WhatsApp Cloud API:

```text
WHATSAPP_ACCESS_TOKEN
WHATSAPP_PHONE_NUMBER_ID
WHATSAPP_TO
```

Secrets opcionais para confirmacao por e-mail:

```text
SMTP_USERNAME
SMTP_PASSWORD
EMAIL_FROM
EMAIL_BODY_TEMPLATE
REMINDER_EMAIL_TO
```

Secrets opcionais para webhook em tempo quase real:

```text
WEBHOOK_PUBLIC_URL
WEBHOOK_SHARED_TOKEN
GOOGLE_WEBHOOK_CHANNEL_ID
```

## Settings principais

```text
EVENT_SUMMARY_PATTERN=.
EXCLUDED_EVENT_SUMMARY_PATTERN=^(Agenda fechada|teste)$
DAYS_AHEAD=180
DELIVERY_DAYS_AFTER_EVENT=0
NOTIFY_ON_EVENT_UPDATE=true
STATE_PATH=data/calendar_event_syncs.json
TRELLO_REMINDER_STATE_PATH=data/trello_reminders.json
GALLERY_REMINDER_DAYS_AFTER_SESSION=2
EDITING_REMINDER_DAYS_AFTER_SESSION=15
HTTP_OPEN_TIMEOUT=10
HTTP_READ_TIMEOUT=30
HTTP_RETRIES=2
RESEND_ENABLED=false
RESEND_API_KEY=
SMTP_SSL=false
SMTP_OPEN_TIMEOUT=10
SMTP_READ_TIMEOUT=30
SMTP_RETRIES=1
```

Por padrao, o script aceita qualquer titulo. Use a exclusao para ignorar bloqueios/testes:

```text
EVENT_SUMMARY_PATTERN=.
EXCLUDED_EVENT_SUMMARY_PATTERN=^(Agenda fechada|teste)$
```

Se sua conexao oscilar ou a API demorar para responder, ajuste estes limites:

```text
HTTP_OPEN_TIMEOUT=10
HTTP_READ_TIMEOUT=30
HTTP_RETRIES=2
```

O cliente HTTP tenta novamente em timeouts e falhas transitórias de rede antes de abortar.

## Webhook (quase em tempo real)

Agora o projeto tambem suporta webhook do Google Calendar para reduzir a latencia entre criar/editar/cancelar o evento e refletir no Trello.

### Como funciona

1. Um endpoint HTTP recebe notificacoes do Google Calendar.
2. Ao receber notificacao, o sistema busca apenas mudancas desde o ultimo `sync_token`.
3. Eventos novos/alterados criam ou atualizam cards no Trello.
4. Eventos cancelados (ou que deixaram de bater no filtro) arquivam o card correspondente.
5. Se o `sync_token` expirar, o sistema faz um resync completo automaticamente.

### Settings para webhook

```text
WEBHOOK_STATE_PATH=data/google_calendar_webhook_state.json
WEBHOOK_BIND=0.0.0.0
WEBHOOK_PORT=4567
WEBHOOK_PATH=/google-calendar/webhook
WEBHOOK_PUBLIC_URL=https://seu-dominio.com/google-calendar/webhook
WEBHOOK_SHARED_TOKEN=seu-token-compartilhado
GOOGLE_WEBHOOK_CHANNEL_ID=uuid-opcional
GOOGLE_WEBHOOK_TTL_SECONDS=604800
```

### Subir endpoint webhook

```bash
ruby bin/run_google_calendar_webhook
```

### Registrar ou renovar canal no Google

```bash
ruby bin/register_google_calendar_watch
```

Esse comando salva os dados do canal em `data/google_calendar_webhook_state.json`.

### Recomendacao de deploy

- Mantenha o webhook em um endpoint publico HTTPS (VPS, Render, Fly.io, Cloud Run, etc.).
- Continue com o workflow agendado como fallback de seguranca.
- Renove o canal periodicamente (o Google expira canais de watch).

## Rodar local

```bash
cp config/sample.env .env
ruby bin/sync_calendar_to_trello
```

O script ja carrega o arquivo `.env` automaticamente. Se voce preferir exportar no shell, mantenha valores com espacos entre aspas.

## Padrao recomendado no Google Agenda

Titulo:

```text
Ensaio Gestante - Maria Silva
```

Descricao:

```text
Email: cliente@example.com
Telefone: 11999999999
Pacote: Gestante Premium
Pagamento: Pendente
Observacoes: Levar vestido azul
```

O e-mail de confirmacao usa o primeiro e-mail encontrado na descricao do evento.
Se nao encontrar, tenta usar o primeiro participante da agenda.

## Trello

Crie uma lista chamada `Agendados` e use o ID dela em `TRELLO_LIST_ID`.

O script arquiva cards usando `closed=true`; ele nao apaga cards definitivamente.

Para lembretes internos por e-mail, configure os IDs das listas:

```text
TRELLO_GALLERY_LIST_ID=69026faa813ce18fe16387e7
TRELLO_EDITING_LIST_ID=69026fe3e95b323354f27f6d
TRELLO_PAYMENT_LIST_ID=6a330b1331176309a014e4e7
TRELLO_EXTRA_PAYMENT_LIST_ID=6a33287ddf1a985770fec18c
```

O script `bin/send_trello_reminders` usa a data `due` do card como referencia:

- cards em `Aguardando Galeria`: envia lembrete quando passaram 2 dias do `due`;
- cards em `Aguardando Edicao`: envia lembrete quando passaram 15 dias do `due`;
- cards em `Aguardando pagamento`: envia lembrete diario enquanto estiverem nessa lista;
- cards em `Aguardando pagamento extra`: envia lembrete diario enquanto estiverem nessa lista;
- o arquivo `data/trello_reminders.json` evita reenviar o mesmo lembrete mais de uma vez no mesmo dia.

O sync tambem ordena essas listas pela data `due`, deixando os ensaios mais antigos primeiro.

Para achar IDs de board/listas, abra:

```text
https://api.trello.com/1/boards/TRELLO_BOARD_ID/lists?key=TRELLO_KEY&token=TRELLO_TOKEN
```

## WhatsApp Cloud API

Quando `WHATSAPP_ENABLED=true` em `config/settings.json`, o script envia mensagem em criacao e em atualizacao relevante de evento.

Templates usados pelo codigo:

```text
Criacao: ensaio_agendado
Atualizacao: ensaio_alterado
Idioma: pt_BR
Variaveis (ordem): client_name, summary, event_date
```

Secrets recomendados:

```text
WHATSAPP_PHONE_NUMBER_ID=ID_DO_NUMERO_DA_META
WHATSAPP_ACCESS_TOKEN=TOKEN_DA_META
```

O numero do cliente e extraido da descricao do evento da agenda. Exemplos aceitos:

```text
Telefone: 11 99999-9999
WhatsApp: +55 11 99999-9999
Celular: (11) 99999-9999
```

`client_name` tenta extrair o nome nesta ordem: sufixo do titulo apos ` - `, linha `Nome:` da descricao e nome de participante da agenda.

## Confirmacao por e-mail

Quando `EMAIL_ENABLED=true` em `config/settings.json`, o script envia confirmacao para o cliente quando cria um card novo.
Se um evento ja tinha sido sincronizado antes da funcao de e-mail existir, o proximo sync envia uma vez e grava `email_notified_at` no state.
O e-mail inclui um anexo `ensaio.ics` para o cliente adicionar o ensaio ao calendario.

Secrets recomendados para Gmail:

```text
SMTP_USERNAME=seuemail@gmail.com
SMTP_PASSWORD=SENHA_DE_APP_DO_GMAIL
EMAIL_FROM=seuemail@gmail.com
```

Mensagem padrao:

```text
Ola!

Seu ensaio foi agendado com sucesso.

Ensaio: {{summary}}
Nome: {{client_name}}
Modelo: {{model_name}}
Tipo: {{shoot_type}}
Data: {{start}}
Local: {{location}}
Referencias: {{references}}

Tambem anexamos um arquivo ensaio.ics para adicionar este ensaio ao seu calendario.

Se precisar ajustar alguma informacao, responda este e-mail.
```

Para personalizar, configure `EMAIL_BODY_TEMPLATE` usando estas variaveis:

```text
{{summary}}
{{start}}
{{end}}
{{location}}
{{description}}
{{calendar_link}}
{{trello_link}}
{{client_name}}
{{model_name}}
{{shoot_type}}
{{references}}
```

## Lembretes por e-mail

Quando `EMAIL_ENABLED=true` em `config/settings.json`, o workflow `Send Trello Reminders` roda uma vez por dia e envia e-mails internos para `REMINDER_EMAIL_TO`.
Se `REMINDER_EMAIL_TO` nao for configurado, o destinatario padrao e `EMAIL_FROM`.

Secrets recomendados:

```text
REMINDER_EMAIL_TO=operacao@example.com
```
