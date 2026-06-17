# Photo Workflow

MVP barato para sincronizar ensaios do Google Agenda com Trello.

Fluxo:

1. GitHub Actions roda a cada 30 minutos.
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
Telefone: 11999999999
Pacote: Gestante Premium
Pagamento: Pendente
Observacoes: Levar vestido azul
```

## Trello

Crie uma lista chamada `Agendados` e use o ID dela em `TRELLO_LIST_ID`.

O script arquiva cards usando `closed=true`; ele nao apaga cards definitivamente.

Para achar IDs de board/listas, abra:

```text
https://api.trello.com/1/boards/TRELLO_BOARD_ID/lists?key=TRELLO_KEY&token=TRELLO_TOKEN
```
