require "time"

require_relative "http_json"
require_relative "settings"

module PhotoWorkflow
  class WhatsAppClient
    DEFAULT_GRAPH_API_VERSION = "v24.0"
    DEFAULT_TEMPLATE_LANGUAGE = "pt_BR"
    PHONE_LABELS = %w[telefone whatsapp celular fone phone].freeze
    PHONE_PATTERN = /(?:\+?55\s*)?(?:\(?\d{2}\)?\s*)?(?:9\d{4}|\d{4})[-\s]?\d{4}/
    TEMPLATE_CONFIGS = {
      created: {
        name: "ensaio_agendado",
        language: "pt_BR",
        # Keep positional order aligned with approved template:
        # {{1}} service, {{2}} date, {{3}} name
        variable_names: %w[shoot_type event_date client_name]
      },
      updated: {
        name: "ensaio_alterado",
        language: "pt_BR",
        named_parameters: true,
        variable_names: %w[client_name shoot_type event_date event_time],
        parameter_names: %w[nome servico data data_nov]
      },
      cancelled: {
        name: "ensaio_cancelado",
        language: "pt_BR",
        named_parameters: true,
        variable_names: %w[client_name shoot_type event_date],
        parameter_names: %w[client_name shoot_type event_date]
      }
    }.freeze
    DESCRIPTION_FIELD_LABELS = %w[nome modelo email telefone tipo referencias origem titulo].freeze
    WEEKDAY_NAMES = {
      0 => "domingo",
      1 => "segunda-feira",
      2 => "terca-feira",
      3 => "quarta-feira",
      4 => "quinta-feira",
      5 => "sexta-feira",
      6 => "sabado"
    }.freeze

    def enabled?
      Settings.boolean("WHATSAPP_ENABLED", false)
    end

    def notify_event_created(event:, card:)
      notify_event(event: event, card: card, kind: :created)
    end

    def notify_event_updated(event:, card:)
      notify_event(event: event, card: card, kind: :updated)
    end

    def notify_event_cancelled(event:, card:)
      notify_event(event: event, card: card, kind: :cancelled)
    end

    def notify_event(event:, card:, kind:)
      return unless enabled?

      to_number = client_phone(event)
      unless to_number
        puts "WhatsApp notification skipped for #{event.fetch("summary", event.fetch("id", "unknown"))}: missing phone in event description"
        return
      end

      send_template_message(
        to: to_number,
        template_config: template_config(kind),
        variables: template_variables(event, card, kind: kind)
      )
      puts "WhatsApp notification sent for #{event.fetch("summary", event.fetch("id", "unknown"))} to #{normalize_phone(to_number)}"
    rescue HttpJson::Error => error
      warn "WhatsApp notification failed for #{event.fetch("summary", event.fetch("id", "unknown"))}: HTTP #{error.code} - #{error.body}"
      raise
    end

    private

    def send_template_message(to:, template_config:, variables:)
      template_payload = {
        name: template_config.fetch(:name),
        language: { code: template_config.fetch(:language, DEFAULT_TEMPLATE_LANGUAGE) }
      }

      if variables.any?
        template_payload[:components] = [
          {
            type: "body",
            parameters: build_template_parameters(template_config, variables)
          }
        ]
      end

      normalized_to = normalize_phone(to)
      puts "WhatsApp request: template=#{template_payload[:name]} to=#{normalized_to} params=#{template_payload.dig(:components, 0, :parameters)&.map { |param| param[:parameter_name] || param[:text] }.inspect}"

      response = HttpJson.post_json(
        messages_url,
        headers: {
          "Authorization" => "Bearer #{required_env("WHATSAPP_ACCESS_TOKEN")}"
        },
        body: {
          messaging_product: "whatsapp",
          to: normalized_to,
          type: "template",
          template: template_payload
        }
      )

      puts "WhatsApp API response: #{response.inspect}"
      response
    end

    def template_variables(event, card, kind:)
      template_config(kind).fetch(:variable_names).map do |name|
        case name
        when "client_name" then client_name(event)
        when "shoot_type" then shoot_type(event)
        when "summary" then event.fetch("summary", "")
        when "start" then formatted_time(event.fetch("start", {}))
        when "end" then formatted_time(event.fetch("end", {}))
        when "event_date" then formatted_date(event.fetch("start", {}))
        when "event_time" then formatted_clock(event.fetch("start", {}))
        when "weekday" then formatted_weekday(event.fetch("start", {}))
        when "location" then event.fetch("location", "")
        when "description" then event.fetch("description", "")
        when "calendar_link" then event.fetch("htmlLink", "")
        when "trello_link" then card["shortUrl"] || card["url"] || ""
        else
          event[name] || ""
        end
      end
    end

    def build_template_parameters(template_config, variables)
      variable_names = template_config.fetch(:variable_names)
      if template_config.fetch(:named_parameters, false)
        parameter_names = template_config.fetch(:parameter_names, variable_names)
        parameter_names.zip(variables).map do |name, value|
          {
            type: "text",
            parameter_name: name,
            text: value.to_s
          }
        end
      else
        variables.map { |value| { type: "text", text: value.to_s } }
      end
    end

    def template_config(kind)
      TEMPLATE_CONFIGS.fetch(kind, TEMPLATE_CONFIGS.fetch(:created))
    end

    def formatted_time(date_hash)
      time = parsed_time(date_hash)
      return "" unless time

      if date_hash["date"]
        time.strftime("%d/%m/%Y")
      else
        time.strftime("%d/%m/%Y %H:%M")
      end
    rescue ArgumentError
      raw_date_value(date_hash).to_s
    end

    def formatted_date(date_hash)
      time = parsed_time(date_hash)
      return "" unless time

      time.strftime("%d/%m/%Y")
    rescue ArgumentError
      raw_date_value(date_hash).to_s
    end

    def formatted_clock(date_hash)
      return "" if date_hash["date"]

      time = parsed_time(date_hash)
      return "" unless time

      time.strftime("%H:%M")
    rescue ArgumentError
      ""
    end

    def formatted_weekday(date_hash)
      time = parsed_time(date_hash)
      return "" unless time

      WEEKDAY_NAMES.fetch(time.wday)
    rescue ArgumentError
      ""
    end

    def client_phone(event)
      phone_from_desc = extract_phone_from_description(event["description"])
      return phone_from_desc unless blank_string?(phone_from_desc)

      # Try to extract from summary: "2025-01-15 - João Silva - (11) 98765-4321"
      parts = event.fetch("summary", "").split(" - ")
      if parts.length >= 3
        phone_from_summary = detect_phone(parts[-1])
        return phone_from_summary unless blank_string?(phone_from_summary)
      end

      nil
    end

    def extract_phone_from_description(description)
      return "" if blank_string?(description)

      PHONE_LABELS.each do |label|
        value = extract_description_field(description, label)
        phone = detect_phone(value)
        return phone unless blank_string?(phone)
      end

      detect_phone(description)
    end

    def detect_phone(text)
      return "" if blank_string?(text)

      raw = text.to_s.match(PHONE_PATTERN)&.[](0)
      return "" if blank_string?(raw)

      digits = normalize_phone(raw)
      return "" if digits.length < 10

      digits.start_with?("55") ? digits : "55#{digits}"
    end

    def client_name(event)
      described_name = extract_description_field(event["description"], "nome")
      return described_name unless blank_string?(described_name)

      summary_name = event.fetch("summary", "").split(" - ", 2)[1]
      return summary_name.strip unless blank_string?(summary_name)

      attendee_name(event["attendees"])
    end

    def shoot_type(event)
      described_type = extract_description_field(event["description"], "tipo")
      return described_type unless blank_string?(described_type)

      event.fetch("summary", "")
    end

    def attendee_name(attendees)
      return "" unless attendees.is_a?(Array)

      attendees.each do |attendee|
        display_name = attendee["displayName"].to_s.strip
        return display_name unless display_name.empty?
      end

      ""
    end

    def extract_description_field(description, field_name)
      fields = description_fields(description)
      fields.fetch(normalize_description_key(field_name), "")
    end

    def description_fields(description)
      return {} if blank_string?(description)

      labels = DESCRIPTION_FIELD_LABELS.join("|")
      pattern = /(?:^|\s)(#{labels})\s*:\s*(.*?)(?=(?:\s*(?:#{labels})\s*:\s*)|\z)/i

      description.to_s.scan(pattern).each_with_object({}) do |(label, value), fields|
        normalized_label = normalize_description_key(label)
        fields[normalized_label] ||= value.to_s.strip
      end
    end

    def normalize_description_key(key)
      key.to_s
         .downcase
         .tr("áàâãäéèêëíìîïóòôõöúùûüç", "aaaaaeeeeiiiiooooouuuuc")
         .gsub(/[^a-z0-9]+/, "_")
         .gsub(/\A_+|_+\z/, "")
    end

    def blank_string?(value)
      value.to_s.strip.empty?
    end

    def normalize_phone(phone)
      phone.gsub(/\D/, "")
    end

    def parsed_time(date_hash)
      value = raw_date_value(date_hash)
      return nil unless value

      Time.parse(value)
    end

    def raw_date_value(date_hash)
      date_hash["dateTime"] || date_hash["date"]
    end

    def messages_url
      version = Settings.value("WHATSAPP_GRAPH_API_VERSION", DEFAULT_GRAPH_API_VERSION)
      "https://graph.facebook.com/#{version}/#{required_env("WHATSAPP_PHONE_NUMBER_ID")}/messages"
    end

    def required_env(name)
      Settings.required(name)
    end
  end
end
