require "time"

require_relative "http_json"

module PhotoWorkflow
  class WhatsAppClient
    DEFAULT_GRAPH_API_VERSION = "v24.0"
    DEFAULT_TEMPLATE_LANGUAGE = "pt_BR"
    DEFAULT_TEMPLATE_VARIABLES = "summary,start,location"

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
      HttpJson.post_json(
        messages_url,
        headers: {
          "Authorization" => "Bearer #{required_env("WHATSAPP_ACCESS_TOKEN")}"
        },
        body: {
          messaging_product: "whatsapp",
          to: normalize_phone(to),
          type: "template",
          template: {
            name: required_env("WHATSAPP_TEMPLATE_NAME"),
            language: { code: ENV.fetch("WHATSAPP_TEMPLATE_LANGUAGE", DEFAULT_TEMPLATE_LANGUAGE) },
            components: [
              {
                type: "body",
                parameters: variables.map { |value| { type: "text", text: value.to_s } }
              }
            ]
          }
        }
      )
    end

    def template_variables(event, card)
      variable_names.map do |name|
        case name
        when "summary" then event.fetch("summary", "")
        when "start" then formatted_time(event.fetch("start", {}))
        when "end" then formatted_time(event.fetch("end", {}))
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
      value = date_hash["dateTime"] || date_hash["date"]
      return "" unless value

      Time.parse(value).strftime("%d/%m/%Y %H:%M")
    rescue ArgumentError
      value.to_s
    end

    def recipients
      required_env("WHATSAPP_TO").split(",").map(&:strip).reject(&:empty?)
    end

    def normalize_phone(phone)
      phone.gsub(/\D/, "")
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
