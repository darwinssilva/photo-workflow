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
      base = env_value("REMINDER_EMAIL_DAILY_SUBJECT", "Resumo diario de lembretes Trello")
      total_cards = groups_with_cards.sum { |entry| entry.fetch(:cards).size }
      "#{base} - #{today.strftime("%d/%m/%Y")} (#{total_cards} card(s))"
    end

    def daily_body(groups_with_cards)
      lines = [
        "Ola!",
        "",
        "Segue o resumo diario consolidado dos lembretes de Trello.",
        "Data: #{today.strftime("%d/%m/%Y")}",
        ""
      ]

      groups_with_cards.each do |entry|
        config = entry.fetch(:config)
        cards = entry.fetch(:cards)

        lines << "Situacao: #{config.fetch(:list_name)}"
        lines << "Regra: #{summary_rule_for(config)}"
        lines << "Quantidade: #{cards.size}"
        lines << ""

        cards.each_with_index do |card, index|
          lines.concat(card_summary_lines(card, index + 1))
          lines << ""
        end
      end

      lines.concat([
        "Atenciosamente,",
        env_value("EMAIL_FROM_NAME", "Photo Workflow")
      ])

      lines.join("\n")
    end

    def summary_rule_for(config)
      case config.fetch(:kind)
      when GALLERY_KIND
        "Aguardando galeria ha #{config.fetch(:trigger_offset_days)} dia(s) apos o due."
      when EDITING_KIND
        "Aguardando edicao ha #{config.fetch(:trigger_offset_days)} dia(s) apos o due."
      when PAYMENT_KIND
        "Card presente na lista de pagamento pendente."
      when EXTRA_PAYMENT_KIND
        "Card presente na lista de pagamento extra pendente."
      else
        "Regra nao informada."
      end
    end

    def card_summary_lines(card, position)
      due_date = card_due_date(card)

      [
        "#{position}. #{card.fetch("name", "(sem nome)")}",
        optional_line("Data de referencia", format_date(due_date)),
        "Link: #{card["shortUrl"] || card["url"]}",
        "Descricao: #{blank_string?(card["desc"]) ? "(sem descricao)" : card["desc"]}"
      ].compact
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
