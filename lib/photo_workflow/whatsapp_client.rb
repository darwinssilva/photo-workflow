require "time"

require_relative "http_json"

module PhotoWorkflow
  class WhatsAppClient
    DEFAULT_GRAPH_API_VERSION = "v24.0"
    DEFAULT_TEMPLATE_LANGUAGE = "pt_BR"
    DEFAULT_TEMPLATE_VARIABLES = "client_name,summary,event_date,event_time,location,trello_link"
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
      ENV.fetch("WHATSAPP_ENABLED", "false").casecmp("true").zero?
    end

    def notify_event_created(event:, card:)
      return unless enabled?

      recipients.each do |recipient|
        send_template_message(
          to: recipient,
          variables: template_variables(event, card)
        )
      end
    end

    private

    def send_template_message(to:, variables:)
      template_payload = {
        name: required_env("WHATSAPP_TEMPLATE_NAME"),
        language: { code: ENV.fetch("WHATSAPP_TEMPLATE_LANGUAGE", DEFAULT_TEMPLATE_LANGUAGE) }
      }

      if variables.any?
        template_payload[:components] = [
          {
            type: "body",
            parameters: variables.map { |value| { type: "text", text: value.to_s } }
          }
        ]
      end

      HttpJson.post_json(
        messages_url,
        headers: {
          "Authorization" => "Bearer #{required_env("WHATSAPP_ACCESS_TOKEN")}"
        },
        body: {
          messaging_product: "whatsapp",
          to: normalize_phone(to),
          type: "template",
          template: template_payload
        }
      )
    end

    def template_variables(event, card)
      variable_names.map do |name|
        case name
        when "client_name" then client_name(event)
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

    def variable_names
      ENV.fetch("WHATSAPP_TEMPLATE_VARIABLES", DEFAULT_TEMPLATE_VARIABLES)
         .split(",")
         .map(&:strip)
         .reject(&:empty?)
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

    def recipients
      required_env("WHATSAPP_TO").split(",").map(&:strip).reject(&:empty?)
    end

    def client_name(event)
      summary_name = event.fetch("summary", "").split(" - ", 2)[1]
      return summary_name.strip unless blank_string?(summary_name)

      described_name = extract_description_field(event["description"], "nome")
      return described_name unless blank_string?(described_name)

      attendee_name(event["attendees"])
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
      return "" if blank_string?(description)

      line = description.each_line.find do |item|
        item.match?(/^#{Regexp.escape(field_name)}\s*:/i)
      end
      return "" unless line

      line.split(":", 2).last.to_s.strip
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
      version = ENV.fetch("WHATSAPP_GRAPH_API_VERSION", DEFAULT_GRAPH_API_VERSION)
      "https://graph.facebook.com/#{version}/#{required_env("WHATSAPP_PHONE_NUMBER_ID")}/messages"
    end

    def required_env(name)
      ENV.fetch(name) { raise "Missing ENV #{name}" }
    end
  end
end
