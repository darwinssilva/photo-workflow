require "date"
require "time"

require_relative "email_client"
require_relative "state_store"
require_relative "trello_client"

module PhotoWorkflow
  class TrelloReminderEmail
    GALLERY_KIND = "gallery"
    EDITING_KIND = "editing"
    PAYMENT_KIND = "payment"
    EXTRA_PAYMENT_KIND = "extra_payment"

    def initialize(trello_client: TrelloClient.new, email_client: EmailClient.new, state_store: StateStore.new(path: ENV.fetch("TRELLO_REMINDER_STATE_PATH", "data/trello_reminders.json")), today: Date.today)
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
      sent_count = reminder_configs.sum { |config| send_due_reminders(config, state) }
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

    def send_due_reminders(config, state)
      trello_client.list_cards(config.fetch(:list_id)).count do |card|
        reminder_due?(card, config) && send_reminder(card, config, state)
      end
    end

    def reminder_due?(card, config)
      return false if card["closed"] || card["dueComplete"]
      return true unless config.fetch(:due_required, true)

      due_date = card_due_date(card)
      return false unless due_date

      today >= due_date + config.fetch(:trigger_offset_days)
    end

    def send_reminder(card, config, state)
      key = state_key(card, config)
      return false if reminder_sent_today?(card, config, state)

      email_client.deliver_text(
        to: recipients,
        subject: config.fetch(:subject) + " - " + card.fetch("name", ""),
        body: reminder_body(card, config)
      )

      state[key] = {
        "card_id" => card.fetch("id"),
        "kind" => config.fetch(:kind),
        "card_name" => card.fetch("name", ""),
        "due" => card["due"],
        "reminder_date" => today.iso8601,
        "sent_at" => Time.now.utc.iso8601
      }
      puts "Reminder email sent for #{card.fetch("name", card.fetch("id"))}"
      true
    rescue StandardError => error
      warn "Reminder email failed for #{card.fetch("name", card.fetch("id"))}: #{error.message}"
      false
    end

    def reminder_body(card, config)
      due_date = card_due_date(card)

      [
        "Ola!",
        "",
        reminder_message(config, due_date),
        "",
        "Card: #{card.fetch("name", "")}",
        "Lista: #{config.fetch(:list_name)}",
        optional_line("Data de referencia", format_date(due_date)),
        "Link: #{card["shortUrl"] || card["url"]}",
        "",
        "Descricao:",
        blank_string?(card["desc"]) ? "(sem descricao)" : card["desc"],
        "",
        "Atenciosamente,",
        env_value("EMAIL_FROM_NAME", "Photo Workflow")
      ].join("\n")
    end

    def reminder_message(config, due_date)
      case config.fetch(:kind)
      when GALLERY_KIND
        "Este ensaio esta aguardando galeria ha 2 dias desde #{format_date(due_date)}."
      when EDITING_KIND
        "Este ensaio esta aguardando edicao ha 15 dias desde #{format_date(due_date)}."
      when PAYMENT_KIND
        "Este card ainda esta em Aguardando pagamento."
      when EXTRA_PAYMENT_KIND
        "Este card ainda esta em Aguardando pagamento extra."
      end
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
      value = ENV[name]
      return fallback if blank_string?(value)

      value
    end

    def blank_string?(value)
      value.to_s.strip.empty?
    end
  end
end
