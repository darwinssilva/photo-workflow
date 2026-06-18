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

## Secrets

Configure estes secrets no repositorio do GitHub:

```text
GOOGLE_CALENDAR_ID
GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET
GOOGLE_REFRESH_TOKEN
TRELLO_KEY
TRELLO_TOKEN
TRELLO_LIST_ID
TRELLO_GALLERY_LIST_ID
TRELLO_EDITING_LIST_ID
```

Secrets opcionais para WhatsApp Cloud API:

```text
WHATSAPP_ENABLED
WHATSAPP_ACCESS_TOKEN
WHATSAPP_PHONE_NUMBER_ID
WHATSAPP_TO
WHATSAPP_TEMPLATE_NAME
WHATSAPP_TEMPLATE_LANGUAGE
WHATSAPP_TEMPLATE_VARIABLES
WHATSAPP_GRAPH_API_VERSION
```

Secrets opcionais para confirmacao por e-mail:

```text
EMAIL_ENABLED
SMTP_HOST
SMTP_PORT
SMTP_DOMAIN
SMTP_USERNAME
SMTP_PASSWORD
SMTP_STARTTLS
SMTP_AUTH
EMAIL_FROM
EMAIL_FROM_NAME
EMAIL_SUBJECT_PREFIX
EMAIL_BODY_TEMPLATE
REMINDER_EMAIL_TO
```

## Variaveis opcionais

```text
EVENT_SUMMARY_PATTERN=.
EXCLUDED_EVENT_SUMMARY_PATTERN=^(Agenda fechada|teste)$
DAYS_AHEAD=180
DELIVERY_DAYS_AFTER_EVENT=0
STATE_PATH=data/calendar_event_syncs.json
TRELLO_REMINDER_STATE_PATH=data/trello_reminders.json
GALLERY_REMINDER_DAYS_AFTER_SESSION=2
EDITING_REMINDER_DAYS_AFTER_SESSION=15
HTTP_OPEN_TIMEOUT=10
HTTP_READ_TIMEOUT=30
HTTP_RETRIES=2
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
```

O script `bin/send_trello_reminders` usa a data `due` do card como referencia:

- cards em `Aguardando Galeria`: envia lembrete quando passaram 2 dias do `due`;
- cards em `Aguardando Edicao`: envia lembrete quando passaram 15 dias do `due`;
- o arquivo `data/trello_reminders.json` evita reenviar o mesmo lembrete para o mesmo card e mesma data.

Para achar IDs de board/listas, abra:

```text
https://api.trello.com/1/boards/TRELLO_BOARD_ID/lists?key=TRELLO_KEY&token=TRELLO_TOKEN
```

## WhatsApp Cloud API

Quando `WHATSAPP_ENABLED=true`, o script envia uma mensagem somente quando cria um card novo.

Template recomendado:

```text
Nome: ensaio_agendado_sucesso
Idioma: pt_BR
Categoria: Utility
Corpo:
Ola, {{1}}!
Seu ensaio foi agendado com sucesso.

Ensaio: {{2}}
Data: {{3}}
Horario: {{4}}
Local: {{5}}
Card no Trello: {{6}}
```

Secrets recomendados:

```text
WHATSAPP_ENABLED=true
WHATSAPP_PHONE_NUMBER_ID=ID_DO_NUMERO_DA_META
WHATSAPP_ACCESS_TOKEN=TOKEN_DA_META
WHATSAPP_TO=5511999999999
WHATSAPP_TEMPLATE_NAME=ensaio_agendado_sucesso
WHATSAPP_TEMPLATE_LANGUAGE=pt_BR
WHATSAPP_TEMPLATE_VARIABLES=client_name,summary,event_date,event_time,location,trello_link
WHATSAPP_GRAPH_API_VERSION=v24.0
```

`WHATSAPP_TO` aceita mais de um telefone separado por virgula:

```text
WHATSAPP_TO=5511999999999,5511888888888
```

Variaveis disponiveis para `WHATSAPP_TEMPLATE_VARIABLES`:

```text
client_name,summary,start,end,event_date,event_time,weekday,location,description,calendar_link,trello_link
```

`client_name` tenta extrair o nome nesta ordem: sufixo do titulo apos ` - `, linha `Nome:` da descricao e nome de participante da agenda.

Se quiser um texto mais enxuto para notificacao interna, um template curto que funciona bem e:

```text
Novo ensaio confirmado.
Cliente: {{1}}
Quando: {{2}} as {{3}}
Onde: {{4}}
Trello: {{5}}
```

Com:

```text
WHATSAPP_TEMPLATE_VARIABLES=client_name,event_date,event_time,location,trello_link
```

## Confirmacao por e-mail

Quando `EMAIL_ENABLED=true`, o script envia confirmacao para o cliente quando cria um card novo.
Se um evento ja tinha sido sincronizado antes da funcao de e-mail existir, o proximo sync envia uma vez e grava `email_notified_at` no state.
O e-mail inclui um anexo `ensaio.ics` para o cliente adicionar o ensaio ao calendario.

Secrets recomendados para Gmail:

```text
EMAIL_ENABLED=true
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_DOMAIN=gmail.com
SMTP_USERNAME=seuemail@gmail.com
SMTP_PASSWORD=SENHA_DE_APP_DO_GMAIL
SMTP_STARTTLS=true
SMTP_AUTH=plain
EMAIL_FROM=seuemail@gmail.com
EMAIL_FROM_NAME="Nome do Studio"
EMAIL_SUBJECT_PREFIX="Confirmacao de ensaio"
```

Mensagem padrao:

```text
Ola!

Seu ensaio foi agendado com sucesso.

Ensaio: {{summary}}
Data: {{start}}
Local: {{location}}

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
```

## Lembretes por e-mail

Quando `EMAIL_ENABLED=true`, o workflow `Send Trello Reminders` roda uma vez por dia e envia e-mails internos para `REMINDER_EMAIL_TO`.
Se `REMINDER_EMAIL_TO` nao for configurado, o destinatario padrao e `EMAIL_FROM`.

Secrets recomendados:

```text
EMAIL_ENABLED=true
REMINDER_EMAIL_TO=operacao@example.com
TRELLO_GALLERY_LIST_ID=69026faa813ce18fe16387e7
TRELLO_EDITING_LIST_ID=69026fe3e95b323354f27f6d
```
