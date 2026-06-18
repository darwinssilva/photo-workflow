# Photo Workflow

MVP barato para sincronizar ensaios do Google Agenda com Trello.

Fluxo:

1. GitHub Actions roda a cada 5 minutos.
2. O script busca eventos futuros do Google Agenda.
3. Eventos futuros viram cards no Trello, exceto os que baterem no filtro de exclusao.
4. O arquivo `data/calendar_event_syncs.json` guarda `google_event_id` e `trello_card_id`.
5. Se o evento for editado, o card existente e atualizado em vez de duplicado.
6. Se um evento futuro sair da agenda, o card correspondente e arquivado no Trello.

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
```

## Variaveis opcionais

```text
EVENT_SUMMARY_PATTERN=.
EXCLUDED_EVENT_SUMMARY_PATTERN=^(Agenda fechada|teste)$
DAYS_AHEAD=180
DELIVERY_DAYS_AFTER_EVENT=0
STATE_PATH=data/calendar_event_syncs.json
```

Por padrao, o script aceita qualquer titulo. Use a exclusao para ignorar bloqueios/testes:

```text
EVENT_SUMMARY_PATTERN=.
EXCLUDED_EVENT_SUMMARY_PATTERN=^(Agenda fechada|teste)$
```

## Rodar local

```bash
cp config/sample.env .env
set -a
source .env
set +a
ruby bin/sync_calendar_to_trello
```

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

Para achar IDs de board/listas, abra:

```text
https://api.trello.com/1/boards/TRELLO_BOARD_ID/lists?key=TRELLO_KEY&token=TRELLO_TOKEN
```

## WhatsApp Cloud API

Quando `WHATSAPP_ENABLED=true`, o script envia uma mensagem somente quando cria um card novo.

Template recomendado:

```text
Nome: novo_ensaio_agendado
Idioma: pt_BR
Categoria: Utility
Corpo:
Novo ensaio agendado: {{1}}
Data: {{2}}
Local: {{3}}
```

Secrets recomendados:

```text
WHATSAPP_ENABLED=true
WHATSAPP_PHONE_NUMBER_ID=ID_DO_NUMERO_DA_META
WHATSAPP_ACCESS_TOKEN=TOKEN_DA_META
WHATSAPP_TO=5511999999999
WHATSAPP_TEMPLATE_NAME=novo_ensaio_agendado
WHATSAPP_TEMPLATE_LANGUAGE=pt_BR
WHATSAPP_TEMPLATE_VARIABLES=summary,start,location
WHATSAPP_GRAPH_API_VERSION=v24.0
```

`WHATSAPP_TO` aceita mais de um telefone separado por virgula:

```text
WHATSAPP_TO=5511999999999,5511888888888
```

Variaveis disponiveis para `WHATSAPP_TEMPLATE_VARIABLES`:

```text
summary,start,end,location,description,calendar_link,trello_link
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
EMAIL_FROM_NAME=Nome do Studio
EMAIL_SUBJECT_PREFIX=Confirmacao de ensaio
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
