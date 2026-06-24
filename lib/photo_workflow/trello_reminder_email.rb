require "date"
require "time"

require_relative "email_client"
require_relative "settings"
require_relative "state_store"
require_relative "trello_client"

module PhotoWorkflow
  class TrelloReminderEmail
    GALLERY_KIND = "gallery"
    EDITING_KIND = "editing"
    PAYMENT_KIND = "payment"
    EXTRA_PAYMENT_KIND = "extra_payment"

    def initialize(trello_client: TrelloClient.new, email_client: EmailClient.new, state_store: StateStore.new(path: Settings.value("TRELLO_REMINDER_STATE_PATH", "data/trello_reminders.json")), today: Date.today)
      @trello_client = trello_client
      @email_client = email_client
      @state_store = state_store
      @today = today
    end

    def call
      unless email_client.enabled?
        puts "Reminder email disabled."
        return
      end

      state = state_store.all
      due_groups = due_reminders_by_config(state)
      sent_count = send_daily_summary(due_groups, state)
      state_store.save(state)
      puts "Trello reminder finished. #{sent_count} email(s) sent."
    end

    private

    attr_reader :trello_client, :email_client, :state_store, :today

    def reminder_configs
      [
        {
          kind: GALLERY_KIND,
          list_id: required_env("TRELLO_GALLERY_LIST_ID"),
          list_name: "Aguardando Galeria",
          trigger_offset_days: env_integer("GALLERY_REMINDER_DAYS_AFTER_SESSION", 2),
          subject: "Lembrete: ensaio aguardando galeria ha 2 dias"
        },
        {
          kind: EDITING_KIND,
          list_id: required_env("TRELLO_EDITING_LIST_ID"),
          list_name: "Aguardando Edicao",
          trigger_offset_days: env_integer("EDITING_REMINDER_DAYS_AFTER_SESSION", 15),
          subject: "Lembrete: ensaio aguardando edicao ha 15 dias"
        },
        {
          kind: PAYMENT_KIND,
          list_id: env_value("TRELLO_PAYMENT_LIST_ID", "6a330b1331176309a014e4e7"),
          list_name: "Aguardando pagamento",
          due_required: false,
          subject: "Lembrete: card aguardando pagamento"
        },
        {
          kind: EXTRA_PAYMENT_KIND,
          list_id: env_value("TRELLO_EXTRA_PAYMENT_LIST_ID", "6a33287ddf1a985770fec18c"),
          list_name: "Aguardando pagamento extra",
          due_required: false,
          subject: "Lembrete: card aguardando pagamento extra"
        }
      ]
    end

    def due_reminders_by_config(state)
      reminder_configs.each_with_object({}) do |config, groups|
        cards = trello_client.list_cards(config.fetch(:list_id)).select do |card|
          reminder_due?(card, config) && !reminder_sent_today?(card, config, state)
        end
        groups[config.fetch(:kind)] = {
          config: config,
          cards: cards
        }
      end
    end

    def reminder_due?(card, config)
      return false if card["closed"] || card["dueComplete"]
      return true unless config.fetch(:due_required, true)

      due_date = card_due_date(card)
      return false unless due_date

      today >= due_date + config.fetch(:trigger_offset_days)
    end

    def send_daily_summary(due_groups, state)
      groups_with_cards = due_groups.values.select { |entry| entry.fetch(:cards).any? }
      return 0 if groups_with_cards.empty?

      email_client.deliver_text(
        to: recipients,
        subject: daily_subject(groups_with_cards),
        body: daily_body(groups_with_cards)
      )

      mark_groups_as_sent(groups_with_cards, state)
      puts "Consolidated reminder email sent with #{groups_with_cards.sum { |entry| entry.fetch(:cards).size }} card(s)."
      1
    rescue StandardError => error
      warn "Consolidated reminder email failed: #{error.message}"
      0
    end

    def mark_groups_as_sent(groups_with_cards, state)
      sent_at = Time.now.utc.iso8601
      groups_with_cards.each do |entry|
        config = entry.fetch(:config)
        entry.fetch(:cards).each do |card|
          state[state_key(card, config)] = {
            "card_id" => card.fetch("id"),
            "kind" => config.fetch(:kind),
            "card_name" => card.fetch("name", ""),
            "due" => card["due"],
            "reminder_date" => today.iso8601,
            "sent_at" => sent_at
          }
        end
      end
    end

    def daily_subject(groups_with_cards)
      base = "Pendências para hoje"
      total_cards = groups_with_cards.sum { |entry| entry.fetch(:cards).size }
      "#{base} - #{today.strftime("%d/%m/%Y")} (#{pluralize(total_cards, "pendência", "pendências")})"
    end

    def daily_body(groups_with_cards)
      total_cards = groups_with_cards.sum { |entry| entry.fetch(:cards).size }
      lines = [
        "Olá!",
        "",
        "Separei os pontos que merecem atenção hoje para ajudar você a priorizar o dia.",
        pending_summary_sentence(total_cards),
        "",
        "Quando resolver um item, é só atualizar ou mover o card no Trello.",
        ""
      ]

      groups_with_cards.each do |entry|
        config = entry.fetch(:config)
        cards = entry.fetch(:cards)

        lines << section_title_for(config, cards.size)
        lines << next_step_for(config)
        lines << ""

        cards.each_with_index do |card, index|
          lines.concat(card_summary_lines(card, config, index + 1))
          lines << ""
        end
      end

      lines.concat([
        "Qualquer ajuste feito no Trello já entra no próximo resumo.",
        "",
        "Bom trabalho!",
        env_value("EMAIL_FROM_NAME", "Photo Workflow")
      ])

      lines.join("\n")
    end

    def section_title_for(config, count)
      title = case config.fetch(:kind)
              when GALLERY_KIND
                "Galerias para acompanhar"
              when EDITING_KIND
                "Edições para revisar"
              when PAYMENT_KIND
                "Pagamentos pendentes"
              when EXTRA_PAYMENT_KIND
                "Pagamentos extras pendentes"
              else
                config.fetch(:list_name)
              end

      "#{title} - #{pluralize(count, "item", "itens")}"
    end

    def next_step_for(config)
      case config.fetch(:kind)
      when GALLERY_KIND
        "Próximo passo: conferir se a galeria já pode ser enviada ao cliente."
      when EDITING_KIND
        "Próximo passo: verificar o andamento da edição e destravar o que estiver parado."
      when PAYMENT_KIND
        "Próximo passo: confirmar cobrança, retorno do cliente ou baixa do pagamento."
      when EXTRA_PAYMENT_KIND
        "Próximo passo: confirmar cobrança, retorno do cliente ou baixa do pagamento extra."
      else
        "Próximo passo: revisar os cards abaixo."
      end
    end

    def card_summary_lines(card, config, position)
      due_date = card_due_date(card)
      notes = card_notes(card)

      [
        "#{position}. #{card.fetch("name", "(sem nome)")}",
        "   #{item_action_for(config)}",
        optional_indented_line(date_label_for(config), format_date(due_date)),
        optional_indented_line("Tempo em aberto", overdue_label(due_date, config)),
        optional_indented_line("Detalhes", notes),
        "   Trello: #{card["shortUrl"] || card["url"]}"
      ].compact
    end

    def item_action_for(config)
      case config.fetch(:kind)
      when GALLERY_KIND
        "Conferir galeria e combinar o envio."
      when EDITING_KIND
        "Checar edição e atualizar o status do card."
      when PAYMENT_KIND
        "Verificar pagamento e registrar a situação."
      when EXTRA_PAYMENT_KIND
        "Verificar pagamento extra e registrar a situação."
      else
        "Revisar este card."
      end
    end

    def date_label_for(config)
      case config.fetch(:kind)
      when PAYMENT_KIND, EXTRA_PAYMENT_KIND
        "Data de referência"
      else
        "Data do ensaio"
      end
    end

    def overdue_label(due_date, config)
      return nil unless due_date && config.fetch(:due_required, true)

      days = (today - due_date).to_i
      return nil unless days.positive?

      pluralize(days, "dia", "dias")
    end

    def card_notes(card)
      desc = card["desc"].to_s
      return nil if blank_string?(desc)

      notes = extract_calendar_description(desc)
      notes = strip_generated_description(desc) if blank_string?(notes)
      notes = notes.lines.map(&:strip).reject(&:empty?).first(4).join(" | ")
      truncate(notes, 360)
    end

    def extract_calendar_description(desc)
      marker = "Descricao da agenda:"
      return nil unless desc.include?(marker)

      after_marker = desc.split(marker, 2).last.to_s
      after_marker.to_s.strip
    end

    def strip_generated_description(desc)
      desc.lines.reject do |line|
        line.match?(/\A(Ensaio criado automaticamente|Titulo:|Status:|Inicio:|Fim:|Local:|Link da agenda:|Criador:|Organizador:|Participantes:)/)
      end.join.strip
    end

    def truncate(text, limit)
      return nil if blank_string?(text)
      return text if text.length <= limit

      text[0, limit - 3].rstrip + "..."
    end

    def card_due_date(card)
      value = card["due"]
      return nil if blank_string?(value)

      Time.parse(value).to_date
    rescue ArgumentError
      nil
    end

    def state_key(card, config)
      [config.fetch(:kind), card.fetch("id"), today.iso8601].join(":")
    end

    def reminder_sent_today?(card, config, state)
      state[state_key(card, config)] || state[legacy_state_key(card, config)]
    end

    def legacy_state_key(card, config)
      [config.fetch(:kind), card.fetch("id"), card["due"], today.iso8601].join(":")
    end

    def recipients
      value = env_value("REMINDER_EMAIL_TO") || env_value("EMAIL_FROM")
      raise "Missing ENV REMINDER_EMAIL_TO or EMAIL_FROM" if blank_string?(value)

      value.split(",").map(&:strip).reject(&:empty?)
    end

    def format_date(date)
      date&.strftime("%d/%m/%Y").to_s
    end

    def optional_line(label, value)
      return nil if blank_string?(value)

      "#{label}: #{value}"
    end

    def optional_indented_line(label, value)
      return nil if blank_string?(value)

      "   #{label}: #{value}"
    end

    def pending_summary_sentence(total_cards)
      if total_cards == 1
        "Há 1 pendência em aberto em #{today.strftime("%d/%m/%Y")}."
      else
        "Há #{total_cards} pendências em aberto em #{today.strftime("%d/%m/%Y")}."
      end
    end

    def pluralize(count, singular, plural)
      "#{count} #{count == 1 ? singular : plural}"
    end

    def env_integer(name, fallback)
      env_value(name, fallback).to_i
    end

    def required_env(name)
      value = env_value(name)
      raise "Missing ENV #{name}" if blank_string?(value)

      value
    end

    def env_value(name, fallback = nil)
      Settings.value(name, fallback)
    end

    def blank_string?(value)
      value.to_s.strip.empty?
    end
  end
end
